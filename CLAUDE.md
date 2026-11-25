# Context for Claude Code — camera-ingest

Run `claude` from this directory and this file loads automatically.

## What this is

A resumable, verified ingest pipeline for camera footage: microSD -> laptop
staging -> home NAS. Written in September 2026 for a six-week trip abroad,
where the link home is high-latency (~250 ms RTT) and unreliable.

Read `README.md` for usage and `ingest-footage.sh` for the implementation.

## The environment it runs in

- **Laptop:** Arch Linux, KDE Plasma (Wayland). Footage staging lands in
  `~/Videos/Luna Ultra/.batches/` (hidden), with every clip hard-linked flat
  into `~/Videos/Luna Ultra/` — that flat folder is the edit source.
- **Camera:** Insta360 Luna Ultra. 8K, dual lens. Removable microSD **plus**
  47 GB of internal storage; the camera's own screen shows only one location
  at a time, so internal storage is easy to forget. Mounts as two USB mass
  storage LUNs (`Internal`, `SD Card`). Recordings segment every 30 min and
  only rejoin in the Insta360 app/Studio, so filenames and ordering inside a
  batch are load-bearing.
- **Network on the road:** a travel router, Tailscale to the home network.
  The NAS is not a Tailscale node; it is reached through a subnet route
  advertised by the home router. Expect 5–30 Mbps upload.
- **NAS:** TrueNAS SCALE, also running Immich.

## Decisions already made — don't undo these without discussing

1. **No NFS for the transfer.** The original plan was `cp` to a mounted NFS
   share over Tailscale. Rejected: NFS is synchronous and chatty so throughput
   collapses at ~250 ms RTT; a hard mount hangs on tunnel blips; `cp` has no
   resume, and a truncated file is indistinguishable from a complete one.
   rsync over SSH instead.
2. **The script has no delete path for the card, deliberately.** Nothing is
   ever removed from the card by code. Card erasure happens in-camera, by
   hand, after `format-check` reports every clip verified on the NAS. `prune`
   deletes only LAPTOP copies of NAS-verified batches — never the card, never
   the NAS — and keeps size+mode+mtime stubs so later stages and
   `format-check` still count those clips.
3. **Verification is checksum-based, not size-based.** A sha256 manifest is
   built from the staged copy, checked against the card, and re-checked on
   the NAS over SSH. This catches bad card reads and silent truncation, which
   is the actual failure mode worth defending against.
4. **The network push is off-site insurance**, not the way the bulk gets
   home. At 10 Mbps, 100 GB is a full day.
5. **Tailscale runs on the laptop for the transfer**, not routed through the
   travel router's userspace WireGuard.

## Conventions

- Bash, `set -euo pipefail`, no external deps beyond rsync/ssh/sha256sum
  (the tray is Python + GTK3 + AyatanaAppIndicator3).
- Per-batch state lives in `<batch>/.ingest/`: `manifest.sha256` and
  `staged.ok` / `checked.ok` / `pushed.ok` / `verified.ok` / `flattened.ok` /
  `pruned.ok` marker files. Idempotency and the `status` table both derive
  from those markers.
- Paths contain spaces (`Luna Ultra`). Quote everything.
- Failures warn and keep partials rather than cleaning up — resumability beats
  tidiness here.
- Anything that fails softly (systemd-inhibit, tailscale absent) must warn and
  continue, never take the transfer down.
- **Editing rule:** the watch service may be running the script, and bash
  reads scripts lazily. Edit a copy and `mv` it over (new inode); never
  rewrite `ingest-footage.sh` in place while a run is active.

## Tests

- `bash tests/run-tests.sh` — fake card / stage / NAS under
  `/tmp/footage-tests.*`, never real data.
- `python3 -m unittest discover -s tests` — tray tests, `gi` mocked.
- `test-controller.sh` — simulates capped / noisy / drifting links for the
  parallel-stream controller.

Run both suites before installing any change.

## Lessons learned the hard way

- **sshd StrictModes** silently ignores an `authorized_keys` whose home
  directory is group-writable. TrueNAS dataset roots often are.
- **`ssh` inside `while read`** eats the loop's stdin: only the first batch
  was ever verified, with exit 0. Use `ssh -n` there.
- **Unmounting the camera is an eject.** It drops its storage and needs a
  replug, so stage straight from the auto-mount; the script only reads.
- **Camera index files** (`DCIM/*.list`, `MISC/dcf_management.db`) change on
  every recording. They are excluded from card-vs-copy checks, or every
  re-check would raise a false mismatch.
- **rsync `--compare-dest` with a mode mismatch** creates the destination by
  copying the compare file instead of reading the source. With sparse prune
  stubs that meant all-zero clips. Stubs now copy the clip's mode, and `stage`
  refuses any batch containing an all-zero footage file.
- **Tailscale stuck on DERP relay:** on an OpenWrt-based router running
  tailscaled itself, a wan->lan FORWARD rule does nothing; UDP 41641 needs an
  INPUT accept on the router.
- **rsync 3.5.1-3** added a `B` suffix to `--info=progress2` byte counts; the
  progress parser accepts both forms.
