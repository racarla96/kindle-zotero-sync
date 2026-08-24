--[[--
Local cache of the Zotero library: last synced `library/version`, plus an
index of items and collections, persisted the same way KOSyncQueue persists
its retry queue — `Persist` with the "dump" codec.

This is what powers incremental sync (compare the cached version against
`ZoteroClient:get_library_version`/the version returned by `list_items`,
only re-fetch when it moved forward) and what the "Browse library" menu in
main.lua reads from — it never talks to the network itself.
--]]

local DataStorage = require("datastorage")
local Persist = require("persist")
local logger = require("logger")

local CACHE_PATH = DataStorage:getSettingsDir() .. "/zotero_library.lua"

local LibraryCache = {}

local function default_state()
    return {
        library_version = 0,
        items = {},       -- item_key -> { key, title, creators, collection_keys, tags, version, content_type, link_mode, parent_item, pdf_path, wanted }
        collections = {}, -- collection_key -> { key, name, parent_collection }
    }
end

function LibraryCache:_storage()
    if not self._persist then
        self._persist = Persist:new{ path = CACHE_PATH, codec = "dump" }
    end
    return self._persist
end

function LibraryCache:load()
    if self._state then return self._state end
    local storage = self:_storage()
    if not storage:exists() then
        self._state = default_state()
        return self._state
    end
    local data, err = storage:load()
    if not data then
        logger.warn("LibraryCache: failed to load cache, starting fresh:", err)
        self._state = default_state()
        return self._state
    end
    self._state = data
    return self._state
end

function LibraryCache:save()
    if not self._state then return end
    local ok, err = self:_storage():save(self._state)
    if not ok then
        logger.warn("LibraryCache: failed to save cache:", err)
    end
end

function LibraryCache:getVersion()
    return self:load().library_version
end

function LibraryCache:setVersion(version)
    if not version then return end
    self:load().library_version = version
end

--- Merge a batch of raw Zotero API item objects (each with `.key` and
-- `.data`, as returned by ZoteroClient:list_items) into the cache.
-- Items the API reports as deleted are dropped from the cache; a
-- previously-downloaded pdf_path, and whether the user marked the item as
-- wanted (see setWanted), are preserved across metadata-only merges — a
-- metadata sync must never silently unmark or re-queue anything.
function LibraryCache:mergeItems(api_items)
    local state = self:load()
    for _, api_item in ipairs(api_items) do
        local data = api_item.data or {}
        if data.deleted then
            state.items[api_item.key] = nil
        else
            local existing = state.items[api_item.key]
            state.items[api_item.key] = {
                key = api_item.key,
                item_type = data.itemType,
                title = data.title or (existing and existing.title),
                creators = data.creators or (existing and existing.creators),
                collection_keys = data.collections or (existing and existing.collection_keys),
                tags = data.tags or (existing and existing.tags),
                version = data.version,
                content_type = data.contentType or (existing and existing.content_type),
                link_mode = data.linkMode or (existing and existing.link_mode),
                parent_item = data.parentItem or (existing and existing.parent_item),
                pdf_path = existing and existing.pdf_path,
                wanted = existing and existing.wanted,
            }
        end
    end
end

--- Merge a batch of raw Zotero API collection objects into the cache.
function LibraryCache:mergeCollections(api_collections)
    local state = self:load()
    for _, api_collection in ipairs(api_collections) do
        local data = api_collection.data or {}
        state.collections[api_collection.key] = {
            key = api_collection.key,
            name = data.name,
            parent_collection = data.parentCollection,
        }
    end
end

function LibraryCache:setPdfPath(item_key, pdf_path)
    local state = self:load()
    if state.items[item_key] then
        state.items[item_key].pdf_path = pdf_path
    end
end

--- Mark (or unmark) an item as selected for download. Saved immediately
-- rather than waiting for the caller's next save() — this is a direct,
-- explicit user action from the "Browse library" UI (a tap), not part of
-- a larger sync transaction, so it shouldn't be lost if something goes
-- wrong before the next unrelated save happens to fire.
function LibraryCache:setWanted(item_key, wanted)
    local state = self:load()
    if state.items[item_key] then
        state.items[item_key].wanted = wanted or nil
        self:save()
    end
end

function LibraryCache:getItem(item_key)
    return self:load().items[item_key]
end

local function is_pdf_attachment(item)
    return item.content_type == "application/pdf"
        and (item.link_mode == "imported_file" or item.link_mode == "imported_url")
end

--- @return array of item entries that are PDF attachments the user marked
-- as wanted (via the "Browse library" toggle) and that aren't downloaded
-- yet. Nothing downloads until the user has explicitly selected it.
function LibraryCache:getPendingAttachments()
    local state = self:load()
    local pending = {}
    for _, item in pairs(state.items) do
        if is_pdf_attachment(item) and item.wanted and not item.pdf_path then
            table.insert(pending, item)
        end
    end
    return pending
end

--- @return array of {key, name, parent_collection}, sorted by name.
function LibraryCache:listCollections()
    local state = self:load()
    local list = {}
    for _, collection in pairs(state.collections) do
        table.insert(list, collection)
    end
    table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
    return list
end

--- @param collection_key string|nil: restrict to one collection, or list
--        every PDF item in the library if nil.
-- @return array of item entries, sorted by title.
function LibraryCache:listItems(collection_key)
    local state = self:load()
    local list = {}
    for _, item in pairs(state.items) do
        if is_pdf_attachment(item) then
            local matches = not collection_key
            if collection_key and item.collection_keys then
                for _, ck in ipairs(item.collection_keys) do
                    if ck == collection_key then matches = true end
                end
            end
            if matches then table.insert(list, item) end
        end
    end
    table.sort(list, function(a, b) return (a.title or "") < (b.title or "") end)
    return list
end

return LibraryCache
