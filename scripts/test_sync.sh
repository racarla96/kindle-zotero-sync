#!/usr/bin/env bash
#
# test_sync.sh — Prueba end-to-end (sin compilar nada) del flujo de sync:
#   1. Lista la biblioteca de Zotero vía API REST (metadata).
#   2. Encuentra un ítem con un adjunto PDF.
#   3. Descarga el .zip correspondiente desde el WebDAV propio (Basic Auth).
#   4. Lo descomprime y valida que el PDF extraído sea un PDF real.
#
# Requisitos: bash, curl, jq, unzip, file.
# Config: config/config.json (ver config/config.example.json como plantilla).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$REPO_ROOT/config/config.json"
TMP_DIR="$SCRIPT_DIR/tmp"

log()  { printf '[test_sync] %s\n' "$1"; }
fail() { printf '[test_sync] ERROR: %s\n' "$1" >&2; exit 1; }

# --- 0. Comprobar dependencias -------------------------------------------
for bin in curl jq unzip file; do
    command -v "$bin" >/dev/null 2>&1 || fail "falta el comando '$bin'. Instálalo antes de continuar."
done

# --- 1. Cargar configuración ----------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
    fail "no existe $CONFIG_FILE. Copia config/config.example.json a config/config.json y rellena tus credenciales."
fi

ZOTERO_API_KEY=$(jq -r '.zotero_api_key // empty' "$CONFIG_FILE")
ZOTERO_USER_ID=$(jq -r '.zotero_user_id // empty' "$CONFIG_FILE")
WEBDAV_URL=$(jq -r '.webdav_url // empty' "$CONFIG_FILE")
WEBDAV_USER=$(jq -r '.webdav_user // empty' "$CONFIG_FILE")
WEBDAV_PASSWORD=$(jq -r '.webdav_password // empty' "$CONFIG_FILE")

for var in ZOTERO_API_KEY ZOTERO_USER_ID WEBDAV_URL WEBDAV_USER WEBDAV_PASSWORD; do
    [[ -n "${!var}" ]] || fail "el campo correspondiente a '$var' está vacío en $CONFIG_FILE."
done

# Normalizar webdav_url para que termine en /
[[ "$WEBDAV_URL" == */ ]] || WEBDAV_URL="${WEBDAV_URL}/"

mkdir -p "$TMP_DIR"

# --- 2. Listar la biblioteca y encontrar un adjunto PDF --------------------
log "Consultando biblioteca de Zotero (user $ZOTERO_USER_ID)..."

ITEMS_JSON="$TMP_DIR/items.json"
HTTP_CODE=$(curl -sS -w '%{http_code}' -o "$ITEMS_JSON" \
    -H "Zotero-API-Key: $ZOTERO_API_KEY" \
    -H "Zotero-API-Version: 3" \
    "https://api.zotero.org/users/${ZOTERO_USER_ID}/items?itemType=attachment&limit=50&format=json")

[[ "$HTTP_CODE" == "200" ]] || fail "la API de Zotero devolvió HTTP $HTTP_CODE (revisa api key / user id). Respuesta: $(cat "$ITEMS_JSON")"

LIBRARY_VERSION=$(curl -sS -I \
    -H "Zotero-API-Key: $ZOTERO_API_KEY" \
    "https://api.zotero.org/users/${ZOTERO_USER_ID}/items?limit=1" \
    | grep -i '^Last-Modified-Version:' | tr -d '\r' | awk '{print $2}' || true)
log "library/version actual: ${LIBRARY_VERSION:-desconocida}"

# Buscar el primer adjunto de tipo PDF con archivo importado (candidato a estar en el WebDAV)
ATTACHMENT=$(jq -c '[.[] | select(.data.itemType == "attachment"
                                   and .data.contentType == "application/pdf"
                                   and (.data.linkMode == "imported_file" or .data.linkMode == "imported_url"))][0] // empty' \
    "$ITEMS_JSON")

[[ -n "$ATTACHMENT" ]] || fail "no se encontró ningún adjunto PDF importado en los primeros 50 ítems. Prueba a subir el límite o revisa la biblioteca."

ATTACHMENT_KEY=$(jq -r '.key' <<<"$ATTACHMENT")
ATTACHMENT_TITLE=$(jq -r '.data.title // .data.filename // "(sin título)"' <<<"$ATTACHMENT")

log "Adjunto encontrado: \"$ATTACHMENT_TITLE\" (key: $ATTACHMENT_KEY)"

# --- 3. Descargar el .zip desde el WebDAV ----------------------------------
ZIP_URL="${WEBDAV_URL}${ATTACHMENT_KEY}.zip"
ZIP_PATH="$TMP_DIR/${ATTACHMENT_KEY}.zip"

log "Descargando desde WebDAV: $ZIP_URL"
HTTP_CODE=$(curl -sS -w '%{http_code}' -o "$ZIP_PATH" \
    --user "${WEBDAV_USER}:${WEBDAV_PASSWORD}" \
    "$ZIP_URL")

[[ "$HTTP_CODE" == "200" ]] || fail "descarga del WebDAV falló con HTTP $HTTP_CODE ($ZIP_URL). Revisa usuario/contraseña o que el adjunto exista en el WebDAV."

log "Descargado: $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"

# --- 4. Descomprimir y validar el PDF --------------------------------------
EXTRACT_DIR="$TMP_DIR/${ATTACHMENT_KEY}"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

unzip -q -o "$ZIP_PATH" -d "$EXTRACT_DIR" || fail "no se pudo descomprimir $ZIP_PATH (¿no es un zip válido?)."

PDF_FILE=$(find "$EXTRACT_DIR" -iname '*.pdf' -type f | head -n1)
[[ -n "$PDF_FILE" ]] || fail "el zip descargado no contiene ningún archivo .pdf."

FILE_TYPE=$(file --brief --mime-type "$PDF_FILE")
[[ "$FILE_TYPE" == "application/pdf" ]] || fail "el archivo extraído no es un PDF válido (mime detectado: $FILE_TYPE)."

log "PDF válido: $PDF_FILE ($(du -h "$PDF_FILE" | cut -f1), mime: $FILE_TYPE)"
log "✅ Test end-to-end completado con éxito."
