# Zotero Kindle Sync — Especificación de Proyecto

> Este documento es el brief técnico para que Claude Code construya el proyecto de principio a fin, incluyendo la creación del repositorio en GitHub. Léelo completo antes de ejecutar nada.

## 1. Objetivo

Crear una app nativa para Kindle e-ink jailbroken que sincronice metadata y PDFs desde una biblioteca de Zotero (API REST + almacenamiento WebDAV propio), y los deje listos para el lector nativo del Kindle.

**No** es un port de la app Android de Zotero — es un proyecto nuevo, específico para el framework del Kindle (Linux embebido + GTK2, o Mesquito/KUAL para la UI).

## 2. Contexto técnico ya decidido

- **Dispositivo:** Kindle e-ink jailbreado (no Fire tablet, no Android).
- **Toolchain:** `koxtoolchain` + `kindle-sdk` (KindleModding), Meson, GTK+2.0, C/C++.
- **Metadata de biblioteca:** API REST pública de Zotero (`https://api.zotero.org`), autenticada con API key (`Zotero-API-Key` header). Sync incremental vía `library/version` + `?since=`.
- **Archivos adjuntos (PDFs):** el usuario usa **WebDAV propio**, no el storage de Zotero. Cada adjunto es un `.zip` nombrado con la key del ítem (ej. `ABCD1234.zip`) que contiene el PDF, más un `.prop` con metadata. Se descarga con HTTP Basic Auth directo al WebDAV.
- **Entrega al usuario:** los PDFs extraídos se copian a `/mnt/us/documents/`; se aprovecha el lector nativo del Kindle en vez de reimplementar renderizado de PDF.
- **UI:** mínima, pensada para e-ink (sin animaciones, refrescos completos de pantalla). Puede ser un menú KUAL o una app GTK simple: lista de colecciones/tags, botón "Sincronizar ahora", botón "Abrir" por ítem.

## 3. Estructura del repositorio

```
zotero-kindle-sync/
├── LICENSE                  # CC BY 4.0 (ver sección 5)
├── README.md
├── CLAUDE.md                 # este archivo
├── config/
│   └── config.example.json  # plantilla de credenciales (API key, WebDAV user/pass, user ID)
├── src/
│   ├── sync/                # lógica de sincronización (C, o script inicial en bash/python)
│   │   ├── zotero_api.c/.h  # llamadas a api.zotero.org
│   │   ├── webdav.c/.h      # descarga y extracción de adjuntos
│   │   └── db.c/.h          # cache local SQLite (items, colecciones, tags, versiones)
│   └── ui/                  # GTK2 o Mesquito WAF (según se decida en fase 3)
├── scripts/
│   └── test_sync.sh         # prueba end-to-end por SSH antes de compilar el binario
├── meson.build
└── manifest.json             # metadata de la app para el package manager del Kindle (KPM)
```

## 4. Tareas para Claude Code (en orden)

### Fase 0 — Repositorio
1. Inicializar repo git local.
2. Crear el repositorio remoto en GitHub con `gh` CLI:
   ```bash
   gh repo create zotero-kindle-sync --public \
     --description "Sync Zotero library + PDFs to a jailbroken e-ink Kindle" \
     --license CC-BY-4.0
   ```
   `CC-BY-4.0` es un identificador SPDX válido para `gh repo create --license`, que genera automáticamente el `LICENSE` con el texto legal completo de Creative Commons.
3. Si `gh` no está autenticado o el flag `--license` falla, como alternativa:
   - Crear el repo con `gh repo create zotero-kindle-sync --public`.
   - Descargar el texto legal completo desde `https://creativecommons.org/licenses/by/4.0/legalcode.txt` y guardarlo como `LICENSE`.
   - Añadir en el `README.md` el aviso corto:
     ```
     This work is licensed under a Creative Commons Attribution 4.0 International License (CC BY 4.0).
     https://creativecommons.org/licenses/by/4.0/
     ```
4. Hacer commit inicial con `LICENSE`, `README.md` y este `CLAUDE.md`.

### Fase 1 — Script de prueba (sin compilar nada todavía)
5. Escribir `scripts/test_sync.sh`: bash + curl que
   - liste la biblioteca vía `GET /users/{userID}/items` con la API key,
   - identifique un ítem con adjunto PDF,
   - descargue el `.zip` correspondiente desde el WebDAV (`https://zotero.racarla.es/zotero/{key}.zip`) con Basic Auth,
   - lo descomprima y confirme que el PDF es válido.
   - Las credenciales se leen de `config/config.json` (no versionado — añadir a `.gitignore`), usando `config/config.example.json` como plantilla con placeholders.
6. Documentar en el README cómo obtener la API key y el user ID de Zotero.

### Fase 2 — Motor de sync nativo
7. Portar la lógica del script a C usando `libcurl` para HTTP y `libzip` (o `minizip`) para descomprimir, siguiendo la estructura de `src/sync/`.
8. Cache local en SQLite (`src/sync/db.c`): tabla `items` (key, título, autores, colección, tags, versión, ruta local del PDF).
9. Sync incremental: guardar el último `library/version` sincronizado y pedir solo deltas.

### Fase 3 — UI e-ink
10. Decidir GTK2 nativo vs Mesquito WAF según qué tan compleja quede la navegación de biblioteca (GTK si se necesita más control; Mesquito si alcanza con listas simples).
11. Pantallas mínimas: lista de colecciones → lista de ítems → detalle con botón "Abrir en lector".
12. Botón/menú "Sincronizar ahora" que invoca el binario de sync y muestra progreso simple (texto, no barras animadas).

### Fase 4 — Empaquetado
13. `manifest.json` para KPM (KindleModding Package Manager) con id, versión, dependencias.
14. Instrucciones de instalación en el README (requiere jailbreak, ver kindlemodding.org).

## 5. Licencia

El proyecto se publica bajo **Creative Commons Attribution 4.0 International (CC BY 4.0)**.

- Resumen: cualquiera puede compartir y adaptar el código, incluso comercialmente, siempre que dé crédito apropiado.
- Texto legal completo: https://creativecommons.org/licenses/by/4.0/legalcode
- Nota: CC BY 4.0 es una licencia pensada originalmente para contenido creativo/documentación, no para software (a diferencia de MIT/Apache/GPL no tiene cláusulas explícitas sobre patentes o distribución de código fuente compilado). Si en algún momento se prefiere una licencia más estándar de software, valorar MIT o Apache 2.0 — pero se respeta la elección de CC BY 4.0 indicada por el usuario.

## 6. Variables de entorno / config que el usuario debe rellenar

```json
{
  "zotero_api_key": "",
  "zotero_user_id": "",
  "webdav_url": "https://zotero.racarla.es/zotero/",
  "webdav_user": "racarla96",
  "webdav_password": ""
}
```

Nunca commitear `config/config.json` con credenciales reales — solo `config.example.json`.

## 7. Criterios de "hecho" para la primera versión funcional (v0.1)

- [ ] Repo en GitHub con LICENSE CC BY 4.0.
- [ ] `test_sync.sh` descarga al menos un PDF real desde el WebDAV del usuario.
- [ ] Binario nativo compila con el toolchain de KindleModding para al menos un modelo de Kindle.
- [ ] El binario deja el PDF en `/mnt/us/documents/` y el lector nativo lo abre sin errores.
- [ ] Sync incremental funciona (segunda ejecución no vuelve a descargar todo).

## 8. Notas de progreso

- **Nombre del repositorio:** el remoto de GitHub se creó como `kindle-zotero-sync` (coincidiendo con el directorio local), no `zotero-kindle-sync` como sugiere el ejemplo de la sección 4. Ajustar cualquier referencia futura (manifest.json, URLs de clone, etc.) a este nombre real.
- **Alcance ejecutado hasta ahora:** Fase 0 (repositorio + licencia) y Fase 1 (`scripts/test_sync.sh`). Fases 2-4 (motor C nativo, UI e-ink, empaquetado KPM) quedan pendientes — requieren el toolchain de KindleModding y un Kindle físico para probar, que no están disponibles en el entorno donde se generó este commit inicial.
