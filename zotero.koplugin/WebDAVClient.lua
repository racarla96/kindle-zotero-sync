--[[--
Minimal WebDAV client for downloading Zotero attachment archives.

Zotero's own WebDAV attachment storage (as opposed to the api.zotero.org
metadata API covered by ZoteroClient.lua) isn't a JSON API: each PDF
attachment is a plain `{item_key}.zip` file (plus a `.prop` sidecar KOReader
doesn't need) served over HTTP with Basic Auth. There's no Spore spec for
that — it's just a GET of a binary blob — so this module talks to it
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
-- PDF inside, and move it to `dest_dir/{item_key}.pdf`.
-- @return pdf_path, nil on success — nil, error_message on failure
function WebDAVClient:_extractPdf(zip_path, item_key, dest_dir)
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

    local pipe = io.popen("find " .. shell_quote(extract_dir) .. " -iname '*.pdf' -type f | head -n1")
    local found = pipe and pipe:read("*l")
    if pipe then pipe:close() end

    if not found or found == "" then
        os.execute("rm -rf " .. shell_quote(extract_dir))
        return nil, "zip for " .. item_key .. " did not contain a PDF"
    end

    local final_path = dest_dir .. "/" .. item_key .. ".pdf"
    os.remove(final_path) -- clear a stale file from a previous partial sync
    os.rename(found, final_path)
    os.execute("rm -rf " .. shell_quote(extract_dir))
    return final_path, nil
end

--- Download and extract one attachment.
-- @param webdav_url base WebDAV URL, e.g. "https://host/zotero/"
-- @param user, password  WebDAV Basic Auth credentials
-- @param item_key  Zotero attachment item key (the .zip is named {key}.zip)
-- @param dest_dir  local directory to place the extracted PDF into
-- @param callback  function(ok, pdf_path_or_nil, error_message_or_nil)
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

        local pdf_path, extract_err = self:_extractPdf(zip_path, item_key, dest_dir)
        os.remove(zip_path)
        if not pdf_path then
            callback(false, nil, extract_err)
            return
        end

        logger.dbg("WebDAVClient: downloaded", item_key, "->", pdf_path)
        callback(true, pdf_path, nil)
    end)
    coroutine.resume(co)
end

return WebDAVClient
