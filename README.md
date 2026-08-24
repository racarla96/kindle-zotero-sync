# kindle-zotero-sync — zotero.koplugin

A [KOReader](https://koreader.rocks/) plugin that syncs your [Zotero](https://www.zotero.org/) library — metadata via the Zotero Web API, attachments via your own WebDAV server — and lets you browse and open items with KOReader's native reader, on a jailbroken e-ink Kindle.

This is **not** a native GTK2/C app (that route was explored and dropped — see [`CLAUDE.md`](./CLAUDE.md) §2 for why). KOReader already solves PDF rendering, async HTTP, e-ink-friendly widgets, and settings persistence, so `zotero.koplugin` is plain Lua built on top of it, following the same architecture as KOReader's own [`kosync.koplugin`](https://github.com/koreader/koreader/tree/master/plugins/kosync.koplugin) (progress-sync plugin): a `WidgetContainer`-based entry point, a [Spore](https://github.com/koreader/koreader/tree/master/frontend/spore) REST client for the JSON API, and a disk-backed retry queue.

> The full technical brief — architecture rationale, phase-by-phase task list, API details — lives in [`CLAUDE.md`](./CLAUDE.md).

## Status

- ✅ **Fase 0** — Repository, CC BY 4.0 license.
- ✅ **Fase 1** — [`zotero.koplugin/api_zotero.json`](./zotero.koplugin/api_zotero.json): Spore spec for the Zotero Web API.
- ✅ **Fase 2** — [`zotero.koplugin/ZoteroClient.lua`](./zotero.koplugin/ZoteroClient.lua): Spore-based client (library version, incremental item listing, collections).
- ✅ **Fase 3** — [`zotero.koplugin/WebDAVClient.lua`](./zotero.koplugin/WebDAVClient.lua): downloads + extracts attachment `.zip`s from the WebDAV over Basic Auth.
- ✅ **Fase 4** — [`zotero.koplugin/ZoteroQueue.lua`](./zotero.koplugin/ZoteroQueue.lua): retry queue for failed downloads, drained on reconnect.
- ✅ **Fase 5** — [`zotero.koplugin/LibraryCache.lua`](./zotero.koplugin/LibraryCache.lua): local cache of items/collections + last synced library version (incremental sync).
- ✅ **Fase 6** — [`zotero.koplugin/main.lua`](./zotero.koplugin/main.lua): FileManager menu, credentials dialog, sync orchestration, collection/item browser.
- ✅ **`scripts/test_sync.sh` validated against a real Zotero account + WebDAV** — confirms the API key/user ID/WebDAV credential flow (see [Getting your Zotero API key](#getting-your-zotero-api-key-and-user-id) below) actually works end-to-end.
- ✅ **Plugin confirmed running on a real Kindle**: menu registers and renders correctly (Sync now / Browse library / Configure credentials / Downloads), credentials save. A first attempt at "Sync now" hit `Could not reach the Zotero API` — see [Troubleshooting](#troubleshooting-could-not-reach-the-zotero-api-or-similar-errors-on-device) — but a later run with the current code succeeded.
- ⚠️ **Format filtering, the WebDAV enable toggle, the "Downloads" status screen, the `filemanagerutil`-based download directory, and the tap-to-download-immediately flow are all new since that last confirmed device run** — written and syntax-checked (`luaL_loadfile` against liblua5.1) but not yet exercised on-device. See [Known gaps](#known-gaps-before-relying-on-this) below.
- ✅ **Confirmed on-device (partial):** metadata sync, Browse library's item listing, and "Test connection"'s Zotero API check all work on the real Kindle. ✅ **Fixed from real on-device symptoms** (not guesses): the "Downloads" crash, downloads/"Test connection" hanging forever with no error, and — from a real error message this time — WebDAV requests crashing on `UIManager.looper` being nil, which is why `WebDAVClient.lua` was rewritten around synchronous `socket.http` instead of the Turbo-based `httpclient`. See [Known gaps](#known-gaps-before-relying-on-this) for all three. None of these fixes has been re-tested on-device yet.

## How it works

1. **Metadata** — [`ZoteroClient.lua`](./zotero.koplugin/ZoteroClient.lua) talks to the [Zotero Web API](https://www.zotero.org/support/dev/web_api/v3/start) (`api.zotero.org`), authenticated with an API key (`Zotero-API-Key` header). Sync is incremental: the cached `library/version` is sent as `?since=`, so a second sync only fetches what changed. Metadata is always synced for the **whole library** — that's what "Browse library" needs in order to show you something to pick from — but that's just JSON, nothing downloads yet.
2. **Format compatibility is checked, but shown, not hidden.** `LibraryCache.lua` checks each attachment's file extension against KOReader's [documented supported formats](https://github.com/koreader/koreader) — PDF, EPUB, DjVu, XPS, CBZ/CBT/CBR, FB2, PDB, TXT, HTML, RTF, CHM, DOC(X), MOBI/AZW(3), ZIP. Every real attachment still shows up in Browse library (so you can see it exists), but one in an unsupported format is rendered dimmed with a `[unsupported format]` tag and can't be selected — tapping it explains why instead of toggling it queued. (Non-attachment items — Zotero notes, standalone web snapshots — aren't attachments at all and never show up either way.)
3. **Downloads are opt-in, per item, and immediate.** Nothing downloads automatically just because it exists in your Zotero library. In **Browse library**, tapping an item that isn't downloaded yet downloads it right then and there (no "mark it and wait for the next sync" step) — the row shows `[downloading…]` while it's in flight, then a `✓` prefix once it's confirmed on the device, or gets queued for retry (see point 6) if it fails. Tapping an item that's already downloaded (✓) opens it in the reader instead.
4. **Attachments come from a WebDAV server you control**, instead of Zotero's own storage — **and it's off by default**. The **Configure credentials** dialog has an **"Enable WebDAV PDF downloads"** checkbox right alongside the WebDAV fields themselves (not inferred from the fields being non-empty — an explicit choice, saved together with the credentials). Without it checked, metadata sync and item selection still work — items just stay queued forever, and "Downloads" tells you why. Once enabled, each attachment is downloaded as `{item_key}.zip` from the WebDAV (the layout Zotero's desktop client itself uses for WebDAV file sync) over HTTP Basic Auth via [`WebDAVClient.lua`](./zotero.koplugin/WebDAVClient.lua) — no Zotero storage quota involved.
5. **Delivery** — documents are extracted into a `zotero/` subfolder of whatever KOReader considers its home/library directory (`filemanagerutil.getDefaultDir()` — respects a custom `home_dir` setting if you've set one, otherwise `Device.home_dir`, which is `/mnt/us` on Kindle). That means synced files show up automatically under **Home → zotero/** in KOReader's normal file browser, with no extra configuration — "Browse library → tap to open" also opens them directly, without needing to navigate there.
6. **Resilience** — a failed download (network blip, WebDAV hiccup) is queued in [`ZoteroQueue.lua`](./zotero.koplugin/ZoteroQueue.lua) and retried automatically the next time KOReader reports the network as connected, or on demand from **Zotero → Downloads**.
7. **"Downloads"** in the Zotero menu shows the full picture at any point: what's downloading right now, what's queued (selected, not yet attempted), what's waiting for a retry, and what's already on the device — see `Zotero:showDownloadsStatus()` in `main.lua`.

## Installing

1. Jailbreak your Kindle and install KOReader — see [kindlemodding.org](https://kindlemodding.org/) and the [KOReader install guide](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices).
2. Copy `zotero.koplugin/` into KOReader's `plugins/` directory on the device (typically `koreader/plugins/zotero.koplugin/`).
3. Restart KOReader. A **Zotero** entry should appear in the FileManager's menu.
4. Open **Zotero → Configure credentials**, fill in your API key, user ID, and WebDAV details (see below), and hit **"Test connection"** to check both against the real Zotero API / WebDAV server without leaving the dialog.
5. Run **Zotero → Sync now** to pull metadata (nothing downloads yet).
6. If you want attachments to actually download: reopen **Configure credentials**, check **"Enable WebDAV PDF downloads"**, and save.
7. Go to **Zotero → Browse library** and tap the items you want — each tap downloads it immediately, no extra sync step. Check **Zotero → Downloads** any time to see what's downloading, retrying, or already on the device (`✓`).

## Getting your Zotero API key and user ID

1. Log into [zotero.org](https://www.zotero.org/), then go straight to **[zotero.org/settings/keys](https://www.zotero.org/settings/keys)** — this is the reliable direct link. (Zotero's settings navigation has changed over time; if you go through **Settings → Security** instead and don't see an "Applications" section there, use the direct `/settings/keys` link above rather than hunting for it.)
2. Click **Create new private key**. Give it a name (e.g. "kindle-sync") and grant at least **Allow library access** (read-only is enough — the plugin never writes to your library).
3. Copy the generated key — Zotero only shows it once. This is what goes in `zotero_api_key` / the plugin's "Configure credentials" dialog. It is **not** your account password.
4. Your **userID for use in API calls** is shown near the top of the same page; copy that number into `zotero_user_id`.

WebDAV credentials are the same ones configured in Zotero's own **Settings → Sync → File Syncing → WebDAV** (in the Zotero desktop app, not the website) — this plugin reads from that same server, it doesn't set it up for you.

## Testing the sync flow without the plugin

[`scripts/test_sync.sh`](./scripts/test_sync.sh) is a standalone bash/curl script that exercises the same flow (list library → find a PDF attachment → download its `.zip` from WebDAV → extract → validate) outside of KOReader, useful for confirming credentials/connectivity before trusting the Lua plugin with them:

```bash
cp config/config.example.json config/config.json
# fill in config/config.json — see § above for how to get these values
./scripts/test_sync.sh
```

`config/config.json` is only used by this test script and is gitignored. The plugin itself stores credentials separately, in KOReader's own `LuaSettings` (`{DataStorage}/settings/zotero.lua`), set via the in-app "Configure credentials" dialog.

## Troubleshooting "Could not reach the Zotero API" (or similar errors) on-device

The plugin's error messages are intentionally generic (e-ink, no room for stack traces) — the real cause is only in KOReader's own log. Work through this in order rather than guessing:

1. **Rule out credentials/network first, without touching the Kindle.** Run `scripts/test_sync.sh` (see above) with the *exact same* API key, user ID and WebDAV password you typed into "Configure credentials" on the device. This hits the real Zotero API and your real WebDAV from your computer.
   - If it **fails** here too: it's a credentials or connectivity problem, not a plugin bug — recheck the values (the API key from step 2 above, not your account password; the userID as a plain number; the WebDAV password from Zotero's desktop sync settings).
   - If it **succeeds** here: your credentials are correct, so the device-side failure is either the Kindle's Wi-Fi not actually being connected at sync time, or a bug in `ZoteroClient.lua`'s Spore/AsyncHTTP handling or `WebDAVClient.lua`'s synchronous `socket.http` requests (see [Known gaps](#known-gaps-before-relying-on-this) below) — go to step 2.
2. **Get the real error from KOReader's log.** Logs live in KOReader's own install directory, **not** inside `plugins/zotero.koplugin/` — `koreader.log` is the regular running log, `crash.log` is written automatically on an actual crash (both under `/mnt/us/koreader/` for a typical Kindle jailbreak install). Two ways to get at them:
   - **No SSH needed:** in KOReader, **Menu → Help → Bug Report** packages the logs into a file for easier viewing/sharing.
   - **Over SSH** (the jailbreak's Dropbear SSH, if enabled): enable verbose logging first if you haven't — **gear icon → More tools → Developer options → Enable debug logging** — then reproduce the failure (tap "Sync now" again), and:
     ```bash
     ssh root@<kindle-ip>
     tail -n 200 /mnt/us/koreader/koreader.log | grep -i zotero
     cat /mnt/us/koreader/crash.log   # only present if it actually crashed
     ```
   - Every failure path in this plugin logs before showing the generic UI message (`logger.dbg`/`logger.warn` calls in `ZoteroClient.lua`, `WebDAVClient.lua`, `main.lua`) — that line will say whether it was an HTTP status, a Lua error from a failed `pcall`, or something else entirely. A hard crash/freeze (rather than a graceful in-app error message) is what `crash.log` is for specifically.
3. Paste the relevant log lines somewhere you can compare them against the `NOTE:` comments in the source — most likely culprits are listed in [Known gaps](#known-gaps-before-relying-on-this) below.

## Known gaps before relying on this

This was built without a KOReader install or a physical Kindle to test against, so a few spots are best-effort and flagged with `NOTE:` comments in the source — check these first if something doesn't work:

- ✅ **Fixed with a real on-device error message** (a screenshot, not a guess this time): "Test connection" reported `WebDAV: failed (internal error: frontend/httpclient.lua:18: attempt to index field 'looper' (a nil value))`. That's `UIManager.looper` — the Turbo event loop KOReader lazily creates for async HTTP — being `nil` in this context; `WebDAVClient.lua` used to call the low-level `httpclient` module directly with no guard for that. (Why the Zotero API side worked anyway: Spore's own `AsyncHTTP` middleware in `ZoteroClient.lua` checks `if not UIManager.looper then return end` and silently falls back to Spore's built-in synchronous transport — `WebDAVClient.lua` had no such fallback.) Fixed by rewriting `WebDAVClient.lua` from scratch around synchronous `socket.http` + `ltn12`, fetched and diffed line-by-line against KOReader's own real, on-device-proven WebDAV code — `plugins/cloudstorage.koplugin/providers/webdav.lua` — via `gh api`, not assumed. That module never touches `httpclient`/`UIManager.looper` at all, and its Basic Auth uses LuaSocket's built-in `user`/`password` request fields instead of a hand-built header, so `mime.b64` is gone entirely too. Confirmed against a second real KOReader networking module (`opds.koplugin/opdsbrowser.lua`) that plain `socket.http.request` — with no `ssl.https` import anywhere in either file — is really how HTTPS requests are made in this codebase, which matters since the user's own WebDAV server is `https://`.
- ✅ **Fixed (superseded by the rewrite above, kept for history): downloads and "Test connection" first got stuck forever with no error at all**, before the *next* attempt started producing the real error message documented above. Root cause of that first symptom: every `coroutine.resume(co, ...)` call in the old Turbo-based `download_attachment`/`test_connection` discarded its `ok, err` return values, so any error inside the coroutine was silently swallowed — no log, no `callback(...)`, UI hung forever. That fix (checking `ok, err`, plus adding the `NetworkMgr:willRerunWhenOnline()` guard `sync()` already had to `downloadPendingAttachments`/`drainQueue`/"Test connection") is what turned the silent hang into the real, visible error above — moot now since the coroutine/httpclient approach it patched has been replaced entirely, but the `NetworkMgr` guards it added are still in place and still worthwhile.
- ✅ **Changed: downloads are now immediate, not queued-then-synced.** Tapping an undownloaded item in Browse library used to just toggle a `wanted` flag for the next "Sync now" to act on — confusing, and it hid the failure above behind an extra step. A tap now calls the new `Zotero:downloadItemNow()` directly: the row shows `[downloading…]`, then either a `✓` prefix (success) or a queued-for-retry message (failure) in place, no separate sync step needed. The old `wanted`/`getPendingAttachments` machinery is still there and still swept up by every sync — purely as a migration path for anything a previous version of the plugin already marked `wanted`, not a first-class flow anymore. Not yet exercised live — see the `✓` glyph note below.
- ✅ **Fixed with a real crash.log traceback**, not a guess: opening "Downloads" crashed KOReader with `attempt to call local '_' (a number value)` at `main.lua:showDownloadsStatus`. Root cause: this file aliases `local _ = require("gettext")`, and three `for _, x in ipairs(...) do ... _("some string") ... end` loops in that function reused `_` as the loop's own discarded variable — inside the loop body, `_` was shadowed by the (numeric) loop index instead of the translator, so calling `_("queued")` etc. tried to *call a number*. Fixed by renaming every discarded loop variable in `main.lua` to `_i`/`_key` instead of `_` (this file is the only one in the plugin that aliases `_` to gettext, so the other modules were never at risk). The `separator = true` field removed in the previous fix and the `pcall` wrapper around this screen were both real, worthwhile fixes too — the `pcall` in particular is exactly what turned the *second* occurrence of this same bug into a graceful `WARN` in the log instead of a second hard crash — but neither was the actual root cause; this was.
- **The `✓` checkmark prefix** (Browse library and Downloads, for on-device items) is a plain Unicode character like the ellipsis/en-dash already confirmed to render fine in this UI, but hasn't itself been exercised on a real device yet — flag it if it shows as a box/missing-glyph and it'll get swapped for plain text.
- **`Menu` widget usage** in `main.lua` (item table shape, `onMenuSelect` signature, `dim = true` to render unsupported-format rows disabled, and `menu:updateItems()` to redraw a row in place after toggling its selection) follows the common pattern across KOReader plugins but wasn't run against a live `UIManager` — this includes the newer "Downloads" status screen.
- **`ReaderUI:showReader(path)`** in `main.lua` is the standard way plugins hand a file to the reader — verify against a recent KOReader checkout if documents don't open as expected.
- **Response header casing** (`Last-Modified-Version`) in `ZoteroClient.lua` is read case-insensitively as a hedge; confirm which casing KOReader's HTTP stack actually normalizes to.
- **`SUPPORTED_EXTENSIONS`** in `LibraryCache.lua` is sourced from KOReader's own documented format list (confirmed via its GitHub README), but a few close siblings of the confirmed formats (docx, azw/azw3, cbr/cb7) were added by inference rather than individually confirmed — drop any that don't actually open.
- **`filemanagerutil.getDefaultDir()`** (used for the download destination) and `Device.home_dir` on Kindle (`/mnt/us`) were verified directly against KOReader's current source rather than assumed, unlike most of the items above — comparatively low risk, but still unverified against a live install's actual `home_dir` setting.
- **The "Enable WebDAV PDF downloads" checkbox in "Configure credentials"** grafts a `CheckButton` onto the `MultiInputDialog` via `dialog:addWidget()` so it lives alongside the WebDAV fields instead of being a separate menu entry. Both `addWidget()` and `CheckButton` are real, source-verified KOReader APIs, but this specific combination — including whether `parent = dialog` is the right target for a redraw on tap — was never exercised live.
- **The dialog's "Test connection" button** adds a second `buttons` row (confirmed as a normal, supported case in `inputdialog.lua`'s source — unlike the `separator` field bug above) and calls `ZoteroClient:get_library_version` / `WebDAVClient:test_connection` directly from the dialog. The two client calls themselves reuse already-existing, previously-used code paths, but invoking them from inside this specific dialog's button handling hasn't run on a live device yet. Its `guard()` helper pcall-wraps the sync setup *and* both async callbacks individually (not just the outermost call — an async callback runs later, outside any pcall around the code that kicked off the request), learning from the fact that `showDownloadsStatus`'s single outer pcall wouldn't have caught an error inside its own async paths either.
- **Expected flow for "Test connection":** tap it → a brief "Testing…" message (1s) → once the async Zotero/WebDAV calls actually complete, a second, longer message (6s) with the real result ("Zotero API: OK/failed", plus "WebDAV: OK/failed (detail)" if those fields are filled in). This is exactly the flow that was silently breaking (see the fixed bug above) — if "Testing…" is still all that ever shows after that fix, check `koreader.log` for a `WebDAVClient:` or `ZoteroClient:` warning line.
- Nothing here has exercised real KOReader event ordering (`onNetworkConnected`, `registerToMainMenu`, etc.) — only Lua syntax was verified (`luaL_loadfile` via a locally-built liblua5.1 checker), not runtime behavior.

## Licencia

Este proyecto está licenciado bajo **Creative Commons Attribution 4.0 International (CC BY 4.0)**.
Puedes compartir y adaptar el código, incluso comercialmente, siempre que des crédito apropiado.

Texto legal completo: https://creativecommons.org/licenses/by/4.0/legalcode
Resumen: https://creativecommons.org/licenses/by/4.0/
