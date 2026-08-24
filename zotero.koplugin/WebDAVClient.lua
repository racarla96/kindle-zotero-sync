--[[--
Minimal WebDAV client for downloading Zotero attachment archives.

Zotero's own WebDAV attachment storage (as opposed to the api.zotero.org
metadata API covered by ZoteroClient.lua) isn't a JSON API: each attachment
(PDF, EPUB, or any other format KOReader can open — see LibraryCache's
SUPPORTED_EXTENSIONS) is a plain `{item_key}.zip` file (plus a `.prop`
sidecar KOReader doesn't need) served over HTTP with Basic Auth.

REWRITTEN after a real on-device error. This used to go through KOReader's
low-level Turbo-based `httpclient` (the same client Spore's AsyncHTTP
middleware in ZoteroClient.lua uses), driven by a hand-rolled coroutine.
On the user's real Kindle, that failed with:

    WebDAV: failed (internal error: frontend/httpclient.lua:18:
    attempt to index field 'looper' (a nil value))

i.e. `UIManager.looper` (the Turbo event loop KOReader lazily creates for
async HTTP) was nil in this context. ZoteroClient.lua's Spore requests
didn't hit this because its AsyncHTTP middleware guards itself with
`if not UIManager.looper then return end` and silently falls through to
Spore's own synchronous transport when the looper isn't there — this file
called httpclient directly, with no such guard or fallback, so it just
crashed into that nil index instead.

Fetched and diffed against KOReader's actual, on-device-proven WebDAV
provider (`plugins/cloudstorage.koplugin/providers/webdav.lua`, via
`gh api repos/koreader/koreader/contents/...`, not guessed) rather than
patched around the symptom — that file never touches `httpclient` or
`UIManager.looper` at all. It downloads over plain, synchronous
`socket.http` + `ltn12`, with Basic Auth handled by LuaSocket's built-in
`user`/`password` request fields (no manual `Authorization` header/base64
needed). This module now follows that exact pattern instead. Synchronous
means this blocks the UI thread briefly per request — acceptable here
since every call site is either an explicit user tap (Browse library,
Test connection) or a background retry, not something that needs to
interleave with other UI work, and it's the same trade-off KOReader's own
bundled WebDAV provider already makes for the same kind of request.
--]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")

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

--- Best-effort HEAD request to learn an attachment's zip size in bytes
-- before downloading it, so a caller can size a progress bar accurately
-- (see main.lua's downloadItemNow, which uses this to set
-- ProgressbarDialog's `progress_max` before the actual download starts).
-- Some servers omit Content-Length on HEAD (chunked transfer, etc.) — this
-- returns nil in that case, which callers should treat as "unknown size":
-- ProgressbarDialog itself already degrades gracefully (hides the bar)
-- when handed a nil progress_max, so there's nothing extra to handle.
function WebDAVClient:get_attachment_size(webdav_url, user, password, item_key)
    local base = webdav_url:gsub("/*$", "/")
    local zip_url = base .. item_key .. ".zip"

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, headers = socket.skip(1, http.request{
        url = zip_url,
        method = "HEAD",
        user = user,
        password = password,
    })
    socketutil:reset_timeout()

    if headers == nil or code ~= 200 then
        return nil
    end
    return tonumber(headers["content-length"])
end

--- Download and extract one attachment. Synchronous — see file header for
-- why that's the right trade-off here.
-- @param webdav_url base WebDAV URL, e.g. "https://host/zotero/"
-- @param user, password  WebDAV Basic Auth credentials
-- @param item_key  Zotero attachment item key (the .zip is named {key}.zip)
-- @param dest_dir  local directory to place the extracted document into
-- @param callback  function(ok, doc_path_or_nil, error_message_or_nil)
-- @param progress_callback optional function(bytes_downloaded_so_far) —
--        forwarded to LuaSocket's sink via socketutil.chainSinkWithProgressCallback,
--        the same helper/pattern KOReader's own WebDAV cloud-storage
--        provider uses to drive its ProgressbarDialog.
function WebDAVClient:download_attachment(webdav_url, user, password, item_key, dest_dir, callback, progress_callback)
    local base = webdav_url:gsub("/*$", "/")
    local zip_url = base .. item_key .. ".zip"
    local zip_path = dest_dir .. "/." .. item_key .. ".zip.part"

    local out_file, open_err = io.open(zip_path, "w")
    if not out_file then
        callback(false, nil, "cannot open " .. zip_path .. " for writing: " .. tostring(open_err))
        return
    end

    local sink = ltn12.sink.file(out_file) -- closes out_file itself once done
    if progress_callback then
        sink = socketutil.chainSinkWithProgressCallback(sink, progress_callback)
    end

    -- FILE_BLOCK_TIMEOUT/FILE_TOTAL_TIMEOUT: socketutil's own presets for
    -- "downloading a file, could be large" requests — the same ones
    -- KOReader's bundled WebDAV cloud-storage provider uses for this
    -- exact kind of call.
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, http.request{
        url = zip_url,
        method = "GET",
        sink = sink,
        user = user,
        password = password,
    })
    socketutil:reset_timeout()

    if headers == nil then
        os.remove(zip_path)
        logger.warn("WebDAVClient: download_attachment no response:", status or code)
        callback(false, nil, "no response downloading " .. zip_url .. ": " .. tostring(status or code))
        return
    end
    if code ~= 200 then
        os.remove(zip_path)
        callback(false, nil, "HTTP " .. tostring(code) .. " downloading " .. zip_url)
        return
    end

    local doc_path, extract_err = self:_extractDocument(zip_path, item_key, dest_dir)
    os.remove(zip_path)
    if not doc_path then
        callback(false, nil, extract_err)
        return
    end

    logger.dbg("WebDAVClient: downloaded", item_key, "->", doc_path)
    callback(true, doc_path, nil)
end

--- Check that Basic Auth against the WebDAV base URL is accepted, without
-- downloading or assuming any particular file exists there — used by the
-- "Test connection" button in main.lua's credentials dialog, so the user
-- can confirm their WebDAV details work without leaving that screen (or
-- waiting for a full library sync). A GET on the bare base URL is enough:
-- a 401 means the credentials were rejected; anything else means the
-- server accepted them and processed the request, whatever it answered
-- with (a directory listing, a 404 for "no index", ...).
-- @param callback function(ok, detail_string)
function WebDAVClient:test_connection(webdav_url, user, password, callback)
    local base = webdav_url:gsub("/*$", "/")
    local sink = {} -- body content doesn't matter, only the status code does

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, http.request{
        url = base,
        method = "GET",
        sink = ltn12.sink.table(sink),
        user = user,
        password = password,
    })
    socketutil:reset_timeout()

    if headers == nil then
        logger.warn("WebDAVClient: test_connection no response:", status or code)
        callback(false, "no response from " .. base .. ": " .. tostring(status or code))
        return
    end
    if code == 401 then
        callback(false, "HTTP 401 — WebDAV username/password rejected")
    else
        callback(true, "HTTP " .. tostring(code))
    end
end

return WebDAVClient
