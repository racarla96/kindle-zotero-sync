# kindle-zotero-sync — zotero.koplugin

A [KOReader](https://koreader.rocks/) plugin that syncs your [Zotero](https://www.zotero.org/) library — metadata via the Zotero Web API, PDF attachments via your own WebDAV server — and lets you browse and open items with KOReader's native reader, on a jailbroken e-ink Kindle.

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
- ⚠️ **Untested on a real device.** All of the above was written and syntax-checked (`luaL_loadfile` against liblua5.1) without access to a physical Kindle or a KOReader install — see [Known gaps](#known-gaps-before-relying-on-this) below before trusting it with your library.

## How it works

1. **Metadata** — [`ZoteroClient.lua`](./zotero.koplugin/ZoteroClient.lua) talks to the [Zotero Web API](https://www.zotero.org/support/dev/web_api/v3/start) (`api.zotero.org`), authenticated with an API key (`Zotero-API-Key` header). Sync is incremental: the cached `library/version` is sent as `?since=`, so a second sync only fetches what changed. Metadata is always synced for the **whole library** — that's what "Browse library" needs in order to show you something to pick from — but that's just JSON, no PDFs move yet.
2. **PDF downloads are opt-in, per item.** Nothing downloads automatically just because it exists in your Zotero library. In **Browse library**, tapping an item that isn't downloaded yet toggles it as queued (`[queued for sync]`); tapping it again unmarks it. The next **Sync now** downloads only what's marked. Tapping an item that's already downloaded opens it in the reader instead.
3. **PDF attachments** — instead of Zotero's own storage, this plugin expects a **WebDAV server you control**. Each attachment lives as `{item_key}.zip` on the WebDAV (the same layout Zotero's desktop client uses for WebDAV-based file sync) and is downloaded directly with HTTP Basic Auth via [`WebDAVClient.lua`](./zotero.koplugin/WebDAVClient.lua) — no Zotero storage quota involved.
4. **Delivery** — PDFs are extracted into KOReader's own data directory (`{DataStorage}/zotero/`) and opened straight in KOReader's native reader; "Browse library" in the plugin menu never reimplements PDF rendering.
5. **Resilience** — a failed download (network blip, WebDAV hiccup) is queued in [`ZoteroQueue.lua`](./zotero.koplugin/ZoteroQueue.lua) and retried automatically the next time KOReader reports the network as connected.

## Installing

1. Jailbreak your Kindle and install KOReader — see [kindlemodding.org](https://kindlemodding.org/) and the [KOReader install guide](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices).
2. Copy `zotero.koplugin/` into KOReader's `plugins/` directory on the device (typically `koreader/plugins/zotero.koplugin/`).
3. Restart KOReader. A **Zotero** entry should appear in the FileManager's menu.
4. Open **Zotero → Configure credentials** and fill in your API key, user ID, and WebDAV details (see below).
5. Run **Zotero → Sync now** to pull metadata (no PDFs yet).
6. Go to **Zotero → Browse library**, tap the items you actually want on the device to mark them, then run **Sync now** again to download just those.

## Getting your Zotero API key and user ID

1. Log into [zotero.org](https://www.zotero.org/) and go to **Settings → Security** ([zotero.org/settings/security](https://www.zotero.org/settings/security)).
2. Under **Applications**, click **Create new private key**. Give it a name (e.g. "kindle-sync") and grant at least **Allow library access** (read-only is enough).
3. Copy the generated key — Zotero only shows it once.
4. On the same page, your **userID for use in API calls** is shown near the top; copy that number too.

WebDAV credentials are the same ones configured in Zotero's own **Settings → Sync → File Syncing → WebDAV** — this plugin reads from that same server, it doesn't set it up for you.

## Testing the sync flow without the plugin

[`scripts/test_sync.sh`](./scripts/test_sync.sh) is a standalone bash/curl script that exercises the same flow (list library → find a PDF attachment → download its `.zip` from WebDAV → extract → validate) outside of KOReader, useful for confirming credentials/connectivity before trusting the Lua plugin with them:

```bash
cp config/config.example.json config/config.json
# fill in config/config.json — see § above for how to get these values
./scripts/test_sync.sh
```

`config/config.json` is only used by this test script and is gitignored. The plugin itself stores credentials separately, in KOReader's own `LuaSettings` (`{DataStorage}/settings/zotero.lua`), set via the in-app "Configure credentials" dialog.

## Known gaps before relying on this

This was built without a KOReader install or a physical Kindle to test against, so a few spots are best-effort and flagged with `NOTE:` comments in the source — check these first if something doesn't work:

- **`Menu` widget usage** in `main.lua` (item table shape, `onMenuSelect` signature, and `menu:updateItems()` to redraw a row in place after toggling its selection) follows the common pattern across KOReader plugins but wasn't run against a live `UIManager`.
- **`ReaderUI:showReader(path)`** in `main.lua` is the standard way plugins hand a file to the reader — verify against a recent KOReader checkout if PDFs don't open as expected.
- **Response header casing** (`Last-Modified-Version`) in `ZoteroClient.lua` is read case-insensitively as a hedge; confirm which casing KOReader's HTTP stack actually normalizes to.
- **`require("mime").b64`** in `WebDAVClient.lua` (LuaSocket's `mime` module, for the Basic Auth header) is assumed present since KOReader bundles LuaSocket — confirm it resolves on-device.
- KOReader ships a `webdav.koplugin` for cloud storage that's a closer precedent than `kosync.koplugin` for `WebDAVClient.lua`'s HTTP needs specifically — worth diffing against once you can test on-device.
- Nothing here has exercised real KOReader event ordering (`onNetworkConnected`, `registerToMainMenu`, etc.) — only Lua syntax was verified (`luaL_loadfile` via a locally-built liblua5.1 checker), not runtime behavior.

## Reference code, licensing

This repo is licensed under **CC BY 4.0**. KOReader's `kosync.koplugin` — used only as a local architectural reference while writing `zotero.koplugin` — is **AGPL-3.0** and is **never committed here**: if you keep a local copy for reference, put it outside the repo or somewhere covered by `.gitignore` (see `CLAUDE.md` §2 for the reasoning).

## Licencia

Este proyecto está licenciado bajo **Creative Commons Attribution 4.0 International (CC BY 4.0)**.
Puedes compartir y adaptar el código, incluso comercialmente, siempre que des crédito apropiado.

Texto legal completo: https://creativecommons.org/licenses/by/4.0/legalcode
Resumen: https://creativecommons.org/licenses/by/4.0/
