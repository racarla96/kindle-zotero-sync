--[[--
Minimal WebDAV client for downloading Zotero attachment archives.

Zotero's own WebDAV attachment storage (as opposed to the api.zotero.org
metadata API covered by ZoteroClient.lua) isn't a JSON API: each attachment
(PDF, EPUB, or any other format KOReader can open — see LibraryCache's
SUPPORTED_EXTENSIONS) is a plain `{item_key}.zip` file (plus a `.prop`
sidecar KOReader doesn't need) served over HTTP with Basic Auth. There's
no Spore spec for that — it's just a GET of a binary blob — so this module
talks to it
directly with KOReader's low-level `httpclient`, the same client the Spore
AsyncHTTP middleware in ZoteroClient.lua uses under the hood, driven by a
plain coroutine yield/resume instead of Spore's request pipeline.

NOTE on things that need on-device verification (no real KOReader install
was available to test against while writing this):
  - `require("mime").b64` (LuaSocket's mime module) is assumed present for
    Basic Auth header encoding — KOReader bundles LuaSocket for HTTP, and
    this is the standard companion library for it, but confirm it resolves.
  - Extraction shells out to the `unzip` binary rather than an FFI zip
    reader, mirroring scripts/test_sync.sh (already proven against a real
    WebDAV/zip pair). KOReader ships a `webdav.koplugin` for cloud storage
    that is a much closer precedent than kosync for this module's HTTP
    needs — worth diffing against once testing on a real device.
--]]

local logger = require("logger")
local socketutil = require("socketutil")
local mime = require("mime")

local DOWNLOAD_TIMEOUTS = { 15, 60 } -- connect, total — PDFs can be large

local WebDAVClient = {}

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", [['\'']]) .. "'"
end

--- Unzip `zip_path` into a scratch dir under `dest_dir`, find the (single)
-- content file inside — Zotero's WebDAV attachment zips hold exactly one
-- document plus a `.prop` metadata sidecar — and move it to
-- `dest_dir/{item_key}.{original_extension}`. The extension is whatever
-- Zotero shipped it as; LibraryCache already filtered the item against
-- KOReader's supported formats before this ever gets called, so this
-- layer doesn't re-check it — it just preserves whatever it finds.
-- @return doc_path, nil on success — nil, error_message on failure
function WebDAVClient:_extractDocument(zip_path, item_key, dest_dir)
    local extract_dir = dest_dir .. "/." .. item_key .. "_extract"
    os.execute("rm -rf " .. shell_quote(extract_dir))
    os.execute("mkdir -p " .. shell_quote(extract_dir))

    -- os.execute's return value differs between plain Lua 5.1 (a single
    -- exit-code number) and 5.2+/some LuaJIT builds (true/nil, "exit", code)
    -- — accept either "it looks like it worked" shape.
    local result = os.execute("unzip -q -o " .. shell_quote(zip_path) .. " -d " .. shell_quote(extract_dir))
    local unzip_ok = (result == true or result == 0)
    if not unzip_ok then
        os.execute("rm -rf " .. shell_quote(extract_dir))
        return nil, "unzip failed for " .. zip_path
    end

    local pipe = io.popen("find " .. shell_quote(extract_dir) .. " -type f -not -iname '*.prop' | head -n1")
    local found = pipe and pipe:read("*l")
    if pipe then pipe:close() end

    if not found or found == "" then
        os.execute("rm -rf " .. shell_quote(extract_dir))
        return nil, "zip for " .. item_key .. " did not contain a document"
    end

    local ext = found:match("%.([%a%d]+)$") or "bin"
    local final_path = dest_dir .. "/" .. item_key .. "." .. ext
    os.remove(final_path) -- clear a stale file from a previous partial sync
    os.rename(found, final_path)
    os.execute("rm -rf " .. shell_quote(extract_dir))
    return final_path, nil
end

--- Download and extract one attachment.
-- @param webdav_url base WebDAV URL, e.g. "https://host/zotero/"
-- @param user, password  WebDAV Basic Auth credentials
-- @param item_key  Zotero attachment item key (the .zip is named {key}.zip)
-- @param dest_dir  local directory to place the extracted document into
-- @param callback  function(ok, doc_path_or_nil, error_message_or_nil)
function WebDAVClient:download_attachment(webdav_url, user, password, item_key, dest_dir, callback)
    local base = webdav_url:gsub("/*$", "/")
    local zip_url = base .. item_key .. ".zip"
    local zip_path = dest_dir .. "/." .. item_key .. ".zip.part"
    local auth_header = "Basic " .. mime.b64(user .. ":" .. password)

    socketutil:set_timeout(DOWNLOAD_TIMEOUTS[1], DOWNLOAD_TIMEOUTS[2])

    local co
    co = coroutine.create(function()
        require("httpclient"):new():request({
            url = zip_url,
            method = "GET",
            on_headers = function(headers)
                headers:add("authorization", auth_header)
            end,
        }, function(res)
            coroutine.resume(co, res)
        end)

        local res = coroutine.yield()
        socketutil:reset_timeout()

        if not res or res.code ~= 200 then
            callback(false, nil, "HTTP " .. tostring(res and res.code or "?") .. " downloading " .. zip_url)
            return
        end

        local out_file, open_err = io.open(zip_path, "wb")
        if not out_file then
            callback(false, nil, "cannot open " .. zip_path .. " for writing: " .. tostring(open_err))
            return
        end
        out_file:write(res.body or "")
        out_file:close()

        local doc_path, extract_err = self:_extractDocument(zip_path, item_key, dest_dir)
        os.remove(zip_path)
        if not doc_path then
            callback(false, nil, extract_err)
            return
        end

        logger.dbg("WebDAVClient: downloaded", item_key, "->", doc_path)
        callback(true, doc_path, nil)
    end)
    coroutine.resume(co)
end

return WebDAVClient
