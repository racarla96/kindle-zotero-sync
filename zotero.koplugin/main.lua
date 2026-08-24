--[[--
Entry point for zotero.koplugin: registers a "Zotero" menu in FileManager,
orchestrates metadata + document sync, and provides a minimal collections
-> items -> open browser. Structured after kosync.koplugin's main.lua
(WidgetContainer:extend, LuaSettings-backed settings, MultiInputDialog for
credentials, NetworkMgr hooks for retrying queued work on reconnect) but
this plugin is a library browser rather than a per-document sync, so it's
registered for FileManager (is_doc_only = false), not the reader.

Sync is opt-in per item: a full sync always refreshes metadata for the
whole library (cheap, needed so "Browse library" has something to select
from), but a document is only downloaded once the user taps it in
browseItems() to mark it `wanted` — see LibraryCache:setWanted/
getPendingAttachments. Nothing downloads on its own just because it
exists in the library. It's also filtered to formats KOReader can
actually open (LibraryCache's SUPPORTED_EXTENSIONS) — not just PDF.

WebDAV is entirely optional and off by default: without it (or with the
"Enable WebDAV PDF downloads" checkbox in showCredentialsDialog() left
unchecked), metadata sync and browsing still work, items can still be
marked wanted, but nothing ever downloads — see isWebDAVConfigured().

NOTE on things that need on-device verification (no real KOReader install
was available to test against while writing this):
  - The `Menu` widget usage below (item_table shape, onMenuSelect
    signature, `dim = true` to render an unsupported-format row as
    disabled, and `menu:updateItems()` to redraw a row's label in place
    after toggling selection) follows the common pattern seen across
    KOReader plugins, but wasn't exercised against a live UIManager.
  - `ReaderUI:showReader(path)` is the standard way plugins hand a file
    off to the reader; double-check the exact call against a recent
    KOReader checkout if it doesn't open PDFs as expected.
  - showCredentialsDialog() grafts a `CheckButton` onto the
    `MultiInputDialog` via `dialog:addWidget()` so the WebDAV toggle
    lives in the same screen as the credential fields. Both APIs are
    real (verified against KOReader's source), but this specific
    combination — and whether `parent = dialog` is the right target for
    the checkbox to trigger a redraw on tap — was never exercised live.
  - The same dialog's "Test connection" button adds a second `buttons`
    row below Cancel/Save — multi-row `buttons` is a normal, source-
    confirmed case for this dialog family (unlike the `separator` field
    that turned out not to exist on `Menu` item rows — see the fixed
    bug noted in CLAUDE.md), so this one is lower-risk, but it does
    call `ZoteroClient:get_library_version` and
    `WebDAVClient:test_connection` from inside the dialog's own event
    handling, which — like everything else in this file — hasn't run
    on a live device yet.
--]]

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local LibraryCache = require("LibraryCache")
local WebDAVClient = require("WebDAVClient")
local ZoteroClient = require("ZoteroClient")
local ZoteroQueue = require("ZoteroQueue")

local Zotero = WidgetContainer:extend{
    name = "zotero",
    is_doc_only = false,
    title = _("Zotero"),
    settings_file = DataStorage:getSettingsDir() .. "/zotero.lua",
    updated = nil,
    settings = nil,
}

Zotero.default_settings = {
    api_key = nil,
    user_id = nil,
    webdav_enabled = false,
    webdav_url = nil,
    webdav_user = nil,
    webdav_password = nil,
}

--- Directory documents are extracted into: a "zotero" subfolder inside
-- whatever KOReader considers its home/library directory —
-- filemanagerutil.getDefaultDir() (respects the user's own "home_dir"
-- setting if they configured one in KOReader, otherwise falls back to
-- Device.home_dir — "/mnt/us" on Kindle, verified against KOReader's
-- actual source rather than assumed). Nested in a subfolder instead of
-- dropped straight into the root so synced items don't scatter loose
-- through the user's existing library, but it still shows up
-- automatically under Home -> zotero/ with no extra configuration.
local function documentDir()
    local dir = filemanagerutil.getDefaultDir() .. "/zotero"
    if not lfs.attributes(dir, "mode") then
        lfs.mkdir(dir)
    end
    return dir
end

function Zotero:loadSettings()
    if not Zotero.settings_obj then
        Zotero.settings_obj = LuaSettings:open(self.settings_file)
    end
    self.settings = Zotero.settings_obj:readSetting("settings", Zotero.default_settings)
end

function Zotero:onFlushSettings()
    if self.updated then
        Zotero.settings_obj:flush()
        self.updated = nil
    end
end

function Zotero:init()
    self:loadSettings()
    -- Drain any queued downloads whenever we come back online.
    self.onNetworkConnected = self._onNetworkConnected
    self.ui.menu:registerToMainMenu(self)
end

function Zotero:isConfigured()
    return self.settings.api_key and self.settings.api_key ~= ""
        and self.settings.user_id and self.settings.user_id ~= ""
end

--- WebDAV fields being filled in isn't enough on its own — downloads only
-- happen once the user has also explicitly checked the "Enable WebDAV PDF
-- downloads" box in showCredentialsDialog(). Keeps "I don't want this
-- yet" an explicit, persisted choice rather than something inferred from
-- which text fields happen to be non-empty.
function Zotero:isWebDAVConfigured()
    return self.settings.webdav_enabled
        and self.settings.webdav_url and self.settings.webdav_url ~= ""
        and self.settings.webdav_user and self.settings.webdav_user ~= ""
        and self.settings.webdav_password and self.settings.webdav_password ~= ""
end

function Zotero:addToMainMenu(menu_items)
    menu_items.zotero = {
        text = _("Zotero"),
        sub_item_table = {
            {
                text = _("Sync now"),
                keep_menu_open = true,
                callback = function() self:sync(true) end,
            },
            {
                text = _("Browse library"),
                keep_menu_open = true,
                callback = function() self:browseCollections() end,
                separator = true,
            },
            {
                text = _("Configure credentials"),
                keep_menu_open = true,
                callback = function() self:showCredentialsDialog() end,
                separator = true,
            },
            {
                text_func = function()
                    local pending = #LibraryCache:getPendingAttachments()
                    local retrying = ZoteroQueue:count()
                    if self.active_download_key then pending = pending + 1 end
                    if pending == 0 and retrying == 0 then
                        return _("Downloads")
                    end
                    return T(_("Downloads (%1 pending, %2 retrying)"), pending, retrying)
                end,
                keep_menu_open = true,
                callback = function() self:showDownloadsStatus() end,
            },
        },
    }
end

--- Credentials + the WebDAV enable toggle, in one screen. MultiInputDialog
-- itself only does text fields — the checkbox is a separate CheckButton
-- widget grafted on via MultiInputDialog:addWidget() (both are real
-- KOReader APIs, verified against source, but this specific combination
-- wasn't exercised on a live device — see the NOTE at the top of this
-- file). `checkbox` is forward-declared like `dialog` so the Save
-- button's closure (defined before the checkbox exists) can still read
-- its final `.checked` state once the user actually taps Save.
function Zotero:showCredentialsDialog()
    local CheckButton = require("ui/widget/checkbutton")
    local dialog
    local checkbox

    -- Shared by Save and Test connection so both read the fields the same
    -- way, whether or not the user has hit Save yet.
    local function readFields()
        local api_key, user_id, webdav_url, webdav_user, webdav_password =
            unpack(dialog:getFields())
        local function trimmed(s) return s and util.trim(s) or "" end
        return {
            api_key = trimmed(api_key),
            user_id = trimmed(user_id),
            webdav_url = trimmed(webdav_url),
            webdav_user = trimmed(webdav_user),
            -- Not trimmed: leading/trailing spaces in a password could be
            -- intentional (unlikely, but not our call).
            webdav_password = webdav_password or "",
        }
    end

    dialog = MultiInputDialog:new{
        title = _("Zotero credentials"),
        fields = {
            { text = self.settings.api_key, hint = _("Zotero API key") },
            { text = self.settings.user_id, hint = _("Zotero user ID") },
            { text = self.settings.webdav_url, hint = _("WebDAV URL, e.g. https://host/zotero/") },
            { text = self.settings.webdav_user, hint = _("WebDAV username") },
            { text = self.settings.webdav_password, hint = _("WebDAV password"), text_type = "password" },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local f = readFields()
                        local function nilIfEmpty(s) return s ~= "" and s or nil end
                        self.settings.api_key = nilIfEmpty(f.api_key)
                        self.settings.user_id = nilIfEmpty(f.user_id)
                        self.settings.webdav_url = nilIfEmpty(f.webdav_url)
                        self.settings.webdav_user = nilIfEmpty(f.webdav_user)
                        self.settings.webdav_password = nilIfEmpty(f.webdav_password)
                        -- isWebDAVConfigured() still requires the three
                        -- WebDAV fields above regardless of this flag, so
                        -- checking the box with empty fields is harmless
                        -- (downloads just won't run until both are true).
                        self.settings.webdav_enabled = checkbox and checkbox.checked or false
                        self.updated = true
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("Zotero credentials saved."),
                            timeout = 2,
                        })
                    end,
                },
            },
            {
                {
                    text = _("Test connection"),
                    callback = function()
                        local f = readFields()
                        if f.api_key == "" or f.user_id == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Fill in the Zotero API key and user ID first."),
                                timeout = 3,
                            })
                            return
                        end

                        UIManager:show(InfoMessage:new{ text = _("Testing…"), timeout = 1 })

                        local function showResult(zotero_ok, webdav_line)
                            local lines = {
                                zotero_ok and _("Zotero API: OK")
                                    or _("Zotero API: failed — check the API key and user ID"),
                            }
                            if webdav_line then table.insert(lines, webdav_line) end
                            UIManager:show(InfoMessage:new{
                                text = table.concat(lines, "\n"),
                                timeout = 6,
                            })
                        end

                        local client = ZoteroClient:new{ service_spec = self.path .. "/api_zotero.json" }
                        client:get_library_version(f.api_key, f.user_id, function(zotero_ok)
                            local has_webdav_fields = f.webdav_url ~= "" and f.webdav_user ~= "" and f.webdav_password ~= ""
                            if not has_webdav_fields then
                                showResult(zotero_ok, nil)
                                return
                            end
                            WebDAVClient:test_connection(f.webdav_url, f.webdav_user, f.webdav_password,
                                function(webdav_ok, detail)
                                    showResult(zotero_ok, (webdav_ok and _("WebDAV: OK") or _("WebDAV: failed"))
                                        .. " (" .. detail .. ")")
                                end)
                        end)
                    end,
                },
            },
        },
    }

    checkbox = CheckButton:new{
        text = _("Enable WebDAV PDF downloads"),
        checked = self.settings.webdav_enabled,
        parent = dialog,
        callback = function() end, -- state is just read from checkbox.checked on Save
    }
    dialog:addWidget(checkbox)

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Full sync: pull collections + item metadata (incrementally, via the
-- cached library version) for the *whole* library — that's what "Browse
-- library" has to select from — then download only the documents
-- the user has explicitly marked as wanted there (see browseItems).
function Zotero:sync(interactive)
    if not self:isConfigured() then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("Please configure your Zotero API key and user ID first."),
                timeout = 3,
            })
        end
        return
    end

    if NetworkMgr:willRerunWhenOnline(function() self:sync(interactive) end) then
        return
    end

    if interactive then
        UIManager:show(InfoMessage:new{
            text = _("Syncing Zotero library…"),
            timeout = 1,
        })
    end

    local client = ZoteroClient:new{ service_spec = self.path .. "/api_zotero.json" }
    local cached_version = LibraryCache:getVersion()

    client:list_collections(self.settings.api_key, self.settings.user_id, function(collections_ok, collections)
        if collections_ok then
            LibraryCache:mergeCollections(collections)
        else
            logger.warn("Zotero: failed to list collections")
        end

        local since = (cached_version and cached_version > 0) and cached_version or nil
        client:list_items(self.settings.api_key, self.settings.user_id, since, function(items_ok, items, new_version)
            if not items_ok then
                if interactive then
                    UIManager:show(InfoMessage:new{
                        text = _("Could not reach the Zotero API. Check your network connection and API key."),
                        timeout = 3,
                    })
                end
                return
            end

            LibraryCache:mergeItems(items)
            LibraryCache:setVersion(new_version)
            LibraryCache:save()

            local changed = #items
            self:downloadPendingAttachments(function(downloaded, failed)
                if interactive then
                    local extra
                    if not self:isWebDAVConfigured() then
                        local pending = #LibraryCache:getPendingAttachments()
                        extra = pending > 0
                            and T(_(" (%1 selected item(s) need WebDAV enabled to download — see \"Configure credentials\")"), pending)
                            or ""
                    else
                        extra = failed > 0 and T(_(", %1 queued for retry"), failed) or ""
                    end
                    UIManager:show(InfoMessage:new{
                        text = T(_("Sync complete: %1 metadata change(s), %2 document(s) downloaded%3."),
                            changed, downloaded, extra),
                        timeout = 4,
                    })
                end
            end)
        end)
    end)
end

--- Download every item marked `wanted` (via "Browse library") that isn't
-- on disk yet, one at a time (sequential on purpose: e-ink WebDAV servers
-- are usually small personal boxes, not something to hammer with parallel
-- requests). Failures are pushed onto ZoteroQueue instead of aborting the
-- batch. `self.active_download_key` tracks which item (if any) is
-- in flight right now, for showDownloadsStatus() to display.
-- @param done_callback function(downloaded_count, failed_count)
function Zotero:downloadPendingAttachments(done_callback)
    if not self:isWebDAVConfigured() then
        if done_callback then done_callback(0, 0) end
        return
    end

    local pending = LibraryCache:getPendingAttachments()
    local dest_dir = documentDir()
    local downloaded, failed = 0, 0

    local function download_one(i)
        local item = pending[i]
        if not item then
            self.active_download_key = nil
            LibraryCache:save()
            if done_callback then done_callback(downloaded, failed) end
            return
        end

        self.active_download_key = item.key
        WebDAVClient:download_attachment(
            self.settings.webdav_url,
            self.settings.webdav_user,
            self.settings.webdav_password,
            item.key,
            dest_dir,
            function(ok, doc_path, err)
                self.active_download_key = nil
                if ok then
                    LibraryCache:setPdfPath(item.key, doc_path)
                    downloaded = downloaded + 1
                else
                    logger.warn("Zotero: failed to download", item.key, err)
                    ZoteroQueue:push{
                        item_key = item.key,
                        webdav_url = self.settings.webdav_url,
                        dest_dir = dest_dir,
                    }
                    failed = failed + 1
                end
                download_one(i + 1)
            end)
    end

    download_one(1)
end

--- Retry everything in ZoteroQueue. Called automatically on reconnect
-- (silently) and from the menu (interactively).
function Zotero:drainQueue(interactive)
    if not self:isWebDAVConfigured() then
        return
    end
    ZoteroQueue:drain(function(item, cb)
        self.active_download_key = item.item_key
        WebDAVClient:download_attachment(
            self.settings.webdav_url,
            self.settings.webdav_user,
            self.settings.webdav_password,
            item.item_key,
            item.dest_dir,
            function(ok, doc_path)
                self.active_download_key = nil
                if ok then
                    LibraryCache:setPdfPath(item.item_key, doc_path)
                    LibraryCache:save()
                end
                cb(ok)
            end)
    end, function(sent)
        if interactive then
            UIManager:show(InfoMessage:new{
                text = sent > 0 and T(_("Retried %1 download(s)."), sent)
                    or _("Retry queue is empty."),
                timeout = 3,
            })
        end
    end)
end

function Zotero:_onNetworkConnected()
    logger.dbg("Zotero: onNetworkConnected")
    UIManager:scheduleIn(0.5, function()
        self:drainQueue(false)
    end)
end

--- "Downloads" entry point: everything currently downloading, queued
-- (selected but not yet attempted), waiting for a retry, and already on
-- the device, in that order. Answers "what's my download queue actually
-- doing" beyond the bare pending-count the main menu shows.
--
-- Wrapped in pcall: this is the newest, least on-device-tested screen in
-- the plugin (see the NOTE block at the top of this file), and a hard
-- crash here is worse than a graceful error message while the real
-- cause is still being tracked down (see CLAUDE.md for the open bug).
function Zotero:showDownloadsStatus()
    local ok, err = pcall(function() self:_showDownloadsStatusImpl() end)
    if not ok then
        logger.warn("Zotero: showDownloadsStatus failed:", err)
        UIManager:show(InfoMessage:new{
            text = _("Couldn't open the downloads view — check koreader.log for details."),
            timeout = 3,
        })
    end
end

function Zotero:_showDownloadsStatusImpl()
    local item_table = {}

    if self.active_download_key then
        local cached = LibraryCache:getItem(self.active_download_key)
        local label = (cached and cached.title) or self.active_download_key
        table.insert(item_table, { text = label .. "  [" .. _("downloading…") .. "]" })
    end

    for _, item in ipairs(LibraryCache:getPendingAttachments()) do
        if item.key ~= self.active_download_key then
            table.insert(item_table, { text = (item.title or item.key) .. "  [" .. _("queued") .. "]" })
        end
    end

    local queue = ZoteroQueue:load()
    if #queue > 0 then
        table.insert(item_table, { text = _("Retry all now"), is_retry_action = true })
        for _, entry in ipairs(queue) do
            local cached = LibraryCache:getItem(entry.item_key)
            local label = (cached and cached.title) or entry.item_key
            table.insert(item_table, { text = label .. "  [" .. _("retry pending") .. "]" })
        end
    end

    for _, item in pairs(LibraryCache:load().items) do
        if item.pdf_path then
            table.insert(item_table, {
                text = (item.title or item.key) .. "  [" .. _("on device") .. "]",
                zotero_item = item,
            })
        end
    end

    if #item_table == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Nothing queued, retrying, or downloaded yet."),
            timeout = 3,
        })
        return
    end

    local menu
    menu = Menu:new{
        title = _("Zotero downloads"),
        item_table = item_table,
        onMenuSelect = function(_self, entry)
            if entry.is_retry_action then
                UIManager:close(menu)
                self:drainQueue(true)
                return
            end
            if entry.zotero_item and entry.zotero_item.pdf_path
                    and lfs.attributes(entry.zotero_item.pdf_path, "mode") then
                UIManager:close(menu)
                self:openDocument(entry.zotero_item.pdf_path)
            end
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

--- "Browse library" entry point: a flat list of collections, plus an
-- "All documents" shortcut, each opening the item list for that scope.
function Zotero:browseCollections()
    local collections = LibraryCache:listCollections()
    local item_table = { { text = _("All documents") } }
    for _, collection in ipairs(collections) do
        table.insert(item_table, {
            text = collection.name or collection.key,
            collection_key = collection.key,
        })
    end

    local menu
    menu = Menu:new{
        title = _("Zotero collections"),
        item_table = item_table,
        onMenuSelect = function(_self, entry)
            UIManager:close(menu)
            self:browseItems(entry.collection_key)
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

local function itemLabel(item, supported)
    local label = item.title or item.key
    if not supported then
        label = label .. "  [" .. _("unsupported format") .. "]"
    elseif item.pdf_path then
        label = label .. "  [" .. _("downloaded") .. "]"
    elseif item.wanted then
        label = label .. "  [" .. _("queued for sync") .. "]"
    end
    return label
end

--- Item list for one collection (or the whole library if collection_key
-- is nil). This is also where the user selects what to sync: tapping an
-- item that isn't downloaded toggles whether it's queued for the next
-- "Sync now" (nothing downloads on its own); tapping an already-downloaded
-- item opens it in the reader instead, since "queue this again" isn't a
-- useful action once it's already on the device. Attachments in a format
-- KOReader can't open are still listed — so the user can see they exist
-- — but rendered dimmed/disabled (`[unsupported format]`) and tapping
-- one just explains why instead of toggling selection.
function Zotero:browseItems(collection_key)
    local items = LibraryCache:listItems(collection_key)
    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No documents here yet. Try \"Sync now\" first."),
            timeout = 3,
        })
        return
    end

    local item_table = {}
    for _, item in ipairs(items) do
        local supported = LibraryCache:isSupportedFormat(item)
        table.insert(item_table, {
            text = itemLabel(item, supported),
            zotero_item = item,
            zotero_supported = supported,
            dim = not supported,
        })
    end

    local menu
    menu = Menu:new{
        title = _("Zotero items — tap to select for sync, or open"),
        item_table = item_table,
        onMenuSelect = function(_self, entry)
            local item = entry.zotero_item
            if not entry.zotero_supported then
                UIManager:show(InfoMessage:new{
                    text = _("This attachment's format isn't one KOReader can open, so it can't be synced."),
                    timeout = 3,
                })
                return
            end
            if item.pdf_path and lfs.attributes(item.pdf_path, "mode") then
                UIManager:close(menu)
                self:openDocument(item.pdf_path)
                return
            end
            -- Not downloaded yet: this tap only toggles selection, no
            -- network activity happens here — "Sync now" is what actually
            -- downloads whatever ends up marked.
            local new_wanted = not item.wanted
            LibraryCache:setWanted(item.key, new_wanted)
            item.wanted = new_wanted
            entry.text = itemLabel(item, true)
            menu:updateItems()
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function Zotero:openDocument(doc_path)
    local ReaderUI = require("apps/reader/readerui")
    UIManager:scheduleIn(0.1, function()
        ReaderUI:showReader(doc_path)
    end)
end

return Zotero
