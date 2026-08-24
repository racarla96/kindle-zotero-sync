--[[--
Disk-backed retry queue for PDF attachments that failed to download,
adapted from kosync.koplugin's KOSyncQueue.lua: same Persist/"dump"
storage, same dedup/expiration/cap policy — pushing an entry for an
item_key that's already queued replaces it rather than piling up.

One deliberate deviation from KOSyncQueue: `drain()` here is
callback-based instead of expecting a synchronous `send_func(item) -> bool`.
KOSyncQueue's progress-push requests are cheap enough to run synchronously
via pcall; WebDAVClient's downloads are inherently async (Turbo/httpclient
+ coroutine yield), so forcing a fake synchronous wrapper around that would
mean either blocking the UI loop or fabricating an unverified pumping API.
Continuation-passing keeps this queue correct for its actual downloader.
--]]

local DataStorage = require("datastorage")
local Persist = require("persist")
local logger = require("logger")

local QUEUE_PATH = DataStorage:getSettingsDir() .. "/zotero_queue.lua"
local MAX_AGE = 28 * 24 * 3600 -- 4 weeks in seconds
local MAX_ENTRIES = 200 -- paranoia cap

local ZoteroQueue = {}

function ZoteroQueue:_storage()
    if not self._persist then
        self._persist = Persist:new{ path = QUEUE_PATH, codec = "dump" }
    end
    return self._persist
end

function ZoteroQueue:load()
    local storage = self:_storage()
    if not storage:exists() then return {} end
    local data, err = storage:load()
    if not data then
        logger.warn("ZoteroQueue: failed to load queue:", err)
        return {}
    end
    return data
end

function ZoteroQueue:save(queue)
    local ok, err = self:_storage():save(queue)
    if not ok then
        logger.warn("ZoteroQueue: failed to save queue:", err)
    end
end

--- Queue a failed attachment download for later retry.
-- @param item table: { item_key, webdav_url, dest_dir }
-- Keeps at most one entry per item_key (a later push replaces the older
-- one). Expires entries older than 4 weeks.
function ZoteroQueue:push(item)
    local queue = self:load()
    local now = os.time()
    item.queued_at = now

    local filtered = {}
    for _, entry in ipairs(queue) do
        local dominated = entry.item_key == item.item_key
        if (now - (entry.queued_at or 0)) < MAX_AGE and not dominated then
            table.insert(filtered, entry)
        end
    end

    table.insert(filtered, item)

    -- Paranoia cap: drop oldest
    while #filtered > MAX_ENTRIES do
        table.remove(filtered, 1)
    end

    self:save(filtered)
    logger.dbg("ZoteroQueue: queued download for", item.item_key, "total:", #filtered)
end

--- Attempt to download all queued attachments, in order, stopping at the
-- first failure (whatever's left, including the failed item, stays queued
-- for the next drain attempt — same "stop on first failure" behavior as
-- KOSyncQueue, on the assumption that one failure usually means the
-- network/server is down rather than that one item being broken).
-- @param download_func function(item, cb): cb(true) on success, cb(false) on failure
-- @param done_callback function(sent_count), optional
function ZoteroQueue:drain(download_func, done_callback)
    local queue = self:load()
    if #queue == 0 then
        if done_callback then done_callback(0) end
        return
    end

    logger.info("ZoteroQueue: draining", #queue, "queued downloads")
    local sent = 0

    local function step(i)
        local item = queue[i]
        if not item then
            self:save({})
            logger.info("ZoteroQueue: downloaded all", sent, "items")
            if done_callback then done_callback(sent) end
            return
        end
        download_func(item, function(ok)
            if ok then
                sent = sent + 1
                step(i + 1)
            else
                local remaining = {}
                for j = i, #queue do
                    table.insert(remaining, queue[j])
                end
                self:save(remaining)
                logger.info("ZoteroQueue: downloaded", sent, ", remaining", #remaining)
                if done_callback then done_callback(sent) end
            end
        end)
    end

    step(1)
end

function ZoteroQueue:count()
    return #self:load()
end

function ZoteroQueue:clear()
    self:save({})
end

return ZoteroQueue
