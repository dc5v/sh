#!/bin/sh

set -eu
umask 077

SCRIPT_NAME=$(basename $0)
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
SCRIPT_DIR=$(dirname -- "$SCRIPT_PATH")
CONF="$SCRIPT_DIR/config.conf"
API_URL="https://api.forwardemail.net/v1/emails"

err() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }
usage() {
printf 'Usage:
  %s <--to "email_address"> <--subject "subject"> <--body "body" | --body-file "filename"> 
    [--from "email_address"] [--file "filename" ...] [--embargo-ms "ms"] \
    [--disclaimer "text"]
' "$SCRIPT_NAME"
  exit 0
}

trim_l() { printf '%s' "$1" | sed 's/^[[:space:]]*//'; }
trim_r() { printf '%s' "$1" | sed 's/[[:space:]]*$//'; }

json_escape_sed() {
  printf '%s' "$1" | sed \
    -e 's/\\/\\\\/g' \
    -e 's/"/\\"/g' \
    -e ':a;N;$!ba;s/\r/\\r/g;s/\n/\\n/g;s/\t/\\t/g'
}

b64_file() {
  f=$1
  if command -v base64 >/dev/null 2>&1; then
    base64 "$f" | tr -d '\n\r '
  elif command -v openssl >/dev/null 2>&1; then
    openssl base64 -A -in "$f"
  else
    printf 'ERROR: base64 or openssl is required\n' >&2; exit 3
  fi
}

sleep_ms() {
  ms=$1
  [ -z "$ms" ] && return 0
  case "$ms" in *[!0-9]* ) err "invalid --embargo-ms (must be integer ms)";; esac
  [ "$ms" -eq 0 ] && return 0
  if command -v usleep >/dev/null 2>&1; then usleep "$(( ms * 1000 ))" && return 0 || true; fi
  if sleep "$(awk -v m="$ms" 'BEGIN{ printf("%.3f", m/1000) }')" 2>/dev/null; then return 0; fi
  sec=$(( (ms + 999) / 1000 )); sleep "$sec"
}


TO=""; FROM_CLI=""; SUBJECT=""; BODY_ARG=""; BODY_FILE=""
EMBARGO_MS_CLI=""; DISCL_SET=0; DISCL_CLI=""
FILES="" 

[ $# -eq 0 ] && usage
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage ;;
    --to)         [ $# -ge 2 ] || usage; TO=$2; shift 2 ;;
    --from)       [ $# -ge 2 ] || usage; FROM_CLI=$2; shift 2 ;;
    --subject)    [ $# -ge 2 ] || usage; SUBJECT=$2; shift 2 ;;
    --body)       [ $# -ge 2 ] || usage; BODY_ARG=$2; shift 2 ;;
    --body-file)  [ $# -ge 2 ] || usage; BODY_FILE=$2; shift 2 ;;
    --embargo-ms) [ $# -ge 2 ] || usage; EMBARGO_MS_CLI=$2; shift 2 ;;
    --disclaimer) [ $# -ge 2 ] || usage; DISCL_SET=1; DISCL_CLI=$2; shift 2 ;;
    --file)
      [ $# -ge 2 ] || usage
      [ -r "$2" ] || { printf 'ERROR: attachment not readable: %s\n' "$2" >&2; exit 4; }
      if [ -z "$FILES" ]; then FILES=$2; else FILES="$FILES
$2"; fi
      shift 2
      ;;
    --) shift; break ;;
    *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -r "$CONF" ] || { err "Can not read config file: $CONF"; }

command -v curl >/dev/null 2>&1 || { err 'curl is required'; }

HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1
APIKEY_CFG=""; FROM_CFG=""; EMBARGO_MS_CFG=""; BODY_DISCLAIMER_CFG=""

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue;; esac
  key=$(trim_r "${line%%=*}"); val=$(trim_l "${line#*=}")
  case "$key" in
    APIKEY)          APIKEY_CFG=$val ;;
    FROM)            FROM_CFG=$val ;;
    EMBARGO_MS)      EMBARGO_MS_CFG=$val ;;
    BODY_DISCLAIMER) BODY_DISCLAIMER_CFG=$val ;;
  esac
done < "$CONF"

[ -z "$APIKEY_CFG" ]          && APIKEY_CFG=${APIKEY:-}
[ -z "$FROM_CFG" ]            && FROM_CFG=${FROM:-}
[ -z "$EMBARGO_MS_CFG" ]      && EMBARGO_MS_CFG=${EMBARGO_MS:-}
[ -z "$BODY_DISCLAIMER_CFG" ] && BODY_DISCLAIMER_CFG=${BODY_DISCLAIMER:-}


[ -n "$APIKEY_CFG" ] || { printf 'ERROR: APIKEY missing (set in %s or env)\n' "$CONF" >&2; exit 3; }
[ -n "$TO" ]      || { printf 'ERROR: --to is required\n' >&2; exit 4; }
[ -n "$SUBJECT" ] || { printf 'ERROR: --subject is required\n' >&2; exit 4; }
if [ -n "$BODY_ARG" ] && [ -n "$BODY_FILE" ]; then err "use either --body or --body-file (not both)"; fi
if [ -z "$BODY_ARG" ] && [ -z "$BODY_FILE" ]; then err "one of --body or --body-file is required"; fi

BODY_TEXT="$BODY_ARG"
if [ -n "$BODY_FILE" ]; then
  [ -r "$BODY_FILE" ] || err "cannot read --body-file"
  BODY_TEXT=$(cat -- "$BODY_FILE")
fi

FROM_FINAL="${FROM_CLI:-$FROM_CFG}"
[ -n "$FROM_FINAL" ] || err "FROM missing (--from or FROM in config)"

if [ $DISCL_SET -eq 1 ]; then BODY_DISCLAIMER_FINAL=$DISCL_CLI; else BODY_DISCLAIMER_FINAL=$BODY_DISCLAIMER_CFG; fi
EMBARGO_MS_FINAL="${EMBARGO_MS_CLI:-$EMBARGO_MS_CFG}"
case "${EMBARGO_MS_FINAL:-}" in ""|*[!0-9]* ) [ -z "${EMBARGO_MS_FINAL:-}" ] || err "invalid EMBARGO_MS";; esac

if [ -n "${BODY_DISCLAIMER_FINAL:-}" ]; then
  BODY_TEXT="$BODY_TEXT
---
$BODY_DISCLAIMER_FINAL"
fi

if [ $HAS_JQ -eq 1 ]; then
  ATT_JSON='[]'
  if [ -n "$FILES" ]; then
    echo "$FILES" | while IFS= read -r f; do
      [ -z "$f" ] && continue
      name=$(basename -- "$f")
      b64=$(b64_file "$f")
      CT=""
      if command -v file >/dev/null 2>&1; then CT=$(file -b --mime-type "$f" 2>/dev/null || true); fi
      if [ -n "$CT" ]; then
        ATT_JSON=$(printf '%s\n' "$ATT_JSON" | jq -c --arg fn "$name" --arg c "$b64" --arg ct "$CT" '. + [{filename:$fn, content:$c, encoding:"base64", contentType:$ct}]')
      else
        ATT_JSON=$(printf '%s\n' "$ATT_JSON" | jq -c --arg fn "$name" --arg c "$b64" '. + [{filename:$fn, content:$c, encoding:"base64"}]')
      fi
      printf '%s\n' "$ATT_JSON" >"$TMPDIR/send.att.$$"
      ATT_JSON=$(cat "$TMPDIR/send.att.$$")
    done
    rm -f "$TMPDIR/send.att.$$" 2>/dev/null || true
  fi
else
  ATT_TMP=$(mktemp -t send_att.XXXXXX); trap 'rm -f "$ATT_TMP"' INT HUP TERM EXIT
  printf '[' >"$ATT_TMP"; first=1
  if [ -n "$FILES" ]; then
    echo "$FILES" | while IFS= read -r f; do
      [ -z "$f" ] && continue
      name=$(basename -- "$f")
      b64=$(b64_file "$f")
      CT=""
      if command -v file >/dev/null 2>&1; then CT=$(file -b --mime-type "$f" 2>/dev/null || true); fi
      obj='{"filename":"'"$(json_escape_sed "$name")"'","content":"'"$b64"'","encoding":"base64"'
      if [ -n "$CT" ]; then obj="$obj"',"contentType":"'"$(json_escape_sed "$CT")"'"'; fi
      obj="$obj"'}'
      if [ $first -eq 1 ]; then printf '%s' "$obj" >>"$ATT_TMP"; first=0; else printf ',%s' "$obj" >>"$ATT_TMP"; fi
    done
  fi
  printf ']' >>"$ATT_TMP"
  ATT_JSON=$(cat "$ATT_TMP")
fi

if [ $HAS_JQ -eq 1 ]; then
  JSON_BODY=$(jq -c -n \
    --arg from "$FROM_FINAL" \
    --arg to "$TO" \
    --arg subject "$SUBJECT" \
    --arg text "$BODY_TEXT" \
    --arg enc "utf-8" \
    --argjson attachments "${ATT_JSON:-[]}" \
    '{from:$from, to:$to, subject:$subject, text:$text, attachments:$attachments, encoding:$enc}')
else
  JSON_BODY=$(
    printf '{'
    printf '"from":"%s",'    "$(json_escape_sed "$FROM_FINAL")"
    printf '"to":"%s",'      "$(json_escape_sed "$TO")"
    printf '"subject":"%s",' "$(json_escape_sed "$SUBJECT")"
    printf '"text":"%s",'    "$(json_escape_sed "$BODY_TEXT")"
    printf '"attachments":%s,' "${ATT_JSON:-[]}"
    printf '"encoding":"utf-8"'
    printf '}'
  )
fi

[ -n "${EMBARGO_MS_FINAL:-}" ] && sleep_ms "$EMBARGO_MS_FINAL"

set +e
RESP=$(curl -sS --fail-with-body -X POST "$API_URL" \
  -H 'Content-Type: application/json' \
  -u "${APIKEY_CFG}:" \
  --data "$JSON_BODY")
RC=$?
set -e
if [ $RC -ne 0 ]; then
  printf 'ERROR: send failed (curl exit %d)\n' "$RC" >&2
  [ -n "$RESP" ] && printf '%s\n' "$RESP" >&2
  exit 5
fi
printf '%s\n' "$RESP"
