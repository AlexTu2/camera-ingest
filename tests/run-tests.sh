#!/usr/bin/env bash
# Regression tests for ingest-footage.sh — the bugs found in the October 2026
# audit, one case each. Nothing real is touched: every case gets its own
# sandbox under a mktemp dir with a fake card, staging area and "NAS" (a local
# folder), its own config, HOME, TMPDIR and XDG_RUNTIME_DIR. ssh/rsync are
# replaced by local stand-ins, and `rm -rf` is switched off (sandboxes are left
# behind on purpose — delete them by hand).
#   tests/run-tests.sh            # all cases
#   tests/run-tests.sh trash      # only cases whose name contains "trash"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${FOOTAGE_SCRIPT:-$HERE/../ingest-footage.sh}"     # FOOTAGE_SCRIPT: test another copy
T="$(mktemp -d "${TMPDIR:-/tmp}/footage-tests.XXXXXX")"
# the library part: everything above the main block (as test-controller.sh does)
sed -n '1,/^# -* main ---/p' "$SCRIPT" > "$T/lib.sh"
FILTER="${1:-}"
PASSED=0; FAILED=0; FAILED_NAMES=()

# ---------------------------------------------------------------- sandbox ---
sandbox() {   # sets C (case dir) and CARD, writes the config
  C="$T/$1"; CARD="$C/media/SD Card"
  mkdir -p "$CARD/DCIM/Camera01" "$C/stage" "$C/nas/incoming" "$C/nas/flat" "$C/run" "$C/tmp" "$C/home"
  cat > "$C/conf" <<EOF
STAGE_ROOT="$C/stage"
MEDIA_ROOT="$C/media"
LOCAL_FLAT_DIR="$C/flatlocal"
TRUSTED_NETWORKS_FILE="$C/trusted-networks"
NOTIFY_DESKTOP=0
NOTIFY_NTFY=""
NAS_FLATTEN_TO=""
NAS_HOST="nas.invalid"
NAS_USER="tester"
NAS_PATH="$C/nas/incoming"
SOURCES=("SD Card:luna-sd")
CARD_GLOBS=("$C/media"/*)
BWLIMIT=0
PUSH_STREAMS=2
PUSH_TICK_SECS=1
NETWORK_GUARD=0
EOF
  export FOOTAGE_CONF="$C/conf" XDG_RUNTIME_DIR="$C/run" TMPDIR="$C/tmp" HOME="$C/home"
}

# the real script, as a command (set -e in force) — only for NAS-less commands
script() { bash "$SCRIPT" "$@"; }

# the library, sourced, with the NAS and everything outside the sandbox stubbed
load() {
  [ -r "$FOOTAGE_CONF" ] || { echo "no sandbox config"; exit 99; }
  # shellcheck disable=SC1091
  . "$T/lib.sh"
  set +e
  ssh() {   # "ssh [opts] host command": run the command here; SSH_FAIL=1 = link down
    while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
    shift
    [ -z "${SSH_FAIL:-}" ] || return 255
    bash -c "$*"
  }
  rsync() {  # host:path -> path
    local a=() x; for x in "$@"; do a+=("${x#"$(remote):"}"); done
    command rsync "${a[@]}"
  }
  rm() { case " $* " in *" -rf "*) return 0 ;; esac; command rm "$@"; }
  net_guard() { return 0; }
  tailscale_check() { :; }
  uplink_conn() { :; }
  systemd-inhibit() { return 1; }
}

mkfile() { mkdir -p "$(dirname "$1")"; head -c "${2:-3000}" /dev/urandom > "$1"; }

# mk_batch NAME [MARKER...] — a finished batch holding the card as it is now
mk_batch() {
  local b="$C/stage/$1" m; mkdir -p "$b/.ingest"
  command rsync -a --exclude '.Trash-*' "$CARD/" "$b/"
  ( cd "$b" && find . -type f -not -path './.ingest/*' -print0 | sort -z | xargs -0 -r sha256sum > .ingest/manifest.sha256 )
  echo "source=$CARD" > "$b/.ingest/staged.ok"
  shift; for m in "$@"; do echo x > "$b/.ingest/$m.ok"; done
}

phase()  { sed -n 's/^phase=//p'  "$C/run/footage-ingest/state" 2>/dev/null; }
reason() { sed -n 's/^reason=//p' "$C/run/footage-ingest/state" 2>/dev/null; }

# check DESCRIPTION COMMAND... — record a failed expectation, carry on
check() {
  local d="$1"; shift
  if "$@"; then echo "    ok: $d"; else echo "    EXPECTATION FAILED: $d"; echo "$d" >> "$C/fails"; fi
}
has()  { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
is()   { [ "$1" = "$2" ]; }
isnt() { [ "$1" != "$2" ]; }

run_case() {
  local name="$1"
  case "$name" in *"$FILTER"*) ;; *) return 0 ;; esac
  ( sandbox "$name"; "t_$name"; touch "$C/finished" ) > "$T/$name.log" 2>&1
  if [ -e "$T/$name/finished" ] && [ ! -e "$T/$name/fails" ]; then
    echo "PASS  $name"; PASSED=$((PASSED+1))
  else
    echo "FAIL  $name"; FAILED=$((FAILED+1)); FAILED_NAMES+=("$name")
    sed 's/^/      | /' "$T/$name.log" | tail -40
  fi
}

# ------------------------------------------------------------------ cases ---

# 1: a card that can't be listed completely must never be called SAFE
t_format_check_unreadable_card() {
  mkfile "$CARD/DCIM/Camera01/A.mp4"
  mk_batch 2026-10-01_luna-sd checked pushed verified
  script format-check > "$C/out" 2>&1; check "readable card with everything verified: rc 0" is $? 0
  check "says SAFE" has "$C/out" "SAFE to format"
  mkfile "$CARD/DCIM/Camera02/B.mp4"; chmod 000 "$CARD/DCIM/Camera02"
  script format-check > "$C/out" 2>&1; local rc=$?
  chmod 755 "$CARD/DCIM/Camera02"
  cat "$C/out"
  check "unreadable folder: rc 1" is "$rc" 1
  check "no SAFE line" hasnt "$C/out" "SAFE to format"
  check "says why" has "$C/out" "could not read the whole card"
}

# 1: an empty card is safe, and says so without claiming files were verified
t_format_check_empty_card() {
  mkfile "$CARD/DCIM/fileinfo_list.list"
  script format-check > "$C/out" 2>&1; check "rc 0" is $? 0
  cat "$C/out"
  check "nothing to back up" has "$C/out" "nothing on it to back up"
}

# 1: stage must fail, not report "nothing new", when the card can't be listed
t_stage_unreadable_card() {
  mkfile "$CARD/DCIM/Camera01/A.mp4"
  mk_batch 2026-10-01_luna-sd checked
  mkfile "$CARD/DCIM/Camera02/B.mp4"; chmod 000 "$CARD/DCIM/Camera02"
  script stage --from "$CARD" --label luna-sd > "$C/out" 2>&1; local rc=$?
  chmod 755 "$CARD/DCIM/Camera02"
  cat "$C/out"
  check "stage fails" isnt "$rc" 0
  check "no 'nothing new'" hasnt "$C/out" "nothing new"
  check "says why" has "$C/out" "could not read the whole card"
}

# 1 + 12: camera run on such a card: no "nothing new", and an error state
t_camera_unreadable_card() {
  load
  mkfile "$CARD/DCIM/Camera01/A.mp4"
  mk_batch 2026-10-01_luna-sd checked pushed verified
  mkfile "$CARD/DCIM/Camera02/B.mp4"; chmod 000 "$CARD/DCIM/Camera02"
  ( cmd_camera ) > "$C/out" 2>&1; local rc=$?
  chmod 755 "$CARD/DCIM/Camera02"
  cat "$C/out"
  check "camera run fails" isnt "$rc" 0
  check "no 'nothing new' notification" hasnt "$C/out" "nothing new"
  check "state is error" is "$(phase)" error
  check "reason copy" is "$(reason)" copy
}

# 2: files in the card's trash — single files and whole trashed folders
t_format_check_trash() {
  mkfile "$CARD/DCIM/Camera01/A.mp4" 3000
  mkfile "$CARD/DCIM/Camera01/C.mp4" 3100
  mkfile "$CARD/DCIM/Camera01/D x.mp4" 3200
  mkfile "$CARD/DCIM/fileinfo_list.list" 100
  mk_batch 2026-10-01_luna-sd checked pushed verified
  local tr="$CARD/.Trash-1000"; mkdir -p "$tr/files/Camera01" "$tr/info"
  # a whole folder trashed: ONE .trashinfo, for the folder
  mv "$CARD/DCIM/Camera01/C.mp4" "$tr/files/Camera01/C.mp4"
  printf '[Trash Info]\nPath=DCIM/Camera01\nDeletionDate=2026-10-01T19:24:00\n' > "$tr/info/Camera01.trashinfo"
  # a single file trashed, percent-encoded name; and a trashed index file
  mv "$CARD/DCIM/Camera01/D x.mp4" "$tr/files/D x.mp4"
  printf '[Trash Info]\nPath=DCIM/Camera01/D%%20x.mp4\n' > "$tr/info/D x.mp4.trashinfo"
  mv "$CARD/DCIM/fileinfo_list.list" "$tr/files/fileinfo_list.list"
  printf '[Trash Info]\nPath=DCIM/fileinfo_list.list\n' > "$tr/info/fileinfo_list.list.trashinfo"
  echo "junk" > "$tr/directorysizes"
  script format-check > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "trashed but backed-up files: rc 0" is "$rc" 0
  check "all 3 counted as verified" has "$C/out" "all 3 footage files verified"

  # footage that was never backed up, inside the trashed folder
  mkfile "$tr/files/Camera01/B.mp4" 3300
  script format-check > "$C/out" 2>&1; rc=$?; cat "$C/out"
  check "un-backed-up file in a trashed folder: rc 1 (not 2, not 0)" is "$rc" 1
  check "no SAFE line" hasnt "$C/out" "SAFE to format"
  check "names it by its original path" has "$C/out" "DCIM/Camera01/B.mp4 (NOT backed up)"

  # a trashed file with no .trashinfo at all: can't be placed, so not safe
  command rm -f "$tr/files/Camera01/B.mp4"
  mkfile "$tr/files/orphan.mp4" 3400
  script format-check > "$C/out" 2>&1; rc=$?; cat "$C/out"
  check "trash entry without .trashinfo: rc 1" is "$rc" 1
  check "reported, not skipped" has "$C/out" "orphan.mp4 (in the card's trash"
}

# 3: camera check — index files that changed are ignored, footage is checked
t_camera_check_ignores_index_files() {
  load
  mkfile "$CARD/DCIM/Camera01/A.mp4"; mkfile "$CARD/DCIM/fileinfo_list.list" 100; mkfile "$CARD/MISC/dcf_management.db" 100
  mk_batch 2026-10-01_luna-sd                   # staged, never checked against the camera
  echo changed >> "$CARD/DCIM/fileinfo_list.list"; echo changed >> "$CARD/MISC/dcf_management.db"
  ( cmd_camera ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "run succeeds" is "$rc" 0
  check "checked.ok written" test -e "$C/stage/2026-10-01_luna-sd/.ingest/checked.ok"
  check "verified.ok written" test -e "$C/stage/2026-10-01_luna-sd/.ingest/verified.ok"
  check "state safe" is "$(phase)" safe
  check "no camera-busy flag left" test -z "$(ls "$C/run/footage-ingest" | grep camera-busy)"
}

# 3: sha256sum dying right after an index file's FAILED line is NOT a pass
t_camera_check_sha256sum_dies() {
  load
  mkfile "$CARD/DCIM/Camera01/A.mp4"; mkfile "$CARD/DCIM/fileinfo_list.list" 100
  mk_batch 2026-10-01_luna-sd
  echo changed >> "$CARD/DCIM/fileinfo_list.list"
  sha256sum() {
    if [ "$PWD" = "$CARD" ] && [[ " $* " == *" -c "* ]]; then
      echo "./DCIM/fileinfo_list.list: FAILED"; return 1      # ...and then it died
    fi
    command sha256sum "$@"
  }
  ( cmd_camera ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "run fails" isnt "$rc" 0
  check "no checked.ok" test ! -e "$C/stage/2026-10-01_luna-sd/.ingest/checked.ok"
  check "state error" is "$(phase)" error
  check "reason mismatch" is "$(reason)" mismatch
}

# 3: footage that really differs is a mismatch
t_camera_check_real_mismatch() {
  load
  mkfile "$CARD/DCIM/Camera01/A.mp4"
  mk_batch 2026-10-01_luna-sd
  local b="$C/stage/2026-10-01_luna-sd"
  # same size and mtime (so the stage sees nothing new), different bytes
  mkfile "$C/other" 3000; touch -r "$CARD/DCIM/Camera01/A.mp4" "$C/stamp"
  cat "$C/other" > "$CARD/DCIM/Camera01/A.mp4"; touch -r "$C/stamp" "$CARD/DCIM/Camera01/A.mp4"
  ( cmd_camera ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "run fails" isnt "$rc" 0
  check "no checked.ok" test ! -e "$b/.ingest/checked.ok"
  check "reason mismatch" is "$(reason)" mismatch
}

# 4: a file lying in the batch folder but absent from its manifest isn't verified
t_format_check_needs_manifest_entry() {
  mkfile "$CARD/DCIM/Camera01/A.mp4"; mkfile "$CARD/DCIM/Camera01/B.mp4"
  mk_batch 2026-10-01_luna-sd checked pushed verified
  local m="$C/stage/2026-10-01_luna-sd/.ingest/manifest.sha256"
  grep -v 'B.mp4' "$m" > "$m.new"; mv "$m.new" "$m"
  script format-check > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "rc 1" is "$rc" 1
  check "B is not backed up" has "$C/out" "DCIM/Camera01/B.mp4 (NOT backed up)"
  check "A still counts" has "$C/out" "1 verified"
}

mk_push_batch() {   # a staged batch of N small files, not from the card
  local b="$C/stage/$1" i; mkdir -p "$b/.ingest"
  for i in $(seq 1 "$2"); do mkfile "$b/DCIM/Camera01/F_$i.mp4" $(( 2000 + i )); done
  ( cd "$b" && find . -type f -not -path './.ingest/*' -print0 | sort -z | xargs -0 sha256sum > .ingest/manifest.sha256 )
  echo x > "$b/.ingest/staged.ok"
}

# 5: a normal parallel push still works
t_push_parallel_ok() {
  load
  mk_push_batch 2026-10-01_luna-sd 6
  ( cmd_push ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "rc 0" is "$rc" 0
  check "pushed.ok written" test -e "$C/stage/2026-10-01_luna-sd/.ingest/pushed.ok"
  ( cd "$C/nas/incoming/2026-10-01_luna-sd" && sha256sum --quiet -c "$C/stage/2026-10-01_luna-sd/.ingest/manifest.sha256" )
  check "NAS copy matches" is $? 0
}

# 5: a stream that dies takes its file with it — that is not a finished push
t_push_parallel_stream_dies() {
  load
  mk_push_batch 2026-10-01_luna-sd 6
  rsync() {
    local a=() x ff=""
    for x in "$@"; do a+=("${x#"$(remote):"}"); case "$x" in --files-from=*) ff="${x#--files-from=}" ;; esac; done
    if [ -n "$ff" ] && grep -q 'F_3.mp4' "$ff"; then kill -9 "$BASHPID"; fi
    command rsync "${a[@]}"
  }
  ( cmd_push ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "push fails" isnt "$rc" 0
  check "no pushed.ok" test ! -e "$C/stage/2026-10-01_luna-sd/.ingest/pushed.ok"
  check "says it stopped early" has "$C/out" "upload stopped early"
}

# 5: TERM during the upload must not leave pushed.ok behind
t_push_parallel_interrupted() {
  load
  mk_push_batch 2026-10-01_luna-sd 6
  rsync() {
    local a=() x ff=""
    for x in "$@"; do a+=("${x#"$(remote):"}"); case "$x" in --files-from=*) ff=1 ;; esac; done
    [ -z "$ff" ] || command sleep 20
    command rsync "${a[@]}"
  }
  ( cmd_push; echo "cmd_push returned $?" > "$C/returned" ) > "$C/out" 2>&1 &
  local pid=$!
  command sleep 3; kill -TERM "$pid"; wait "$pid"; local rc=$?; cat "$C/out"
  check "exit status is not 0" isnt "$rc" 0
  check "cmd_push did not carry on past the interrupt" test ! -e "$C/returned"
  check "no pushed.ok" test ! -e "$C/stage/2026-10-01_luna-sd/.ingest/pushed.ok"
  command sleep 1
  check "stream rsyncs were stopped too" test -z "$(pgrep -f "$C/tmp/footage-push" || true)"
}

# 6: a stage interrupted while hashing is finished by the next run
t_stage_resumes_after_copy() {
  mkfile "$CARD/DCIM/Camera01/A.mp4"; mkfile "$CARD/DCIM/Camera01/B.mp4"; mkfile "$CARD/DCIM/fileinfo_list.list" 100
  script stage --from "$CARD" --label luna-sd > "$C/out" 2>&1; check "first stage ok" is $? 0
  local b; b="$(echo "$C"/stage/*_luna-sd)"
  command rm -f "$b/.ingest/staged.ok" "$b/.ingest/manifest.sha256"     # = killed while hashing
  script stage --from "$CARD" --label luna-sd > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "second stage ok" is "$rc" 0
  check "staged.ok written" test -e "$b/.ingest/staged.ok"
  check "manifest has all 3 files" is "$(wc -l < "$b/.ingest/manifest.sha256" 2>/dev/null)" 3
  check "still one batch" is "$(ls "$C/stage" | wc -l)" 1
  script stage --from "$CARD" --label luna-sd > "$C/out" 2>&1
  check "third stage: nothing new" has "$C/out" "nothing new"
  check "still one batch after that" is "$(ls "$C/stage" | wc -l)" 1
}

# 7 + 8: flatten moves ALL footage, wherever it sits under DCIM/<folder>/
t_flatten_all_footage() {
  load; NAS_FLATTEN_TO="$C/nas/flat"
  mkfile "$CARD/DCIM/Camera01/A.mp4"; mkfile "$CARD/DCIM/Camera02/B.mp4"; mkfile "$CARD/DCIM/Camera01/sub/C.mp4"
  mkfile "$CARD/DCIM/Camera01/.hidden.mp4"; mkfile "$CARD/DCIM/fileinfo_list.list" 100; mkfile "$CARD/MISC/dcf_management.db" 100
  mk_batch 2026-10-01_luna-sd checked
  local b="$C/stage/2026-10-01_luna-sd"
  ( cmd_push && cmd_verify_remote ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "rc 0" is "$rc" 0
  check "flattened.ok written" test -e "$b/.ingest/flattened.ok"
  check "all four footage files are loose on the NAS" is "$(ls -A "$C/nas/flat" | LC_ALL=C sort | tr '\n' ' ')" ".hidden.mp4 A.mp4 B.mp4 C.mp4 "
  check "they are intact" cmp -s "$C/nas/flat/B.mp4" "$b/DCIM/Camera02/B.mp4"
  check "batch folder removed from the landing dir" test ! -e "$C/nas/incoming/2026-10-01_luna-sd"
}

# 8: anything that is not a camera index file blocks the removal
t_flatten_refuses_leftovers() {
  load; NAS_FLATTEN_TO="$C/nas/flat"
  mkfile "$CARD/DCIM/Camera01/A.mp4"; mkfile "$CARD/notes.txt" 50; mkfile "$CARD/DCIM/fileinfo_list.list" 100
  mk_batch 2026-10-01_luna-sd checked
  local b="$C/stage/2026-10-01_luna-sd" r="$C/nas/incoming/2026-10-01_luna-sd"
  ( cmd_push ) > "$C/out" 2>&1
  mkfile "$r/DCIM/Camera01/stray.bin" 500          # on the NAS, in no manifest
  ( cmd_verify_remote ) >> "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "verify-remote reports failure" is "$rc" 1
  check "verified (the data is fine)" test -e "$b/.ingest/verified.ok"
  check "not marked flattened" test ! -e "$b/.ingest/flattened.ok"
  check "refusal is explained" has "$C/out" "refusing to remove"
  check "footage outside DCIM/<folder>/ is still on the NAS" test -f "$r/notes.txt"
  check "unknown file is still on the NAS" test -f "$r/DCIM/Camera01/stray.bin"
  check "the clip itself was moved" test -f "$C/nas/flat/A.mp4"
}

# 8: same name in two DCIM subfolders, different contents: never overwritten
t_flatten_name_collision() {
  load; NAS_FLATTEN_TO="$C/nas/flat"
  mkfile "$CARD/DCIM/Camera01/X.mp4" 3000; mkfile "$CARD/DCIM/Camera02/X.mp4" 3001
  mkdir -p "$CARD/DCIM/Camera03"; cp -p "$CARD/DCIM/Camera01/X.mp4" "$CARD/DCIM/Camera03/X.mp4"
  mk_batch 2026-10-01_luna-sd checked
  local b="$C/stage/2026-10-01_luna-sd" r="$C/nas/incoming/2026-10-01_luna-sd"
  ( cmd_push && cmd_verify_remote ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "reports failure" isnt "$rc" 0
  check "not marked flattened" test ! -e "$b/.ingest/flattened.ok"
  check "first X.mp4 is loose, intact" cmp -s "$C/nas/flat/X.mp4" "$b/DCIM/Camera01/X.mp4"
  check "the different X.mp4 stays in the batch, intact" cmp -s "$r/DCIM/Camera02/X.mp4" "$b/DCIM/Camera02/X.mp4"
  check "the identical copy was recognised as a duplicate" test ! -e "$r/DCIM/Camera03/X.mp4"
  check "conflict is named" has "$C/out" "conflict (left in place): DCIM/Camera02/X.mp4"
}

# 7a: batch folder already gone on the NAS (link dropped after the flatten)
t_flatten_recovers_when_batch_gone() {
  load
  mkfile "$CARD/DCIM/Camera01/A.mp4"; mkfile "$CARD/DCIM/Camera02/B.mp4"; mkfile "$CARD/DCIM/fileinfo_list.list" 100
  mk_batch 2026-10-01_luna-sd checked
  local b="$C/stage/2026-10-01_luna-sd" r="$C/nas/incoming/2026-10-01_luna-sd"
  ( cmd_push && cmd_verify_remote ) > "$C/out" 2>&1
  check "verified without flatten" test -e "$b/.ingest/verified.ok"
  # what a flatten whose reply was lost leaves behind
  mv "$r/DCIM/Camera01/A.mp4" "$r/DCIM/Camera02/B.mp4" "$C/nas/flat/"; mv "$r" "$C/nas/gone"
  NAS_FLATTEN_TO="$C/nas/flat"
  cp "$C/nas/flat/B.mp4" "$C/keepB"; echo damaged > "$C/nas/flat/B.mp4"
  ( cmd_verify_remote ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "a loose file with the wrong checksum: failure" is "$rc" 1
  check "not marked flattened" test ! -e "$b/.ingest/flattened.ok"
  cp "$C/keepB" "$C/nas/flat/B.mp4"
  ( cmd_verify_remote ) > "$C/out" 2>&1; rc=$?; cat "$C/out"
  check "all loose files proven: rc 0" is "$rc" 0
  check "flattened.ok written" test -e "$b/.ingest/flattened.ok"
}

# 7b: the link dropping during verify or flatten is "unreachable", not a mismatch
t_verify_remote_unreachable() {
  load; NAS_FLATTEN_TO="$C/nas/flat"
  mkfile "$CARD/DCIM/Camera01/A.mp4"
  mk_batch 2026-10-01_luna-sd checked
  local b="$C/stage/2026-10-01_luna-sd"
  ( cmd_push ) > "$C/out" 2>&1
  ( SSH_FAIL=1; cmd_verify_remote ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "verify unreachable: rc 4" is "$rc" 4
  check "says could not reach" has "$C/out" "could not reach"
  echo x > "$b/.ingest/verified.ok"                # verified earlier; now only the flatten is left
  ( SSH_FAIL=1; cmd_verify_remote ) > "$C/out" 2>&1; rc=$?; cat "$C/out"
  check "flatten unreachable: rc 4" is "$rc" 4
  check "says could not reach" has "$C/out" "could not reach"
  check "not marked flattened" test ! -e "$b/.ingest/flattened.ok"
  ( cmd_verify_remote ) > "$C/out" 2>&1; check "link back: rc 0" is $? 0
  check "flattened.ok written" test -e "$b/.ingest/flattened.ok"
}

# 9: the NAS is checked against the laptop's manifest, and every batch is checked
t_verify_remote_uses_local_manifest() {
  load
  mkfile "$CARD/DCIM/Camera01/A.mp4"; mk_batch 2026-10-01_luna-sd checked
  mkfile "$CARD/DCIM/Camera01/B.mp4"; mk_batch 2026-10-02_luna-sd checked
  ( cmd_push ) > "$C/out" 2>&1
  # the NAS copy of batch 1 is damaged, manifest included — consistently
  local r="$C/nas/incoming/2026-10-01_luna-sd"
  echo damaged > "$r/DCIM/Camera01/A.mp4"
  ( cd "$r" && find . -type f -not -path './.ingest/*' -print0 | sort -z | xargs -0 sha256sum > .ingest/manifest.sha256 )
  ( cmd_verify_remote ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "rc 1" is "$rc" 1
  check "damaged batch NOT verified" test ! -e "$C/stage/2026-10-01_luna-sd/.ingest/verified.ok"
  check "the next batch was still checked (stdin not swallowed)" test -e "$C/stage/2026-10-02_luna-sd/.ingest/verified.ok"
}

# 10: watch — retry after a failed run, replug of the same card, stale "safe"
t_watch_retry_and_stale_safe() {
  load; WATCH_RETRY_SECS=0
  mkfile "$CARD/DCIM/Camera01/A.mp4"; mkdir -p "$C/media/USB"
  echo 0 > "$C/calls"; echo 0 > "$C/ticks"
  state safe "Safe to format" "left over from the previous card"
  cmd_camera() {
    local n; n=$(( $(cat "$C/calls") + 1 )); echo "$n" > "$C/calls"
    [ "$n" = 1 ] && { phase > "$C/phase-at-first-run"; return 1; }       # first run fails
    state safe "Safe to format" "x"; return 0
  }
  sleep() {   # the scheduler: act between the watch loop's 30 s polls
    [ "$1" = 30 ] || return 0
    local n; n=$(( $(cat "$C/ticks") + 1 )); echo "$n" > "$C/ticks"
    case "$n" in
      2) mv "$CARD" "$C/unplugged" ;;                                    # after the good run: unplug
      3) phase > "$C/phase-after-unplug"; mv "$C/unplugged" "$CARD" ;;   # same card back
      4) mv "$CARD" "$C/unplugged"; mv "$C/media/USB" "$C/usb-out" ;;    # everything out
    esac
  }
  ( cmd_watch ) > "$C/out" 2>&1; cat "$C/out"
  check "stale 'safe' replaced as soon as the camera is seen" is "$(cat "$C/phase-at-first-run")" checking
  check "failed run retried, and the replugged card run again (3 runs)" is "$(cat "$C/calls")" 3
  check "'safe' stepped down once unplugged" is "$(cat "$C/phase-after-unplug")" verified
  check "ends on 'verified', not 'safe'" is "$(phase)" verified
}

# 11: more batches of one label than rsync takes --compare-dest dirs
t_stage_with_25_batches() {
  local i b
  for i in $(seq 1 25); do
    mkfile "$CARD/DCIM/Camera01/F_$i.mp4" $(( 2000 + i ))
    b="$C/stage/2026-09-$(printf '%02d' "$i")_luna-sd"; mkdir -p "$b/DCIM/Camera01" "$b/.ingest"
    cp -p "$CARD/DCIM/Camera01/F_$i.mp4" "$b/DCIM/Camera01/"
    ( cd "$b" && sha256sum "./DCIM/Camera01/F_$i.mp4" > .ingest/manifest.sha256 )
    echo x > "$b/.ingest/staged.ok"; touch -d "2026-09-$(printf '%02d' "$i") 12:00" "$b/.ingest/staged.ok"
  done
  script stage --from "$CARD" --label luna-sd > "$C/out" 2>&1; cat "$C/out"
  check "nothing new with 25 batches" has "$C/out" "nothing new"
  check "no 26th batch" is "$(ls "$C/stage" | wc -l)" 25
  mkfile "$CARD/DCIM/Camera01/NEW.mp4"
  script stage --from "$CARD" --label luna-sd > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "stage ok" is "$rc" 0
  b="$(ls -d "$C"/stage/*_luna-sd | grep -v '2026-09-')"
  check "new batch holds exactly the one new file" is "$(cd "$b" && find . -type f -not -path './.ingest/*' | sort | tr '\n' ' ')" "./DCIM/Camera01/NEW.mp4 "
  script status > "$C/out" 2>&1; cat "$C/out"
  check "status doesn't list the .seen folder" hasnt "$C/out" ".seen"
  check "status lists 26 batches" is "$(grep -c '_luna-sd' "$C/out")" 26
  # a batch folder that is taken away makes its file new again
  mv "$C/stage/2026-09-03_luna-sd" "$C/taken-away"
  mkfile "$CARD/DCIM/Camera01/NEW2.mp4"
  script stage --from "$CARD" --label luna-sd > "$C/out" 2>&1; cat "$C/out"
  b="$(ls -d "$C"/stage/*_luna-sd | grep -v '2026-09-' | tail -1)"
  check "file of the removed batch is staged again" is "$(ls "$C"/stage/*_luna-sd/DCIM/Camera01/F_3.mp4 2>/dev/null | wc -l)" 1
  script format-check > "$C/out" 2>&1; cat "$C/out"
  check "format-check still works (and is not safe: nothing verified)" has "$C/out" "NOT safe"
}

# 12: the laptop copy failing its re-check leaves an error state, not a busy one
t_camera_state_on_verify_failure() {
  load
  mkfile "$CARD/DCIM/Camera01/A.mp4"
  cmd_verify() { return 1; }
  ( cmd_camera ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "run fails" isnt "$rc" 0
  check "state error" is "$(phase)" error
  check "reason verify-local" is "$(reason)" verify-local
  check "no checked.ok" test -z "$(ls "$C"/stage/*/.ingest/checked.ok 2>/dev/null)"
}

# 12: leaving cmd_camera unexpectedly in a busy phase says so
t_camera_state_when_stopped() {
  load
  mkfile "$CARD/DCIM/Camera01/A.mp4"
  notify() { case "$2" in *"safe to unplug"*) exit 9 ;; esac; }      # the run dies mid-way
  ( cmd_camera ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "run fails" is "$rc" 9
  check "state error" is "$(phase)" error
  check "reason stopped" is "$(reason)" stopped
  check "no camera-busy flag left" test -z "$(ls "$C/run/footage-ingest" | grep camera-busy)"
  # ...but a busy state written by ANOTHER run is left alone
  RUN_ID=other state copying "Copying from the camera" "another run"
  ( trap camera_exit EXIT; exit 0 )
  check "another run's busy state is not replaced" is "$(phase)" copying
}

# 12: TERM during the camera check
t_camera_state_on_term() {
  load
  mkfile "$CARD/DCIM/Camera01/A.mp4"
  cmd_verify() { touch "$C/in-verify"; while [ ! -e "$C/go" ]; do command sleep 0.2; done; }
  ( cmd_camera ) > "$C/out" 2>&1 &
  local pid=$! i
  for i in $(seq 1 100); do [ -e "$C/in-verify" ] && break; command sleep 0.2; done
  check "busy while checking" is "$(phase)" checking
  kill -TERM "$pid"; touch "$C/go"; wait "$pid"; local rc=$?; cat "$C/out"
  check "exit status is not 0" isnt "$rc" 0
  check "state error" is "$(phase)" error
  check "reason stopped" is "$(reason)" stopped
  check "nothing marked checked" test -z "$(ls "$C"/stage/*/.ingest/checked.ok 2>/dev/null)"
}

# the whole chain as the script runs it — top level, set -e in force — twice
t_camera_full_run_under_set_e() {
  load
  echo "NAS_FLATTEN_TO=\"$C/nas/flat\"" >> "$C/conf"
  { echo ". \"$T/lib.sh\""; declare -f ssh rsync rm net_guard tailscale_check uplink_conn systemd-inhibit; echo cmd_camera; } > "$C/main.sh"
  mkfile "$CARD/DCIM/Camera01/A.mp4"; mkfile "$CARD/DCIM/Camera01/B.mp4"; mkfile "$CARD/DCIM/fileinfo_list.list" 100
  bash "$C/main.sh" > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "first run: rc 0" is "$rc" 0
  check "state safe" is "$(phase)" safe
  check "both clips loose on the NAS" is "$(ls "$C/nas/flat" | tr '\n' ' ')" "A.mp4 B.mp4 "
  mkfile "$CARD/DCIM/Camera01/C.mp4"; echo changed >> "$CARD/DCIM/fileinfo_list.list"
  bash "$C/main.sh" > "$C/out" 2>&1; rc=$?; cat "$C/out"
  check "second run: rc 0" is "$rc" 0
  check "state safe" is "$(phase)" safe
  check "two batches, both flattened" is "$(ls "$C"/stage/*/.ingest/flattened.ok | wc -l)" 2
  check "second batch holds only the new clip" has "$C/out" "SD Card: 1 files"
  check "says all 3 verified" has "$C/out" "all 3 footage files verified"
  check "no temp files left" test -z "$(ls "$C/tmp" | grep -v footage-push)"    # (those: rm -rf is off here)
}

# 14: the uploader yields the tray to a run that is copying
t_camera_busy_flag() {
  load
  mkdir -p "$C/run/footage-ingest"
  check "no flag: not busy" eval '! camera_busy'
  : > "$C/run/footage-ingest/camera-busy.$$"
  check "flag of a live process: busy" camera_busy
  command rm -f "$C/run/footage-ingest/camera-busy.$$"
  ( exit 0 ) & local dead=$!; wait "$dead"
  : > "$C/run/footage-ingest/camera-busy.$dead"
  check "flag of a dead process: not busy" eval '! camera_busy'
  check "and it is cleaned up" test ! -e "$C/run/footage-ingest/camera-busy.$dead"
  camera_flag on
  check "own flag: not busy" eval '! camera_busy'
  camera_flag off
  state idle a b; state idle a b
  check "no shared .tmp left behind" test -z "$(ls "$C/run/footage-ingest" | grep tmp)"
}

# 15: three stages inside the same minute get three different batches
t_stage_same_minute() {
  local i
  for i in 1 2 3; do
    mkfile "$CARD/DCIM/Camera01/F_$i.mp4"
    script stage --from "$CARD" --label luna-sd > "$C/out" 2>&1; check "stage $i ok" is $? 0
  done
  cat "$C/out"
  check "three batches" is "$(ls "$C/stage" | wc -l)" 3
  check "all three finished" is "$(ls "$C"/stage/*/.ingest/staged.ok | wc -l)" 3
  check "one new file each" is "$(cat "$C"/stage/*/.ingest/manifest.sha256 | wc -l)" 3
}

# 15: a network that can't be identified is not a trusted one
t_net_guard_unknown_network() {
  load; unset -f net_guard; . "$T/lib.sh"; set +e      # the real net_guard back
  uplink_conn() { :; }; tailscale() { return 0; }; ping() { return 0; }
  NETWORK_GUARD=1; echo "Home Wi-Fi" > "$C/trusted-networks"
  ( net_guard ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "held (rc 3)" is "$rc" 3
  check "state held" is "$(phase)" held
  check "reason network-unknown" is "$(reason)" network-unknown
  uplink_conn() { printf 'GENERAL.CONNECTION:Home Wi-Fi\nGENERAL.METERED:no\n'; }
  ( net_guard ) > "$C/out" 2>&1; check "known trusted network passes" is $? 0
  NETWORK_GUARD=0; uplink_conn() { :; }
  ( net_guard ) > "$C/out" 2>&1; check "NETWORK_GUARD=0 passes" is $? 0
}

# prune: a verified batch's clips go (batch + flat link), its stubs stay and
# still count — the card is not copied again and still shows SAFE
mk_pruneable() {   # a batch pushed, verified, flattened into nas/flat and linked
  load; NAS_FLATTEN_TO="$C/nas/flat"
  mkfile "$CARD/DCIM/Camera01/A.mp4" 5000; mkfile "$CARD/DCIM/Camera01/B.mp4" 7000; mkfile "$CARD/DCIM/fileinfo_list.list" 100
  mk_batch 2026-10-01_luna-sd checked
  ( cmd_push && cmd_verify_remote && link_flat "$C/stage/2026-10-01_luna-sd" ) > "$C/setup" 2>&1
}
t_prune_frees_and_still_counts() {
  mk_pruneable; local b="$C/stage/2026-10-01_luna-sd"
  check "setup: flattened" test -e "$b/.ingest/flattened.ok"
  check "setup: flat link" test "$C/flatlocal/A.mp4" -ef "$b/DCIM/Camera01/A.mp4"
  ( cmd_prune ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "rc 0" is "$rc" 0
  check "pruned.ok" test -e "$b/.ingest/pruned.ok"
  check "manifest kept" test -s "$b/.ingest/manifest.sha256"
  check "clips gone from the batch" test ! -e "$b/DCIM/Camera01/A.mp4"
  check "flat links gone" test ! -e "$C/flatlocal/A.mp4"
  check "stub has the clip's size" is "$(stat -c %s "$b/.ingest/stubs/DCIM/Camera01/B.mp4")" 7000
  check "stub takes no space" is "$(stat -c %b "$b/.ingest/stubs/DCIM/Camera01/B.mp4")" 0
  check "stub has the clip's mtime" is "$(stat -c %Y "$b/.ingest/stubs/DCIM/Camera01/B.mp4")" "$(stat -c %Y "$CARD/DCIM/Camera01/B.mp4")"
  check ".seen points at the stub" test "$C/stage/.seen-luna-sd/DCIM/Camera01/B.mp4" -ef "$b/.ingest/stubs/DCIM/Camera01/B.mp4"
  check "NAS untouched" cmp -s "$C/nas/flat/B.mp4" "$CARD/DCIM/Camera01/B.mp4"
  script stage --from "$CARD" --label luna-sd > "$C/out" 2>&1; check "re-stage rc 0" is $? 0; cat "$C/out"
  check "re-stage copies nothing" has "$C/out" "nothing new"
  check "no new batch" is "$(ls "$C/stage" | wc -l)" 1
  script format-check > "$C/out" 2>&1; check "format-check rc 0" is $? 0; cat "$C/out"
  check "still SAFE" has "$C/out" "SAFE to format"
  script verify > "$C/out" 2>&1; check "verify rc 0" is $? 0
  check "verify skips it" has "$C/out" "pruned"
  script status > "$C/out" 2>&1; check "status says pruned" has "$C/out" "pruned"
  mkfile "$CARD/DCIM/Camera01/C.mp4"
  script stage --from "$CARD" --label luna-sd > "$C/out" 2>&1; cat "$C/out"
  check "a new clip is still staged" test -e "$(ls -d "$C"/stage/*_luna-sd | grep -v 2026-10-01)/DCIM/Camera01/C.mp4"
  check "and only that one" test ! -e "$(ls -d "$C"/stage/*_luna-sd | grep -v 2026-10-01)/DCIM/Camera01/A.mp4"
}

# prune keeps a batch the NAS doesn't fully have, one it can't reach, and an unverified one
t_prune_refuses_when_unsure() {
  mk_pruneable; local b="$C/stage/2026-10-01_luna-sd"
  mv "$C/nas/flat/B.mp4" "$C/nas/B.away"
  ( cmd_prune ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "missing on NAS: rc 1" is "$rc" 1
  check "names the file" has "$C/out" "B.mp4"
  check "batch kept" test -e "$b/DCIM/Camera01/A.mp4"
  check "flat link kept" test -e "$C/flatlocal/A.mp4"
  check "no pruned.ok" test ! -e "$b/.ingest/pruned.ok"
  mv "$C/nas/B.away" "$C/nas/flat/B.mp4"
  ( SSH_FAIL=1 cmd_prune ) > "$C/out" 2>&1; rc=$?; cat "$C/out"
  check "unreachable: rc 4" is "$rc" 4
  check "batch kept" test -e "$b/DCIM/Camera01/A.mp4"
  rm -f "$b/.ingest/verified.ok"
  ( ONLY=2026-10-01_luna-sd cmd_prune ) > "$C/out" 2>&1; rc=$?; cat "$C/out"
  check "unverified with --only: rc 1" is "$rc" 1
  check "says why" has "$C/out" "not verified"
  check "batch kept" test -e "$b/DCIM/Camera01/A.mp4"
}

# an interrupted prune (pruned.ok written, files half deleted) finishes next time
t_prune_resumes() {
  mk_pruneable; local b="$C/stage/2026-10-01_luna-sd"
  ( prune_stubs "$b" && printf 'bytes=12000\n' > "$b/.ingest/pruned.ok" && rm -f "$b/DCIM/Camera01/A.mp4" ) > "$C/out" 2>&1
  ( cmd_prune ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "rc 0" is "$rc" 0
  check "says it finished" has "$C/out" "interrupted prune"
  check "rest deleted" test ! -e "$b/DCIM/Camera01/B.mp4"
  check "stubs kept" test -e "$b/.ingest/stubs/DCIM/Camera01/A.mp4"
}

# the camera's clips are 755 (exfat fmask): a stub of another mode made rsync
# copy the all-zero stub into the next batch instead of skipping (2026-10-24)
t_prune_stub_keeps_mode() {
  chmod 755 "$CARD/DCIM/Camera01" 2>/dev/null
  mk_pruneable; local b="$C/stage/2026-10-01_luna-sd"
  chmod 755 "$CARD"/DCIM/Camera01/*.mp4 "$b"/DCIM/Camera01/*.mp4
  ( cmd_prune ) > "$C/out" 2>&1; check "prune rc 0" is $? 0; cat "$C/out"
  check "stub has the clip's mode" is "$(stat -c %a "$b/.ingest/stubs/DCIM/Camera01/A.mp4")" 755
  script stage --from "$CARD" --label luna-sd > "$C/out" 2>&1; check "re-stage rc 0" is $? 0; cat "$C/out"
  check "re-stage copies nothing" has "$C/out" "nothing new"
  check "no new batch" is "$(ls "$C/stage" | wc -l)" 1
}

# if a stub's mode still differs, the all-zero copy is caught, deleted, and
# the batch is never marked staged
t_stage_refuses_zero_clips() {
  mk_pruneable; local b="$C/stage/2026-10-01_luna-sd"
  ( cmd_prune ) > "$C/out" 2>&1; check "prune rc 0" is $? 0
  chmod 755 "$CARD"/DCIM/Camera01/*.mp4; chmod 600 "$b"/.ingest/stubs/DCIM/Camera01/*.mp4
  mkfile "$CARD/DCIM/Camera01/C.mp4"
  script stage --from "$CARD" --label luna-sd > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "stage fails" is "$rc" 1
  check "says why" has "$C/out" "nothing but zeros"
  check "names the clip" has "$C/out" "all zeros: DCIM/Camera01/A.mp4"
  local nb; nb="$(ls -d "$C"/stage/*_luna-sd | grep -v 2026-10-01)"
  check "no staged.ok" test ! -e "$nb/.ingest/staged.ok"
  check "zero copy deleted" test ! -e "$nb/DCIM/Camera01/A.mp4"
  check "real new clip kept" cmp -s "$nb/DCIM/Camera01/C.mp4" "$CARD/DCIM/Camera01/C.mp4"
  check "card untouched" test -s "$CARD/DCIM/Camera01/A.mp4"
}

# a batch from a camera that isn't an Insta360: every DCIM/<folder>/ file gets linked
t_link_any_dcim_folder() {
  load
  mkfile "$CARD/DCIM/100GOPRO/GX010001.MP4"; mkfile "$CARD/DCIM/101GOPRO/GX010002.MP4"
  mkfile "$CARD/DCIM/100MEDIA/sub/DJI_0001.MP4"; mkfile "$CARD/DCIM/fileinfo_list.list" 100
  mk_batch 2026-10-01_cam
  local b="$C/stage/2026-10-01_cam"
  ( link_flat "$b" ) > "$C/out" 2>&1; local rc=$?; cat "$C/out"
  check "rc 0" is "$rc" 0
  check "every clip linked, index file not" is "$(ls -A "$C/flatlocal" | LC_ALL=C sort | tr '\n' ' ')" "DJI_0001.MP4 GX010001.MP4 GX010002.MP4 "
  check "a hard link, not a copy" test "$C/flatlocal/DJI_0001.MP4" -ef "$b/DCIM/100MEDIA/sub/DJI_0001.MP4"
}

# -------------------------------------------------------------------- run ---
for c in format_check_unreadable_card format_check_empty_card stage_unreadable_card camera_unreadable_card \
         format_check_trash camera_check_ignores_index_files camera_check_sha256sum_dies camera_check_real_mismatch \
         format_check_needs_manifest_entry push_parallel_ok push_parallel_stream_dies push_parallel_interrupted \
         stage_resumes_after_copy flatten_all_footage flatten_refuses_leftovers flatten_name_collision \
         flatten_recovers_when_batch_gone verify_remote_unreachable verify_remote_uses_local_manifest \
         watch_retry_and_stale_safe stage_with_25_batches camera_state_on_verify_failure camera_state_when_stopped \
         camera_state_on_term camera_full_run_under_set_e camera_busy_flag stage_same_minute net_guard_unknown_network \
         prune_frees_and_still_counts prune_refuses_when_unsure prune_resumes prune_stub_keeps_mode \
         stage_refuses_zero_clips link_any_dcim_folder; do
  run_case "$c"
done
echo
echo "$PASSED passed, $FAILED failed${FAILED_NAMES:+: ${FAILED_NAMES[*]}}"
echo "sandboxes and logs left in $T (delete when done)"
[ "$FAILED" = 0 ]
