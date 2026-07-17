#!/usr/bin/env bash
# Shared Google Sheets/Docs/Drive helper for cowork-snyk skills.
#
# WHY THIS EXISTS: the `gws` CLI does NOT work under Zscaler — it wraps a Rust
# binary (rustls) that trusts only Mozilla's baked-in roots, rejects the Zscaler
# interception cert ("invalid peer certificate: UnknownIssuer"), and ignores
# SSL_CERT_FILE. macOS `curl` works because it trusts the Zscaler root via the
# keychain. This helper gets a token by decrypting the gws credential and calls
# the REST APIs with curl + --cacert. Canonical reference:
#   05_context/operating-protocols/tool-preferences.md
#   auto-memory reference_google_docs_access.md
#
# USAGE (source, then call):
#   source ~/.claude/skills/_shared/gsheets.sh
#   gsheet_get    SPREADSHEET_ID 'Sheet1!A:P'
#   gsheet_append SPREADSHEET_ID 'Sheet1!A:P' '{"values":[["a","b"]]}'
#   gsheet_update SPREADSHEET_ID 'Sheet1!A1'  '{"values":[["a","b"]]}'
#   gsheet_clear  SPREADSHEET_ID 'Sheet1!A2:P'
#   TOKEN=$(gws_token)   # raw bearer token for ad-hoc Docs/Drive curl calls
#
# Do NOT add `set -euo pipefail` here — this file is sourced into the caller's shell.

GWS_CERT="${GWS_CERT:-$HOME/Documents/zscaler-root-ca.crt}"
GWS_DIR="${GWS_DIR:-$HOME/.config/gws}"

gws_token() {
  # Token is cached in GWS_ACCESS_TOKEN for the life of the shell (valid ~1h).
  if [ -n "${GWS_ACCESS_TOKEN:-}" ]; then printf '%s' "$GWS_ACCESS_TOKEN"; return 0; fi
  local creds cid csec rtok
  # Prefer the gws CLI's own decrypt (`auth export`). Newer gws (>=0.22) stores the
  # encryption key in the OS keychain, not as ~/.config/gws/.encryption_key, so the
  # file-decrypt path below fails on those installs. `auth export --unmasked` works
  # regardless of where the key lives. Fall back to the file decrypt if the CLI
  # export is unavailable (older gws, or gws not on PATH).
  creds=$(gws auth export --unmasked 2>/dev/null | python3 -c "
import sys, json
c = json.load(sys.stdin)
print(c['client_id']); print(c['client_secret']); print(c['refresh_token'])
" 2>/dev/null)
  if [ -z "$creds" ]; then
    creds=$(python3 - "$GWS_DIR" <<'PY'
import base64, json, sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
d = sys.argv[1]
key = base64.b64decode(open(d + "/.encryption_key", "rb").read().strip())
blob = open(d + "/credentials.enc", "rb").read()      # nonce = first 12 bytes
c = json.loads(AESGCM(key).decrypt(blob[:12], blob[12:], None))
print(c["client_id"]); print(c["client_secret"]); print(c["refresh_token"])
PY
) || { echo "gws_token: failed to obtain credentials (gws auth export and file decrypt both failed)" >&2; return 1; }
  fi
  cid=$(printf '%s\n' "$creds" | sed -n 1p)
  csec=$(printf '%s\n' "$creds" | sed -n 2p)
  rtok=$(printf '%s\n' "$creds" | sed -n 3p)
  local cacert=(); [ -n "${GWS_CERT:-}" ] && [ -f "${GWS_CERT}" ] && cacert=(--cacert "$GWS_CERT")
  GWS_ACCESS_TOKEN=$(curl -sS "${cacert[@]}" https://oauth2.googleapis.com/token \
    -d client_id="$cid" -d client_secret="$csec" -d refresh_token="$rtok" -d grant_type=refresh_token \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])") \
    || { echo "gws_token: token exchange failed" >&2; return 1; }
  export GWS_ACCESS_TOKEN
  printf '%s' "$GWS_ACCESS_TOKEN"
}

# Internal: curl with cert + auth header. Args appended verbatim.
_gws_curl() {
  local tok; tok=$(gws_token) || return 1
  # --cacert only when the Zscaler cert actually exists. Off-Zscaler there is no
  # such file → omit it and use curl's system trust, so one helper works everywhere.
  local cacert=(); [ -n "${GWS_CERT:-}" ] && [ -f "${GWS_CERT}" ] && cacert=(--cacert "$GWS_CERT")
  curl -sS --fail-with-body "${cacert[@]}" -H "Authorization: Bearer $tok" "$@"
}

# Internal: URL-encode a value (spaces, !, etc.) for use in a URL path.
_gws_enc() { python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }

# gsheet_get SPREADSHEET_ID RANGE  ->  {"range":..,"values":[[..]]}
gsheet_get() {
  _gws_curl "https://sheets.googleapis.com/v4/spreadsheets/$1/values/$(_gws_enc "$2")"
}

# gsheet_append SPREADSHEET_ID RANGE JSON_BODY  (body: {"values":[[..]]})
gsheet_append() {
  _gws_curl -X POST -H "Content-Type: application/json" \
    "https://sheets.googleapis.com/v4/spreadsheets/$1/values/$(_gws_enc "$2"):append?valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS" \
    -d "$3"
}

# gsheet_update SPREADSHEET_ID RANGE JSON_BODY  (body: {"values":[[..]]})
gsheet_update() {
  _gws_curl -X PUT -H "Content-Type: application/json" \
    "https://sheets.googleapis.com/v4/spreadsheets/$1/values/$(_gws_enc "$2")?valueInputOption=USER_ENTERED" \
    -d "$3"
}

# gsheet_clear SPREADSHEET_ID RANGE
gsheet_clear() {
  _gws_curl -X POST "https://sheets.googleapis.com/v4/spreadsheets/$1/values/$(_gws_enc "$2"):clear"
}
