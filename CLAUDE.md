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

## 8. Criterios de "hecho" para v0.1

- [x] Repo en GitHub con `LICENSE` CC BY 4.0.
- [x] Ningún archivo de `kosync.koplugin` (AGPL-3.0) commiteado al repo.
- [x] `test_sync.sh` descarga al menos un PDF real desde el WebDAV del usuario. — verificado 2026-08-24 contra la cuenta real del usuario (userID 9440868): API de Zotero, WebDAV y extracción de PDF funcionan de punta a punta.
- [x] `zotero.koplugin` carga en KOReader sin errores (aparece en el menú). — confirmado en Kindle real: aparecen "Sincronizar ahora", "Browse library", "Configure credentials", "Retry queue (empty)".
- [ ] Sync incremental funciona (segunda ejecución no vuelve a pedir toda la biblioteca). — bloqueado por el bug de abajo.
- [ ] Descarga de PDF con fallo de red se encola y se reintenta al reconectar wifi.
- [ ] Un ítem de la biblioteca se puede abrir desde el menú del plugin y KOReader lo renderiza.

## 9. Bug conocido: "Could not reach the Zotero API" en dispositivo real — RESUELTO (¿solo)

Detectado 2026-08-24 en un Kindle real, con credenciales confirmadas correctas (ver checklist arriba: `test_sync.sh` funciona con las mismas credenciales). El menú del plugin se registra y renderiza bien, pero "Sincronizar ahora" fallaba en la llamada a `ZoteroClient:list_items`. Diagnóstico completo documentado en el README (§ Troubleshooting: primero `test_sync.sh` en el PC, luego log de KOReader por SSH).

**Actualización, mismo día:** el usuario reporta que "la versión que había actualmente" funciona al reintentar en el Kindle real. No se llegó a confirmar la causa raíz exacta vía log SSH (seguía pendiente cuando se resolvió solo) — candidatos más probables que quedan sin descartar del todo: wifi no conectado en el primer intento, o un problema transitorio de red/servidor de Zotero. El SSH al dispositivo (IP/credenciales) sigue sin configurarse en esta sesión; si el problema reaparece, retomar por ahí.

## 10. Notas de progreso

- **Fases 0-6 completadas** en una sola sesión (a petición explícita del usuario): repo actualizado, `.gitignore` protegiendo `example/` (verificado con `git check-ignore`), `zotero.koplugin/` completo (`api_zotero.json`, `ZoteroClient.lua`, `WebDAVClient.lua`, `ZoteroQueue.lua`, `LibraryCache.lua`, `main.lua`, `_meta.lua`), y `README.md` reescrito para la nueva arquitectura.
- **Verificación realizada:** los 6 archivos `.lua` pasan un chequeo de sintaxis (`luaL_loadfile` contra un `liblua5.1` compilado localmente con un wrapper C mínimo, ver historial de la sesión). Posteriormente se validó `test_sync.sh` contra la cuenta real del usuario (ver checklist arriba) y se probó el plugin en un Kindle real (ver §9).
- **Puntos marcados como "verificar en dispositivo"** (con comentarios `NOTE:` en el código y listados en el README bajo "Known gaps"): forma exacta del widget `Menu` (item_table/`onMenuSelect`/`menu:updateItems()`) en `main.lua`; llamada `ReaderUI:showReader(path)`; casing del header `Last-Modified-Version` en `ZoteroClient.lua`; disponibilidad de `require("mime").b64` en `WebDAVClient.lua`. KOReader trae un `webdav.koplugin` propio (cloud storage) que es un precedente más cercano que `kosync.koplugin` para las necesidades HTTP de `WebDAVClient.lua` — vale la pena comparar contra él al probar en el dispositivo.
- **Desviación deliberada del brief:** `ZoteroQueue:drain()` (Fase 4, tarea 11) no es "casi literal" a `KOSyncQueue:drain()` — se cambió de una firma síncrona (`send_func(item) -> bool`) a callback-based (`download_func(item, cb)`), porque `WebDAVClient` es intrínsecamente asíncrono (coroutine + `httpclient`/Turbo) y envolverlo en una espera síncrona habría requerido una API de "pump" del UIManager no verificada. `main.lua` y `WebDAVClient.lua` están escritos alrededor de esta versión async de `drain()`.
- `manifest.json` y `meson.build` de la estructura original (Fase 0-4 del plan GTK2/C descartado) nunca se crearon — el nuevo plan (§2) no los necesita, `zotero.koplugin/` se instala copiando la carpeta directamente a `plugins/`.
- Directorios vacíos `src/sync/` y `src/ui/` (residuos del plan GTK2/C descartado) eliminados del working tree.
- Sync selectivo por ítem (post-v0.1, a petición del usuario): `LibraryCache` persiste un flag `wanted` por ítem (`LibraryCache:setWanted`), preservado entre syncs de metadata igual que `pdf_path`. `getPendingAttachments()` solo devuelve ítems con `wanted = true` y sin `pdf_path` — nada se descarga sin selección explícita. En "Browse library" (`main.lua:browseItems`), tocar un ítem no descargado alterna su estado `wanted` (`[queued for sync]`) y redibuja la fila con `menu:updateItems()`; tocar uno ya descargado lo abre en el lector. El sync de metadata sigue trayendo toda la biblioteca (es barato, JSON) — solo la descarga de PDFs quedó gateada por selección.
- `example/kosync.koplugin/` (la referencia AGPL-3.0) se eliminó del disco tras la sesión del pivote a KOReader — ya estaba fuera del repo (gitignored) y sus patrones quedaron incorporados en el código/comentarios; no queda ningún archivo AGPL en el entorno de trabajo.
- El README ganó una sección "Troubleshooting" con el flujo de diagnóstico validado en esta sesión: primero `test_sync.sh` en el PC (descarta credenciales), luego log de KOReader vía SSH (`koreader.log`, requiere activar "Enable debug logging" en Developer options) si el fallo persiste solo en el dispositivo. También se corrigieron las instrucciones de la API key: el enlace directo y fiable es `zotero.org/settings/keys`, no siempre aparece una sección "Applications" bajo Settings → Security.

## 11. Filtro de formatos, WebDAV como checkbox explícito, carpeta de destino real, y panel de Downloads (post-v0.1, mismo día)

A petición del usuario (tras confirmar que el plugin ya sincroniza en su Kindle real):

- **Filtro por formato compatible con KOReader** (`LibraryCache.lua`): se sustituyó el filtro estricto `contentType == "application/pdf"` por `is_koreader_document()`, que mira la extensión del campo `filename` de la API de Zotero contra una whitelist (`SUPPORTED_EXTENSIONS`) — pdf, epub, djvu/djv, xps, cbz/cbt/cbr/cb7, fb2, pdb, txt, html/htm, rtf, chm, doc/docx, mobi/azw/azw3, zip. Lista verificada contra la documentación real de KOReader vía WebSearch (no inventada), salvo docx/azw/azw3/cbr/cb7 que son inferencias razonables sobre formatos hermanos, marcadas como tal en el README. `WebDAVClient.lua` (`_extractDocument`, antes `_extractPdf`) ya no busca solo `*.pdf` dentro del zip — toma el primer archivo que no sea `.prop` y preserva su extensión original al renombrar.
- **WebDAV pasó a requerir un toggle explícito**, no solo campos rellenos: nuevo setting `webdav_enabled` (default `false`) + entrada de menú "Enable WebDAV PDF downloads" con `checked_func`/`callback` (patrón verificado, copiado del toggle "Automatically keep documents in sync" de `kosync.koplugin`), con `enabled_func` que solo permite activarlo si los campos de WebDAV ya están rellenos. `isWebDAVConfigured()` ahora exige `webdav_enabled == true` además de los campos.
- **Carpeta de destino cambiada** de `{DataStorage}/zotero/` (interna, invisible en la librería normal) a `filemanagerutil.getDefaultDir() .. "/zotero"` — verificado directamente contra el código fuente real de KOReader (`frontend/apps/filemanager/filemanagerutil.lua` y `frontend/device/kindle/device.lua` vía WebFetch, no asumido): `getDefaultDir()` devuelve `Device.home_dir` si no hay `home_dir` custom configurado por el usuario, y en Kindle `Device.home_dir = "/mnt/us"` (no `/mnt/us/documents` como se asumía antes). Así los documentos aparecen solos bajo Home → zotero/ en el explorador de archivos normal de KOReader.
- **Nuevo panel "Downloads"** (`Zotero:showDownloadsStatus()`), reemplaza la entrada de menú "Retry queue": muestra en un único listado qué se está descargando ahora mismo (`self.active_download_key`, trackeado en `downloadPendingAttachments`/`drainQueue`), qué está en cola (seleccionado, sin intentar aún), qué espera reintento (contenido real de `ZoteroQueue`, no solo el contador), y qué ya está en el dispositivo — con acción "↻ Retry all now" y apertura directa de ítems ya descargados desde ahí mismo.
- Renombrado interno (sin tocar el campo persistido `pdf_path`, para no romper la cache ya sincronizada del usuario): `pdfDir()` → `documentDir()`, `openPdf()` → `openDocument()`, textos de UI "PDF(s)" → "document(s)" donde aplicaba.
- Todo verificado con el syntax-checker local (`liblua5.1`) tras cada cambio; nada de esto se ha probado aún en el Kindle real — queda añadido a "Known gaps" del README.
- Ítems en formato no soportado por KOReader: a petición del usuario, ya no se ocultan del todo en "Browse library" — `LibraryCache.lua` separó el filtro en `is_attachment()` (qué entra en la lista) e `is_supported_format()` (qué es seleccionable, expuesto como `LibraryCache:isSupportedFormat()`). `main.lua:browseItems()` los muestra con `dim = true` y etiqueta `[unsupported format]`; tocarlos explica por qué en vez de marcarlos para sync. `getPendingAttachments()` sigue exigiendo formato soportado, así que nunca pueden llegar a descargarse aunque ahora se vean.
- Checkbox de WebDAV movido dentro de "Configure credentials": a petición del usuario, dejó de ser una entrada de menú separada (`checked_func`/`callback` sobre `Menu`) y pasó a vivir en el mismo `MultiInputDialog` que los campos de WebDAV, vía `dialog:addWidget()` con un widget `CheckButton` (ambas APIs verificadas contra el código fuente real de KOReader — `frontend/ui/widget/multiinputdialog.lua`, `frontend/ui/widget/checkbutton.lua` — pero la combinación de ambas nunca se probó en vivo). `hasWebDAVFields()` se eliminó por quedar sin uso; `isWebDAVConfigured()` sigue exigiendo los 3 campos de WebDAV además del checkbox, así que marcarlo sin rellenar los campos es inofensivo.

## 12. Bug confirmado: "Downloads" petaba KOReader — mitigado, causa raíz sin confirmar

El usuario reportó que tocar "Downloads" en el menú principal congelaba/crasheaba KOReader. Sin acceso al log real del dispositivo (SSH sigue pendiente de configurar en esta sesión), se investigó por revisión de código contra el código fuente real de `frontend/ui/widget/menu.lua`:

- **Bug confirmado y corregido:** `showDownloadsStatus()` ponía `separator = true` en una fila de `item_table` — ese campo es válido en el menú principal (TouchMenu/`sub_item_table` de `addToMainMenu`), pero **no existe** en el widget genérico `Menu:new{item_table=...}` que usan "Browse library" y "Downloads" (confirmado vía WebFetch del archivo real, que no menciona "separator" en ningún sitio). Quitado.
- **Precaución adicional:** se quitó el glifo "↻" de esa misma fila (el archivo estaba en UTF-8 válido, así que no era corrupción de bytes, pero es un codepoint bastante raro que podría no estar en la fuente de KOReader — se sustituyó por texto plano por si acaso). Nota: el elipsis "…" en "Syncing Zotero library…" ya se había confirmado que renderiza bien en un sync real anterior, así que los caracteres unicode comunes no son sospechosos en general.
- **Mitigación defensiva:** `showDownloadsStatus()` ahora envuelve la lógica real (renombrada `_showDownloadsStatusImpl`) en `pcall`, mostrando un `InfoMessage` de error en vez de crashear si algo falla. **Importante:** esto solo cubre errores síncronos antes de `UIManager:show(menu)` — si el crash ocurre durante el renderizado/paint del `Menu` widget (llamado más tarde por el loop de UIManager), el `pcall` no lo atrapará. No es una solución garantizada, es reducción de riesgo mientras no hay log real.
- **Pendiente:** seguimos sin SSH configurado a este Kindle en la sesión. Si el crash persiste tras estos cambios, el siguiente paso ineludible es sacar el traceback real de `koreader.log`/`crash.log` (ver README § Troubleshooting) — sin eso, cualquier fix adicional sigue siendo una conjetura basada en lectura de código, no en evidencia del fallo real.
- **Ubicación de los logs, aclarada:** viven en el propio directorio de instalación de KOReader (`/mnt/us/koreader/koreader.log` y `.../crash.log` en un Kindle típico), no dentro de `plugins/zotero.koplugin/`. `crash.log` se genera solo si hubo un crash real de verdad. Alternativa sin SSH: Menú → Help → Bug Report empaqueta los logs para verlos/compartirlos.

## 13. Botón "Test connection" en Configure credentials (post-v0.1)

A petición del usuario: se quitó el texto extra del checkbox ("(needs the WebDAV fields above filled in)" — ya no era necesario explicarlo) y se añadió un botón "Test connection" al mismo `MultiInputDialog`, para poder verificar credenciales sin salir del diálogo ni esperar a un sync completo.

- Nueva segunda fila de `buttons` en el diálogo (confirmado contra el código fuente real de `frontend/ui/widget/inputdialog.lua` que filas múltiples de botones son un caso normal y soportado — a diferencia del bug de `separator` de la sección 12, esta vez se verificó ANTES de usarlo).
- El botón lee los campos actuales con `dialog:getFields()` (sin necesidad de haber pulsado Save antes) y llama a `ZoteroClient:get_library_version()` (ya existente, reutilizado tal cual) para probar la API de Zotero, y al nuevo `WebDAVClient:test_connection()` para probar el WebDAV — un simple `GET` a la URL base con Basic Auth: `401` = credenciales rechazadas, cualquier otro código = credenciales aceptadas (no hace falta que exista ningún archivo concreto).
- Resultado mostrado en un único `InfoMessage` con el estado de ambos por separado.
- Verificado con el syntax-checker local; la combinación específica de este botón dentro del diálogo (como todo lo demás en esta sesión) no se ha probado en un KOReader real todavía.

## 14. Causa raíz real del crash de "Downloads" — confirmada con `crash.log` real

El usuario copió `/mnt/us/koreader/crash.log` al directorio del repo (fuera de git, se descartó tras leerlo). Traceback real:

```
./luajit: plugins/zotero.koplugin/main.lua:420: attempt to call local '_' (a number value)
stack traceback:
	plugins/zotero.koplugin/main.lua:420: in function 'showDownloadsStatus'
	plugins/zotero.koplugin/main.lua:180: in function 'callback'
	...
```

**Causa raíz real, distinta de lo que se había arreglado en la §12:** `main.lua` hace `local _ = require("gettext")` a nivel de archivo. Tres bucles dentro de `_showDownloadsStatusImpl()` usaban `for _, x in ipairs(...) do ... _("algo") ... end` — la variable de descarte del bucle también se llamaba `_`, así que dentro del cuerpo del bucle tapaba a la función de traducción con el índice numérico del bucle. Al llamar `_("queued")` etc., Lua intentaba "llamar" un número → exactamente el mensaje del crash.

- El log también confirma que el `pcall` de la §12 **sí funcionó**: la segunda vez que el usuario probó (ya con esa versión desplegada), el mismo bug quedó como `WARN Zotero: showDownloadsStatus failed: ...` en el log en vez de crashear KOReader — buena señal de que esa mitigación defensiva era correcta, aunque no arreglara la causa real.
- Fix real: renombradas TODAS las variables de descarte `for _, ...` de `main.lua` a `_i`/`_key` (los otros 4 archivos del plugin no hacen `require("gettext")` como `_`, así que nunca tuvieron este riesgo — verificado con grep). `browseCollections`/`browseItems` nunca crashearon porque sus bucles no llaman a `_(...)` directamente dentro del cuerpo (pasan por `itemLabel()`, una función definida fuera del bucle, cuyo `_` interno sí resuelve bien por scope léxico) — muestra de que el bug es específico de cómo se escribe el bucle, no de usar `_` como nombre en general.
- **Extendido el mismo aprendizaje al botón "Test connection"** (§13): su `callback` ahora usa un helper `guard(fn)` que envuelve en `pcall` tanto el setup síncrono como CADA callback async por separado (el `get_library_version` y el `test_connection` de WebDAV) — un solo `pcall` alrededor de la función exterior no habría protegido los callbacks async, que corren más tarde, fuera del alcance dinámico de ese `pcall`. Esta ya se escribió bien desde el principio, sin necesidad de otro ciclo de crash-fix.
- Pendiente de verificar en el dispositivo real: si con estos cambios "Downloads" ya no crashea y muestra el listado correctamente.
