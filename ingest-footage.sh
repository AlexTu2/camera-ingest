#!/usr/bin/env bash
# ingest-footage.sh — camera card -> laptop staging -> NAS, resumable and verified.
#
# Designed for flaky/high-latency links (e.g. hotel Wi-Fi on another continent, over Tailscale).
# Never deletes anything from the card. Safe to re-run after any interruption.
#
#   ./ingest-footage.sh stage            # card -> local staging + sha256 manifest
#   ./ingest-footage.sh push             # staging -> NAS (resumable, rate limited)
#   ./ingest-footage.sh run              # stage + verify + push + verify-remote
#   ./ingest-footage.sh status           # what's staged, what's pushed
#
set -euo pipefail

VERSION=1.0.0
SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- defaults ---
NAS_HOST="truenas"                                  # tailscale hostname
NAS_USER="$USER"
NAS_PATH="/mnt/tank/footage"
STAGE_ROOT="$HOME/Videos/Luna Ultra/.batches"
BWLIMIT="2M"                                        # rsync --bwlimit (0 = unlimited)
HASH=1                                              # build/verify sha256 manifests
NAS_FLATTEN_TO=""                                   # NAS dir to move verified clips into, loose ("" = off)
LOCAL_FLAT_DIR=""                                   # laptop dir of hard links to every staged clip ("" = off)
MEDIA_ROOT="/run/media/$USER"                       # where the desktop auto-mounts removable media
SOURCES=("Internal:luna-internal" "SD Card:luna-sd")  # "<volume name under MEDIA_ROOT>:<batch label>" for 'camera'
NETWORK_GUARD=1                                     # check Tailscale / metered / trusted network before pushing
TRUSTED_NETWORKS_FILE="$HOME/.config/footage-ingest/trusted-networks"  # one NetworkManager connection name per line
WATCH_RETRY_SECS=600                                # watch: retry a failed camera run this long after (a replug retries at once)
NOTIFY_DESKTOP=1                                    # notify-send on milestones and failures
NOTIFY_NTFY=""                                      # optional phone alerts, e.g. https://ntfy.sh/<secret-topic> ("" = off)
PUSH_STREAMS="auto"                                 # parallel rsync streams per batch: auto, or a number
PUSH_MAX_STREAMS=8                                  # ceiling for auto
PUSH_TICK_SECS=3                                    # how often progress / speed is refreshed for the tray
PUSH_PROBE_SECS=30                                  # auto: measure this long before adding a stream
PUSH_GAIN_PCT=15                                    # auto: keep adding while each stream adds >= this %
PUSH_REPROBE_SECS=600                               # auto: after settling, re-test one more stream this often
PUSH_STALL_PCT=25                                   # auto: a window below this % of the baseline is a stall, not data
PUSH_MIN_RATE=65536                                 # auto: below this many B/s nothing real is moving
                                                    #   (e.g. streams skipping files already on the NAS) — don't judge
CARD_GLOBS=(/run/media/"$USER"/* /media/"$USER"/* /run/media/* /mnt/card)
SSH_OPTS="-T -o Compression=no -o ServerAliveInterval=20 -o ServerAliveCountMax=6 -o ConnectTimeout=20"

# config precedence: $FOOTAGE_CONF > ~/.config/footage-ingest.conf > alongside script
for _c in "${FOOTAGE_CONF:-}" "$HOME/.config/footage-ingest.conf" "$SCRIPT_DIR/footage-ingest.conf"; do
  [ -n "$_c" ] && [ -r "$_c" ] && { . "$_c"; CONF_USED="$_c"; break; }
done

META=.ingest
DRY=0
LABEL=""
SRC=""
ONLY=""

# ------------------------------------------------------------------- utils ---
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[ -t 1 ] || { c_red=""; c_grn=""; c_ylw=""; c_dim=""; c_off=""; }
say()  { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%swarn:%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

need() {
  local missing=()
  for b in "$@"; do command -v "$b" >/dev/null 2>&1 || missing+=("$b"); done
  [ ${#missing[@]} -eq 0 ] || die "missing required command(s): ${missing[*]}"
}

remote() { printf '%s@%s' "$NAS_USER" "$NAS_HOST"; }

# state PHASE TITLE [DETAIL] [REASON] [PROGRESS] — what the tray icon shows.
# PHASE: idle copying checking uploading verifying held safe verified notsafe error
# Written atomically to $XDG_RUNTIME_DIR/footage-ingest/state; never fails the caller.
# The temp name is per process: a copying run and an uploading run both write
# here, and with one shared .tmp either could rename the other's half-written
# file. run= says which run wrote it (cmd_camera's exit net only replaces its own).
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/footage-ingest/state"
# every desktop notification is also kept here; the tray's "Recent messages" reads it
MESSAGES_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/footage-ingest/messages.log"
RUN_ID="$$"
state() {
  local tmp="$STATE_FILE.tmp.$BASHPID"     # taken here: inside the pipeline below $BASHPID is another process
  { mkdir -p "$(dirname "$STATE_FILE")" &&
    printf 'phase=%s\ntitle=%s\ndetail=%s\nreason=%s\nprogress=%s\nnetwork=%s\nupdated=%s\nrun=%s\n' \
      "$1" "$2" "${3:-}" "${4:-}" "${5:-}" "$(uplink_conn 2>/dev/null | sed -n 's/^GENERAL.CONNECTION://p')" "$(date +%s)" "$RUN_ID" \
      | tr -d '\r' > "$tmp" && mv "$tmp" "$STATE_FILE"; } 2>/dev/null || true
}
state_get() { sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | head -1; }

# While a run copies from / checks against the camera it drops a flag file
# named after its pid. An upload running in another process then keeps its
# progress lines out of the tray, so "don't unplug" isn't replaced every few
# seconds. (Not a flock probe on the camera lock: holding it even for a moment
# could make a run that is just starting believe another one is active.)
CAM_FLAG=""
camera_flag() {
  if [ "$1" = on ]; then
    CAM_FLAG="$(dirname "$STATE_FILE")/camera-busy.$BASHPID"
    { mkdir -p "$(dirname "$CAM_FLAG")" && : > "$CAM_FLAG"; } 2>/dev/null || true
  else
    [ -n "$CAM_FLAG" ] && rm -f "$CAM_FLAG" 2>/dev/null || true
    CAM_FLAG=""
  fi
  return 0
}
camera_busy() {   # is another process in its copy/check phase right now?
  local f
  for f in "$(dirname "$STATE_FILE")"/camera-busy.*; do
    [ -e "$f" ] || continue
    [ "$f" = "$CAM_FLAG" ] && continue
    kill -0 "${f##*.}" 2>/dev/null && return 0
    rm -f "$f" 2>/dev/null || true               # left behind by a run that was killed
  done
  return 1
}

# keep_awake — hold a sleep inhibitor until keep_awake_stop, but only if
# inhibiting actually works here (it needs a working logind session; it fails
# in containers and over some remote shells, and a failed inhibit must not take
# the run down with it). The helper watches this shell's pid, so the inhibitor
# also goes away if the script is killed; and it gets none of the lock fds
# (6/7/9), or a leftover helper would keep the locks held after the script died.
INHIBIT_PID=""
keep_awake() {
  [ -z "$INHIBIT_PID" ] || return 0
  local me="$BASHPID"                        # taken here: in the background job below it would be the job's own pid
  if command -v systemd-inhibit >/dev/null 2>&1 &&
     systemd-inhibit --what=idle --why="probe" true >/dev/null 2>&1; then
    systemd-inhibit --what=idle:sleep --why="footage ingest" --mode=block \
      tail --pid="$me" -f /dev/null >/dev/null 2>&1 6>&- 7>&- 9>&- &
    INHIBIT_PID=$!
  else
    warn "cannot inhibit sleep — make sure the lid stays open / sleep is off until the upload is done"
  fi
  return 0
}
keep_awake_stop() {
  [ -n "$INHIBIT_PID" ] && { pkill -P "$INHIBIT_PID" 2>/dev/null; kill "$INHIBIT_PID" 2>/dev/null; } || true
  INHIBIT_PID=""; return 0
}

fmt_bytes() { awk -v b="$1" 'BEGIN { if (b >= 1e9) printf "%.1f GB", b/1e9; else printf "%.0f MB", b/1e6 }'; }

# ticker PHASE TITLE DETAIL TOTAL CMD... — in the background, every
# PUSH_TICK_SECS, rewrite the tray state with how far CMD says we are (it
# prints bytes done of TOTAL), plus rate and ETA. Long local steps (copy, hash,
# check) otherwise leave the tray frozen on one line for half an hour. Sets
# TICKER to its pid; stop it with ticker_stop. Exits by itself if the caller dies.
ticker() {
  local phase="$1" title="$2" detail="$3" total="$4" parent="$BASHPID"; shift 4
  TICKER=""
  [ "${total:-0}" -gt 0 ] || return 0
  (
    t0=$(date +%s); d0=""; n=0
    while sleep "$PUSH_TICK_SECS"; do
      kill -0 "$parent" 2>/dev/null || exit 0
      d=$("$@" 2>/dev/null) || continue
      case "$d" in ''|*[!0-9]*) continue ;; esac
      [ "$d" -gt "$total" ] && d=$total
      [ -n "$d0" ] || { d0=$d; t0=$(date +%s); }
      now=$(date +%s); n=$((n+1))
      rate=$(( (d - d0) / (now > t0 ? now - t0 : 1) ))
      eta=""; [ "$n" -ge 3 ] && [ "$rate" -gt 0 ] && eta=" · ~$(( (total - d) / rate / 60 + 1 )) min left"
      state "$phase" "$title" "$detail$(fmt_bytes "$d") of $(fmt_bytes "$total") · $(fmt_bytes "$rate")/s$eta" "" $(( d * 100 / total ))
    done
  ) &
  TICKER=$!
}
ticker_stop() { [ -n "${TICKER:-}" ] && { kill "$TICKER" 2>/dev/null; wait "$TICKER" 2>/dev/null || true; }; TICKER=""; return 0; }

# bytes_since BASE DIR — bytes now under DIR (minus .ingest), less BASE
bytes_since() { echo $(( $(du -sb --exclude="$META" "$2" | cut -f1) - $1 )); }

# size_list ROOT — reads relative paths (one per line, in the order sha256sum
# will read them) and prints "BYTES_BEFORE<TAB>PATH" per file, then "TOTAL<TAB>"
size_list() {
  local root="$1"
  ( cd "$root" && sed 's|^\./||' | tr '\n' '\0' | xargs -0 -r stat -c '%s	%n' ) \
    | awk -F'\t' '{ print c "\t" $2; c += $1 } END { print c+0 "\t" }'
}
manifest_paths() { cut -c67- "$1"; }   # "<64 hex>  ./path" -> ./path

# hash_pos ROOT LIST — bytes a sha256sum working in ROOT has read so far, going
# by the file it has open now and how far into it it is (LIST from size_list)
hash_pos() {
  local root="$1" list="$2" p fd t cur pos
  for p in $(pgrep -u "$UID" -x sha256sum); do
    [ "$(readlink "/proc/$p/cwd")" = "$root" ] || continue
    for fd in /proc/"$p"/fd/*; do
      t="$(readlink "$fd")"; case "$t" in "$root"/*) ;; *) continue ;; esac
      cur="${t#"$root"/}"; pos="$(awk '/^pos:/ {print $2}' "/proc/$p/fdinfo/${fd##*/}")"
      awk -F'\t' -v f="$cur" -v pos="${pos:-0}" '$2 == f { print $1 + pos; found=1; exit } END { exit !found }' "$list" && return 0
    done
  done
  return 1
}

# notify URGENCY TITLE BODY — desktop and/or phone; never fails the caller
notify() {
  local u="$1" t="$2" b="$3"
  say "    ${c_dim}[notify] $t — $b${c_off}"
  if [ "$NOTIFY_DESKTOP" = 1 ]; then
    # one line per message: time, urgency, title, body (tabs and newlines flattened)
    local lt="${t//[$'\t\n']/ }" lb="${b//$'\t'/ }"
    { mkdir -p "$(dirname "$MESSAGES_FILE")" &&
      printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$u" "$lt" "${lb//$'\n'/\\n}" >> "$MESSAGES_FILE"; } 2>/dev/null || true
    command -v notify-send >/dev/null 2>&1 && { notify-send -a footage-ingest -u "$u" "$t" "$b" 2>/dev/null || true; }
  fi
  if [ -n "$NOTIFY_NTFY" ] && command -v curl >/dev/null 2>&1; then
    curl -fsS -m 15 -H "Title: $t" -H "Priority: $([ "$u" = critical ] && echo high || echo default)" \
         -d "$b" "$NOTIFY_NTFY" >/dev/null 2>&1 || true
  fi
}

# Files the camera itself rewrites (indexes, its database): not footage, and
# rebuilt by an in-camera format. Ignored when deciding "is there anything new"
# and "is it safe to format".
is_camera_meta() {
  case "$1" in
    DCIM/*/*) return 1 ;;                                   # DCIM/Camera01/... is footage
    DCIM/*|MISC/*|camera/*|"System Volume Information"/*) return 0 ;;
  esac
  return 1
}

# rsync junk that filesystems and OSes leave on removable media
EXCLUDES=(
  --exclude 'System Volume Information' --exclude '.Spotlight-V100'
  --exclude '.fseventsd' --exclude '.Trashes' --exclude '.Trash-*'
  --exclude '$RECYCLE.BIN' --exclude 'lost+found' --exclude '.rsync-partial'
)

# zero_files BATCH — its footage files (relative paths) that are nothing but
# zero bytes. A real clip never is. rsync makes one when a --compare-dest file
# matches size and mtime but not mode: it copies that file instead of reading
# the card, and a prune stub is all zeros (2026-10-24: 211 clips).
zero_files() {
  local b="$1" rel s
  while IFS= read -r -d '' rel; do
    is_camera_meta "$rel" && continue
    s="$(stat -c %s -- "$b/$rel")" || continue
    [ "$s" -gt 0 ] && cmp -s -n "$s" -- "$b/$rel" /dev/zero && printf '%s\n' "$rel"
  done < <(cd "$b" && find . -type f -not -path "./$META/*" -not -path './.rsync-partial/*' -printf '%P\0')
  return 0
}

# --------------------------------------------------------------- detection ---
cmd_detect() {
  local found=0 d
  for d in "${CARD_GLOBS[@]}"; do
    [ -d "$d" ] || continue
    if [ -d "$d/DCIM" ] || compgen -G "$d/DCIM" >/dev/null 2>&1; then
      local sz; sz=$(du -sh "$d/DCIM" 2>/dev/null | cut -f1 || echo '?')
      printf '%s  %s(DCIM, %s)%s\n' "$d" "$c_dim" "$sz" "$c_off"; found=1
    fi
  done
  [ "$found" = 1 ] || {
    warn "no mounted volume with a DCIM/ folder found"
    say  "  checked: ${CARD_GLOBS[*]}"
    say  "  insert the microSD (or plug the camera in and let it mount), or pass --from <path>"
    return 1
  }
}

pick_source() {
  [ -n "$SRC" ] && { [ -d "$SRC" ] || die "--from path not a directory: $SRC"; printf '%s' "$SRC"; return; }
  local cands=() d
  for d in "${CARD_GLOBS[@]}"; do
    [ -d "$d" ] && [ -d "$d/DCIM" ] && cands+=("$d")
  done
  [ ${#cands[@]} -eq 1 ] || {
    [ ${#cands[@]} -eq 0 ] && die "no card detected; run '$SELF detect' or pass --from <path>"
    printf '%s\n' "${cands[@]}" >&2
    die "multiple candidates above; pick one with --from"
  }
  printf '%s' "${cands[0]}"
}

batch_dirs() {
  shopt -s nullglob
  local d
  for d in "$STAGE_ROOT"/*/; do
    d="${d%/}"
    [ -n "$ONLY" ] && [ "$(basename "$d")" != "$ONLY" ] && continue
    printf '%s\n' "$d"
  done
  shopt -u nullglob
}

# ------------------------------------------------------------------- stage ---
# compare_dest LBL — sets CMP to the rsync args that make it skip whatever the
# finished batches of LBL already hold unchanged (same path, size and mtime).
# rsync takes at most 20 --compare-dest dirs and a card soon has more batches
# than that, so they are merged into one: $STAGE_ROOT/.seen-LBL/ holds a hard
# link to every staged file under its card-relative path (hard links keep size
# and mtime, which is all rsync's quick check looks at, and cost no space).
# Refreshed on every call — only new or changed links are touched, and links to
# files no batch holds any more are dropped, so deleting a batch folder makes
# its files "new" again. Where a path is in several batches the most recently
# staged one wins. Used by both the stage and cmd_camera's size probe, so the
# two can never disagree about what is new.
compare_dest() {
  local lbl="$1" seen="$STAGE_ROOT/.seen-$1" d rel ok=1 prior=()
  CMP=()
  case "$lbl" in ""|*/*) return 0 ;; esac       # never build (or prune) a folder outside STAGE_ROOT
  # oldest first by staging time, not by name: 2026-10-10-0516_x is newer than
  # 2026-10-10_x but sorts before it
  while IFS= read -r d; do
    [ -n "$d" ] && prior+=("$d")
  done < <(for d in "$STAGE_ROOT"/*_"$lbl"; do
             [ -e "$d/$META/staged.ok" ] && printf '%s\t%s\n' "$(stat -c %Y "$d/$META/staged.ok")" "$d"
           done | sort -n | cut -f2-)
  if [ ${#prior[@]} -eq 0 ]; then
    [ -d "$seen" ] && find "$seen" -mindepth 1 -delete 2>/dev/null || true
    return 0
  fi
  local -A want=()
  for d in "${prior[@]}"; do
    while IFS= read -r -d '' rel; do
      want[$rel]="$d/$rel"
    done < <(cd "$d" && find . -type f -not -path "./$META/*" -not -path '*/.rsync-partial/*' -printf '%P\0')
    # a pruned batch's clips are gone from the laptop: its stubs (empty files
    # with the same size, mode and mtime) stand in for them, so they still count
    if [ -d "$d/$META/stubs" ]; then
      while IFS= read -r -d '' rel; do
        want[$rel]="$d/$META/stubs/$rel"
      done < <(cd "$d/$META/stubs" && find . -type f -printf '%P\0')
    fi
  done
  mkdir -p "$seen" 2>/dev/null || ok=0
  if [ "$ok" = 1 ]; then
    for rel in "${!want[@]}"; do
      [ "$seen/$rel" -ef "${want[$rel]}" ] && continue
      mkdir -p "$(dirname "$seen/$rel")" 2>/dev/null && ln -f -- "${want[$rel]}" "$seen/$rel" 2>/dev/null || { ok=0; break; }
    done
  fi
  if [ "$ok" = 1 ]; then
    while IFS= read -r -d '' rel; do
      [ -n "${want[$rel]:-}" ] || rm -f -- "$seen/$rel"
    done < <(find "$seen" -type f -printf '%P\0')
    find "$seen" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true
    CMP=(--compare-dest="$seen/")
    return 0
  fi
  # no hard links here (odd filesystem?): fall back to the batch folders
  # themselves, as many as rsync takes — anything older is simply copied again
  warn "could not build $seen — comparing against the batch folders directly"
  [ ${#prior[@]} -gt 20 ] && { warn "more than 20 earlier '$lbl' batches — comparing against the newest 20 only"
                               prior=("${prior[@]: -20}"); }
  for d in "${prior[@]}"; do CMP+=(--compare-dest="$d/"); done
  return 0
}

# card_listing SRC DEST OUT — what a stage of SRC into DEST would copy, given
# CMP: "BYTES PATH" lines in the file OUT. Non-zero if rsync could not read the
# whole card (unreadable folder, I/O error, card gone): the listing is then
# short, and "nothing new" must never be concluded from it.
card_listing() {
  local src="$1" dest="$2" out="$3" rc=0
  rsync -a --dry-run --out-format='%l %n' "${EXCLUDES[@]}" "${CMP[@]}" "$src/" "$dest/" > "$out" 2> "$out.err" || rc=$?
  [ "$rc" = 0 ] || warn "could not list $src (rsync exit $rc): $(head -3 "$out.err" | tr '\n' ' ')"
  rm -f "$out.err"
  return "$rc"
}

# has_footage DIR — does DIR (a batch) hold any file that isn't a camera index file?
has_footage() {
  local f
  while IFS= read -r -d '' f; do
    is_camera_meta "$f" || return 0
  done < <(cd "$1" 2>/dev/null && find . -type f -not -path "./$META/*" -not -path '*/.rsync-partial/*' -printf '%P\0')
  return 1
}

cmd_stage() {
  need rsync
  local src batch
  src="$(pick_source)"
  local lbl="${LABEL:-$(basename "$src" | tr -cs '[:alnum:]._-' '-' | sed 's/^-*//;s/-*$//')}"
  [ -n "$lbl" ] || lbl=card
  batch="$STAGE_ROOT/$(date +%F)_$lbl"
  # today's batch is already complete (and may be mid-push or verified): never
  # add files to it — a second stage the same day gets its own timestamped
  # batch, with seconds (and then a counter) if that minute's name is taken too
  local n=1
  [ -e "$batch/$META/staged.ok" ] && batch="$STAGE_ROOT/$(date +%F-%H%M)_$lbl"
  [ -e "$batch/$META/staged.ok" ] && batch="$STAGE_ROOT/$(date +%F-%H%M%S)_$lbl"
  while [ -e "$batch/$META/staged.ok" ]; do
    n=$((n+1)); batch="$STAGE_ROOT/$(date +%F-%H%M%S)-${n}_$lbl"
  done
  # an interrupted stage of the same label resumes into its own batch, even on
  # a later day — otherwise the date prefix would start over from zero
  local d
  for d in "$STAGE_ROOT"/*_"$lbl"; do
    [ -d "$d/$META" ] && [ ! -e "$d/$META/staged.ok" ] && batch="$d"
  done

  local args=(-a --info=progress2 --human-readable --no-inc-recursive
              --partial --partial-dir=.rsync-partial "${EXCLUDES[@]}")
  [ "$DRY" = 1 ] && args+=(--dry-run)

  # The card is never erased by this script, so it keeps growing between
  # stages. Stage only what earlier finished batches of this label don't
  # already hold unchanged.
  compare_dest "$lbl"
  [ ${#CMP[@]} -gt 0 ] && say "    new files only — skipping what earlier '$lbl' batches already hold"
  args+=("${CMP[@]}")

  # The camera rewrites its index files on every mount; if nothing but those
  # changed there is no new footage, so don't make a near-empty batch for them.
  local f sz new=0 todo=0 lst
  lst="$(mktemp "${TMPDIR:-/tmp}/footage-list.XXXXXX")"
  card_listing "$src" "$batch" "$lst" \
    || { rm -f "$lst"; die "could not read the whole card ($src) — nothing copied; re-plug it and try again"; }
  while read -r sz f; do
    case "$f" in */|"") continue ;; esac
    todo=$((todo + sz))
    is_camera_meta "$f" || new=1
  done < "$lst"
  rm -f "$lst"
  # a stage that was interrupted after the copy but before staged.ok (while
  # hashing) has nothing left to copy, yet it is not finished: carry on, so it
  # gets its manifest — otherwise the batch would sit there unfinished for ever
  if [ "$new" = 0 ] && [ "$DRY" != 1 ] && [ -d "$batch/$META" ] && [ ! -e "$batch/$META/staged.ok" ] && has_footage "$batch"; then
    say "    $(basename "$batch") was copied but never finished — finishing it now"; new=1
  fi
  if [ "$new" = 0 ]; then
    info "nothing new on $src since the last '$lbl' batch (camera index files only)"; return 0
  fi
  info "staging  $src  ->  $batch"
  [ "$DRY" = 1 ] || mkdir -p "$batch/$META"

  # trailing slash: copy the card's contents (DCIM/ and siblings) into the batch
  local base=0 rrc=0 mnt; mnt="$(basename "$src")"
  [ "$DRY" = 1 ] || { base=$(du -sb --exclude="$META" "$batch" | cut -f1)
                      ticker copying "Copying from $mnt — don't unplug" "" "$todo" bytes_since "$base" "$batch"; }
  rsync "${args[@]}" "$src/" "$batch/" || rrc=$?
  ticker_stop
  [ "$rrc" = 0 ] || die "rsync from card failed (exit $rrc) — card still intact, re-run to resume"
  [ "$DRY" = 1 ] && { info "dry run, nothing written"; return 0; }

  # rsync still recreates the card's directory tree around skipped files;
  # sweep the empty directories (staging only — the card is never touched)
  find "$batch" -mindepth 1 -depth -type d -empty -not -path "$batch/$META" -delete
  if [ -z "$(find "$batch" -type f -not -path "$batch/$META/*" -print -quit)" ]; then
    rmdir "$batch/$META" "$batch" 2>/dev/null || true
    info "nothing new on $src since the last '$lbl' batch"; return 0
  fi

  # a clip that is nothing but zero bytes is a copied prune stub, not footage:
  # drop it (left in place, a re-run would skip it as unchanged) and stop
  # before staged.ok, so nothing downstream trusts this batch
  local zl; zl="$(zero_files "$batch")"
  if [ -n "$zl" ]; then
    printf '%s\n' "$zl" | sed 's/^/    all zeros: /' >&2
    ( cd "$batch" && printf '%s\n' "$zl" | tr '\n' '\0' | xargs -0 -r rm -f -- )
    die "$(printf '%s\n' "$zl" | wc -l) clip(s) arrived as nothing but zeros — those copies deleted, card untouched"
  fi

  if [ "$HASH" = 1 ]; then
    need sha256sum
    info "hashing staged files (reads every byte; --no-hash to skip)"
    local hl; hl="$(mktemp "${TMPDIR:-/tmp}/footage-sizes.XXXXXX")"
    ( cd "$batch" && find . -type f -not -path "./$META/*" -not -path './.rsync-partial/*' | sort ) | size_list "$batch" > "$hl"
    ticker checking "Fingerprinting the laptop copy — don't unplug" "$mnt: " "$(tail -1 "$hl" | cut -f1)" hash_pos "$batch" "$hl"
    ( cd "$batch" && find . -type f -not -path "./$META/*" -not -path './.rsync-partial/*' -print0 \
        | sort -z | xargs -0 -r sha256sum > "$META/manifest.sha256.tmp" \
      && mv "$META/manifest.sha256.tmp" "$META/manifest.sha256" ) || { ticker_stop; rm -f "$hl"; die "hashing failed"; }
    ticker_stop; rm -f "$hl"
    say "    $(wc -l < "$batch/$META/manifest.sha256") files hashed"
  fi

  printf 'source=%s\nstaged_at=%s\nhost=%s\n' "$src" "$(date -Is)" "$(uname -n)" > "$batch/$META/staged.ok"
  [ -n "${STAGE_RESULT_FILE:-}" ] && printf '%s\n' "$batch" > "$STAGE_RESULT_FILE"
  info "staged: $(du -sh "$batch" | cut -f1) in $batch"
  [ -n "$LOCAL_FLAT_DIR" ] && { link_flat "$batch" || warn "some clips not linked into $LOCAL_FLAT_DIR (they are still staged)"; }
  say  "${c_dim}the card is untouched — keep it as your second copy until the NAS copy verifies${c_off}"
}

# -------------------------------------------------------------------- link ---
# Hard-link a batch's clips (every file under DCIM/<folder>/, at any depth —
# DCIM/Camera01/, DCIM/100GOPRO/, ...) loose into LOCAL_FLAT_DIR. The
# batch folders stay as the script's bookkeeping (incremental stage, verify);
# the flat folder is the view to edit from and costs no extra space. Never
# overwrites: a different file with the same name is reported and skipped.
link_flat() {
  local b="$1" f n t made=0 have=0 conf=0
  [ -n "$LOCAL_FLAT_DIR" ] || return 0
  mkdir -p "$LOCAL_FLAT_DIR"
  while IFS= read -r -d '' f; do
    n="${f##*/}"; t="$LOCAL_FLAT_DIR/$n"
    if [ -e "$t" ]; then
      if [ "$t" -ef "$f" ]; then have=$((have+1))
      elif cmp -s "$t" "$f"; then have=$((have+1))
      else warn "name clash, not linked: $n (already in $LOCAL_FLAT_DIR with different contents)"; conf=$((conf+1)); fi
    else
      ln -- "$f" "$t" || { warn "could not link $n (different filesystem?)"; conf=$((conf+1)); continue; }
      made=$((made+1))
    fi
  done < <(find "$b/DCIM" -mindepth 2 -type f -print0 2>/dev/null | sort -z)
  say "    $(basename "$b"): linked $made new, $have already there, $conf not linked"
  [ "$conf" = 0 ]
}

cmd_link() {
  [ -n "$LOCAL_FLAT_DIR" ] || die "LOCAL_FLAT_DIR is not set in the config"
  info "linking staged clips into $LOCAL_FLAT_DIR"
  local b rc=0
  while read -r b; do
    [ -f "$b/$META/staged.ok" ] || continue
    link_flat "$b" || rc=1
  done < <(batch_dirs)
  return $rc
}

# ------------------------------------------------------------------ verify ---
cmd_verify() {
  need sha256sum
  local b rc=0
  while read -r b; do
    [ -f "$b/$META/manifest.sha256" ] || { warn "no manifest: $(basename "$b") (staged with --no-hash?)"; continue; }
    [ -f "$b/$META/pruned.ok" ] && { say "${c_dim}skip $(basename "$b") (pruned — its clips are only on the NAS now)${c_off}"; continue; }
    info "verifying $(basename "$b") (local)"
    if ( cd "$b" && sha256sum --quiet -c "$META/manifest.sha256" ); then
      say "    ${c_grn}ok${c_off}"
    else
      warn "checksum mismatch in $(basename "$b") — re-stage from the card before pushing"; rc=1
    fi
  done < <(batch_dirs)
  return $rc
}

# -------------------------------------------------------------------- push ---
tailscale_check() {
  command -v tailscale >/dev/null 2>&1 || { warn "tailscale not on PATH — skipping path check"; return 0; }
  local out
  out="$(tailscale ping -c 1 --timeout 5s "$NAS_HOST" 2>&1 | grep -v "^Warning: client version" || true)"
  case "$out" in
    *"via DERP"*) warn "Tailscale is RELAYING via DERP — expect poor throughput.
       try: tailscale netcheck   (UDP 41641 blocked? hard NAT on this hotel/mobile network?)
       pushing anyway at --bwlimit=$BWLIMIT" ;;
    # a direct path reads "pong from <node> (<ip>) via <endpoint> in Nms" —
    # the word "direct" never appears, so match the pong instead
    *"pong from"*" via "*) info "Tailscale path: direct  ${c_dim}(${out})${c_off}" ;;
    *)            warn "could not confirm Tailscale path to $NAS_HOST: $out" ;;
  esac
}

# ----------------------------------------------------------- network guard ---
# Before any real push: is Tailscale up, is this network OK to upload on, and
# does the NAS actually answer through the tunnel? Returns 3 ("held") when the
# push should wait for a person, so retry loops know not to spin on it.
uplink_conn() {   # NetworkManager connection carrying the default route
  local dev; dev=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$dev" ] && nmcli -t -f GENERAL.CONNECTION,GENERAL.METERED dev show "$dev" 2>/dev/null
}

net_guard() {
  [ "$NETWORK_GUARD" = 1 ] || return 0
  if command -v tailscale >/dev/null 2>&1 && ! tailscale status >/dev/null 2>&1; then
    warn "Tailscale is not running — start it:  sudo systemctl enable --now tailscaled"
    notify critical "Backup paused: no connection to home" "Tailscale is off — choose Connect to home in the tray menu"
    state held "Paused: no connection to home" "Tailscale is off — use Connect to home in this menu (or: sudo systemctl start tailscaled)" tailscale; return 3
  fi
  local info con metered
  info="$(uplink_conn)" || info=""
  con="$(printf '%s\n' "$info" | sed -n 's/^GENERAL.CONNECTION://p')"
  metered="$(printf '%s\n' "$info" | sed -n 's/^GENERAL.METERED://p')"
  case "$metered" in yes*)
    warn "network '$con' is marked metered — not uploading (unmark it, or push with NETWORK_GUARD=0)"
    notify critical "Backup paused: metered connection" "'$con' is metered — the upload waits for a connection that isn't"
    state held "Paused: '$con' is metered" "Not uploading over a metered connection" metered; return 3 ;;
  esac
  # with a trusted-networks list, a network that can't be identified (no
  # NetworkManager answer, no default route) is not a trusted one: hold, don't
  # upload blind — it might be the phone tether
  if [ -z "$con" ] && [ -f "$TRUSTED_NETWORKS_FILE" ]; then
    warn "can't tell which network this is — not uploading (check the connection, or push with NETWORK_GUARD=0)"
    notify critical "Backup paused: unknown network" "Can't tell which network this is — check the connection, then choose Back up now"
    state held "Paused: unknown network" "Can't tell which network this is — check the connection, then use 'Back up now'" network-unknown; return 3
  fi
  if [ -n "$con" ] && [ -f "$TRUSTED_NETWORKS_FILE" ] && ! grep -qxF -- "$con" "$TRUSTED_NETWORKS_FILE"; then
    warn "network '$con' isn't trusted for uploads — if it's unlimited:  $SELF trust-network"
    notify critical "Backup paused: new network" "'$con' — if its data is unlimited, choose Allow uploads in the tray menu"
    state held "Paused: new network '$con'" "If its data is unlimited, allow it in this menu and the upload starts" network; return 3
  fi
  # the relay path has gone dead while Tailscale still looked "up": check the
  # NAS really answers, and reset the tunnel once if it doesn't
  if ! ping -c2 -W5 -q "$NAS_HOST" >/dev/null 2>&1; then
    warn "NAS not answering through Tailscale — resetting the tunnel"
    { tailscale down && tailscale up; } >/dev/null 2>&1 || warn "tailscale down/up failed (operator not set? sudo tailscale set --operator=\$USER)"
    local t0; t0=$(date +%s)
    until ping -c1 -W3 -q "$NAS_HOST" >/dev/null 2>&1; do
      [ $(( $(date +%s) - t0 )) -ge 90 ] && { warn "NAS still unreachable"; notify critical "Backup paused: the NAS isn't answering" "Connected to home, but the NAS doesn't reply — it retries by itself"
        state held "Paused: the NAS isn't answering" "Connected to home, but the NAS doesn't reply — it retries by itself" nas; return 3; }
      sleep 3
    done
    info "tunnel back"
  fi
  return 0
}

cmd_trust_network() {
  local con; con="$(uplink_conn | sed -n 's/^GENERAL.CONNECTION://p')"
  [ -n "$con" ] || die "can't tell which network carries the default route"
  mkdir -p "$(dirname "$TRUSTED_NETWORKS_FILE")"
  if grep -qxF -- "$con" "$TRUSTED_NETWORKS_FILE" 2>/dev/null; then info "'$con' is already trusted"
  else printf '%s\n' "$con" >> "$TRUSTED_NETWORKS_FILE"; info "trusted '$con' for uploads ($TRUSTED_NETWORKS_FILE)"; fi
}

# ---------------------------------------------------------- parallel push ---
# Several rsync streams per batch, each its own ssh connection (one long, lossy
# TCP stream can't fill a high-latency link; several often can — but never
# multiplex them over one ssh ControlMaster, that defeats the point). Files go
# into a shared queue largest-first; each stream pops the next one. With
# PUSH_STREAMS=auto it starts with one stream, measures the real upload rate on
# the interface that carries traffic to the NAS, and adds streams while each
# one raises the total by >= PUSH_GAIN_PCT, up to PUSH_MAX_STREAMS.
tx_bytes() { cat "/sys/class/net/$1/statistics/tx_bytes" 2>/dev/null || echo 0; }

push_parallel() {
  local b="$1" dest="$2" wd n=0 target pids=() iface rate t0 b0 t1 b1 left p me="$BASHPID"
  # auto controller state: mode ramp|trial|steady|fixed; base = rate to beat;
  # samples = measurements in the current judging round (judged on their mean)
  local mode=ramp base=0 warm=0 samples=() avg last_trial
  wd="$(mktemp -d "${TMPDIR:-/tmp}/footage-push.XXXXXX")"
  ( cd "$b" && find . -type f -not -path './.rsync-partial/*' -printf '%s %P\n' ) \
    | sort -rn | cut -d' ' -f2- > "$wd/queue"
  local total; total=$(wc -l < "$wd/queue")
  local total_bytes; total_bytes=$(cd "$b" && find . -type f -not -path './.rsync-partial/*' -printf '%s\n' | awk '{s+=$1} END {print s+0}')
  : > "$wd/failed"
  # directory skeleton first, so streams never race to create the same dirs
  rsync -a -s -f'+ */' -f'- *' -e "ssh $SSH_OPTS" "$b/" "$dest/" || { rm -rf "$wd"; return 1; }

  _pop() { local l; { flock 8; l="$(head -n1 "$wd/queue")"; [ -n "$l" ] && sed -i 1d "$wd/queue"; } 8>"$wd/q.lock"; printf '%s' "$l"; [ -n "$l" ]; }
  _stream() {
    local f sp="$BASHPID"   # not $BASHPID below: inside a pipeline it is the pipeline's own subshell
    while :; do
      # the controller retires one stream (that added nothing) by dropping this file
      mv "$wd/retire" "$wd/retired.$sp" 2>/dev/null && break
      kill -0 "$me" 2>/dev/null || break       # the script was killed: don't upload on as an orphan
      f="$(_pop)" || break
      printf '%s\n' "$f" > "$wd/item.$sp"
      # --out-format prints a line only for files actually sent (not ones already
      # on the NAS); its %l lets the progress estimate tell sent from skipped
      # rsync's own progress for this file goes to prog.<pid> (read by the
      # display loop); --out-format adds a "SENT <bytes>" line only for files
      # actually sent, so skipped (already on the NAS) files don't count as speed
      : > "$wd/prog.$sp"
      if rsync -a -s --partial --partial-dir=.rsync-partial --files-from="$wd/item.$sp" \
            --info=progress2 --out-format='SENT %l' -e "ssh $SSH_OPTS" "$b/" "$dest/" \
            2>>"$wd/errors" >>"$wd/prog.$sp"; then
        stat -c%s "$b/$f" >> "$wd/done.$sp" 2>/dev/null || true
        grep -ao 'SENT [0-9]*' "$wd/prog.$sp" | awk '{s+=$2} END {print s+0}' >> "$wd/sent.$sp"
      else
        printf '%s\n' "$f" >> "$wd/failed"
      fi
      rm -f "$wd/item.$sp" "$wd/prog.$sp"
    done
  }
  _start() { _stream & pids+=($!); n=$((n+1)); }
  _alive() { local p; for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && return 0; done; return 1; }
  # Interrupted: stop the streams (and the rsync each one is running) and leave
  # with an error. This must exit, not just clean up — otherwise the function
  # carries on, returns 0, and the caller marks a half-sent batch as pushed.
  trap 'for p in "${pids[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; rm -rf "$wd"; exit 130' INT TERM HUP

  if [ "$PUSH_STREAMS" = auto ]; then target=$PUSH_MAX_STREAMS; _start
  else target=$PUSH_STREAMS; while [ $n -lt "$target" ]; do _start; done; mode=fixed; fi
  iface="$(ip route get "$NAS_HOST" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
  say "    $total files, ${PUSH_STREAMS} streams (measuring on ${iface:-?})"

  _logn() { printf '%s %s %s\n' "$(date -Is)" "$n" "$base" >> "$HOME/.cache/footage-ingest-streams.log" 2>/dev/null || true; }
  _sum() { cat "$@" 2>/dev/null | awk '{s+=$1} END {print s+0}'; }
  _fmt() { awk -v b="$1" 'BEGIN { if (b >= 1e9) printf "%.1f GB", b/1e9; else printf "%.0f MB", b/1e6 }'; }
  # Progress in bytes, straight from rsync: finished files plus each stream's
  # own count for the file it's on. Independent of any other traffic on the
  # interface (the interface counter is still what the stream controller uses).
  _inflight() { local pf sum=0 v; for pf in "$wd"/prog.*; do [ -f "$pf" ] || continue
      v=$(tail -c 400 "$pf" 2>/dev/null | tr '\r' '\n' | grep -aoE '^ *[0-9,]+B? +[0-9]+%' | tail -1 | awk '{gsub("[,B]","",$1); print $1+0}')
      sum=$(( sum + ${v:-0} )); done; echo $sum; }
  local tt tnow tbnow drate=0 done_b sent_b infl moved prev_moved=0 eta ticks=0 pct mins
  t0=$(date +%s); b0=$(tx_bytes "$iface"); last_trial=$t0; tt=$t0
  while _alive; do
    sleep "$PUSH_TICK_SECS" & wait $! 2>/dev/null
    tnow=$(date +%s); tbnow=$(tx_bytes "$iface")
    done_b=$(_sum "$wd"/done.*); sent_b=$(_sum "$wd"/sent.*); infl=$(_inflight)
    # speed counts only bytes actually sent (finished-and-sent + in flight), so
    # files skipped as already-on-the-NAS don't show up as a burst of speed
    moved=$(( sent_b + infl ))
    local r=$(( (moved - prev_moved) / ( (tnow-tt) > 0 ? (tnow-tt) : 1 ) )); [ $r -lt 0 ] && r=0
    prev_moved=$moved; tt=$tnow
    drate=$(( drate == 0 ? r : (drate*2 + r) / 3 ))
    done_b=$(( done_b + infl )); [ $done_b -gt $total_bytes ] && done_b=$total_bytes
    ticks=$((ticks+1))
    pct=$(( done_b*100 / (total_bytes>0?total_bytes:1) ))
    if camera_busy; then
      :   # another run is copying from the camera: its "don't unplug" line owns the tray
    elif [ "$done_b" -ge "$total_bytes" ]; then
      # rsync counts bytes once they're in the socket; on a long link tens of
      # MB are still in flight until the NAS confirms — don't claim 100% yet
      state uploading "Uploading to the NAS" "$(_fmt $total_bytes) sent · finishing — waiting for the NAS to confirm" "" 99
    else
      eta=""
      if [ $ticks -ge 3 ] && [ $drate -gt 0 ]; then      # no guesses before the speed settles
        mins=$(( (total_bytes-done_b) / drate / 60 ))
        eta=" · $([ $mins -lt 1 ] && echo '<1 min' || echo "~$mins min") left"
      fi
      state uploading "Uploading to the NAS" \
        "$(_fmt $done_b) / $(_fmt $total_bytes) · $(( drate/100000 / 10 )).$(( drate/100000 % 10 )) MB/s · $n stream(s)$eta" \
        "" "$([ $pct -gt 99 ] && echo 99 || echo $pct)"
    fi
    [ $(( tnow - t0 )) -lt "$PUSH_PROBE_SECS" ] && continue

    # ---- controller step, on the longer PUSH_PROBE_SECS window
    t1=$tnow; b1=$tbnow
    rate=$(( (b1-b0) / ( (t1-t0) > 0 ? (t1-t0) : 1 ) )); t0=$t1; b0=$b1
    left=$(wc -l < "$wd/queue")
    say "    streams=$n  $(( rate/1000 )) kB/s  files left in queue: $left/$total"
    [ "$mode" = fixed ] && continue
    # a stream was just added: let it connect and ramp before judging it
    [ "$warm" = 1 ] && { warm=0; continue; }
    # resuming: streams mostly skip finished files, the rate says nothing yet
    [ "$rate" -lt "$PUSH_MIN_RATE" ] && continue
    # a window far below the baseline is the link hiccuping (relay stall, Wi-Fi
    # dropout), not evidence about the stream count: leave it out entirely
    if [ "$base" -gt 0 ] && [ "$rate" -lt $(( base * PUSH_STALL_PCT / 100 )) ]; then
      say "    ${c_dim}(stall window ignored)${c_off}"; continue
    fi

    if [ "$mode" = steady ]; then
      base=$(( (base*3 + rate) / 4 ))          # smoothed rate of the current stream count
      # links drift (relays, Wi-Fi, time of day): periodically re-test one more stream
      if [ $(( t1 - last_trial )) -ge "$PUSH_REPROBE_SECS" ] && [ "$left" -gt 0 ] && [ $n -lt "$target" ]; then
        _start; warm=1; mode=trial; samples=(); say "    trying $n streams (baseline $(( base/1000 )) kB/s)"
      fi
      continue
    fi

    # ramp/trial: judge on the mean of two windows, never one (relayed links swing a lot)
    samples+=("$rate"); [ ${#samples[@]} -lt 2 ] && continue
    avg=$(( (samples[0] + samples[1]) / 2 )); samples=()
    if [ "$base" = 0 ]; then                    # first real measurement, one stream
      base=$avg
      if [ "$left" -gt 0 ] && [ $n -lt "$target" ]; then _start; warm=1; continue; fi
      mode=steady; last_trial=$t1; continue
    fi
    if [ "$avg" -gt $(( base * (100+PUSH_GAIN_PCT) / 100 )) ]; then
      base=$avg                                 # the new stream paid for itself
      # it helped, so try one more straight away (initial ramp or a successful re-test)
      if [ "$left" -gt 0 ] && [ $n -lt "$target" ]; then _start; warm=1; mode=ramp; continue; fi
      say "    ${c_grn}using $n stream(s)${c_off} ($(( base/1000 )) kB/s)"
    else
      # it didn't: retire it after its current file
      touch "$wd/retire"; n=$((n-1))
      say "    ${c_grn}using $n stream(s)${c_off} ($(( base/1000 )) kB/s; one more added only $(( avg/1000 )) kB/s total)"
    fi
    mode=steady; last_trial=$t1; _logn
  done
  wait "${pids[@]}" 2>/dev/null || true
  trap - INT TERM HUP
  if [ -s "$wd/failed" ]; then
    warn "$(wc -l < "$wd/failed") file(s) failed: $(head -3 "$wd/failed" | tr '\n' ' ')"; tail -3 "$wd/errors" >&2
    rm -rf "$wd"; return 1
  fi
  # No failure recorded is not the same as everything sent: a stream that died
  # (killed, out of memory) took the file it had popped with it, and streams
  # that all stopped early leave the queue non-empty. Success is an empty queue
  # and one "done" record per file — nothing less.
  local sent_n; sent_n=$(cat "$wd"/done.* 2>/dev/null | wc -l)
  left=$(wc -l < "$wd/queue")
  if [ "$left" -ne 0 ] || [ "$sent_n" -ne "$total" ]; then
    warn "upload stopped early: $sent_n of $total file(s) confirmed sent, $left still queued"
    rm -rf "$wd"; return 1
  fi
  rm -rf "$wd"
}

cmd_push() {
  need rsync ssh
  [ -d "$STAGE_ROOT" ] || die "nothing staged (no $STAGE_ROOT)"
  if [ "$DRY" != 1 ]; then net_guard || return $?; fi
  tailscale_check

  local lock="${TMPDIR:-/tmp}/footage-push.$UID.lock"
  exec 9>"$lock"
  flock -n 9 || die "another push is already running (lock: $lock)"

  # keep the laptop awake for the duration (cmd_camera already does, for its
  # whole run; then this is a no-op and the inhibitor stays its to release)
  local awake=0
  [ "$DRY" = 1 ] || [ -n "$INHIBIT_PID" ] || { keep_awake; awake=1; }

  local b name rc=0 prc
  while read -r b; do
    name="$(basename "$b")"
    [ -f "$b/$META/staged.ok" ] || { warn "skipping $name (not fully staged)"; continue; }
    [ -f "$b/$META/pruned.ok" ] && { say "${c_dim}skip $name (pruned — nothing left on the laptop to send)${c_off}"; continue; }
    if [ -f "$b/$META/pushed.ok" ] && [ "${FORCE:-0}" != 1 ]; then
      say "${c_dim}skip $name (already pushed; FORCE=1 to redo)${c_off}"; continue
    fi

    info "pushing $name -> $(remote):$NAS_PATH/$name   (bwlimit=$BWLIMIT)"
    # -s keeps NAS_PATH off the remote command line entirely (it is sent over
    # the protocol instead). The path has a space in it ("Luna Ultra"); modern
    # rsync escapes it by default, but -s is not at the mercy of --old-args or
    # a stray RSYNC_OLD_ARGS in the environment.
    local args=(-a -s --info=progress2 --human-readable --no-inc-recursive
                --partial --partial-dir=.rsync-partial
                --bwlimit="$BWLIMIT" "${EXCLUDES[@]}" -e "ssh $SSH_OPTS")
    [ "$DRY" = 1 ] && args+=(--dry-run)

    # parallel streams for real pushes; a bandwidth cap is per stream in rsync,
    # so a capped push stays single-stream to keep the cap meaningful
    prc=0
    if [ "$DRY" = 1 ] || [ "$PUSH_STREAMS" = 1 ] || [ "$BWLIMIT" != 0 ]; then
      rsync "${args[@]}" "$b/" "$(remote):$NAS_PATH/$name/" || prc=$?
    else
      push_parallel "$b" "$(remote):$NAS_PATH/$name" || prc=$?
    fi
    if [ "$prc" = 0 ]; then
      [ "$DRY" = 1 ] || printf 'pushed_at=%s\ntarget=%s:%s/%s\n' \
        "$(date -Is)" "$(remote)" "$NAS_PATH" "$name" > "$b/$META/pushed.ok"
      info "pushed $name"
    else
      warn "push of $name interrupted (exit $prc) — partials kept, re-run '$SELF push' to resume"; rc=1
    fi
  done < <(batch_dirs)
  [ "$awake" = 1 ] && keep_awake_stop
  return $rc
}

# ----------------------------------------------------------- verify-remote ---
# Move a verified batch's footage (every file under DCIM/<folder>/, at any
# depth — not just DCIM/Camera01/*) loose into NAS_FLATTEN_TO. Runs on the NAS,
# working from the LAPTOP's manifest (sent along inside the script), never the
# copy of it on the NAS. Never overwrites: a file whose name already exists
# there — from an older batch, or from another DCIM subfolder of this one — is
# only treated as a duplicate if that file's sha256 matches the manifest, and
# anything else is a conflict that stays put (exit 2). The leftover batch dir is
# removed only when nothing but camera index files, the .ingest folder and
# stale rsync partials is left in it; if any other file remains (footage
# outside DCIM/<folder>/, a file the manifest doesn't know) it refuses and
# leaves the batch where it is (exit 3). Removal is file by file and then
# rmdir, never a recursive delete. If the batch dir is already gone — an
# earlier flatten finished on the NAS but the connection dropped before the
# laptop heard — it proves instead that every footage file of the manifest is
# in NAS_FLATTEN_TO with the right sha256. Card is never involved.
# Exit: 0 flattened, 2 conflicts, 3 refused, 255 NAS unreachable, else failed.
flatten_remote() {
  local b="$1" name; name="$(basename "$b")"
  [ -f "$b/$META/manifest.sha256" ] || { warn "$name has no manifest — can't flatten"; return 1; }
  info "flattening $name -> $NAS_FLATTEN_TO"
  # built in a file, not a pipe: the remote side may finish without reading it
  # all, and a SIGPIPE on this end must not be mistaken for a failure there
  local scr frc=0; scr="$(mktemp "${TMPDIR:-/tmp}/footage-flatten.XXXXXX")"
  { printf "manifest() { cat <<'__FOOTAGE_MANIFEST__'\n"
    cat "$b/$META/manifest.sha256"
    printf "__FOOTAGE_MANIFEST__\n}\n"
    cat <<'REMOTE'
set -u
src="$1"; dest="$2"; name="$3"
case "$src" in */"$name") ;; *) echo "refusing: odd batch path $src"; exit 1 ;; esac
[ -d "$dest" ] && [ -w "$dest" ] || { echo "destination not writable: $dest"; exit 1; }
# same rule as is_camera_meta on the laptop
is_meta() {
  case "$1" in
    DCIM/*/*) return 1 ;;
    DCIM/*|MISC/*|camera/*|"System Volume Information"/*) return 0 ;;
  esac
  return 1
}
want_of() { manifest | awk -v p="./$1" 'substr($0,67)==p {print $1; exit}'; }
sum_of() { sha256sum < "$1" | cut -d' ' -f1; }

if [ ! -d "$src" ]; then
  [ -d "${src%/*}" ] || { echo "landing folder missing: ${src%/*}"; exit 1; }
  ok=0 miss=0
  while IFS= read -r line; do
    h="${line%% *}"; p="${line:66}"; p="${p#./}"
    is_meta "$p" && continue
    if [ -f "$dest/${p##*/}" ] && [ "$(sum_of "$dest/${p##*/}")" = "$h" ]; then ok=$((ok+1))
    else echo "not in $dest with the right checksum: $p"; miss=$((miss+1)); fi
  done < <(manifest)
  echo "    batch folder already gone: $ok footage file(s) proven in $dest, $miss missing"
  [ "$miss" = 0 ] || exit 1
  exit 0
fi

cd "$src" || exit 1
moved=0 dup=0 conf=0
while IFS= read -r -d '' f; do
  f="${f#./}"
  case "$f" in .rsync-partial/*|*/.rsync-partial/*) continue ;; esac
  is_meta "$f" && continue
  want="$(want_of "$f")"
  [ -n "$want" ] || continue                 # not in the manifest: stays, and blocks the removal below
  n="${f##*/}"
  if [ -e "$dest/$n" ]; then
    if [ "$want" = "$(sum_of "$dest/$n")" ]; then rm -- "$f"; dup=$((dup+1))
    else echo "conflict (left in place): $f"; conf=$((conf+1)); fi
  else
    mv -n -- "$f" "$dest/$n" && [ -e "$dest/$n" ] && [ ! -e "$f" ] || { echo "move failed: $f"; exit 1; }
    moved=$((moved+1))
  fi
done < <(find ./DCIM -mindepth 2 -type f -print0 2>/dev/null | sort -z)
echo "    moved=$moved  duplicates=$dup  conflicts=$conf"
[ "$conf" = 0 ] || exit 2

left=()
while IFS= read -r -d '' f; do
  f="${f#./}"
  case "$f" in .ingest/*|.rsync-partial/*|*/.rsync-partial/*) continue ;; esac
  is_meta "$f" || left+=("$f")
done < <(find . ! -type d -print0)
if [ ${#left[@]} -gt 0 ]; then
  echo "refusing to remove $src: ${#left[@]} file(s) in it are not camera index files and were not moved:"
  printf '      %s\n' "${left[@]:0:10}"
  exit 3
fi
find . ! -type d -exec rm -f -- {} +
find . -mindepth 1 -depth -type d -exec rmdir -- {} + 2>/dev/null
cd / && rmdir -- "$src" || { echo "refusing to remove $src: it is not empty"; exit 3; }
REMOTE
  } > "$scr"
  ssh $SSH_OPTS "$(remote)" "bash -s -- $(printf '%q ' "$NAS_PATH/$name" "$NAS_FLATTEN_TO" "$name")" < "$scr" || frc=$?
  rm -f "$scr"
  return "$frc"
}

# flatten_step BATCH — flatten and record it; 0 done, 4 NAS unreachable, 1 failed
flatten_step() {
  local b="$1" name frc=0; name="$(basename "$b")"
  flatten_remote "$b" || frc=$?
  case "$frc" in
    0)   printf 'flattened_at=%s\ntarget=%s\n' "$(date -Is)" "$NAS_FLATTEN_TO" > "$b/$META/flattened.ok"; return 0 ;;
    255) # ssh itself failed: nothing is known to be wrong, it just isn't done yet
         warn "$name: could not reach $NAS_HOST — verified but not flattened yet; re-run '$SELF verify-remote' when the link is back"; return 4 ;;
    *)   warn "$name verified but NOT flattened (see above) — re-run '$SELF verify-remote' once that is sorted out"; return 1 ;;
  esac
}

# Exit: 0 all verified; 4 nothing wrong but the NAS could not be reached for at
# least one batch (retry later); 1 a batch failed verification or flattening.
cmd_verify_remote() {
  need ssh
  local b name rc=0 vrc
  # the batch list comes in on fd 3: the ssh calls below read stdin (the
  # manifest), and anything on the loop's stdin would be swallowed by them —
  # that once left every batch but the first unverified
  while read -r b <&3; do
    name="$(basename "$b")"
    [ -f "$b/$META/pushed.ok" ] || continue
    if [ -f "$b/$META/flattened.ok" ]; then
      say "${c_dim}skip $name (verified and flattened into $(sed -n 's/^target=//p' "$b/$META/flattened.ok"))${c_off}"; continue
    fi
    # verified earlier but the flatten stopped partway (e.g. a name conflict):
    # some clips have already left $NAS_PATH/$name, so the batch can't be
    # re-checksummed in place. Resume the flatten instead — what is left there
    # is untouched since it verified, and duplicates are re-hashed anyway.
    if [ -n "$NAS_FLATTEN_TO" ] && [ -f "$b/$META/verified.ok" ]; then
      vrc=0; flatten_step "$b" || vrc=$?
      if [ "$vrc" = 4 ]; then [ "$rc" = 0 ] && rc=4; elif [ "$vrc" != 0 ]; then rc=1; fi
      continue
    fi
    [ -f "$b/$META/manifest.sha256" ] || { warn "$name has no manifest to verify against"; continue; }
    info "verifying $name on $NAS_HOST (this re-reads every byte on the NAS)"
    # checked against the laptop's manifest, fed on stdin — not the copy of it
    # that was uploaded, which is only as good as the upload being checked
    vrc=0
    ssh $SSH_OPTS "$(remote)" \
         "cd '$NAS_PATH/$name' && sha256sum --quiet -c -" < "$b/$META/manifest.sha256" || vrc=$?
    if [ "$vrc" = 255 ]; then
      # ssh itself failed (link down, relay stall): says nothing about the data
      warn "$name: could not reach $NAS_HOST — not verified yet; re-run '$SELF verify-remote' when the link is back"
      [ "$rc" = 0 ] && rc=4
      continue
    fi
    if [ "$vrc" = 0 ]; then
      say "    ${c_grn}ok — NAS copy matches the staged copy${c_off}"
      printf 'verified_at=%s\n' "$(date -Is)" > "$b/$META/verified.ok"
      if [ -n "$NAS_FLATTEN_TO" ]; then
        vrc=0; flatten_step "$b" || vrc=$?
        if [ "$vrc" = 4 ]; then [ "$rc" = 0 ] && rc=4; elif [ "$vrc" != 0 ]; then rc=1; fi
      fi
    else
      warn "$name FAILED remote verification — re-run '$SELF push' (FORCE=1) before trusting it"; rc=1
    fi
  done 3< <(batch_dirs)
  return $rc
}

# ------------------------------------------------------------ format-check ---
# For every camera storage that is mounted: is every footage file on it in a
# batch that verified on the NAS (same path and size)? Camera index files are
# ignored — an in-camera format rebuilds them. Files in a desktop trash folder
# on the card count by their original path. Exit 0 only if all are safe.
# A file counts only if its batch's manifest lists it (so it was hashed and
# that hash checked on the NAS) — merely lying in the batch folder isn't proof.
# If the card can't be listed completely the answer is NOT safe, never SAFE:
# a short listing looks exactly like a card with less footage on it.
cmd_format_check() {
  local entry mnt lbl src b f rel n o t top sz v m p u any=0 unsafe=0 lst lerr
  lst="$(mktemp "${TMPDIR:-/tmp}/footage-list.XXXXXX")"
  for entry in "${SOURCES[@]}"; do
    mnt="${entry%%:*}"; lbl="${entry#*:}"; src="$MEDIA_ROOT/$mnt"
    [ -d "$src/DCIM" ] || continue
    any=1; lerr=0
    declare -A seen=()
    for b in "$STAGE_ROOT"/*_"$lbl"; do
      [ -f "$b/$META/staged.ok" ] && [ -f "$b/$META/manifest.sha256" ] || continue
      local mark=P; [ -f "$b/$META/verified.ok" ] && mark=V
      [ -f "$b/$META/checked.ok" ] || mark=U    # copy never compared with the camera
      # a pruned batch's sizes come from its stubs (same paths, same sizes)
      local root="$b"; [ -f "$b/$META/pruned.ok" ] && root="$b/$META/stubs"
      while IFS= read -r f; do
        [ "${seen[$f]:-}" = V ] || seen[$f]=$mark
      done < <(cd "$root" && manifest_paths "$b/$META/manifest.sha256" | sed 's|^\./||' | tr '\n' '\0' \
                 | xargs -0 -r stat -c '%n|%s' 2>/dev/null)
    done
    find "$src" -type f -print0 > "$lst" 2>/dev/null || lerr=1
    v=0; p=0; m=0; u=0; local missing=()
    while IFS= read -r -d '' f; do
      rel="${f#"$src"/}"
      case "$rel" in .Trash-*/info/*|.Trash-*/directorysizes) continue ;; esac
      if [[ $rel == .Trash-*/files/* ]]; then
        # the trash keeps one .trashinfo per trashed item; for a trashed
        # folder that is the folder, not each file in it — so look up the top
        # entry and add the rest of the path. Unknown origin = not backed up.
        t="${rel%%/files/*}"; n="${rel#*/files/}"; top="${n%%/*}"
        o="$(sed -n 's/^Path=//p' "$src/$t/info/$top.trashinfo" 2>/dev/null | head -1)" || o=""
        if [ -z "$o" ]; then
          m=$((m+1)); missing+=("$rel (in the card's trash, original place unknown — NOT backed up)"); continue
        fi
        o="$(printf '%b' "${o//%/\\x}")" || o=""
        [ "$n" != "$top" ] && o="$o/${n#*/}"
        o="${o#"$src"/}"
        case "$o" in DCIM/*) rel="$o" ;; *DCIM/*) rel="DCIM/${o#*DCIM/}" ;; *) rel="${o#/}" ;; esac
      fi
      is_camera_meta "$rel" && continue
      sz="$(stat -c%s "$f" 2>/dev/null)" || { lerr=1; sz=""; }
      case "${seen[$rel|$sz]:-}" in V) v=$((v+1)) ;; P) p=$((p+1)); missing+=("$rel (staged, not verified on NAS yet)") ;; U) u=$((u+1)); missing+=("$rel (copied, but the copy was never checked against the camera)") ;; *) m=$((m+1)); missing+=("$rel (NOT backed up)") ;; esac
    done < "$lst"
    unset seen
    if [ "$lerr" = 0 ] && [ $((p+m+u)) -eq 0 ]; then
      if [ "$v" -eq 0 ]; then say "${c_grn}SAFE to format${c_off}  $mnt — no footage on it, nothing on it to back up"
      else say "${c_grn}SAFE to format${c_off}  $mnt — all $v footage files verified on the NAS"; fi
    else
      unsafe=1
      [ "$lerr" = 1 ] && say "${c_red}NOT safe${c_off}       $mnt — could not read the whole card, so there may be footage on it that wasn't seen; re-plug the camera and check again"
      if [ $((p+m+u)) -gt 0 ]; then
        say "${c_red}NOT safe${c_off}       $mnt — $v verified, $p staged but not verified, $u not checked against the camera, $m not backed up"
        [ "$u" -gt 0 ] && say "                 leave the camera plugged in and run: $SELF camera  (tray: Back up now) to finish the check"
        printf '                 %s\n' "${missing[@]:0:10}"
        [ ${#missing[@]} -gt 10 ] && say "                 … and $(( ${#missing[@]} - 10 )) more"
      fi
    fi
  done
  rm -f "$lst"
  [ "$any" = 1 ] || { warn "no camera storage mounted under $MEDIA_ROOT"; return 2; }
  return $unsafe
}

# ------------------------------------------------------------------ camera ---
# Last thing a camera run does, however it ends (normal return, die, set -e,
# Ctrl-C, TERM): stop its helpers, and if the tray would be left showing a busy
# phase that this run wrote, say that it stopped — a tray stuck on "Copying…"
# with nothing running tells nobody what to do next.
camera_exit() {
  ticker_stop; keep_awake_stop; camera_flag off
  [ ${#CAM_TMP[@]} -gt 0 ] && rm -f "${CAM_TMP[@]}" 2>/dev/null || true
  case "$(state_get phase)" in copying|checking|uploading|verifying)
    [ "$(state_get run)" = "$RUN_ID" ] &&
      state error "Stopped unexpectedly" "Use 'Resume backup' in the menu — nothing is lost" stopped ;;
  esac
  return 0
}
CAM_TMP=()

# The whole chain for every mounted camera storage: stage only what's new,
# check the copy against the camera itself, then push (retrying through
# dropouts), verify on the NAS (retrying only when it's unreachable), and say
# when it's safe to unplug and when it's safe to format.
cmd_camera() {
  local lock="${XDG_RUNTIME_DIR:-/tmp}/footage-camera.$UID.lock"
  exec 7>"$lock"; flock -n 7 || die "another camera ingest is already running"
  local entry mnt lbl src b res rc try out batches=() names=() sl fm todo=() f line
  # From here on this shell — the script itself, or the subshell 'watch' runs
  # this in — leaves through camera_exit. (push_parallel's own INT/TERM/HUP
  # trap lives in the ( cmd_push ) subshell below, so neither disturbs the other.)
  trap camera_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  camera_flag on
  keep_awake                                 # for the whole run: copy, check, upload, verify
  res="$(mktemp "${TMPDIR:-/tmp}/footage-stage.XXXXXX")"
  sl="$(mktemp "${TMPDIR:-/tmp}/footage-sizes.XXXXXX")"
  fm="$(mktemp "${TMPDIR:-/tmp}/footage-check.XXXXXX")"
  CAM_TMP=("$res" "$sl" "$fm")

  # say straight away what's about to happen — a big copy is a long silence otherwise
  local plan=() bytes=0 cnt sz d perr=0
  for entry in "${SOURCES[@]}"; do
    mnt="${entry%%:*}"; lbl="${entry#*:}"; src="$MEDIA_ROOT/$mnt"
    [ -d "$src/DCIM" ] || continue
    # same comparison as the stage itself will make (compare_dest), and a
    # listing that failed is not "nothing new" — the stage below will say why
    compare_dest "$lbl"
    card_listing "$src" "$STAGE_ROOT/.probe-$lbl" "$res" || { perr=1; continue; }
    read -r cnt sz <<< "$(awk '{ p = $0; sub(/^[0-9]+ /, "", p) } p !~ /\/$/ && p ~ /^DCIM\/[^\/]+\// { n++; s += $1 } END { print n+0, s+0 }' "$res")"
    [ "${cnt:-0}" -gt 0 ] && { plan+=("$mnt: $cnt files, $(( sz/1000000000 )).$(( sz%1000000000/100000000 )) GB"); bytes=$((bytes+sz)); }
  done
  if [ ${#plan[@]} -gt 0 ]; then
    state copying "Copying from the camera — don't unplug" "$(printf '%s; ' "${plan[@]}")"
    notify normal "Backup started — don't unplug yet" "$(printf '%s\n' "${plan[@]}")Copying to the laptop first (~$(( bytes/40000000/60 + 1 )) min); you'll be told when it's safe to unplug."
  elif [ "$perr" = 1 ]; then
    state checking "Camera connected — looking for new footage" "Couldn't list everything on it yet — don't unplug"
  else
    state checking "Camera connected — nothing new" "Checking it's safe to format"
    notify low "Camera connected — nothing new" "All footage on it is already backed up; checking it's safe to format…"
  fi
  for entry in "${SOURCES[@]}"; do
    mnt="${entry%%:*}"; lbl="${entry#*:}"; src="$MEDIA_ROOT/$mnt"
    [ -d "$src/DCIM" ] || continue
    info "=== $mnt  ($lbl)"
    : > "$res"
    ( SRC="$src" LABEL="$lbl" STAGE_RESULT_FILE="$res" cmd_stage ) \
      || { notify critical "Copy FAILED — do NOT format" "$mnt: copying to the laptop failed — nothing deleted; re-plug the camera to retry"
           state error "Copying from $mnt failed" "Nothing deleted — re-plug to retry" copy; return 1; }
    # what to check against the camera: the batch just copied, plus any earlier
    # one whose check never finished (laptop restarted or cable pulled mid-check)
    # — otherwise the next run sees "nothing new" and the check is never done
    b="$(cat "$res")"; todo=(); [ -n "$b" ] && todo+=("$b")
    for d in "$STAGE_ROOT"/*_"$lbl"; do
      [ -e "$d/$META/staged.ok" ] && [ ! -e "$d/$META/checked.ok" ] && [ "$d" != "$b" ] || continue
      if ( cd "$src" && manifest_paths "$d/$META/manifest.sha256" | tr '\n' '\0' | xargs -0 -r ls -d >/dev/null 2>&1 ); then
        info "$(basename "$d"): its check against $mnt never finished — doing it now"; todo+=("$d")
      else
        warn "$(basename "$d") was never checked against $mnt and its files are no longer all on it — can't check"
      fi
    done
    for b in "${todo[@]}"; do
    info "checking $(basename "$b") against $mnt itself"
    state checking "Checking the copy against $mnt — don't unplug" "$(basename "$b")"
    # The camera rewrites its own index files whenever it's used, so on a
    # check done later they differ: leave them out of what is checked, rather
    # than sorting FAILED lines afterwards (sha256sum dying right after an
    # index file's FAILED line then looked like "only index files differ").
    # What is left is all footage, so ANY failure of the check is a mismatch.
    [ -f "$b/$META/manifest.sha256" ] || { warn "$(basename "$b") has no manifest (staged with --no-hash?) — can't check it against $mnt"; continue; }
    : > "$fm"
    while IFS= read -r line; do
      f="${line:66}"; is_camera_meta "${f#./}" || printf '%s\n' "$line"
    done < "$b/$META/manifest.sha256" >> "$fm"
    manifest_paths "$fm" | size_list "$b" > "$sl"
    rc=0; out=""
    if [ -s "$fm" ]; then
      ticker checking "Checking the copy against $mnt — don't unplug" "re-reading the camera: " "$(tail -1 "$sl" | cut -f1)" hash_pos "$src" "$sl"
      out="$( cd "$src" && sha256sum --quiet -c "$fm" 2>&1 )" || rc=$?
      ticker_stop
    fi
    if [ "$rc" != 0 ]; then
      printf '%s\n' "$out"
      notify critical "Copy doesn't match the camera — do NOT format" "$mnt: the laptop copy differs from the camera; re-plug the camera to retry"
      state error "Copy doesn't match the camera" "$mnt — do NOT format; re-plug to retry" mismatch; return 1
    fi
    ticker checking "Re-checking the laptop copy — don't unplug" "re-reading the laptop: " "$(tail -1 "$sl" | cut -f1)" hash_pos "$b" "$sl"
    rc=0; ( ONLY="$(basename "$b")" cmd_verify ) || rc=$?
    ticker_stop
    [ "$rc" = 0 ] || { notify critical "Laptop copy damaged — do NOT format" "$(basename "$b") failed its re-check on the laptop; it has to be copied again"
                       state error "The laptop copy failed its re-check" "$(basename "$b") is damaged on the laptop — do NOT format; it has to be copied again" verify-local; return 1; }
    printf 'checked_at=%s\nagainst=%s\n' "$(date -Is)" "$src" > "$b/$META/checked.ok"
    batches+=("$b"); names+=("$mnt")
    done
  done

  if [ ${#batches[@]} -eq 0 ]; then
    info "nothing new on the camera"
  else
    notify normal "Copied to the laptop — safe to unplug" "${names[*]}: ${#batches[@]} batch(es) copied and checked against the camera"
    state uploading "Copied — safe to unplug. Uploading…" "${names[*]}: ${#batches[@]} batch(es) on the laptop and checked"
  fi

  # The copy-and-check part is over: let go of the camera lock so that plugging
  # the camera in during a long upload can still copy and check. Uploads take
  # their own lock; a second run waits here, then pushes whatever is left.
  camera_flag off
  exec 7>&-
  exec 6>"${XDG_RUNTIME_DIR:-/tmp}/footage-upload.$UID.lock"
  flock -n 6 || { info "another run is uploading — waiting for it, then uploading whatever is left"; flock 6; }

  # push everything not yet pushed (this run's batches and anything left over)
  for try in $(seq 1 30); do
    rc=0; ( cmd_push ) || rc=$?          # set -e: never let a failed attempt end the script
    [ "$rc" = 0 ] && break
    [ "$rc" = 3 ] && { warn "upload held — fix the above, then: $SELF camera  (or: $SELF push && $SELF verify-remote)"; return 3; }
    [ "$try" = 30 ] && { notify critical "Upload FAILED" "Gave up after 30 attempts — choose Try again in the tray menu"
                         state error "Upload failed after 30 attempts" "Use 'Back up now' to retry" push; return 1; }
    camera_busy || state uploading "Upload interrupted — retrying (attempt $((try+1)))" "rsync resumes; nothing is lost"
    warn "push attempt $try failed — retrying in 60s"; sleep 60
  done
  for try in $(seq 1 10); do
    camera_busy || state verifying "Verifying on the NAS" "Re-reading every byte there and comparing checksums"
    rc=0; out="$( ( cmd_verify_remote ) 2>&1 )" || rc=$?; printf '%s\n' "$out"
    [ "$rc" = 0 ] && break
    # 4 = nothing wrong, the NAS just couldn't be reached: retry. Anything else
    # (a mismatch, even alongside an unreachable batch) is a real failure.
    if [ "$rc" != 4 ]; then
      notify critical "NAS copy doesn't match — do NOT format" "A batch on the NAS differs from the laptop copy (to re-send it: FORCE=1 $SELF push)"
      state error "NAS copy doesn't match" "Do NOT format — re-push with FORCE=1" verify; return 1
    fi
    [ "$try" = 10 ] && { notify critical "Backup paused: the NAS isn't answering" "Uploaded, but not verified yet — choose Try again in the tray menu"
                         state held "Paused: the NAS isn't answering" "Use 'Back up now' to retry" nas; return 1; }
    warn "NAS unreachable — retrying the check in 60s"; sleep 60
  done

  # final word: per-file check if the camera is still attached
  rc=0; out="$( ( cmd_format_check ) 2>&1 )" || rc=$?
  if [ "$rc" = 0 ]; then
    printf '%s\n' "$out"; notify normal "Backed up — safe to format" "Every footage file on the camera is verified on the NAS"
    state safe "Safe to format" "Every footage file on the camera is verified on the NAS"
  elif [ "$rc" = 2 ]; then
    notify normal "Backed up" "${#batches[@]} new batch(es) verified on the NAS. Plug the camera in to confirm it's safe to format."
    state verified "All footage is backed up" "Camera unplugged — plug it in to confirm it's safe to format"
  else
    printf '%s\n' "$out"; notify critical "NOT safe to format" "Some files on the camera aren't verified on the NAS — choose Can I format the card? for the list"
    state notsafe "NOT safe to format" "Some files on the camera aren't verified — see 'Can I format the card?'"
  fi
  cmd_status
}

# ------------------------------------------------------------------- watch ---
# Run by the systemd path unit when something mounts under MEDIA_ROOT. Stays
# up while anything is mounted there (so the path unit doesn't re-fire), and
# runs 'camera' whenever a camera storage appears or its contents change.
# camera_gone — the camera is no longer attached: a green "Safe to format" left
# in the tray would now be about a card that isn't there (and the next card
# plugged in is a different matter), so step it down to plain "verified"
camera_gone() {
  [ "$(state_get phase)" = safe ] &&
    state verified "All footage is backed up" "Backed up — plug the camera in to confirm it's safe to format"
  return 0
}

cmd_watch() {
  local last="" fp entry src rc i greeted=0 failed="" retry_at=0
  info "watching $MEDIA_ROOT"
  # let both camera volumes mount — but say at once that the camera has been
  # seen, so whatever the tray still shows from the previous card is replaced
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$greeted" = 0 ]; then
      for entry in "${SOURCES[@]}"; do
        [ -d "$MEDIA_ROOT/${entry%%:*}" ] || continue
        state checking "Camera connected — looking for new footage" "Don't unplug yet"; greeted=1; break
      done
    fi
    sleep 1
  done
  while [ -n "$(ls -A "$MEDIA_ROOT" 2>/dev/null)" ]; do
    fp=""
    for entry in "${SOURCES[@]}"; do
      src="$MEDIA_ROOT/${entry%%:*}"
      # the volume name is part of it, so a card with no footage at all still
      # counts as "a camera is here" and gets its one run
      [ -d "$src/DCIM" ] && fp+="${entry%%:*}:$(find "$src/DCIM" -path '*/DCIM/*/*' -type f -printf '%P %s %T@\n' 2>/dev/null | sort | sha256sum)"
    done
    if [ -z "$fp" ]; then
      # unplugged (something else is still mounted): forget the fingerprint, so
      # plugging the same card back in is a new event even if nothing changed
      last=""; failed=""; camera_gone
    elif [ "$fp" != "$last" ] && { [ "$fp" != "$failed" ] || [ "$(date +%s)" -ge "$retry_at" ]; }; then
      [ -n "$last" ] || [ "$greeted" = 1 ] || state checking "Camera connected — looking for new footage" "Don't unplug yet"
      greeted=0
      rc=0; ( cmd_camera ) || rc=$?
      # only a run that finished (0) or is waiting for a person (3 = held) has
      # dealt with this card; after a failure the same contents must be tried
      # again — on a replug, or after a while
      if [ "$rc" = 0 ] || [ "$rc" = 3 ]; then last="$fp"; failed=""
      else warn "camera run ended with status $rc"; failed="$fp"; retry_at=$(( $(date +%s) + WATCH_RETRY_SECS )); fi
    fi
    sleep 30
  done
  camera_gone
  info "nothing mounted under $MEDIA_ROOT — done"
}

# ------------------------------------------------------------------- prune ---
# Free laptop space: delete the clips of batches that are verified on the NAS,
# from the batch folder and from LOCAL_FLAT_DIR. Never touches the card or the
# NAS. Before anything goes, every file of the manifest gets a stub in
# .ingest/stubs/ (an empty sparse file with the same size, mode and mtime) and the
# manifest stays, so compare_dest and format-check still count a pruned
# batch's clips as copied and backed up — a card that still holds them is not
# copied again, and still shows SAFE. A batch is pruned only when it is
# verified (and flattened, with NAS_FLATTEN_TO) and the NAS, asked right now,
# has every footage file at the right size. Deletion is file by file, never a
# recursive delete. An interrupted prune finishes on the next run.
# Exit: 0 done, 4 the NAS could not be reached for some batch, 1 a batch kept.

# prune_nas_check BATCH — 0 every footage file is on the NAS at its size,
# 4 NAS unreachable, 1 not
prune_nas_check() {
  local b="$1" name rel lst scr flat prc=0; name="$(basename "$b")"
  flat="$(sed -n 's/^target=//p' "$b/$META/flattened.ok" 2>/dev/null)"; flat="${flat:-$NAS_FLATTEN_TO}"
  lst="$(mktemp "${TMPDIR:-/tmp}/footage-prune.XXXXXX")"
  scr="$(mktemp "${TMPDIR:-/tmp}/footage-prune.XXXXXX")"
  # where each file is on the NAS: loose in NAS_FLATTEN_TO once flattened (the
  # camera index files were dropped there), else still in the landing folder
  while IFS= read -r rel; do
    rel="${rel#./}"
    if [ -f "$b/$META/flattened.ok" ]; then
      is_camera_meta "$rel" && continue
      printf '%s\t%s\n' "$(stat -c %s -- "$b/$rel")" "$flat/${rel##*/}"
    else
      printf '%s\t%s\n' "$(stat -c %s -- "$b/$rel")" "$NAS_PATH/$name/$rel"
    fi
  done < <(manifest_paths "$b/$META/manifest.sha256") > "$lst"
  { printf "list() { cat <<'__FOOTAGE_LIST__'\n"
    cat "$lst"
    printf "__FOOTAGE_LIST__\n}\n"
    cat <<'REMOTE'
ok=0 bad=0
while IFS=$'\t' read -r s p; do
  if [ -n "$s" ] && [ "$(stat -c %s -- "$p" 2>/dev/null)" = "$s" ]; then ok=$((ok+1))
  else echo "    not on the NAS at the right size: $p"; bad=$((bad+1)); fi
done < <(list)
echo "    $ok footage file(s) on the NAS at the right size, $bad not"
[ "$bad" = 0 ]
REMOTE
  } > "$scr"
  ssh $SSH_OPTS "$(remote)" "bash -s" < "$scr" || prc=$?
  rm -f "$lst" "$scr"
  case "$prc" in 0) return 0 ;; 255) return 4 ;; *) return 1 ;; esac
}

# prune_stubs BATCH — write .ingest/stubs/: one stand-in per manifest file
prune_stubs() {
  local b="$1" st="$1/$META/stubs" rel
  [ -d "$st.tmp" ] && find "$st.tmp" -depth -delete
  while IFS= read -r rel; do
    rel="${rel#./}"
    mkdir -p "$(dirname "$st.tmp/$rel")" &&
      truncate -s "$(stat -c %s -- "$b/$rel")" "$st.tmp/$rel" &&
      chmod --reference="$b/$rel" -- "$st.tmp/$rel" &&
      touch -m -r "$b/$rel" "$st.tmp/$rel" || return 1
  done < <(manifest_paths "$b/$META/manifest.sha256")
  [ -d "$st" ] && find "$st" -depth -delete
  mv "$st.tmp" "$st"
}

# prune_delete BATCH — delete its files (and their links in LOCAL_FLAT_DIR); keeps .ingest
prune_delete() {
  local b="$1" f t
  while IFS= read -r -d '' f; do
    if [ -n "$LOCAL_FLAT_DIR" ]; then
      t="$LOCAL_FLAT_DIR/${f##*/}"
      if [ "$t" -ef "$f" ]; then rm -f -- "$t"; fi
    fi
    rm -f -- "$f"
  done < <(find "$b" -path "$b/$META" -prune -o -type f -print0)
  find "$b" -mindepth 1 -depth -type d -empty -not -path "$b/$META" -not -path "$b/$META/*" -delete
}

cmd_prune() {
  need ssh truncate
  exec 7>"${XDG_RUNTIME_DIR:-/tmp}/footage-camera.$UID.lock"
  flock -n 7 || die "a camera run is copying — prune once it's done"
  exec 6>"${XDG_RUNTIME_DIR:-/tmp}/footage-upload.$UID.lock"
  flock -n 6 || die "an upload is running — prune once it's done"
  local b name why sz vrc rc=0 n=0 bytes=0 lbl labels=() avail
  # the batch list comes in on fd 3: the ssh in prune_nas_check reads stdin
  while read -r b <&3; do
    name="$(basename "$b")"
    if [ -f "$b/$META/pruned.ok" ]; then
      [ -n "$(find "$b" -path "$b/$META" -prune -o -type f -print -quit)" ] || continue
      info "$name: finishing an interrupted prune"
      [ "$DRY" = 1 ] && continue
      sz=$(sed -n 's/^bytes=//p' "$b/$META/pruned.ok"); sz=${sz:-0}
    else
      why=""
      [ -f "$b/$META/manifest.sha256" ] || why="no manifest"
      [ -f "$b/$META/verified.ok" ] || why="not verified on the NAS yet"
      [ -z "$NAS_FLATTEN_TO" ] || [ -f "$b/$META/flattened.ok" ] || why="${why:-not flattened on the NAS yet}"
      if [ -n "$why" ]; then
        if [ -n "$ONLY" ]; then warn "not pruning $name: $why"; rc=1
        else say "${c_dim}keep $name ($why)${c_off}"; fi
        continue
      fi
      sz=$(du -sb --exclude="$META" "$b" | cut -f1)
      info "$name: $(fmt_bytes "$sz") — checking the NAS has every clip"
      vrc=0; prune_nas_check "$b" || vrc=$?
      if [ "$vrc" = 4 ]; then warn "$name: could not reach $NAS_HOST — kept"; [ "$rc" = 0 ] && rc=4; continue
      elif [ "$vrc" != 0 ]; then warn "$name: not everything is on the NAS (above) — kept"; rc=1; continue; fi
      if [ "$DRY" = 1 ]; then say "    would delete its clips ($(fmt_bytes "$sz"))"; bytes=$((bytes + sz)); continue; fi
      prune_stubs "$b" || { warn "$name: could not write its stubs — kept"; rc=1; continue; }
      printf 'pruned_at=%s\nbytes=%s\n' "$(date -Is)" "$sz" > "$b/$META/pruned.ok"
    fi
    prune_delete "$b"
    say "    ${c_grn}pruned${c_off} — $(fmt_bytes "$sz") of clips deleted from the laptop"
    bytes=$((bytes + sz)); n=$((n+1)); labels+=("${name#*_}")
  done 3< <(batch_dirs)
  if [ "$DRY" = 1 ]; then info "dry run: would delete $(fmt_bytes "$bytes"); nothing changed"; return $rc; fi
  # .seen-<label> still hard-links the deleted clips; re-pointing it at the
  # stubs is what actually gives the space back
  for lbl in $(printf '%s\n' "${labels[@]}" | sort -u); do compare_dest "$lbl"; done
  avail=$(df -B1 --output=avail "$STAGE_ROOT" 2>/dev/null | tail -1 | tr -d ' ')
  info "pruned $n batch(es), $(fmt_bytes "$bytes") of clips${avail:+ — $(fmt_bytes "$avail") free now}"
  return $rc
}

# ------------------------------------------------------------------ status ---
cmd_status() {
  say "config:  ${CONF_USED:-<defaults, no config file>}"
  say "nas:     $(remote):$NAS_PATH   bwlimit=$BWLIMIT"
  say "staging: $STAGE_ROOT"
  say ""
  printf '%-30s %6s %6s %6s %6s %8s %5s %6s\n' BATCH SIZE FILES STAGED PUSHED VERIFIED FLAT LOCAL
  local b name n
  while read -r b; do
    name="$(basename "$b")"
    n=$([ -f "$b/$META/manifest.sha256" ] && wc -l < "$b/$META/manifest.sha256" || echo '-')
    printf '%-30s %6s %6s %6s %6s %8s %5s %6s\n' "$name" \
      "$(du -sh "$b" 2>/dev/null | cut -f1)" "$n" \
      "$([ -f "$b/$META/staged.ok" ]   && echo yes || echo no)" \
      "$([ -f "$b/$META/pushed.ok" ]   && echo yes || echo no)" \
      "$([ -f "$b/$META/verified.ok" ] && echo yes || echo no)" \
      "$([ -f "$b/$META/flattened.ok" ] && echo yes || echo no)" \
      "$([ -f "$b/$META/pruned.ok" ] && echo pruned || echo yes)"
  done < <(batch_dirs)
}

cmd_run() { cmd_stage; [ "$HASH" = 1 ] && cmd_verify; cmd_push; [ "$HASH" = 1 ] && cmd_verify_remote; cmd_status; }

usage() {
  cat <<USAGE
$SELF $VERSION — resumable, verified camera-card ingest to a NAS

  $SELF detect                 list mounted volumes that look like camera cards
  $SELF stage  [--from PATH] [--label NAME]
  $SELF verify                 re-check staged files against their sha256 manifest
  $SELF link                   hard-link every staged clip into LOCAL_FLAT_DIR (stage does it too)
  $SELF push                   staging -> NAS, resumable, rate limited
  $SELF verify-remote          checksum the NAS copy over ssh, then (if NAS_FLATTEN_TO
                               is set) move its clips loose into that folder
  $SELF run                    stage + verify + push + verify-remote
  $SELF status                 table of every batch and how far it has got
  $SELF camera                 everything, for each mounted camera storage: stage new
                               footage, check it against the camera, push, verify, notify
  $SELF format-check           per mounted storage: is every footage file verified on the NAS?
  $SELF trust-network          allow uploads on the network you're on now
  $SELF prune [--only BATCH]   free laptop space: delete the clips of batches verified on the
                               NAS (batch folder + LOCAL_FLAT_DIR); keeps manifests and
                               stubs so they still count as copied. Never touches the card
  $SELF watch                  (for the systemd path unit) run 'camera' whenever it's plugged in

options   --from PATH  --label NAME  --only BATCH  --bwlimit 2M  --streams auto|N
          --no-hash  --dry-run
env       FORCE=1 re-push an already-pushed batch
config    \$FOOTAGE_CONF, ~/.config/footage-ingest.conf, or ./footage-ingest.conf

tip: long pushes belong in tmux —  tmux new -As push '$SELF push'
note: this script never deletes from the card. Erase it in-camera once
      'status' shows VERIFIED=yes and you are home with a third copy.
USAGE
}

# -------------------------------------------------------------------- main ---
SUB="${1:-status}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --from)    SRC="${2:?}"; shift 2 ;;
    --label)   LABEL="${2:?}"; shift 2 ;;
    --only)    ONLY="${2:?}"; shift 2 ;;
    --bwlimit) BWLIMIT="${2:?}"; shift 2 ;;
    --streams) PUSH_STREAMS="${2:?}"; shift 2 ;;
    --no-hash) HASH=0; shift ;;
    --dry-run|-n) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1  (try --help)" ;;
  esac
done
mkdir -p "$STAGE_ROOT"
case "$SUB" in
  detect)        cmd_detect ;;
  stage)         cmd_stage ;;
  verify)        cmd_verify ;;
  link)          cmd_link ;;
  push)          cmd_push ;;
  verify-remote) cmd_verify_remote ;;
  run)           cmd_run ;;
  status)        cmd_status ;;
  camera)        cmd_camera ;;
  format-check)  cmd_format_check ;;
  watch)         cmd_watch ;;
  trust-network) cmd_trust_network ;;
  prune)         cmd_prune ;;
  -h|--help|help) usage ;;
  *) die "unknown command: $SUB  (try --help)" ;;
esac
