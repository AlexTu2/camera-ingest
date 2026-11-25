# camera-ingest

Camera card -> laptop -> NAS, built for a bad link. Written for an Insta360
Luna Ultra on a six-week trip abroad, but it works with any camera that
mounts as a USB drive with a `DCIM/` folder (GoPro, DJI, Canon, Fujifilm,
Nikon, ...): set `SOURCES` to your card's volume name. Not supported: cameras
that keep video outside `DCIM/` (Sony's `PRIVATE/M4ROOT/`), and phones that
only connect over MTP.

Three properties matter:

1. **Nothing is ever deleted from the card.** The card stays a valid second
   copy until you erase it deliberately, in camera, at home.
2. **Every step resumes.** `--partial-dir` keeps an interrupted file, and the
   next run uses it as the basis for rsync's delta transfer, so a 40 GB file
   picks up where it stopped instead of restarting. (`--append-verify` was
   dropped: rsync refuses to combine it with `--partial-dir`.)
3. **Every copy is proved, not assumed.** A sha256 manifest is built at
   staging time and checked again on the NAS, so a silent truncation or a
   bad card read shows up as a failure rather than as corrupt footage you
   find six months later.

## Setup

```
cp footage-ingest.conf ~/.config/footage-ingest.conf   # then edit it
ssh-copy-id you@truenas                                # key auth, no passwords
```

## Hands-off mode (recommended)

Plug the camera in. That's it. A systemd user path unit
(`systemd/footage-ingest.path`, installed in `~/.config/systemd/user/`) notices
anything mounting under `/run/media/$USER` and runs `ingest-footage.sh watch`,
which runs `camera` for every camera storage in `SOURCES` (Internal and SD
Card by default) and again whenever new footage appears while it's plugged in.
You get desktop notifications at each milestone:

| Notification | Meaning |
|---|---|
| **Copied to the laptop — safe to unplug** | new footage is on the laptop and matches the camera byte for byte |
| **Backup paused: …** | Tailscale is off, the network is metered or not trusted, or the NAS won't answer — the reason is in the notification |
| **Backed up — safe to format** | every footage file on the camera is verified on the NAS (per-file check) |
| **… FAILED / do NOT format / NOT safe** | something needs a look; nothing was deleted |

Every notification is also kept under *Recent messages* in the tray menu.

Commands behind it, also fine to run by hand:

```
./ingest-footage.sh camera          # the whole chain for whatever camera storage is mounted
./ingest-footage.sh format-check    # per storage: SAFE to format, or which files aren't verified yet
./ingest-footage.sh trust-network   # allow uploads on the network you're on now (unlimited data only)
./ingest-footage.sh prune           # free laptop space: delete clips already verified on the NAS
journalctl --user -u footage-ingest -f   # watch the background run
```

The network guard runs before every push: it holds (exit 3, notification)
if Tailscale isn't running, the connection is marked metered, or it isn't in
`~/.config/footage-ingest/trusted-networks`; if the NAS doesn't answer it resets
Tailscale once (needs `sudo tailscale set --operator=$USER`). Changes that are
only the camera rewriting its index files no longer make a batch. Phone alerts:
set `NOTIFY_NTFY` to an ntfy topic URL.

**Tray icon.** `footage-tray.py` (GTK + Ayatana AppIndicator; installed as the
`footage-tray` user service, starts with the desktop) shows the state the
script writes to `$XDG_RUNTIME_DIR/footage-ingest/state`: grey idle, blue busy
(ring = upload progress), **orange needs you**, green safe to format, red
failed. The menu is short: two status lines, and — only when the backup is
stuck — the one button that unsticks it (*Allow uploads on "…"*, *Connect to
home*, *Resume backup* or *Try again*); then the camera line (can it be
unplugged, based on the script's phase *and* whether any rsync/sha256sum has
files open on it, with *Eject camera* when it can), the home connection
(Tailscale), *Back up now*, *Can I format the card?* and *Open footage
folder*. *More* holds *Backup history*, *Show live log*, *Test home
connection*, the colour key and *What each option does* (the explanations,
since Plasma tray menus have no tooltips). Upload progress is in bytes, refreshed
every `PUSH_TICK_SECS` (3 s), straight from rsync's own counters.

To turn hands-off mode off: `systemctl --user disable --now footage-ingest.path`.

## Daily use on the road

```
./ingest-footage.sh detect                # confirm the card mounted
./ingest-footage.sh stage                 # card -> ~/Videos/Luna Ultra (flat), batches in .batches/
tmux new -As push './ingest-footage.sh push'   # let it grind; detach with C-b d
./ingest-footage.sh status                # check on it later
```

Or the whole pipeline in one shot: `./ingest-footage.sh run`

**Flat NAS layout.** With `NAS_FLATTEN_TO` set in the config, `verify-remote`
moves each batch's clips loose into that folder once the batch verifies, then
removes the leftover batch folder (camera index files and the manifest). A
clip whose name already exists there is dropped only if its sha256 matches;
any other clash is a conflict, left in place and reported, and the batch
stays unflattened until you resolve it and re-run `verify-remote`. `status`
shows this in the FLAT column. The laptop copy keeps its batch folders.

**Parallel push.** A batch's files are spread over several rsync streams,
each on its own ssh connection, because one TCP stream rarely fills a
high-latency link. `PUSH_STREAMS=auto` (default) starts with one stream,
measures the real upload rate every `PUSH_PROBE_SECS`, and adds streams
while each adds at least `PUSH_GAIN_PCT` (15%) — up to `PUSH_MAX_STREAMS`
(8). Each step is judged on the mean of two measurement windows, so one dip
on a jittery link can't decide it, and every `PUSH_REPROBE_SECS` (10 min)
it re-tests one more stream, because relayed and hotel links drift. A stream
that added nothing is retired. `--streams N` fixes the count;
`--streams 1`, `--dry-run` or a non-zero `--bwlimit` use the old single
stream. Each push logs its settled count to
`~/.cache/footage-ingest-streams.log`.

**Flat laptop view.** With `LOCAL_FLAT_DIR` set, `stage` hard-links each new
batch's clips loose into that folder (`link` does it for existing batches).
Same btrfs volume, so it costs no space; edit from there. The batch folders
under `ingest/` stay: they are how `stage` knows what it already has and
what `verify` checks. Deleting a clip from the flat folder alone frees
nothing — the batch copy still holds it.

Use the same `--label` every day for the same card. Nothing is erased from the
card, so it accumulates; each new `stage` holds only files that earlier
finished batches of that label don't already have unchanged (same path, size
and mtime), so a day's batch is a day's footage, not the whole card again.
Long stages and pushes go in tmux (installed 2026-09-30), so a closed
terminal doesn't kill them. mosh is installed too, for interactive shells over
the flaky link — but rsync can't ride on mosh (it needs a plain ssh
transport), and the NAS has no `mosh-server` (TrueNAS SCALE blocks apt), so
mosh helps for shells *into* the laptop, not for the transfer or the NAS.

## Notes for the Luna Ultra

- Pull the microSD and use a card reader. Faster than the camera's USB
  bridge and it doesn't drain the battery.
- The camera **also** has 47 GB of internal storage, and its own screen only
  shows one location at a time. When you empty internal storage, plug the
  camera in (it mounts as removable storage) and run
  `./ingest-footage.sh stage --from /run/media/$USER/<mount> --label luna-internal`.
- Recordings segment every 30 minutes. Those segments are separate files on
  disk and only stitch back together in the Insta360 app or Studio, so don't
  rename or reorder anything inside a batch.

## When the push is slow

`push` warns you if Tailscale is relaying through a DERP node instead of
holding a direct path — that, not your bandwidth, is usually the problem on
hotel and mobile networks. `tailscale netcheck` tells you whether UDP 41641
is getting through. Run Tailscale on the laptop for the transfer rather than
pushing the bulk copy through the Slate 7's userspace WireGuard.

Expect 5-30 Mbps upload from abroad, and a flaky international leg. At
10 Mbps that is ~4.5 GB/hour, so 100 GB is a full day of uninterrupted
transfer. Treat the NAS push as off-site insurance and carry the bulk home
on an external SSD.

## Freeing laptop space

```
./ingest-footage.sh prune --dry-run          # what would go, and is it all on the NAS?
./ingest-footage.sh prune                    # every batch verified on the NAS
./ingest-footage.sh prune --only 2026-10-19_luna-sd
```

`prune` deletes a batch's clips from the laptop: the batch folder and its
links in `LOCAL_FLAT_DIR`. It only takes batches that are verified (and
flattened, if `NAS_FLATTEN_TO` is set), and first asks the NAS, right then,
for every footage file at the right size; anything missing or an unreachable
NAS keeps the batch. It never touches the card or the NAS.

What stays is the batch's `.ingest/` folder: the manifest, the markers, and
`stubs/` — an empty sparse file per clip with the clip's size and mtime. The
stubs stand in for the clips, so a pruned batch still counts as copied (a
card that still holds those clips is not copied again) and as backed up
(`format-check` still says SAFE). `status` shows `LOCAL=pruned`. Don't delete
batch folders by hand: without the stubs those clips look new again.

After a prune the NAS is the only copy unless the card still has the clips.

## Immich library and tags

`immich-tag.sh` scans the camera's external library and maintains the
`<root>/Video`, `<root>/Photo`, and `<root>/Edited` tags, where `<root>` is
`IMMICH_TAG_ROOT` (default `Camera`; set e.g. `"Luna Ultra"`). The
backup's NAS verification and Immich's indexing are separate steps.

The `immich-sidecars.py` helper creates missing `filename.ext.xmp` files
beside indexed NAS media. These contain those tags plus other tags
already attached in Immich, so metadata extraction can restore them even
with Immich's library mounted read-only. Media and existing XMP files are
never rewritten. Existing sidecars remain authoritative; their tags must
be edited separately if needed. New sidecars trigger Immich's sidecar
discovery job. Metadata processing can continue in the background.

The helper uses `NAS_USER`, `NAS_HOST`, and `NAS_FLATTEN_TO` from the same
configuration as the backup, plus passwordless SSH and Python 3.9+ on the
NAS. Immich's mount defaults to `/mnt/luna` (`IMMICH_NAS_PREFIX` overrides
it). Set `IMMICH_URL` and `IMMICH_LIBRARY_ID` in the config (see
`footage-ingest.conf`). The API key is read from `IMMICH_KEY_FILE`
(default `~/.config/immich-api-key`), never stored in a sidecar.

Install the hourly user timer with:

```sh
install -m 644 systemd/immich-tag.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now immich-tag.timer
systemctl --user start immich-tag.service
```

The timer runs while the laptop's user session is active and needs access
to the NAS. Check progress with `journalctl --user -u immich-tag.service`.

## Erasing a card

Only when `status` shows `VERIFIED=yes` for that batch **and** you have a
third copy. Do it in the camera, not with `rm` — the script deliberately has
no delete path.
