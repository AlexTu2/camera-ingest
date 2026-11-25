#!/usr/bin/env bash
# Exercises push_parallel's auto stream controller against simulated links,
# using a local folder as the "NAS" (no network, no ssh). Each case fakes the
# interface byte counter so the measured rate depends on the stream count.
#   bash test-controller.sh
set -uo pipefail
cd "$(dirname "$0")"
S="$(mktemp -d "${TMPDIR:-/tmp}/ctl-test.XXXXXX")"
mkdir -p "$S/b/DCIM/Camera01" "$S/b/.ingest"
for i in $(seq 1 80); do head -c 64K /dev/urandom > "$S/b/DCIM/Camera01/F_$i"; done
( cd "$S/b" && find . -type f -not -path './.ingest/*' -print0 | sort -z | xargs -0 sha256sum > .ingest/manifest.sha256 )
sed -n '1,/^# -* main ---/p' ingest-footage.sh > "$S/lib.sh"

run() {   # $1 name, $2 shell snippet that sets r (bytes this probe) from n and c
  local R; R="$(mktemp -d "$S/run.XXXX")"; mkdir "$R/nas"
  cat > "$R/t.sh" <<EOF
set -euo pipefail
FOOTAGE_CONF=/dev/null; . "$S/lib.sh"; STATE_FILE="$R/state"; NOTIFY_DESKTOP=0; NAS_HOST=127.0.0.1; PUSH_PROBE_SECS=1; PUSH_REPROBE_SECS=6
tx_bytes() { local c a r; c=\$(cat "$R/c" 2>/dev/null || echo 0); c=\$((c+1)); echo \$c > "$R/c"; a=\$(cat "$R/acc" 2>/dev/null || echo 0); $2; a=\$((a + r)); echo \$a > "$R/acc"; echo \$a; }
rsync() { command rsync "\$@"; local x=\$?; sleep 0.5; return \$x; }
push_parallel "$S/b" "$R/nas/batch" >"$R/out" 2>&1; echo "rc=\$?"
EOF
  echo "=== $1"; bash "$R/t.sh"
  grep -E 'using|trying|stall' "$R/out"; echo "probes: $(grep -c 'streams=' "$R/out")"
  ( cd "$R/nas/batch" && sha256sum --quiet -c .ingest/manifest.sha256 && echo "checksums match" )
}

run "saturates at 3 (expect: settle 3, later trials of 4 retired)" \
    'k=$(( n<3 ? n : 3 )); r=$(( k*1000000 ))'
run "noisy: every 3rd probe dips to 40%, real cap 4 (expect: reaches 4)" \
    'k=$(( n<4 ? n : 4 )); r=$(( k*1000000 )); [ $((c%3)) = 0 ] && r=$(( r*4/10 )) || true'
run "drift: cap 2 for 12 probes, then cap 5 (expect: 2, then trials climb)" \
    'cap=2; [ $c -gt 12 ] && cap=5; k=$(( n<cap ? n : cap )); r=$(( k*1000000 ))'
run "stall: real cap 3, probes 6 and 7 collapse to 10% (expect: 'stall window ignored', still reaches 3)" \
    'k=$(( n<3 ? n : 3 )); r=$(( k*1000000 )); { [ $c = 6 ] || [ $c = 7 ]; } && r=$(( r*10/100 )) || true'
echo; echo "test files left in $S (delete when done)"
