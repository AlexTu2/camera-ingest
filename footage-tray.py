#!/usr/bin/env python3
"""Tray icon for footage-ingest (GTK3 + Ayatana AppIndicator, which registers
natively with KDE Plasma's tray via StatusNotifierItem).

Reads the state file that ingest-footage.sh writes at every step
($XDG_RUNTIME_DIR/footage-ingest/state, key=value lines) and shows it as a
coloured icon; the menu shows the details and offers actions. It only reads
state and launches the script; it never touches footage itself.

The state file can be stale (camera unplugged since, run killed, laptop
restarted), so what is shown goes through display_state() first. An upload the
script held is started again by itself once the cause is gone (should_resume);
the script's own network guard still decides whether it may run.

  grey     idle / nothing happening
  blue     copying, checking, uploading, verifying (ring = upload progress)
  orange   needs you: upload held (new network, Tailscale off, NAS unreachable)
  green    safe to format / all uploads verified
  red      something failed — do not format
"""
import json
import math
import os
import re
import shutil
import subprocess
import sys
import textwrap
import threading
import time
import traceback
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3 as AppIndicator  # noqa: E402
from gi.repository import GLib, Gtk  # noqa: E402

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "ingest-footage.sh"
STATE = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "footage-ingest" / "state"
ICONS = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "footage-ingest" / "icons"
# every notification, from the script and from here; same path as the script's MESSAGES_FILE
MESSAGES = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "footage-ingest" / "messages.log"
MESSAGES_KEEP = 300        # lines kept in that file
FOOTAGE_DIR = Path.home() / "Videos" / "Luna Ultra"

CONF = Path(os.environ.get("FOOTAGE_CONF", Path.home() / ".config" / "footage-ingest.conf"))
TRUSTED = Path.home() / ".config" / "footage-ingest" / "trusted-networks"   # the script's TRUSTED_NETWORKS_FILE default

MEDIA_ROOT = Path("/run/media") / os.environ.get("USER", "")
CAMERA_MOUNTS = ["Internal", "SD Card"]      # must match SOURCES in ingest-footage.sh
READERS = {"rsync", "sha256sum"}             # what the script uses to read the camera

SCRIPT_PHASES = {"idle", "copying", "checking", "uploading", "verifying", "held", "safe", "verified",
                 "notsafe", "error"}       # what ingest-footage.sh writes
BUSY = {"copying", "checking", "uploading", "verifying"}
# "stopped" and "pending" are never in the state file: the tray derives them (display_state)
ATTENTION = {"held", "error", "notsafe", "stopped", "pending"}
STALE_SECS = 90            # a busy phase this old with no lock held = the run died
LAUNCH_GRACE = 10          # after starting the script, count it as running until it has its lock
RESUME_COOLDOWN = 600      # don't auto-resume the same (reason, network) again within this...
RESUME_PER_HOUR = 4        # ...and never more often than this, whatever the reason
NAS_RETRY_SECS = 120       # "NAS unreachable": leave it alone this long before trying again
PENDING_DELAY = 20         # after the tray starts, let the network come up before looking for leftovers
PENDING_RECHECK = 600      # while batches are waiting and nothing is happening, look again this often
LOOK = {  # phase -> (colour, glyph)
    "idle": ("#7f8c8d", "•"),
    "copying": ("#2e86de", "↓"),
    "checking": ("#2e86de", "…"),
    "uploading": ("#2e86de", "↑"),
    "verifying": ("#2e86de", "✓"),
    "held": ("#f39c12", "!"),
    "stopped": ("#f39c12", "!"),
    "pending": ("#f39c12", "↑"),
    "safe": ("#27ae60", "✓"),
    "verified": ("#27ae60", "✓"),
    "notsafe": ("#e74c3c", "!"),
    "error": ("#e74c3c", "×"),
}


def parse_state(text):
    """The script's key=value state lines -> dict. Only the first '=' splits, so
    titles and details may contain '=' themselves."""
    st = {"phase": "idle", "title": "Footage ingest: idle", "detail": "Plug in the camera to start."}
    for line in text.splitlines():
        k, sep, v = line.partition("=")
        if sep and k:
            st[k] = v
    if st.get("phase") not in SCRIPT_PHASES:
        st["phase"] = "idle"
    return st


def read_state():
    try:
        return parse_state(STATE.read_text())
    except (OSError, ValueError):
        return parse_state("")


_logged = {}


def log_exc(where, every=60):
    """Traceback of the exception being handled -> stderr (the journal), at
    most once per `every` seconds for the same place and error."""
    text = traceback.format_exc()
    key = (where, text)
    now = time.monotonic()
    if key in _logged and now - _logged[key] < every:
        return
    if len(_logged) > 50:
        _logged.clear()
    _logged[key] = now
    print(f"footage-tray: error in {where}:\n{text}", file=sys.stderr, flush=True)


def spawn(cmd, **kw):
    """Start a detached helper (notify-send, xdg-open, systemd-run, a terminal)
    and reap it when it exits, so it never lingers as a zombie."""
    kw.setdefault("stdin", subprocess.DEVNULL)
    try:
        p = subprocess.Popen(cmd, **kw)
    except OSError:
        log_exc(f"spawn {cmd[0]}")
        return None
    threading.Thread(target=p.wait, daemon=True).start()
    return p


def icon_path(phase, progress):
    """Generate (once) and return an SVG icon for this phase / progress bucket."""
    colour, glyph = LOOK[phase]
    bucket = ""
    if phase in BUSY and progress:
        try:
            bucket = str(max(0, min(100, int(progress))) // 10 * 10)
        except ValueError:
            bucket = ""
    ICONS.mkdir(parents=True, exist_ok=True)
    path = ICONS / f"footage-{phase}{('-' + bucket) if bucket else ''}.svg"
    if not path.exists():
        ring = ""
        if bucket:
            frac = int(bucket) / 100
            if frac >= 1:
                ring = '<circle cx="32" cy="32" r="22" fill="none" stroke="white" stroke-width="6"/>'
            elif frac > 0:
                a = 2 * math.pi * frac
                x, y = 32 + 22 * math.sin(a), 32 - 22 * math.cos(a)
                large = 1 if frac > 0.5 else 0
                ring = (f'<path d="M32 10 A22 22 0 {large} 1 {x:.2f} {y:.2f}" fill="none" '
                        f'stroke="white" stroke-width="6" stroke-linecap="round"/>')
        size = 26 if bucket else 34
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">'
               f'<circle cx="32" cy="32" r="29" fill="{colour}"/>{ring}'
               f'<text x="32" y="33" font-family="sans-serif" font-weight="bold" font-size="{size}" '
               f'fill="white" text-anchor="middle" dominant-baseline="central">{glyph}</text></svg>')
        path.write_text(svg)
    return str(path)


def lock_files():
    uid = os.getuid()
    return [Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / f"footage-camera.{uid}.lock",
            Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / f"footage-upload.{uid}.lock",
            Path(os.environ.get("TMPDIR") or "/tmp") / f"footage-push.{uid}.lock"]


def kernel_dev(st_dev):
    """A stat() device number the way /proc/locks prints it: hex maj:min."""
    return f"{os.major(st_dev):02x}:{os.minor(st_dev):02x}"


def parse_mountinfo(text):
    """/proc/self/mountinfo -> [(mountpoint, 'maj:min' in decimal as printed, source)]."""
    out = []
    unesc = lambda v: re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), v)
    for line in text.splitlines():
        left, sep, right = line.partition(" - ")
        f, r = left.split(), right.split()
        if sep and len(f) >= 5 and len(r) >= 2:
            out.append((unesc(f[4]), f[2], unesc(r[1])))
    return out


def lock_ids(paths, mountinfo=""):
    """{(device, inode)} naming these lock files as /proc/locks would. The
    device there is the filesystem's own; stat() reports the same one except on
    btrfs subvolumes, so the device of the mount holding the file counts too."""
    mounts = parse_mountinfo(mountinfo)
    ids = set()
    for lock in paths:
        try:
            s = os.stat(lock)
        except OSError:
            continue
        ids.add((kernel_dev(s.st_dev), s.st_ino))
        best = ("", None)
        for mp, dev, _ in mounts:
            if (str(lock) == mp or str(lock).startswith(mp.rstrip("/") + "/")) and len(mp) >= len(best[0]):
                best = (mp, dev)
        try:
            major, minor = best[1].split(":")
            ids.add((f"{int(major):02x}:{int(minor):02x}", s.st_ino))
        except (AttributeError, ValueError):
            pass
    return ids


def lock_held(table, ids):
    """True if /proc/locks text shows a flock held on any (device, inode) in ids."""
    for line in table.splitlines():
        # "1: FLOCK  ADVISORY  WRITE 12345 00:1a:6789 0 EOF" — field 6 is maj:min:inode,
        # both device numbers in hex. "1: -> FLOCK ..." is somebody waiting, not holding.
        parts = line.split()
        if len(parts) > 5 and parts[1] == "FLOCK":
            dev, _, ino = parts[5].rpartition(":")
            try:
                major, minor = dev.split(":")
                if (f"{int(major, 16):02x}:{int(minor, 16):02x}", int(ino)) in ids:
                    return True
            except ValueError:
                pass
    return False


def run_in_progress():
    """True if the script holds its camera, upload or push lock right now — whoever
    started it (this menu, the background service, or a terminal)."""
    # Read the kernel's lock table instead of trying the lock ourselves: taking
    # it, even for a moment, could make a run starting at that instant refuse.
    try:
        mountinfo = Path("/proc/self/mountinfo").read_text()
    except OSError:
        mountinfo = ""
    ids = lock_ids(lock_files(), mountinfo)
    if not ids:
        return False
    try:
        return lock_held(Path("/proc/locks").read_text(), ids)
    except OSError:
        return False


def camera_mounts(mountinfo=None):
    """[(name, mountpoint, device)] for the camera storages that are mounted now."""
    # read from /proc, not findmnt: this runs on the GTK thread every 2 seconds
    if mountinfo is None:
        try:
            mountinfo = Path("/proc/self/mountinfo").read_text()
        except OSError:
            return []
    out = []
    for target, _, source in parse_mountinfo(mountinfo):
        p = Path(target)
        if p.parent == MEDIA_ROOT and p.name in CAMERA_MOUNTS and (p.name, target, source) not in out:
            out.append((p.name, target, source))
    return out


def media_root_mtime():
    """When something last appeared under (or left) the desktop's mount folder."""
    try:
        return os.stat(MEDIA_ROOT).st_mtime
    except OSError:
        return 0


def camera_being_read(mountpoints):
    """True if an rsync / sha256sum process has a file (or its cwd) on the camera."""
    if not mountpoints:
        return False
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            if Path(f"/proc/{pid}/comm").read_text().strip() not in READERS:
                continue
            paths = [os.readlink(f"/proc/{pid}/cwd")]
            fd_dir = f"/proc/{pid}/fd"
            paths += [os.readlink(f"{fd_dir}/{fd}") for fd in os.listdir(fd_dir)]
        except OSError:
            continue
        if any(x == mp or x.startswith(mp + "/") for x in paths for mp in mountpoints):
            return True
    return False


def ago(ts):
    secs = time.time() - ts
    if secs < 60:
        return "just now"
    if secs < 3600:
        return f"{int(secs // 60)} min ago"
    return f"{int(secs // 3600)} h {int(secs % 3600 // 60)} min ago"


def conf_value(key, default=""):
    """Last KEY=value in the script's config file (plain values only)."""
    val = default
    try:
        for line in CONF.read_text().splitlines():
            m = re.match(rf"\s*{key}=[\"']?([^\"'#]*)", line)
            if m:
                val = m.group(1).strip()
    except OSError:
        pass
    return val


def tailscale_status():
    """(kind, menu line, explanation). kind: missing / off / down / nonas / relay / direct.
    Slow (pings the NAS), so only ever called off the GTK thread."""
    if not shutil.which("tailscale"):
        return ("missing", "🏠  Home connection: Tailscale isn't installed", "")
    try:
        r = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=8)
        backend = json.loads(r.stdout).get("BackendState", "?") if r.returncode == 0 else None
    except (subprocess.TimeoutExpired, ValueError):
        backend = None
    if backend is None:
        return ("off", "🏠  Home connection: off — uploads can't reach the NAS",
                "The Tailscale service isn't running on this laptop.")
    if backend != "Running":
        return ("down", "🏠  Home connection: off — Tailscale is disconnected",
                f"The Tailscale service is running but not connected to your network ({backend}).")
    host = conf_value("NAS_HOST", "truenas")
    try:
        r = subprocess.run(["tailscale", "ping", "-c", "1", "--timeout", "4s", host],
                           capture_output=True, text=True, timeout=10)
        out = r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        out = ""
    m = re.search(r"pong from (\S+) .*? via (\S+) in (\d+)\s*ms", out)
    if not m:
        return ("nonas", "🏠  Home connection: home isn't answering",
                f"Connected to Tailscale, but no reply from {host}. Home internet or the router may be down.")
    node, via, ms = m.groups()
    if "DERP" in via:
        return ("relay", "🏠  Home connection: connected, but slow (relayed)",
                f"Reaching {node} through a relay server, not directly ({ms} ms).")
    return ("direct", "🏠  Home connection: connected",
            f"Straight connection to {node} ({ms} ms); full upload speed.")


def launch(*args):
    """Run the script detached via systemd-run so it logs to the journal and
    outlives the tray."""
    cmd = [str(SCRIPT), *args]
    if shutil.which("systemd-run"):
        spawn(["systemd-run", "--user", "--collect", f"--unit=footage-ingest-manual-{int(time.time())}",
               "--property=Nice=5", *cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        spawn(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def run_capture(*args, timeout=300):
    try:
        r = subprocess.run([str(SCRIPT), *args], capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
        return r.returncode, re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    except OSError as e:
        return 127, f"couldn't run {SCRIPT.name}: {e}"


def log_message(title, body, urgent=False, now=None):
    """Keep a notification for "Recent messages" (the script appends its own)."""
    flat = lambda t: t.replace("\t", " ")
    try:
        MESSAGES.parent.mkdir(parents=True, exist_ok=True)
        with MESSAGES.open("a") as f:
            f.write(f"{int(now or time.time())}\t{'critical' if urgent else 'normal'}\t"
                    f"{flat(title).replace(chr(10), ' ')}\t{flat(body).replace(chr(10), '\\n')}\n")
        lines = MESSAGES.read_text().splitlines(keepends=True)
        if len(lines) > 2 * MESSAGES_KEEP:               # trim now and then, not on every message
            tmp = MESSAGES.with_name(f"{MESSAGES.name}.tmp.{os.getpid()}")
            tmp.write_text("".join(lines[-MESSAGES_KEEP:]))
            tmp.replace(MESSAGES)
    except OSError:
        pass


def read_messages():
    """[(time, urgent, title, body)], oldest first; lines that don't parse are skipped."""
    out = []
    try:
        lines = MESSAGES.read_text(errors="replace").splitlines()
    except OSError:
        return out
    for line in lines:
        parts = line.split("\t", 3)
        if len(parts) == 4 and parts[0].isdigit():
            out.append((int(parts[0]), parts[1] == "critical", parts[2], parts[3].replace("\\n", "\n")))
    return out


def format_messages(msgs, now=None):
    """The message list as text, newest first, grouped by day."""
    if not msgs:
        return "No messages yet.\n\nEvery notification from the backup is kept here, newest first."
    today = time.localtime(now or time.time())
    out, day = [], None
    for ts, urgent, title, body in reversed(msgs):
        lt = time.localtime(ts)
        if (lt.tm_year, lt.tm_yday) != day:
            day = (lt.tm_year, lt.tm_yday)
            name = "Today" if day == (today.tm_year, today.tm_yday) else time.strftime("%A %-d %B", lt)
            out.append(("" if not out else "\n") + name)
        out.append(f"  {time.strftime('%H:%M', lt)}  {'⚠ ' if urgent else ''}{title}")
        out.extend(f"         {row}" for part in body.split("\n") if part.strip()
                   for row in textwrap.wrap(part.strip(), 84))
    return "\n".join(out) + "\n"


def notify(title, body, urgent=False):
    """Plasma always shows notifications; windows opened by a tray app may not
    be raised (KWin focus-stealing prevention), so results go here first."""
    log_message(title, body, urgent)
    if shutil.which("notify-send"):
        spawn(["notify-send", "-a", "footage-ingest", "-u", "critical" if urgent else "normal", title, body])


def dialog(kind, title, text, mono=False):
    """Non-modal details window; asks to be raised but results never rely on it."""
    d = Gtk.MessageDialog(message_type=kind, buttons=Gtk.ButtonsType.OK, text=title)
    if mono:
        d.format_secondary_markup("<tt>" + GLib.markup_escape_text(text) + "</tt>")
    else:
        d.format_secondary_text(text)
    d.set_keep_above(True)
    d.set_urgency_hint(True)
    d.connect("response", lambda w, *_: w.destroy())
    d.show_all()
    d.present_with_time(Gtk.get_current_event_time() or GLib.get_monotonic_time() // 1000)


def text_window(title, text, refresh=None):
    """Resizable, scrollable read-only text window (monospace) for tables and
    file lists that don't fit a message box. refresh() -> new text, optional."""
    win = Gtk.Window(title=title)
    win.set_default_size(820, 520)
    win.set_keep_above(True)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin=8)
    sw = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
    sw.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
    tv = Gtk.TextView(editable=False, cursor_visible=False, monospace=True,
                      left_margin=6, right_margin=6, top_margin=6, bottom_margin=6)
    tv.get_buffer().set_text(text)
    sw.add(tv)
    box.pack_start(sw, True, True, 0)
    buttons = Gtk.Box(spacing=6, halign=Gtk.Align.END)
    if refresh:
        rb = Gtk.Button(label="Refresh")

        def do_refresh(*_):
            rb.set_sensitive(False)
            in_background(refresh, lambda new: (tv.get_buffer().set_text(new), rb.set_sensitive(True)),
                          error=lambda e: f"Couldn't refresh: {type(e).__name__}: {e}")
        rb.connect("clicked", do_refresh)
        buttons.pack_start(rb, False, False, 0)
    cb = Gtk.Button(label="Close")
    cb.connect("clicked", lambda *_: win.destroy())
    buttons.pack_start(cb, False, False, 0)
    box.pack_start(buttons, False, False, 0)
    win.add(box)
    win.show_all()
    win.present_with_time(Gtk.get_current_event_time() or GLib.get_monotonic_time() // 1000)
    return win


def help_window(title, sections):
    """Read-only help: a bold heading per section, its intro, then its options.
    Laid out with wrapping labels, not spaces, so it lines up in any font."""
    win = Gtk.Window(title=title)
    win.set_default_size(640, 600)
    win.set_keep_above(True)
    body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin=16)
    names = Gtk.SizeGroup(mode=Gtk.SizeGroupMode.HORIZONTAL)   # one name column width across sections
    for heading, intro, options in sections:
        h = Gtk.Label(xalign=0, margin_top=10)
        h.set_markup(f"<b>{GLib.markup_escape_text(heading)}</b>")
        body.pack_start(h, False, False, 0)
        if intro:
            body.pack_start(Gtk.Label(label=intro, xalign=0, wrap=True, max_width_chars=70),
                            False, False, 0)
        if options:
            grid = Gtk.Grid(column_spacing=16, row_spacing=6, margin_start=12)
            for row, (name, what) in enumerate(options):
                n = Gtk.Label(xalign=0, yalign=0)
                n.set_markup(f"<b>{GLib.markup_escape_text(name)}</b>")
                names.add_widget(n)
                grid.attach(n, 0, row, 1, 1)
                grid.attach(Gtk.Label(label=what, xalign=0, yalign=0, wrap=True, hexpand=True,
                                      max_width_chars=50), 1, row, 1, 1)
            body.pack_start(grid, False, False, 0)
    sw = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
    sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
    sw.add(body)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin=8)
    box.pack_start(sw, True, True, 0)
    cb = Gtk.Button(label="Close", halign=Gtk.Align.END)
    cb.connect("clicked", lambda *_: win.destroy())
    box.pack_start(cb, False, False, 0)
    win.add(box)
    win.show_all()
    win.present_with_time(Gtk.get_current_event_time() or GLib.get_monotonic_time() // 1000)
    return win


def parse_status(out):
    """ingest-footage.sh status -> (info lines, header, rows)."""
    info, header, rows = [], [], []
    for line in out.splitlines():
        if line.startswith("BATCH"):
            header = line.split()
        elif header and line.strip():
            parts = line.split()
            if len(parts) == len(header):
                rows.append(parts)
        elif line.strip():
            info.append(line.strip())
    return info, header, rows


def size_bytes(sz):
    m = re.match(r"([\d.]+)([KMGT]?)", sz or "")
    if not m:
        return 0
    return float(m.group(1)) * {"": 1, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12}[m.group(2)]


def batches_window():
    """The batch table as a real Gtk table: columns line up in any font,
    newest first, click a header to sort, totals at the bottom."""
    win = Gtk.Window(title="Backup history")
    win.set_default_size(760, 560)
    win.set_keep_above(True)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin=8)
    summary = Gtk.Label(xalign=0, selectable=True)
    box.pack_start(summary, False, False, 0)

    # batch, size (text), files, staged, pushed, verified, flat, size (bytes, for sorting), files (int)
    store = Gtk.ListStore(str, str, str, str, str, str, str, float, int)
    tv = Gtk.TreeView(model=store)
    tv.set_grid_lines(Gtk.TreeViewGridLines.HORIZONTAL)
    cols = [("Batch", 0, 0, 0.0), ("Size", 1, 7, 1.0), ("Files", 2, 8, 1.0),
            ("Copied", 3, 3, 0.5), ("Uploaded", 4, 4, 0.5), ("Verified", 5, 5, 0.5), ("Flat", 6, 6, 0.5)]
    for title, idx, sort_idx, align in cols:
        r = Gtk.CellRendererText(xalign=align)
        c = Gtk.TreeViewColumn(title, r, text=idx)
        c.set_sort_column_id(sort_idx)
        c.set_alignment(align)
        c.set_resizable(True)
        if idx == 0:
            c.set_expand(True)
        tv.append_column(c)
    sw = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
    sw.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
    sw.add(tv)
    box.pack_start(sw, True, True, 0)
    totals = Gtk.Label(xalign=0)
    box.pack_start(totals, False, False, 0)

    def fill(out):
        info, header, rows = parse_status(out)
        store.clear()
        mark = lambda v: "✓" if v == "yes" else "✗"
        tot_b = tot_f = all_ok = 0
        for r in sorted(rows, key=lambda r: r[0], reverse=True):     # newest first
            batch, size, files, staged, pushed, verified, flat = (r + [""] * 7)[:7]
            nfiles = int(files) if files.isdigit() else 0
            store.append([batch, size, files, mark(staged), mark(pushed), mark(verified), mark(flat),
                          size_bytes(size), nfiles])
            tot_b += size_bytes(size)
            tot_f += nfiles
            all_ok += verified == "yes"
        summary.set_text("\n".join(l for l in info if l.startswith(("nas:", "staging:"))))
        totals.set_markup(f"<b>{len(rows)} batches · {tot_f} files · {tot_b / 1e9:.0f} GB</b> — "
                          f"{all_ok} of {len(rows)} verified on the NAS")

    fetch = lambda: run_capture("status", timeout=60)[1]
    buttons = Gtk.Box(spacing=6, halign=Gtk.Align.END)
    rb = Gtk.Button(label="Refresh")

    def do_refresh(*_):
        rb.set_sensitive(False)
        in_background(fetch, lambda out: (fill(out), rb.set_sensitive(True)), error=lambda e: "")
    rb.connect("clicked", do_refresh)
    summary.set_text("Loading…")
    do_refresh()                  # the script measures every batch: never on the GTK thread
    cb = Gtk.Button(label="Close")
    cb.connect("clicked", lambda *_: win.destroy())
    buttons.pack_start(rb, False, False, 0)
    buttons.pack_start(cb, False, False, 0)
    box.pack_start(buttons, False, False, 0)
    win.add(box)
    win.show_all()
    win.present_with_time(Gtk.get_current_event_time() or GLib.get_monotonic_time() // 1000)
    return win


def in_background(fn, done, error=None):
    """Run fn() off the GTK thread, then done(result) back on it. done always
    runs: if fn raises, the traceback is logged and done gets error(exception)
    (None without an error handler), so no "busy" flag is ever left set."""
    def work():
        try:
            res = fn()
        except Exception as e:
            log_exc(f"background {getattr(fn, '__name__', 'job')}")
            try:
                res = error(e) if error else None
            except Exception:
                log_exc("background error handler")
                res = None

        def finish():
            try:
                done(res)
            except Exception:
                log_exc(f"result of {getattr(fn, '__name__', 'job')}")
            return False
        GLib.idle_add(finish)
    threading.Thread(target=work, daemon=True).start()


MENU_WIDTH = 44            # Plasma cuts long menu rows off, so text is wrapped onto extra rows
INDENT = "      "


def wrap_rows(text, first=""):
    """text as menu rows no wider than MENU_WIDTH; continuation rows are indented."""
    if not text:
        return []
    return textwrap.wrap(text, MENU_WIDTH, initial_indent=first, subsequent_indent=INDENT,
                         break_long_words=False, break_on_hyphens=False)


def updated_at(st):
    try:
        return int(st.get("updated") or 0)
    except ValueError:
        return 0


def display_state(st, mounts, running, now, mounted_since=None, pending=0):
    """The state to SHOW for what the script last wrote — the state file can be
    out of date, and the icon must never claim more than is known right now.

    st: parse_state() dict; mounts: camera storages mounted now; running: a run
    holds a lock; mounted_since: when the newest of those mounts appeared;
    pending: batches copied but not verified on the NAS (0 if unknown).
    Returns a copy; nothing is written back to the state file."""
    d = dict(st)
    phase, upd = st["phase"], updated_at(st)
    if phase == "safe" and (not mounts or (mounted_since or 0) > upd):
        # "safe to format" was worked out for a camera that has since been
        # unplugged (or swapped): what is still true is that it's backed up
        d.update(phase="verified", title="Backed up",
                 detail="Plug the camera in to confirm it's safe to format" if not mounts
                 else "Camera reconnected — not checked against it yet")
    elif phase in BUSY and not running and now - upd > STALE_SECS:
        # busy phases rewrite the state every few seconds; the only long
        # silence is "Verifying on the NAS", and then a lock is held
        d.update(phase="stopped", title="Stopped unexpectedly",
                 detail="Choose Resume backup to carry on — nothing is lost", progress="")
    elif phase == "idle" and pending and not running:
        d.update(phase="pending", title=f"{pending} batch{'' if pending == 1 else 'es'} not yet uploaded",
                 detail="Copied to the laptop, not on the NAS yet — the upload starts by itself")
    return d


def pending_batches(header, rows):
    """How many batches in a parse_status() table are staged but not verified."""
    try:
        staged, verified = header.index("STAGED"), header.index("VERIFIED")
    except ValueError:
        return 0
    return sum(1 for r in rows if r[staged] == "yes" and r[verified] != "yes")


def default_dev(routes):
    """Interface of the first default route in `ip route show default` output."""
    for line in routes.splitlines():
        parts = line.split()
        if "dev" in parts[:-1]:
            return parts[parts.index("dev") + 1]
    return ""


def parse_uplink(out):
    """`nmcli -t -f GENERAL.CONNECTION,GENERAL.METERED dev show DEV` -> (name, metered).
    The name is kept exactly as nmcli prints it, because that is what the
    script puts in the state file and in the trusted-networks file."""
    con, metered = "", None
    for line in out.splitlines():
        if line.startswith("GENERAL.CONNECTION:"):
            con = line.partition(":")[2]
        elif line.startswith("GENERAL.METERED:"):
            metered = line.partition(":")[2].startswith("yes")
    return con, metered


def current_uplink():
    """(connection name, metered) of the network carrying the default route,
    found the way the script's uplink_conn does. ("", None) if there is none.
    Runs ip and nmcli, so only ever called off the GTK thread."""
    try:
        r = subprocess.run(["ip", "route", "show", "default"], capture_output=True, text=True, timeout=5)
        dev = default_dev(r.stdout)
        if not dev:
            return "", None
        r = subprocess.run(["nmcli", "-t", "-f", "GENERAL.CONNECTION,GENERAL.METERED", "dev", "show", dev],
                           capture_output=True, text=True, timeout=8)
        return parse_uplink(r.stdout)
    except (OSError, subprocess.TimeoutExpired):
        return "", None


def trusted_networks():
    """Names in the script's TRUSTED_NETWORKS_FILE (one per line, matched whole),
    or None if there is no such file — the script then holds no network back."""
    home = str(Path.home())
    path = conf_value("TRUSTED_NETWORKS_FILE").replace("${HOME}", home).replace("$HOME", home)
    try:
        return set((Path(path).expanduser() if path else TRUSTED).read_text().split("\n")) - {""}
    except FileNotFoundError:
        return None
    except OSError:
        return set()


def link_status():
    """Everything the tray needs to know about the connection, gathered in one
    background pass: Tailscale, the current network, and the trusted list."""
    con, metered = current_uplink()
    return {"ts": tailscale_status(), "net": con, "metered": metered, "trusted": trusted_networks()}


# ---- auto-resume: a held upload carries on by itself once its cause is gone.
# It only ever re-launches the script; the script's net_guard decides again
# whether this network may be used, so nothing here can bypass it.
def cause_cleared(st, ts_kind, current_network, trusted, metered=None):
    """True if whatever held the upload (st["reason"]) no longer applies."""
    if st.get("phase") != "held":
        return False
    reason = st.get("reason")
    if reason in ("tailscale", "nas"):
        return ts_kind in ("direct", "relay")
    if reason in ("network", "metered"):
        if not current_network:
            return False                                  # offline: nothing to resume on
        if current_network != st.get("network", ""):
            return True                                   # moved to another network
        if reason == "network":
            return trusted is None or current_network in trusted
        return metered is False                           # same network, no longer metered
    return False              # "check" needs the camera; anything unknown needs a person


def resume_key(st, current_network):
    return (st.get("reason") or "", current_network or "")


def resume_allowed(history, key, now):
    """Loop guard. history: [{"t", "key", "rearmed"}], one per automatic start."""
    recent = [h for h in history if now - h["t"] < 3600]
    if len(recent) >= RESUME_PER_HOUR:
        return False
    return not any(h["key"] == key and not h["rearmed"] and now - h["t"] < RESUME_COOLDOWN for h in recent)


def should_resume(st, ts_kind, current_network, trusted, history, now, metered=None):
    """Start the held upload again now? Only when its cause has cleared, and
    not again for the same (reason, network) until the cause has come back and
    cleared once more (rearm) or RESUME_COOLDOWN has passed."""
    if not cause_cleared(st, ts_kind, current_network, trusted, metered):
        return False
    if st.get("reason") == "nas" and now - updated_at(st) < NAS_RETRY_SECS:
        return False
    return resume_allowed(history, resume_key(st, current_network), now)


def note_resume(history, key, now):
    history[:] = [h for h in history if now - h["t"] < 3600]
    history.append({"t": now, "key": key, "rearmed": False})


def rearm(history, key):
    """The cause is back: the next time it clears is a new event, not a loop."""
    for h in history:
        if h["key"] == key:
            h["rearmed"] = True


class Tray:
    def __init__(self):
        st = read_state()
        self.ind = AppIndicator.Indicator.new("footage-ingest", icon_path(st["phase"], st.get("progress")),
                                              AppIndicator.IndicatorCategory.APPLICATION_STATUS)
        self.ind.set_title("Footage ingest")
        self.ind.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.last = None           # what the menu was last built for
        self.dirty = True          # rebuild the menu at the next refresh whatever the state
        self.last_icon = None
        self.running = run_in_progress()
        self.launched_at = 0       # when this tray last started the script
        self.labels = {}
        self.checking = False      # 'Check if safe to format' is in flight
        self.unmounting = False    # 'Eject camera' is in flight
        self.trusting = False      # 'Allow uploads on …' is in flight
        self.ts = ("checking", "🏠  Home connection: checking…", "")
        self.ts_busy = False       # a check is in flight
        self.ts_starting = False   # 'Connect to home' is in flight
        self.net, self.metered, self.trusted = "", None, set()   # filled in by the first poll
        self.history = []          # automatic starts, for the loop guard (resume_allowed)
        self.pending = 0           # batches copied but not verified, from 'status'
        self.pending_at = 0
        self.pending_busy = False
        self.state_seen = STATE.exists()
        # a camera that's already mounted when the tray starts isn't "just connected":
        # the folder the desktop mounts under changed when it was
        mounts = camera_mounts()
        self.mount_names = {n for n, _, _ in mounts}
        self.mounts_seen_at = media_root_mtime() if mounts else None
        self.cam = ("none", "📷  Camera: not connected")
        self.build_menu(st)
        self.refresh()
        GLib.timeout_add_seconds(2, self.refresh)
        self.poll_timer()
        GLib.timeout_add_seconds(15, self.poll_timer)
        # after a restart the state file is gone, but batches may still be waiting
        GLib.timeout_add_seconds(PENDING_DELAY, self.check_pending)

    def is_running(self):
        return run_in_progress() or time.time() - self.launched_at < LAUNCH_GRACE

    def poll_timer(self):
        try:
            self.poll_tailscale()
        except Exception:
            self.ts_busy = False
            log_exc("poll")
        return True  # keep the timer

    def poll_tailscale(self, then=None):
        """Refresh the Tailscale line (and which network we're on) in the
        background; then(status) if given — status is None if the check broke."""
        if self.ts_busy and then is None:
            return True

        def done(res):
            self.ts_busy = False
            if res is None:
                if then:
                    then(None)
                return
            changed = res["ts"][0] != self.ts[0]
            self.ts, self.net, self.metered, self.trusted = res["ts"], res["net"], res["metered"], res["trusted"]
            if changed:
                self.dirty = True     # the Start button appears/disappears
                self.refresh()
            if then:
                then(self.ts)
            self.auto_resume()
        self.ts_busy = True
        in_background(link_status, done)
        return True

    def auto_resume(self):
        """A held upload carries on by itself once what held it is gone; called
        after every connection poll."""
        now = time.time()
        st = read_state()
        if self.is_running():
            return
        if st["phase"] == "held":
            key = resume_key(st, self.net)
            if should_resume(st, self.ts[0], self.net, self.trusted, self.history, now, self.metered):
                note_resume(self.history, key, now)
                print(f"footage-tray: resuming the held upload by itself (reason={key[0]}, network={key[1]!r})",
                      file=sys.stderr, flush=True)
                self.upload_now()
            elif not cause_cleared(st, self.ts[0], self.net, self.trusted, self.metered):
                rearm(self.history, key)
        elif st["phase"] == "idle" and self.pending and now - self.pending_at > PENDING_RECHECK:
            self.check_pending()

    def check_pending(self):
        """Ask the script which batches still aren't verified on the NAS — the
        state file doesn't survive a restart, the batches do — and start the
        upload if any are waiting and nothing else has said what's going on."""
        if self.pending_busy:
            return False
        self.pending_busy = True

        def done(res):
            self.pending_busy = False
            now = self.pending_at = time.time()
            rc, out = res
            if rc != 0:
                return                # couldn't tell: keep what we knew
            _, header, rows = parse_status(out)
            n = pending_batches(header, rows)
            if n != self.pending:
                self.pending = n
                self.dirty = True
            key = ("pending", self.net)
            if n and read_state()["phase"] == "idle" and not self.is_running() \
                    and resume_allowed(self.history, key, now):
                note_resume(self.history, key, now)
                print(f"footage-tray: {n} batch(es) not verified on the NAS — starting the upload",
                      file=sys.stderr, flush=True)
                self.upload_now()
            self.refresh()
        in_background(lambda: run_capture("status", timeout=120), done, error=lambda e: (1, str(e)))
        return False  # also a one-shot timer callback

    def refresh(self):
        # the 2-second timer: an exception here must never stop it (the icon
        # would freeze on whatever it showed last)
        try:
            self.refresh_now()
        except Exception:
            log_exc("refresh")
        return True  # keep the timer

    def refresh_now(self):
        now = time.time()
        raw = read_state()
        running = self.is_running()
        mounts = camera_mounts()
        names = {n for n, _, _ in mounts}
        if not names:
            self.mounts_seen_at = None
        elif names - self.mount_names:
            self.mounts_seen_at = now
        self.mount_names = names
        present = STATE.exists()
        # state gone, or a run just ended: count what's left (once this refresh is done)
        recount = (self.state_seen and not present) or (self.running and not running and self.pending)
        self.state_seen = present
        st = display_state(raw, mounts, running, now, self.mounts_seen_at, self.pending)
        cam = self.camera_status(st, mounts)
        if running != self.running or cam[0] != self.cam[0]:
            self.dirty = True         # menu structure changed: rebuild
        self.running, self.cam = running, cam
        self.update_labels(st)        # text that changes often is updated in place
        key = (st["phase"], st.get("reason"), st.get("network") if st["phase"] == "held" else None,
               bool(st.get("progress")) and st["phase"] in BUSY)
        if key != self.last or self.dirty:
            prev = self.last[0] if self.last else None
            self.last, self.dirty = key, False
            self.build_menu(st)
            self.ind.set_icon_full(icon_path(st["phase"], st.get("progress")), st.get("title", ""))
            self.ind.set_title(f"Footage ingest — {st.get('title', '')}")
            # orange/red asks for attention in Plasma (and stays highlighted)
            self.ind.set_status(AppIndicator.IndicatorStatus.ATTENTION if st["phase"] in ATTENTION
                                else AppIndicator.IndicatorStatus.ACTIVE)
            self.ind.set_attention_icon_full(icon_path(st["phase"], st.get("progress")), st.get("title", ""))
            # No notification for held / error / not safe: the script sends its
            # own for each, and a second one made Plasma drop them as "too many
            # similar". A run that died can't speak for itself, so that one is ours.
            if st["phase"] == "stopped" and prev != "stopped":
                notify(st["title"], st["detail"])
        icon_key = (st["phase"], st.get("progress"))
        if icon_key != self.last_icon:
            self.last_icon = icon_key
            self.ind.set_icon_full(icon_path(st["phase"], st.get("progress")), st.get("title", ""))
        if recount:
            self.check_pending()

    def camera_status(self, st, mounts):
        """(kind, menu line) for the camera."""
        if not mounts:
            return ("none", "📷  Camera: not connected")
        names = " + ".join(n for n, _, _ in mounts)
        seen = self.mounts_seen_at or 0
        if st["phase"] in ("copying", "checking") or camera_being_read([mp for _, mp, _ in mounts]):
            return ("busy", f"📷  Camera ({names}): don't unplug — still being read")
        if time.time() - seen < 30 and updated_at(st) < seen:
            return ("new", f"📷  Camera ({names}): just connected — looking for new footage")
        return ("ok", f"📷  Camera ({names}): OK to unplug")

    def text(self, st):
        """The menu lines that change without the menu's shape changing."""
        dot = next((d for d, _, _, phases in self.LEGEND if st["phase"] in phases), "⚪")
        title = st.get("title", "")
        if st.get("progress") and st["phase"] in BUSY:
            title += f" — {st['progress']}%"
        return {
            "title": wrap_rows(f"{dot}  {title}" if title else ""),
            "detail": wrap_rows(st.get("detail", ""), first=INDENT),
            "camera": wrap_rows(self.cam[1]),
            "home": wrap_rows("🏠  Home connection: connecting…" if self.ts_starting else self.ts[1]),
        }

    def update_labels(self, st):
        for k, rows in self.text(st).items():
            items = self.labels.get(k)
            if items is None:
                continue
            if len(items) != len(rows):
                self.dirty = True     # the text now needs more or fewer rows: rebuild
                continue
            for it, v in zip(items, rows):
                if it.get_label() != v:
                    it.set_label(v)

    def fix_action(self, st):
        """(label, handler) for the one thing that gets a stuck backup going
        again — it sits right under the status — or None."""
        phase, reason = st["phase"], st.get("reason")
        if self.running:
            return None
        if phase == "held":
            if reason == "network":
                shown = st.get("network") or ""
                # the handler gets the name that is on the button, not whatever is current when it runs
                return (f"▶  Allow uploads on “{shown or 'this network'}”", lambda: self.trust_and_upload(shown))
            if reason == "tailscale" and self.ts[0] in ("off", "down", "checking"):
                return ("▶  Connect to home", self.start_tailscale)
            if reason == "metered":
                return None           # nothing to press: it waits for a connection that isn't metered
            return ("▶  Try again", self.upload_now)
        if phase == "stopped" or (phase == "error" and reason == "stopped"):
            return ("▶  Resume backup", self.upload_now)
        if phase == "error":
            return ("▶  Try again", self.upload_now)
        return None

    def build_menu(self, st):
        m = Gtk.Menu()

        def info(text, menu=m):
            it = Gtk.MenuItem(label=text)
            it.set_sensitive(False)
            menu.append(it)
            return it

        def run(fn):
            try:
                fn()
            except Exception:
                log_exc("menu action")

        def action(label, fn, menu=m):
            it = Gtk.MenuItem(label=label)
            it.connect("activate", lambda *_: run(fn))
            menu.append(it)

        self.labels = {}
        t = self.text(st)

        def status(key):
            self.labels[key] = [info(row) for row in t[key]]

        # what's going on, and — when it's stuck — the one thing that unsticks it
        status("title")
        status("detail")
        fix = self.fix_action(st)
        if self.trusting:
            info("Allowing this network…")
        elif self.ts_starting:
            info("Connecting to home…")
        elif fix:
            action(*fix)
        m.append(Gtk.SeparatorMenuItem())
        status("camera")
        if self.unmounting:
            info("Ejecting camera…")
        elif self.cam[0] == "ok":
            action("Eject camera", self.unmount_camera)
        status("home")
        home_is_fix = bool(fix) and fix[1] == self.start_tailscale
        if self.ts[0] in ("off", "down") and not self.ts_starting and not home_is_fix:
            action("Connect to home", self.start_tailscale)
        m.append(Gtk.SeparatorMenuItem())
        # Plasma's tray menus (DBusMenu) carry no tooltips, so a greyed-out
        # item says why in the row under it; everything else is explained in
        # More ▸ What each option does
        if self.running:
            info("Back up now")
            info(INDENT + "already running")
        else:
            action("Back up now", self.upload_now)
        if self.checking:
            info("Checking the card…")
        elif self.cam[0] == "none":
            info("Can I format the card?")
            info(INDENT + "plug the camera in first")
        else:
            action("Can I format the card?", self.format_check)
        action("Open footage folder", lambda: spawn(["xdg-open", str(FOOTAGE_DIR)]))
        action("Recent messages…", self.show_messages)
        m.append(Gtk.SeparatorMenuItem())
        top = Gtk.MenuItem(label="More")
        more = Gtk.Menu()
        action("Backup history…", self.show_status, more)
        action("Show live log", self.show_log, more)
        action("Test home connection", self.check_tailscale, more)
        more.append(self.legend_menu(st["phase"]))
        action("What each option does…", self.show_help, more)
        more.append(Gtk.SeparatorMenuItem())
        action("Quit tray icon", Gtk.main_quit, more)
        top.set_submenu(more)
        m.append(top)
        m.show_all()
        self.ind.set_menu(m)

    # colour key, shown as a submenu; the row matching the current icon is marked
    LEGEND = [
        ("⚪", "Grey", "idle", {"idle"}),
        ("🔵", "Blue", "busy (ring = upload progress)", BUSY),
        ("🟠", "Orange", "needs you: paused or stopped", {"held", "stopped", "pending"}),
        ("🟢", "Green", "backed up / safe to format", {"safe", "verified"}),
        ("🔴", "Red", "failed: do NOT format", {"error", "notsafe"}),
    ]

    # (heading, intro, [(option, what it does), ...]) — keep in step with the menu
    HELP_SECTIONS = [
        ("The top two lines",
         "What the backup is doing right now. The dot is the same colour as the tray icon. "
         "If the backup is stuck, one button appears right under them:",
         [("▶ Allow uploads on \"…\"",
           "You're on a Wi-Fi it hasn't seen before. Press this only if the network's data is "
           "unlimited (not a phone hotspot or a pay-per-GB connection). It remembers the network "
           "and uploads."),
          ("▶ Connect to home",
           "Turns Tailscale on (the private link to the NAS at home). It may ask for your "
           "password. The upload then carries on."),
          ("▶ Resume backup",
           "The backup was cut off (restart, crash). Carries on from where it stopped; nothing "
           "is lost."),
          ("▶ Try again",
           "The NAS didn't answer, or a step failed. It also retries by itself every few minutes.")]),
        ("Camera",
         "Says whether the cable can be pulled. \"Don't unplug\" means files are being read "
         "from the camera right now.",
         [("Eject camera",
           "Safely disconnects the camera's storage so you can unplug. OK to unplug is NOT the "
           "same as safe to format.")]),
        ("Home connection",
         "Whether the laptop can reach the NAS at home. \"Slow (relayed)\" means it's going "
         "through a relay server instead of straight home, so uploads crawl.",
         []),
        ("Back up now",
         "Does everything: copies anything new from the camera to the laptop, checks the copy, "
         "uploads to the NAS, and re-reads every file there to verify it. It normally starts by "
         "itself when you plug the camera in; this is for doing it by hand.",
         []),
        ("Can I format the card?",
         "Checks every file on the camera against the verified copies on the NAS. The answer "
         "arrives as a notification: Safe to format, or NOT safe with a list of the files that "
         "aren't backed up yet. Nothing is ever deleted from the card by this program; "
         "formatting is always done by you, in the camera.",
         []),
        ("Open footage folder",
         "Opens the footage folder: every clip on the laptop in one place.",
         []),
        ("Recent messages",
         "Every notification the backup has sent, newest first, in case one popped up while "
         "you weren't looking. ⚠ marks the ones that needed attention.",
         []),
        ("More",
         "",
         [("Backup history…",
           "Every batch (one per copy from the camera) and whether it has been copied, uploaded "
           "and verified."),
          ("Show live log", "A terminal showing what the backup is doing, line by line."),
          ("Test home connection", "Tests the link to the NAS now; the answer is a notification."),
          ("What the icon colours mean", "The colour key; the current one is marked."),
          ("Quit tray icon",
           "Hides the icon until you next log in. Backups keep running without it.")]),
    ]

    def show_messages(self):
        text_window("Footage backup — recent messages", format_messages(read_messages()),
                    refresh=lambda: format_messages(read_messages()))

    def show_help(self):
        help_window("Footage backup — what each option does", self.HELP_SECTIONS)

    def legend_menu(self, phase):
        top = Gtk.MenuItem(label="What the icon colours mean")
        sub = Gtk.Menu()
        for dot, name, meaning, phases in self.LEGEND:
            now = "   ← now" if phase in phases else ""
            it = Gtk.MenuItem(label=f"{dot}  {name}: {meaning}{now}")
            it.set_sensitive(bool(now))   # greyed out except the current one
            sub.append(it)
        top.set_submenu(sub)
        return top

    def rebuild(self):
        self.dirty = True
        self.refresh()

    def unmount_camera(self):
        if self.unmounting:
            return
        self.unmounting = True
        self.rebuild()                                   # menu shows "Ejecting…"

        def work():
            mounts = camera_mounts()
            if camera_being_read([mp for _, mp, _ in mounts]):
                return "busy", []
            failed = []
            for name, _, dev in mounts:
                try:
                    r = subprocess.run(["udisksctl", "unmount", "-b", dev], capture_output=True, text=True,
                                       timeout=30, stdin=subprocess.DEVNULL)
                    if r.returncode != 0:
                        failed.append(f"{name}: {(r.stderr or r.stdout).strip()}")
                except subprocess.TimeoutExpired:
                    failed.append(f"{name}: no answer after 30 seconds")
            return "done", failed

        def done(res):
            self.unmounting = False
            self.rebuild()
            kind, failed = res
            if kind == "busy":
                notify("Don't unplug yet", "The camera is being read right now.", urgent=True)
            elif failed:
                hint = ("\n\nSomething still has a file or folder open on it — close any Dolphin "
                        "window showing the camera and try again.") if any("busy" in f.lower() for f in failed) else ""
                notify("Couldn't eject the camera", "\n".join(failed) + hint, urgent=True)
            else:
                notify("Camera ejected", "You can unplug the camera now.")
        in_background(work, done, error=lambda e: ("done", [f"{type(e).__name__}: {e}"]))

    def check_tailscale(self):
        def report(res):
            if res is None:
                notify("Connection to home", "Couldn't run the check — try again.", urgent=True)
                return
            notify("Connection to home", res[1].replace("🏠  Home connection: ", "").capitalize() + (f"\n{res[2]}" if res[2] else ""),
                   urgent=res[0] in ("off", "down", "nonas"))
        self.poll_tailscale(then=report)

    def start_tailscale(self):
        if self.ts_starting:
            return
        self.ts_starting = True
        self.rebuild()

        def start():
            # the service needs root: plain systemctl asks through the desktop's
            # password prompt (polkit). 'tailscale up' needs none (operator is set).
            quiet = {"stdin": subprocess.DEVNULL, "capture_output": True, "text": True}
            try:
                if subprocess.run(["systemctl", "is-active", "--quiet", "tailscaled"], timeout=10, **quiet).returncode != 0:
                    # generous: this one waits for a person to type a password
                    r = subprocess.run(["systemctl", "start", "tailscaled"], timeout=180, **quiet)
                    if r.returncode != 0:
                        return (r.stderr or r.stdout).strip() or "the service didn't start (password prompt cancelled?)"
            except subprocess.TimeoutExpired:
                return "starting the service timed out (password prompt left open?)"
            # a service that started a moment ago isn't listening yet: give it a few seconds
            for _ in range(15):
                try:
                    if subprocess.run(["tailscale", "status", "--json"], timeout=8, **quiet).returncode == 0:
                        break
                except subprocess.TimeoutExpired:
                    pass
                time.sleep(1)
            try:
                r = subprocess.run(["tailscale", "up", "--timeout", "30s"], timeout=45, **quiet)
            except subprocess.TimeoutExpired:
                return "'tailscale up' timed out — no internet?"
            return "" if r.returncode == 0 else (r.stderr or r.stdout).strip()

        def done(err):
            self.ts_starting = False
            self.rebuild()
            if err:
                notify("Couldn't connect to home", err, urgent=True)
                self.poll_tailscale(then=lambda _res: None)
                return

            def after(res):
                if res is None:
                    return
                notify("Connected to home" if res[0] in ("direct", "relay") else "Home connection", res[1].replace("🏠  ", ""), urgent=res[0] == "nonas")
                st = read_state()
                # an upload that stopped only because Tailscale was off carries on by itself
                if st["phase"] == "held" and st.get("reason") == "tailscale" and not self.is_running():
                    note_resume(self.history, resume_key(st, self.net), time.time())
                    self.upload_now()
            self.poll_tailscale(then=after)
        # never leave the menu stuck on "Starting…"
        in_background(start, done, error=lambda e: f"{type(e).__name__}: {e}")

    def upload_now(self):
        if time.time() - self.launched_at < LAUNCH_GRACE:
            return                                       # a second click on the same menu
        launch("camera")
        # show "running" straight away instead of waiting for the script to take its lock
        self.launched_at = time.time()
        self.running = True
        self.rebuild()

    def trust_and_upload(self, shown):
        """Trust the network named on the button — `shown` — and upload. The
        script trusts whichever network is current, so check it's still that one."""
        if self.trusting:
            return
        self.trusting = True
        self.rebuild()

        def work():
            current = current_uplink()[0]
            if shown and current != shown:
                return "changed", current
            rc, out = run_capture("trust-network", timeout=30)
            return ("ok" if rc == 0 else "failed"), out

        def done(res):
            self.trusting = False
            self.rebuild()
            kind, out = res
            if kind == "changed":
                now = f"Network changed to {out}" if out else "The network went away"
                notify(f"“{shown}” not allowed", f"{now} — check the menu again", urgent=True)
                self.poll_tailscale(then=lambda _res: None)     # pick the new network up now
            elif kind == "failed":
                notify("Couldn't allow the network", out, urgent=True)
            else:
                self.upload_now()
        in_background(work, done, error=lambda e: ("failed", f"{type(e).__name__}: {e}"))

    def format_check(self):
        if self.checking:
            return
        self.checking = True
        self.rebuild()                                   # menu shows "Checking…"
        notify("Checking the card…", "Comparing every file on the camera with the NAS.")

        def done(res):
            self.checking = False
            self.rebuild()
            rc, out = res
            # keep the per-storage verdict lines for the notification
            verdicts = "\n".join(l.strip() for l in out.splitlines() if l.startswith(("SAFE", "NOT safe")))
            if rc == 0:
                notify("✅ Safe to format", verdicts or out)
            elif rc == 2:
                notify("No camera connected", "Plug the camera in, then check again.")
            else:
                notify("⛔ NOT safe to format", (verdicts or out) + "\nDetails are in the window that opened.", urgent=True)
                text_window("NOT safe to format — files not yet verified on the NAS", out)
        in_background(lambda: run_capture("format-check", timeout=600), done,
                      error=lambda e: (1, f"The check itself broke: {type(e).__name__}: {e}"))

    def show_status(self):
        batches_window()

    def show_log(self):
        cmd = ["journalctl", "--user", "-u", "footage-ingest*", "-f", "-n", "200"]
        for term in (["konsole", "-e"], ["kitty"], ["alacritty", "-e"], ["xterm", "-e"]):
            if shutil.which(term[0]):
                spawn([*term, *cmd])
                return
        dialog(Gtk.MessageType.INFO, "No terminal found", "Run:\n" + " ".join(cmd))


def main():
    Tray()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
