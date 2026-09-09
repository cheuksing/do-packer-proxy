#!/usr/bin/env bash
# Generate a V2Box-compatible VLESS + REALITY QR code from client/.env.
set -euo pipefail

QRCODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$QRCODE_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/client/.env"
OUTPUT_DIR="$QRCODE_DIR/output"
OUTPUT_FILE="$OUTPUT_DIR/v2box.png"

fatal() {
  echo "FATAL: $*" >&2
  exit 1
}

[ -f "$ENV_FILE" ] || fatal "$ENV_FILE missing - run client/fetch-params.sh first"
command -v qrencode >/dev/null 2>&1 || fatal "qrencode not found in PATH"

set -a
. "$ENV_FILE"
set +a

SERVER_PORT="${SERVER_PORT:-443}"
FINGERPRINT="${FINGERPRINT:-chrome}"
FLOW="${FLOW:-xtls-rprx-vision}"

for var in SERVER_ADDR UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SNI; do
  [ -n "${!var:-}" ] || fatal "$var is empty in $ENV_FILE"
  case "${!var}" in
    *[[:space:]@/?#\&=]*) fatal "$var contains characters that are not valid in a VLESS URI" ;;
  esac
done

case "$SERVER_PORT" in
  ''|*[!0-9]*) fatal "SERVER_PORT must be numeric" ;;
esac

case "$SERVER_ADDR" in
  *:*)
    case "$SERVER_ADDR" in
      \[*\]) SERVER_AUTHORITY="$SERVER_ADDR" ;;
      *) SERVER_AUTHORITY="[$SERVER_ADDR]" ;;
    esac
    ;;
  *) SERVER_AUTHORITY="$SERVER_ADDR" ;;
esac

# V2Box imports the standard VLESS URI fields for TCP + REALITY.
VLESS_URI="vless://${UUID}@${SERVER_AUTHORITY}:${SERVER_PORT}?type=tcp&headerType=none&security=reality&encryption=none&sni=${REALITY_SNI}&fp=${FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&flow=${FLOW}#V2Box"

umask 077
mkdir -p "$OUTPUT_DIR"
TMP_FILE="$(mktemp "$OUTPUT_DIR/.v2box.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT

qrencode -l M -s 8 -m 4 -o "$TMP_FILE" "$VLESS_URI"
mv -f "$TMP_FILE" "$OUTPUT_FILE"
trap - EXIT

echo "generated $OUTPUT_FILE"
