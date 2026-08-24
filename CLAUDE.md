# zotero.koplugin — Especificación de Proyecto

> Brief técnico para que Claude Code construya el proyecto de principio a fin, incluyendo la creación del repositorio en GitHub. Léelo completo antes de ejecutar nada.

## 1. Objetivo

Plugin de **KOReader** (Lua) que sincroniza una biblioteca de Zotero (metadata vía API REST + PDFs vía WebDAV propio) y deja los ítems navegables/abribles dentro de KOReader en Kindles e-ink jailbreados.

## 2. Decisión de arquitectura

Se descarta la ruta nativa GTK2/Meson y la ruta Mesquito/WAF exploradas inicialmente. **KOReader ya resuelve** motor de PDF con anotaciones, HTTP async, descompresión, persistencia de settings y widgets de UI para e-ink — reimplementar eso en C no aporta nada.

El proyecto se construye como plugin `zotero.koplugin`, usando **`kosync.koplugin`** (plugin oficial de sync de progreso de KOReader) como template arquitectónico directo. Los 5 archivos de referencia se entregan junto a este documento pero **no se commitean al repositorio**: `kosync.koplugin` es parte del código fuente de KOReader y está bajo licencia **AGPL-3.0**, incompatible con mezclarlo sin más en un repo licenciado como CC BY 4.0. Se usan solo como consulta local durante el desarrollo — el código que se escriba en `zotero.koplugin/` es original, inspirado en el *patrón* de diseño, no una copia ni un fork.

Los archivos de referencia y su rol:

| Archivo de referencia | Rol en `kosync` | Adaptación para `zotero.koplugin` |
|---|---|---|
| `main.lua` | Entry point, menú, settings, eventos de red | `main.lua`: mismo patrón `WidgetContainer:extend`, menú "Zotero" en FileManager, settings de credenciales |
| `KOSyncClient.lua` | Cliente REST genérico sobre **Spore** + middleware de auth | `ZoteroClient.lua`: cliente Spore para `api.zotero.org`, auth vía header `Zotero-API-Key` |
| `api.json` | Spec declarativo de endpoints Spore | `api_zotero.json`: endpoints `items`, `collections`, `library version` (ver sección 5) |
| `KOSyncQueue.lua` | Cola de reintentos en disco (dedup, expiración, cap) | `ZoteroQueue.lua`: mismo patrón para reintentar descargas de PDF fallidas |

**Módulo nuevo sin equivalente en kosync:** `WebDAVClient.lua` — el WebDAV de Zotero no es una API JSON limpia (devuelve `.zip` binarios + `.prop`), así que no encaja en el patrón Spore/Format.JSON de `KOSyncClient`. Se implementa aparte con `httpclient` (el mismo cliente HTTP de bajo nivel que usa el middleware `AsyncHTTP` de kosync) + `ffi/zlib` o `ffi/archiver` para descomprimir.

## 3. Estructura del repositorio

```
zotero-koplugin/
├── LICENSE                    # CC BY 4.0
├── README.md
├── CLAUDE.md                  # este archivo
├── zotero.koplugin/
│   ├── _meta.lua               # nombre/descripción del plugin (adaptado de reference/kosync/_meta.lua)
│   ├── main.lua                 # WidgetContainer, menú, orquestación de sync
│   ├── ZoteroClient.lua         # cliente Spore para api.zotero.org
│   ├── ZoteroQueue.lua          # cola de reintentos (descargas fallidas)
│   ├── WebDAVClient.lua         # descarga + extracción de adjuntos PDF
│   ├── LibraryCache.lua         # cache local de biblioteca (Persist/dump, igual que ZoteroQueue)
│   └── api_zotero.json          # spec Spore de la API de Zotero
├── config/
│   └── config.example.json      # plantilla de credenciales
└── scripts/
    └── test_sync.sh             # prueba end-to-end por SSH antes de cargar el plugin
```

## 4. Tareas para Claude Code (en orden)

### Fase 0 — Repositorio
1. `git init`.
2. Crear el repo remoto con licencia incluida:
   ```bash
   gh repo create zotero-koplugin --public \
     --description "KOReader plugin: sync a Zotero library (metadata + WebDAV PDFs) to your e-reader" \
     --license CC-BY-4.0
   ```
   Si `--license` falla o `gh` no está autenticado: crear el repo sin ese flag, descargar el texto legal completo de `https://creativecommons.org/licenses/by/4.0/legalcode.txt` como `LICENSE`, y añadir el aviso corto en el README (ver sección 6).
3. Los 5 archivos de referencia (`main.lua`, `KOSyncClient.lua`, `KOSyncQueue.lua`, `_meta.lua`, `api.json` de `kosync.koplugin`) se dejan **fuera del working tree del repo** — en una carpeta hermana, ej. `../kosync-reference/`, o en cualquier ruta listada en `.gitignore`. Nunca se commitean: son AGPL-3.0 y este repo es CC BY 4.0 (ver sección 2 y 6).
4. Commit inicial: `LICENSE`, `README.md`, `CLAUDE.md`.

### Fase 1 — Spec de la API de Zotero (`api_zotero.json`)
5. Definir en formato Spore (mismo formato que `reference/kosync/api.json`) los endpoints necesarios de `https://api.zotero.org`:
   - `get_library_version`: `GET /users/{userID}/items?limit=1` (leer header `Last-Modified-Version` de la respuesta).
   - `list_items`: `GET /users/{userID}/items?since={version}&format=json`.
   - `list_collections`: `GET /users/{userID}/collections`.
   - Auth: header `Zotero-API-Key` en vez del `x-auth-user`/`x-auth-key` de kosync — adaptar el middleware `KOSyncAuth` a un middleware `ZoteroAuth` equivalente en `ZoteroClient.lua`.

### Fase 2 — Cliente Zotero (`ZoteroClient.lua`)
6. Copiar la estructura de `KOSyncClient.lua`: `init()` monta Spore + middlewares (`Format.JSON`, `ZoteroAuth`, `AsyncHTTP` reutilizado tal cual).
7. Métodos: `get_library_version(api_key, user_id, callback)`, `list_items(api_key, user_id, since, callback)`, `list_collections(api_key, user_id, callback)`.
8. Mantener los timeouts cortos (patrón `PROGRESS_TIMEOUTS`/`AUTH_TIMEOUTS` de kosync) para no bloquear la UI en e-ink.

### Fase 3 — Cliente WebDAV (`WebDAVClient.lua`)
9. Función `download_attachment(webdav_url, user, password, item_key, dest_dir, callback)`:
   - `GET {webdav_url}/{item_key}.zip` con Basic Auth.
   - Guardar a un temporal, descomprimir con `ffi/zlib` o `ffi/archiver` (ver módulos ya presentes en KOReader).
   - Mover el PDF resultante a la carpeta de biblioteca del plugin (ej. `{DataStorage}/zotero/`).
10. En caso de fallo (red caída, 404), no relanzar: encolar en `ZoteroQueue` para reintento.

### Fase 4 — Cola de reintentos (`ZoteroQueue.lua`)
11. Copiar `KOSyncQueue.lua` casi literal, cambiando la semántica de la entrada de `{document, progress, ...}` a `{item_key, webdav_url, dest_dir}`. Mismo mecanismo de dedup/expiración/cap.
12. En `main.lua`, igual que kosync hace en `_onNetworkConnected`, llamar `ZoteroQueue:drain(...)` al reconectar wifi.

### Fase 5 — Cache local de biblioteca (`LibraryCache.lua`)
13. Usar `Persist` con codec `"dump"` (igual que `KOSyncQueue:_storage()`) para guardar la última versión sincronizada y un índice `{item_key → {title, creators, collection, tags, pdf_path}}`.
14. Sync incremental: en cada `main.lua:sync()`, comparar `get_library_version` contra la versión cacheada; si es mayor, pedir `list_items?since=`.

### Fase 6 — UI (`main.lua`)
15. Registrar entrada de menú "Zotero" en `FileManager` (`self.ui.menu:registerToMainMenu(self)`, igual que kosync).
16. Submenú: "Sincronizar biblioteca", "Configurar credenciales" (API key, user ID, URL/usuario/password WebDAV vía `MultiInputDialog`, igual que el diálogo de servidor custom de kosync), "Ver biblioteca" (lista de colecciones → ítems → abrir PDF).
17. Mostrar progreso con `InfoMessage`/`Notification` (no animaciones, refrescos completos), igual que `showSyncedMessage`/`showSyncError` en kosync.

## 5. Detalles de la API de Zotero (para `api_zotero.json`)

- Base URL: `https://api.zotero.org`
- Auth: header `Zotero-API-Key: <key>`
- Versión de biblioteca: header de respuesta `Last-Modified-Version` en cualquier request a `/items`.
- Sync incremental: parámetro `?since=<version>`.
- El WebDAV **no** pasa por esta API — se accede directo a la URL configurada por el usuario (ver conversación previa: `https://zotero.racarla.es/zotero/{item_key}.zip`, Basic Auth).

## 6. Licencia

**Creative Commons Attribution 4.0 International (CC BY 4.0)**.

- Texto legal completo: https://creativecommons.org/licenses/by/4.0/legalcode
- Aviso corto para el README si `gh --license` no genera el archivo automáticamente:
  ```
  This work is licensed under a Creative Commons Attribution 4.0 International License (CC BY 4.0).
  https://creativecommons.org/licenses/by/4.0/
  ```
- Nota: CC BY 4.0 no es la licencia más común para software (no cubre patentes ni tiene cláusulas de distribución de binarios como MIT/Apache 2.0). Se mantiene por ser la elección explícita del usuario; se puede reconsiderar más adelante si el proyecto crece y necesita contribuciones de terceros bajo una licencia más estándar en el ecosistema KOReader (que en general usa AGPL-3.0 para el core).

## 7. Config del usuario

```json
{
  "zotero_api_key": "",
  "zotero_user_id": "",
  "webdav_url": "https://zotero.racarla.es/zotero/",
  "webdav_user": "racarla96",
  "webdav_password": ""
}
```

Nunca commitear `config/config.json` con credenciales reales — solo `config.example.json`. Añadir `config/config.json` a `.gitignore`. Dentro del plugin instalado, las credenciales viven en `LuaSettings` (mismo mecanismo que `kosync.settings_file`), no en este archivo — el `config.json` es solo para el script de prueba de la Fase 0.

## 9. Notas de progreso

- **Fases 0-6 completadas** en una sola sesión (a petición explícita del usuario): repo actualizado, `.gitignore` protegiendo `example/` (verificado con `git check-ignore`), `zotero.koplugin/` completo (`api_zotero.json`, `ZoteroClient.lua`, `WebDAVClient.lua`, `ZoteroQueue.lua`, `LibraryCache.lua`, `main.lua`, `_meta.lua`), y `README.md` reescrito para la nueva arquitectura.
- **Verificación realizada:** los 6 archivos `.lua` pasan un chequeo de sintaxis (`luaL_loadfile` contra un `liblua5.1` compilado localmente con un wrapper C mínimo, ver historial de la sesión). **No** se ejecutó nada contra un KOReader real ni un Kindle físico — no había ninguno disponible en el entorno de generación.
- **Puntos marcados como "verificar en dispositivo"** (con comentarios `NOTE:` en el código y listados en el README bajo "Known gaps"): forma exacta del widget `Menu` (item_table/`onMenuSelect`) en `main.lua`; llamada `ReaderUI:showReader(path)`; casing del header `Last-Modified-Version` en `ZoteroClient.lua`; disponibilidad de `require("mime").b64` en `WebDAVClient.lua`. KOReader trae un `webdav.koplugin` propio (cloud storage) que es un precedente más cercano que `kosync.koplugin` para las necesidades HTTP de `WebDAVClient.lua` — vale la pena comparar contra él al probar en el dispositivo.
- **Desviación deliberada del brief:** `ZoteroQueue:drain()` (Fase 4, tarea 11) no es "casi literal" a `KOSyncQueue:drain()` — se cambió de una firma síncrona (`send_func(item) -> bool`) a callback-based (`download_func(item, cb)`), porque `WebDAVClient` es intrínsecamente asíncrono (coroutine + `httpclient`/Turbo) y envolverlo en una espera síncrona habría requerido una API de "pump" del UIManager no verificada. `main.lua` y `WebDAVClient.lua` están escritos alrededor de esta versión async de `drain()`.
- `manifest.json` y `meson.build` de la estructura original (Fase 0-4 del plan GTK2/C descartado) nunca se crearon — el nuevo plan (§2) no los necesita, `zotero.koplugin/` se instala copiando la carpeta directamente a `plugins/`.
- Directorios vacíos `src/sync/` y `src/ui/` (residuos del plan GTK2/C descartado) eliminados del working tree.

## 10. Sync selectivo por ítem (post-v0.1)

A petición del usuario, la descarga de PDFs dejó de ser automática para toda la biblioteca:

- `LibraryCache` ahora persiste un flag `wanted` por ítem (`LibraryCache:setWanted`), preservado entre syncs de metadata igual que `pdf_path`.
- `getPendingAttachments()` solo devuelve ítems con `wanted = true` y sin `pdf_path` — nada se descarga sin selección explícita.
- En "Browse library" (`main.lua:browseItems`), tocar un ítem no descargado alterna su estado `wanted` (`[queued for sync]`) y redibuja la fila con `menu:updateItems()`; tocar uno ya descargado lo abre en el lector.
- El sync de metadata (`Zotero:sync`) sigue trayendo **toda** la biblioteca (es barato, JSON) — es lo que alimenta el listado para poder seleccionar. Solo la descarga de PDFs quedó gateada por selección.
- `example/kosync.koplugin/` (la referencia AGPL-3.0) se eliminó del disco tras esta sesión — ya estaba fuera del repo (gitignored) y sus patrones quedaron incorporados en el código/comentarios; no queda ningún archivo AGPL en el entorno de trabajo.

## 8. Criterios de "hecho" para v0.1

- [ ] Repo en GitHub con `LICENSE` CC BY 4.0.
- [ ] Ningún archivo de `kosync.koplugin` (AGPL-3.0) commiteado al repo.
- [ ] `test_sync.sh` descarga al menos un PDF real desde el WebDAV del usuario.
- [ ] `zotero.koplugin` carga en KOReader sin errores (aparece en el menú).
- [ ] Sync incremental funciona (segunda ejecución no vuelve a pedir toda la biblioteca).
- [ ] Descarga de PDF con fallo de red se encola y se reintenta al reconectar wifi.
- [ ] Un ítem de la biblioteca se puede abrir desde el menú del plugin y KOReader lo renderiza.
