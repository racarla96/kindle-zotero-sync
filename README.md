# kindle-zotero-sync

Sincroniza tu biblioteca de [Zotero](https://www.zotero.org/) (metadata vía API REST + PDFs vía tu propio servidor WebDAV) a un Kindle e-ink jailbreado, dejando los PDFs listos para el lector nativo del dispositivo.

Este no es un port de la app oficial de Zotero para Android — es un proyecto nuevo, específico para el framework del Kindle (Linux embebido + GTK2 / KUAL).

> El brief técnico completo del proyecto, con todas las fases planeadas, está en [`CLAUDE.md`](./CLAUDE.md).

## Estado actual

- ✅ **Fase 0** — Repositorio creado, licenciado bajo CC BY 4.0.
- ✅ **Fase 1** — [`scripts/test_sync.sh`](./scripts/test_sync.sh): prueba end-to-end en bash/curl que lista la biblioteca, descarga un PDF desde el WebDAV y valida el resultado.
- ⏳ **Fase 2** — Motor de sync nativo en C (libcurl + libzip/minizip + SQLite). Pendiente.
- ⏳ **Fase 3** — UI e-ink (GTK2 o Mesquito/KUAL). Pendiente.
- ⏳ **Fase 4** — Empaquetado KPM para KindleModding. Pendiente.

## Cómo funciona

1. **Metadata**: se consulta la [API REST de Zotero](https://www.zotero.org/support/dev/web_api/v3/start) (`api.zotero.org`), autenticada con una API key, para listar ítems de la biblioteca. El sync incremental usa el header `library/version` + el parámetro `?since=` para pedir solo los cambios.
2. **Adjuntos (PDFs)**: en vez del storage de Zotero, se usa un **WebDAV propio**. Cada adjunto vive como `{key}.zip` (más un `.prop` con metadata) en el WebDAV, y se descarga con HTTP Basic Auth.
3. **Entrega**: los PDFs extraídos se copian a `/mnt/us/documents/` para que los abra el lector nativo del Kindle.

## Configuración de credenciales

1. Copia la plantilla:
   ```bash
   cp config/config.example.json config/config.json
   ```
2. Rellena `config/config.json` (este archivo **no se sube al repo**, está en `.gitignore`):

   ```json
   {
     "zotero_api_key": "",
     "zotero_user_id": "",
     "webdav_url": "https://zotero.racarla.es/zotero/",
     "webdav_user": "racarla96",
     "webdav_password": ""
   }
   ```

### Obtener tu API key de Zotero

1. Inicia sesión en [zotero.org](https://www.zotero.org/) y ve a **Settings → Security** (o directamente [zotero.org/settings/security](https://www.zotero.org/settings/security)).
2. En la sección **Applications**, pulsa **Create new private key**.
3. Dale un nombre descriptivo (ej. "kindle-sync") y marca al menos **Allow library access** (lectura). No necesitas permisos de escritura para esta fase.
4. Guarda la key generada — Zotero solo la muestra una vez — y pégala en `zotero_api_key`.

### Obtener tu User ID de Zotero

1. En la misma página de [Settings → Security](https://www.zotero.org/settings/security), tu **userID** aparece en la sección "Your userID for use in API calls is *NNNNNNN*".
2. Cópialo tal cual (es un número) en `zotero_user_id`.

### Credenciales del WebDAV

`webdav_user` y `webdav_password` son las mismas que configuraste en Zotero (**Settings → Sync → File Syncing → WebDAV**) para que el propio Zotero sincronice adjuntos contra tu servidor. `webdav_url` es la URL base donde Zotero deja los `.zip` de cada adjunto.

## Ejecutar la prueba end-to-end

Requiere `curl`, `jq`, `unzip` y `file` instalados.

```bash
./scripts/test_sync.sh
```

El script:
1. Lista tu biblioteca vía la API de Zotero.
2. Busca el primer adjunto PDF importado.
3. Descarga su `.zip` desde el WebDAV con Basic Auth.
4. Lo descomprime y valida que el PDF extraído sea válido.

Los archivos temporales quedan en `scripts/tmp/` (ignorado por git).

## Licencia

Este proyecto está licenciado bajo **Creative Commons Attribution 4.0 International (CC BY 4.0)**.
Puedes compartir y adaptar el código, incluso comercialmente, siempre que des crédito apropiado.

Texto legal completo: https://creativecommons.org/licenses/by/4.0/legalcode
Resumen: https://creativecommons.org/licenses/by/4.0/
