#!/usr/bin/env bash
# immich-tag.sh — rescan a camera's external library in Immich and tag what is
# in it: <root>/Video, <root>/Photo, and <root>/Edited for anything under the
# library's Edited/ folder (<root> is IMMICH_TAG_ROOT, e.g. "Luna Ultra").
# Safe to run any time: tagging is idempotent, and an asset that left Edited/ loses that tag.
#   immich-tag.sh            # scan, wait for it to settle, then tag
#   immich-tag.sh --no-scan  # tag only
# Immich reads the folder read-only (/mnt/luna in the immich stack). The helper
# creates missing XMP tag sidecars over SSH; media and existing XMP are preserved.
# Needs curl, jq, python3 and SSH access to the NAS.
set -euo pipefail

CONF="${FOOTAGE_CONF:-$HOME/.config/footage-ingest.conf}"
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
IMMICH_URL="${IMMICH_URL:-}"
IMMICH_KEY_FILE="${IMMICH_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/immich-api-key}"
IMMICH_LIBRARY_ID="${IMMICH_LIBRARY_ID:-}"
IMMICH_EDITED_PREFIX="${IMMICH_EDITED_PREFIX:-/mnt/luna/Edited/}"
TAG_ROOT="${IMMICH_TAG_ROOT:-Camera}"

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
for b in curl jq python3 ssh; do command -v "$b" >/dev/null || die "$b is not installed"; done
[ -n "${NAS_USER:-}" ] && [ -n "${NAS_HOST:-}" ] && [ -n "${NAS_FLATTEN_TO:-}" ] \
  || die "NAS_USER, NAS_HOST and NAS_FLATTEN_TO must be set in $CONF"
[ -n "$IMMICH_URL" ] && [ -n "$IMMICH_LIBRARY_ID" ] \
  || die "IMMICH_URL and IMMICH_LIBRARY_ID must be set in $CONF"
[ -r "$IMMICH_KEY_FILE" ] || die "no Immich API key at $IMMICH_KEY_FILE"
KEY="$(cat "$IMMICH_KEY_FILE")"
# one run at a time (the hourly timer and a hand run can overlap)
exec 9> "${XDG_RUNTIME_DIR:-/tmp}/immich-tag.lock"
flock -n 9 || { say "another immich-tag run is going — leaving it to that one"; exit 0; }

# api METHOD PATH [JSON] — the response body; non-2xx is an error
api() {
  local out code
  out="$(curl -sS -m 300 -X "$1" -H "x-api-key: $KEY" -H 'Content-Type: application/json' \
         ${3:+--data "$3"} -w '\n%{http_code}' "$IMMICH_URL/api$2")" || die "could not reach Immich at $IMMICH_URL"
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  case "$code" in 2??) printf '%s' "$out" ;; *) die "$1 $2 -> HTTP $code: $out" ;; esac
}

total() { api GET "/libraries/$IMMICH_LIBRARY_ID/statistics" | jq -r .total; }

if [ "${1:-}" != "--no-scan" ]; then
  before="$(total)"
  api POST "/libraries/$IMMICH_LIBRARY_ID/scan" > /dev/null
  # the scan runs in the background: wait until the count stops changing
  # (two equal readings 20 s apart), at most 10 minutes
  prev=-1; n="$before"
  for _ in $(seq 30); do
    sleep 20; n="$(total)"
    [ "$n" = "$prev" ] && break
    prev="$n"
  done
  say "scanned: $before -> $n assets"
fi

# Database-only tags on a read-only library can be cleared by metadata jobs.
# Persist them in XMP first, including any other existing Immich tags.
IMMICH_URL="$IMMICH_URL" IMMICH_KEY_FILE="$IMMICH_KEY_FILE" \
IMMICH_LIBRARY_ID="$IMMICH_LIBRARY_ID" IMMICH_EDITED_PREFIX="$IMMICH_EDITED_PREFIX" IMMICH_TAG_ROOT="$TAG_ROOT" \
NAS_USER="$NAS_USER" NAS_HOST="$NAS_HOST" NAS_FLATTEN_TO="$NAS_FLATTEN_TO" \
python3 "$(dirname "${BASH_SOURCE[0]}")/immich-sidecars.py"

# Let sidecar discovery and metadata extraction settle before reconciling tags.
# The XMP copies keep the tags durable even if processing outlasts this wait.
for _ in $(seq 120); do
  left="$(api GET /jobs | jq '.metadataExtraction.jobCounts | .active + .waiting')"
  [ "$left" = 0 ] && break
  sleep 30
done
[ "$left" = 0 ] || say "Immich still has $left metadata jobs queued — tagging anyway"

# every asset in the library as "id<TAB>type<TAB>originalPath", minus hidden
# ones: the video half of each LIV live photo is a hidden asset of its own
all="$(mktemp)"; trap 'rm -f "$all"' EXIT
page=1
while [ -n "$page" ] && [ "$page" != null ]; do
  r="$(api POST /search/metadata "$(jq -nc --arg l "$IMMICH_LIBRARY_ID" --argjson p "$page" \
        '{libraryId:$l, size:1000, page:$p, withDeleted:false}')")"
  jq -r '.assets.items[] | select(.visibility != "hidden") | [.id, .type, .originalPath] | @tsv' <<< "$r" >> "$all"
  page="$(jq -r '.assets.nextPage' <<< "$r")"
done

tags="$(api PUT /tags "$(jq -nc --arg r "$TAG_ROOT" '{tags:[$r+"/Video", $r+"/Photo", $r+"/Edited"]}')")"
tag_id() { jq -r --arg v "$TAG_ROOT/$1" '.[] | select(.value==$v) | .id' <<< "$tags"; }
VID="$(tag_id Video)"; PIC="$(tag_id Photo)"; EDT="$(tag_id Edited)"

# tagged TAGID — ids of the library's assets that already carry that tag
tagged() {
  local page=1 r
  while [ -n "$page" ] && [ "$page" != null ]; do
    r="$(api POST /search/metadata "$(jq -nc --arg l "$IMMICH_LIBRARY_ID" --arg t "$1" --argjson p "$page" \
          '{libraryId:$l, tagIds:[$t], size:1000, page:$p}')")"
    jq -r '.assets.items[].id' <<< "$r"
    page="$(jq -r '.assets.nextPage' <<< "$r")"
  done
}

# tag TAGID LABEL — tag the asset ids on stdin that lack it yet, 200 per
# request (500 can take over a minute). Only the missing ones are sent: every
# asset tagged makes Immich queue work for it
tag() {
  local ids n=0 have want
  have="$(mktemp)"; want="$(mktemp)"
  tagged "$1" | sort -u > "$have"; sort -u > "$want"
  while mapfile -t -n 200 ids && [ ${#ids[@]} -gt 0 ]; do
    api PUT /tags/assets "$(printf '%s\n' "${ids[@]}" | jq -Rnc --arg t "$1" '{tagIds:[$t], assetIds:[inputs]}')" > /dev/null
    n=$((n + ${#ids[@]}))
  done < <(comm -23 "$want" "$have")
  say "$2: $(wc -l < "$want") ($n newly tagged)"
  rm -f "$have" "$want"
}

awk -F'\t' '$2=="VIDEO"{print $1}' "$all" | tag "$VID" "Video"
awk -F'\t' '$2=="IMAGE"{print $1}' "$all" | tag "$PIC" "Photo"
awk -F'\t' -v p="$IMMICH_EDITED_PREFIX" 'index($3,p)==1{print $1}' "$all" | tag "$EDT" "Edited"

# drop Edited from assets no longer under Edited/
stale="$(api POST /search/metadata "$(jq -nc --arg l "$IMMICH_LIBRARY_ID" --arg t "$EDT" \
          '{libraryId:$l, tagIds:[$t], size:1000}')" \
         | jq -r --arg p "$IMMICH_EDITED_PREFIX" '.assets.items[] | select(.originalPath | startswith($p) | not) | .id')"
if [ -n "$stale" ]; then
  api DELETE "/tags/$EDT/assets" "$(jq -Rnc '{ids:[inputs]}' <<< "$stale")" > /dev/null
  say "Edited tag removed: $(wc -l <<< "$stale")"
fi
