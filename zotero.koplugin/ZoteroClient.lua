--[[--
REST client for the Zotero Web API (https://api.zotero.org), following the
same Spore-based structure as KOReader's own KOSyncClient.lua (see
kosync.koplugin) — Spore for declarative endpoints, a custom auth
middleware, and the same coroutine-driven AsyncHTTP middleware reused
verbatim so requests don't block the UI on e-ink.

This module only talks to api.zotero.org (metadata: items, collections,
library version). PDF attachments live on the user's own WebDAV server and
are handled separately by WebDAVClient.lua, since that's a binary
zip/Basic-Auth transfer, not a JSON API Spore can describe.
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local socketutil = require("socketutil")

-- Item/collection listings can be large; version checks should be snappy.
local LIST_TIMEOUTS    = { 10, 20 }
local VERSION_TIMEOUTS = { 5,  10 }

-- Zotero API pagination cap (also the server-side max for `limit`).
local PAGE_LIMIT = 100

local ZoteroClient = {
    service_spec = nil,
    custom_url = nil,
}

function ZoteroClient:new(o)
    if o == nil then o = {} end
    setmetatable(o, self)
    self.__index = self
    if o.init then o:init() end
    return o
end

function ZoteroClient:init()
    local Spore = require("Spore")
    self.client = Spore.new_from_spec(self.service_spec, {
        base_url = self.custom_url,
    })

    package.loaded["Spore.Middleware.ZoteroAuth"] = {}
    require("Spore.Middleware.ZoteroAuth").call = function(args, req)
        req.headers["zotero-api-key"] = args.api_key
        req.headers["zotero-api-version"] = "3"
    end

    -- Identical to kosync's AsyncHTTP middleware: runs the request through
    -- KOReader's low-level httpclient (Turbo-based), resuming the calling
    -- coroutine from the ioloop callback once a response is available.
    package.loaded["Spore.Middleware.AsyncHTTP"] = {}
    require("Spore.Middleware.AsyncHTTP").call = function(args, req)
        -- disable async http if Turbo looper is missing
        if not UIManager.looper then return end
        req:finalize()
        local result
        require("httpclient"):new():request({
            url = req.url,
            method = req.method,
            body = req.env.spore.payload,
            on_headers = function(headers)
                for header, value in pairs(req.headers) do
                    if type(header) == "string" then
                        headers:add(header, value)
                    end
                end
            end,
        }, function(res)
            result = res
            -- Turbo HTTP client uses code instead of status
            -- change to status so that Spore can understand
            result.status = res.code
            coroutine.resume(args.thread)
        end)
        return coroutine.create(function() coroutine.yield(result) end)
    end
end

--- Best-effort read of the `Last-Modified-Version` response header, which
-- Zotero sets on every /items and /collections response. Header keys are
-- read case-insensitively since it's unclear which casing the underlying
-- HTTP stack normalizes to; NOTE: verify the exact casing on-device.
function ZoteroClient:_readVersionHeader(res)
    local headers = res and res.headers
    if not headers then return nil end
    local raw = headers["last-modified-version"] or headers["Last-Modified-Version"]
    return raw and tonumber(raw) or nil
end

--- Fetch just the current library version (cheap: limit=1, no processing
-- of the returned item(s)).
-- @param callback function(ok, version)
function ZoteroClient:get_library_version(api_key, user_id, callback)
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("ZoteroAuth", { api_key = api_key })
    socketutil:set_timeout(VERSION_TIMEOUTS[1], VERSION_TIMEOUTS[2])

    local co = coroutine.create(function()
        local ok, res = pcall(function()
            return self.client:get_library_version({
                user_id = user_id,
                limit = 1,
            })
        end)
        socketutil:reset_timeout()
        if not ok then
            logger.dbg("ZoteroClient:get_library_version failure:", res)
            callback(false, nil)
            return
        end
        callback(res.status == 200, self:_readVersionHeader(res))
    end)
    self.client:enable("AsyncHTTP", { thread = co })
    coroutine.resume(co)
    if UIManager.looper then UIManager:setInputTimeout() end
end

--- Fetch every page of results for a Spore method, accumulating into one
-- array. Shared by list_items/list_collections since both paginate the
-- same way (`start`/`limit`, stop once a short page comes back).
-- @param callback function(ok, results, library_version)
function ZoteroClient:_fetchAllPages(method_name, base_params, callback)
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("ZoteroAuth", { api_key = base_params.api_key })

    local all_results = {}
    local library_version = nil

    local function fetch_page(start)
        socketutil:set_timeout(LIST_TIMEOUTS[1], LIST_TIMEOUTS[2])
        local co = coroutine.create(function()
            local params = {}
            for k, v in pairs(base_params) do params[k] = v end
            params.api_key = nil -- consumed by the auth middleware, not a query param
            params.limit = PAGE_LIMIT
            params.start = start

            local ok, res = pcall(function()
                return self.client[method_name](self.client, params)
            end)
            socketutil:reset_timeout()

            if not ok then
                logger.dbg("ZoteroClient:" .. method_name .. " failure:", res)
                callback(false, nil, nil)
                return
            end
            if res.status ~= 200 then
                logger.dbg("ZoteroClient:" .. method_name .. " HTTP", res.status)
                callback(false, nil, nil)
                return
            end

            library_version = library_version or self:_readVersionHeader(res)
            local page = res.body or {}
            for _, entry in ipairs(page) do
                table.insert(all_results, entry)
            end

            if #page == PAGE_LIMIT then
                -- Short-circuit recursion guard: Zotero libraries are not
                -- expected to need more than a few thousand pages here,
                -- but this is unbounded by construction — a future
                -- revision could convert this to an explicit loop driven
                -- by a single reusable coroutine if that becomes an issue.
                fetch_page(start + PAGE_LIMIT)
            else
                callback(true, all_results, library_version)
            end
        end)
        self.client:enable("AsyncHTTP", { thread = co })
        coroutine.resume(co)
        if UIManager.looper then UIManager:setInputTimeout() end
    end

    fetch_page(0)
end

--- List items modified since `since` (a library version number), or the
-- whole library if `since` is nil/0.
-- @param callback function(ok, items, library_version)
function ZoteroClient:list_items(api_key, user_id, since, callback)
    self:_fetchAllPages("list_items", {
        api_key = api_key,
        user_id = user_id,
        since = since,
        format = "json",
    }, callback)
end

--- List all collections in the library.
-- @param callback function(ok, collections, library_version)
function ZoteroClient:list_collections(api_key, user_id, callback)
    self:_fetchAllPages("list_collections", {
        api_key = api_key,
        user_id = user_id,
    }, callback)
end

return ZoteroClient
