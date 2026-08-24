--[[--
Entry point for zotero.koplugin: registers a "Zotero" menu in FileManager,
orchestrates metadata + PDF sync, and provides a minimal collections ->
items -> open browser. Structured after kosync.koplugin's main.lua
(WidgetContainer:extend, LuaSettings-backed settings, MultiInputDialog for
credentials, NetworkMgr hooks for retrying queued work on reconnect) but
this plugin is a library browser rather than a per-document sync, so it's
registered for FileManager (is_doc_only = false), not the reader.

NOTE on things that need on-device verification (no real KOReader install
was available to test against while writing this):
  - The `Menu` widget usage below (item_table shape, onMenuSelect
    signature) follows the common pattern seen across KOReader plugins,
    but wasn't exercised against a live UIManager.
  - `ReaderUI:showReader(path)` is the standard way plugins hand a file
    off to the reader; double-check the exact call against a recent
    KOReader checkout if it doesn't open PDFs as expected.
--]]

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
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
    webdav_url = nil,
    webdav_user = nil,
    webdav_password = nil,
}

--- Directory PDFs are extracted into — inside KOReader's own data dir
-- rather than /mnt/us/documents/ directly, so the plugin doesn't scatter
-- files across the user's book folder; "Open" pushes the reader straight
-- at the file regardless of where it lives.
local function pdfDir()
    local dir = DataStorage:getFullDataDir() .. "/zotero"
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
    -- Drain any queued PDF downloads whenever we come back online.
    self.onNetworkConnected = self._onNetworkConnected
    self.ui.menu:registerToMainMenu(self)
end

function Zotero:isConfigured()
    return self.settings.api_key and self.settings.api_key ~= ""
        and self.settings.user_id and self.settings.user_id ~= ""
end

function Zotero:isWebDAVConfigured()
    return self.settings.webdav_url and self.settings.webdav_url ~= ""
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
            },
            {
                text_func = function()
                    local pending = ZoteroQueue:count()
                    return pending > 0
                        and T(_("Retry queue (%1 pending)"), pending)
                        or _("Retry queue (empty)")
                end,
                enabled_func = function() return ZoteroQueue:count() > 0 end,
                keep_menu_open = true,
                callback = function() self:drainQueue(true) end,
            },
        },
    }
end

function Zotero:showCredentialsDialog()
    local dialog
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
                        local api_key, user_id, webdav_url, webdav_user, webdav_password =
                            unpack(dialog:getFields())
                        local function nilIfEmpty(s)
                            s = s and util.trim(s) or ""
                            return s ~= "" and s or nil
                        end
                        self.settings.api_key = nilIfEmpty(api_key)
                        self.settings.user_id = nilIfEmpty(user_id)
                        self.settings.webdav_url = nilIfEmpty(webdav_url)
                        self.settings.webdav_user = nilIfEmpty(webdav_user)
                        -- Don't trim the password: leading/trailing spaces
                        -- could be intentional (unlikely, but not our call).
                        self.settings.webdav_password = (webdav_password ~= "" and webdav_password) or nil
                        self.updated = true
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("Zotero credentials saved."),
                            timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Full sync: pull collections + item metadata (incrementally, via the
-- cached library version), then download any PDF attachments that aren't
-- on disk yet.
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
                    local extra = failed > 0 and T(_(", %1 queued for retry"), failed) or ""
                    UIManager:show(InfoMessage:new{
                        text = T(_("Sync complete: %1 metadata change(s), %2 PDF(s) downloaded%3."),
                            changed, downloaded, extra),
                        timeout = 4,
                    })
                end
            end)
        end)
    end)
end

--- Download every cached PDF attachment that isn't on disk yet, one at a
-- time (sequential on purpose: e-ink WebDAV servers are usually small
-- personal boxes, not something to hammer with parallel requests).
-- Failures are pushed onto ZoteroQueue instead of aborting the batch.
-- @param done_callback function(downloaded_count, failed_count)
function Zotero:downloadPendingAttachments(done_callback)
    if not self:isWebDAVConfigured() then
        if done_callback then done_callback(0, 0) end
        return
    end

    local pending = LibraryCache:getPendingAttachments()
    local dest_dir = pdfDir()
    local downloaded, failed = 0, 0

    local function download_one(i)
        local item = pending[i]
        if not item then
            LibraryCache:save()
            if done_callback then done_callback(downloaded, failed) end
            return
        end

        WebDAVClient:download_attachment(
            self.settings.webdav_url,
            self.settings.webdav_user,
            self.settings.webdav_password,
            item.key,
            dest_dir,
            function(ok, pdf_path, err)
                if ok then
                    LibraryCache:setPdfPath(item.key, pdf_path)
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
        WebDAVClient:download_attachment(
            self.settings.webdav_url,
            self.settings.webdav_user,
            self.settings.webdav_password,
            item.item_key,
            item.dest_dir,
            function(ok, pdf_path)
                if ok then
                    LibraryCache:setPdfPath(item.item_key, pdf_path)
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

--- "Browse library" entry point: a flat list of collections, plus an
-- "All PDFs" shortcut, each opening the item list for that scope.
function Zotero:browseCollections()
    local collections = LibraryCache:listCollections()
    local item_table = { { text = _("All PDFs") } }
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

--- Item list for one collection (or the whole library if collection_key
-- is nil). Selecting a downloaded item opens it in the reader; selecting
-- one that hasn't synced yet just points the user at "Sync now".
function Zotero:browseItems(collection_key)
    local items = LibraryCache:listItems(collection_key)
    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No PDF items here yet. Try \"Sync now\" first."),
            timeout = 3,
        })
        return
    end

    local item_table = {}
    for _, item in ipairs(items) do
        local label = item.title or item.key
        if not item.pdf_path then
            label = label .. "  [" .. _("not downloaded") .. "]"
        end
        table.insert(item_table, { text = label, zotero_item = item })
    end

    local menu
    menu = Menu:new{
        title = _("Zotero items"),
        item_table = item_table,
        onMenuSelect = function(_self, entry)
            local item = entry.zotero_item
            if item.pdf_path and lfs.attributes(item.pdf_path, "mode") then
                UIManager:close(menu)
                self:openPdf(item.pdf_path)
            else
                UIManager:show(InfoMessage:new{
                    text = _("This PDF hasn't been downloaded yet. Run \"Sync now\" first."),
                    timeout = 3,
                })
            end
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function Zotero:openPdf(pdf_path)
    local ReaderUI = require("apps/reader/readerui")
    UIManager:scheduleIn(0.1, function()
        ReaderUI:showReader(pdf_path)
    end)
end

return Zotero
