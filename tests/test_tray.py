#!/usr/bin/env python3
"""Tests for footage-tray.py's logic. No display, no GTK, no script runs:
`gi` is replaced by mocks before the module is imported, and everything that
would start a process is patched out.

    python3 -m unittest discover -s tests -v      (or: python3 tests/test_tray.py)
"""
import importlib.util
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

# the real gi would want AyatanaAppIndicator3 and, to do anything, a display
gi = mock.MagicMock()
sys.modules["gi"] = gi
sys.modules["gi.repository"] = gi.repository

SRC = Path(__file__).resolve().parent.parent / "footage-tray.py"
spec = importlib.util.spec_from_file_location("footage_tray", SRC)
tray = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tray)

NOW = 1_800_000_000
CAM = [("SD Card", "/run/media/u/SD Card", "/dev/sda1")]


def st(phase, **kw):
    d = {"phase": phase, "title": f"script says {phase}", "detail": "d", "reason": "", "progress": "",
         "network": "", "updated": str(NOW - 5)}
    d.update({k: str(v) for k, v in kw.items()})
    return d


class StateParsing(unittest.TestCase):
    def test_equals_in_values(self):
        s = tray.parse_state("phase=uploading\ntitle=Uploading a=b\ndetail=x = y == z\nreason=\nprogress=42\n"
                             "network=Café=Free\nupdated=123\n")
        self.assertEqual(s["title"], "Uploading a=b")
        self.assertEqual(s["detail"], "x = y == z")
        self.assertEqual(s["network"], "Café=Free")
        self.assertEqual((s["phase"], s["progress"], s["updated"]), ("uploading", "42", "123"))

    def test_missing_or_garbage_is_idle(self):
        self.assertEqual(tray.parse_state("")["phase"], "idle")
        self.assertEqual(tray.parse_state("phase=banana\n")["phase"], "idle")
        self.assertEqual(tray.parse_state("no equals sign here\n=novalue\n")["phase"], "idle")
        # the tray's own display-only phases are never accepted from the file
        self.assertEqual(tray.parse_state("phase=stopped\n")["phase"], "idle")

    def test_every_phase_has_an_icon(self):
        for phase in tray.SCRIPT_PHASES | tray.ATTENTION | tray.BUSY:
            self.assertIn(phase, tray.LOOK)

    def test_updated_at(self):
        self.assertEqual(tray.updated_at({"updated": "17"}), 17)
        self.assertEqual(tray.updated_at({"updated": ""}), 0)
        self.assertEqual(tray.updated_at({"updated": "soon"}), 0)
        self.assertEqual(tray.updated_at({}), 0)


class Locks(unittest.TestCase):
    TABLE = ("1: POSIX  ADVISORY  WRITE 1133964 00:23:29357 1073741826 1073742335\n"
             "2: FLOCK  ADVISORY  WRITE 8963 00:4b:280 0 EOF\n"
             "3: FLOCK  ADVISORY  WRITE 77 fd:01:903 0 EOF\n"
             "3: -> FLOCK  ADVISORY  WRITE 78 00:36:555 0 EOF\n"
             "4: OFDLCK ADVISORY  READ -1 00:36:903 0 EOF\n")

    def test_device_and_inode_must_both_match(self):
        self.assertTrue(tray.lock_held(self.TABLE, {("00:4b", 280)}))
        self.assertTrue(tray.lock_held(self.TABLE, {("fd:01", 903)}))
        self.assertFalse(tray.lock_held(self.TABLE, {("00:4c", 280)}), "same inode, other filesystem")
        self.assertFalse(tray.lock_held(self.TABLE, {("00:4b", 281)}))

    def test_only_held_flocks_count(self):
        self.assertFalse(tray.lock_held(self.TABLE, {("00:23", 29357)}), "a POSIX lock is not the script's")
        self.assertFalse(tray.lock_held(self.TABLE, {("00:36", 555)}), "waiting for a lock is not holding it")
        self.assertFalse(tray.lock_held(self.TABLE, {("00:36", 903)}))
        self.assertFalse(tray.lock_held("", {("00:4b", 280)}))
        self.assertFalse(tray.lock_held("garbage\n1: FLOCK ADVISORY WRITE 1 nonsense 0 EOF\n", {("00:4b", 280)}))

    def test_kernel_dev_format(self):
        self.assertEqual(tray.kernel_dev(os.makedev(0, 75)), "00:4b")
        self.assertEqual(tray.kernel_dev(os.makedev(253, 1)), "fd:01")
        self.assertEqual(tray.kernel_dev(os.makedev(8, 17)), "08:11")

    def test_lock_ids_of_a_real_file(self):
        with tempfile.NamedTemporaryFile() as f:
            s = os.stat(f.name)
            ids = tray.lock_ids([f.name, "/nonexistent/lock"])
            self.assertEqual(ids, {(f"{os.major(s.st_dev):02x}:{os.minor(s.st_dev):02x}", s.st_ino)})
            # the device of the mount holding it is accepted too (btrfs subvolumes)
            info = f"30 1 0:99 / {os.path.dirname(f.name)} rw - btrfs /dev/x rw\n1 0 0:5 / / rw - ext4 /dev/y rw\n"
            self.assertIn(("00:63", s.st_ino), tray.lock_ids([f.name], info))
            self.assertNotIn(("00:05", s.st_ino), tray.lock_ids([f.name], info))

    def test_real_flock_is_seen(self):
        import fcntl
        with tempfile.NamedTemporaryFile(dir=os.environ.get("XDG_RUNTIME_DIR") or None) as f:
            ids = tray.lock_ids([f.name], Path("/proc/self/mountinfo").read_text())
            self.assertFalse(tray.lock_held(Path("/proc/locks").read_text(), ids))
            fcntl.flock(f, fcntl.LOCK_EX)
            self.assertTrue(tray.lock_held(Path("/proc/locks").read_text(), ids))


class Mounts(unittest.TestCase):
    def test_camera_mounts_from_mountinfo(self):
        root = str(tray.MEDIA_ROOT)
        info = (f"605 181 8:1 / {root}/SD\\040Card rw,nosuid shared:7 - exfat /dev/sda1 rw\n"
                f"606 181 8:16 / {root}/Internal rw,nosuid shared:8 - exfat /dev/sdb rw\n"
                f"607 181 8:32 / {root}/USB\\040Stick rw - vfat /dev/sdc1 rw\n"
                f"608 181 8:48 / {root}/Internal/deeper rw - vfat /dev/sdd1 rw\n"
                "167 42 0:54 / /tmp rw,nosuid,nodev shared:137 - tmpfs tmpfs rw\n")
        self.assertEqual(tray.camera_mounts(info),
                         [("SD Card", f"{root}/SD Card", "/dev/sda1"), ("Internal", f"{root}/Internal", "/dev/sdb")])
        self.assertEqual(tray.camera_mounts(""), [])

    def test_parse_mountinfo_skips_malformed(self):
        self.assertEqual(tray.parse_mountinfo("short line\n1 2 3:4 / /a rw\n"), [])
        self.assertEqual(tray.parse_mountinfo("1 2 0:54 / /tmp rw opt:1 opt:2 - tmpfs tmpfs rw\n"),
                         [("/tmp", "0:54", "tmpfs")])


class Display(unittest.TestCase):
    def show(self, state, mounts=(), running=False, **kw):
        return tray.display_state(state, list(mounts), running, NOW, **kw)

    def test_safe_stays_green_only_for_the_camera_it_was_computed_for(self):
        s = st("safe", updated=NOW - 100)
        self.assertEqual(self.show(s, CAM, mounted_since=NOW - 500)["phase"], "safe")
        self.assertEqual(self.show(s, CAM, mounted_since=0)["title"], s["title"])

    def test_safe_without_camera_is_backed_up(self):
        d = self.show(st("safe"))
        self.assertEqual((d["phase"], d["title"], d["detail"]),
                         ("verified", "Backed up", "Plug the camera in to confirm it's safe to format"))

    def test_safe_for_a_camera_plugged_in_later_is_backed_up(self):
        d = self.show(st("safe", updated=NOW - 100), CAM, mounted_since=NOW - 10)
        self.assertEqual((d["phase"], d["title"]), ("verified", "Backed up"))
        self.assertNotIn("Plug the camera in", d["detail"])
        # also while a new run is starting up on it
        self.assertEqual(self.show(st("safe", updated=NOW - 100), CAM, True, mounted_since=NOW - 10)["phase"],
                         "verified")

    def test_demotion_does_not_touch_the_input(self):
        s = st("safe")
        self.show(s)
        self.assertEqual(s["phase"], "safe")

    def test_dead_run(self):
        for phase in tray.BUSY:
            d = self.show(st(phase, updated=NOW - 91, progress=40))
            self.assertEqual((d["phase"], d["title"], d["detail"], d["progress"]),
                             ("stopped", "Stopped unexpectedly",
                              "Choose Resume backup to carry on — nothing is lost", ""), phase)
        self.assertIn("stopped", tray.ATTENTION)
        self.assertEqual(tray.LOOK["stopped"][0], tray.LOOK["held"][0], "orange, like held")

    def test_busy_is_left_alone_while_fresh_or_locked(self):
        self.assertEqual(self.show(st("uploading", updated=NOW - 89))["phase"], "uploading")
        self.assertEqual(self.show(st("uploading", updated=NOW - 90))["phase"], "uploading")
        # "Verifying on the NAS" writes nothing for a long time, but holds a lock
        self.assertEqual(self.show(st("verifying", updated=NOW - 7200), running=True)["phase"], "verifying")
        self.assertEqual(self.show(st("copying", updated=NOW - 7200), CAM, True)["phase"], "copying")

    def test_final_phases_never_become_stopped(self):
        for phase in ("idle", "held", "verified", "notsafe", "error"):
            self.assertEqual(self.show(st(phase, updated=NOW - 99999))["phase"], phase)
        # what the script is about to start writing itself must pass straight through
        d = self.show(st("error", reason="stopped", updated=NOW - 99999))
        self.assertEqual((d["phase"], d["reason"]), ("error", "stopped"))
        d = self.show(st("checking", title="Camera connected — looking for new footage"), CAM, True,
                      mounted_since=NOW - 6)
        self.assertEqual(d["title"], "Camera connected — looking for new footage")
        self.assertEqual(self.show(st("verified"), CAM, mounted_since=NOW)["title"], "script says verified")

    def test_pending_batches_shown_when_idle(self):
        d = self.show(tray.parse_state(""), pending=2)
        self.assertEqual((d["phase"], d["title"]), ("pending", "2 batches not yet uploaded"))
        self.assertEqual(self.show(tray.parse_state(""), pending=1)["title"], "1 batch not yet uploaded")
        self.assertEqual(self.show(tray.parse_state(""), pending=0)["phase"], "idle")
        self.assertEqual(self.show(tray.parse_state(""), running=True, pending=2)["phase"], "idle")
        self.assertEqual(self.show(st("held", reason="nas"), pending=2)["phase"], "held")
        self.assertEqual(self.show(st("error"), pending=2)["phase"], "error")


class Resume(unittest.TestCase):
    def ok(self, state, ts="direct", net="Hotel", trusted=frozenset(), history=None, now=NOW, **kw):
        return tray.should_resume(state, ts, net, set(trusted), [] if history is None else history, now, **kw)

    def test_tailscale(self):
        s = st("held", reason="tailscale", network="Hotel")
        self.assertTrue(self.ok(s, "direct"))
        self.assertTrue(self.ok(s, "relay"))
        for kind in ("off", "down", "nonas", "missing", "checking"):
            self.assertFalse(self.ok(s, kind), kind)

    def test_nas_waits_two_minutes(self):
        self.assertFalse(self.ok(st("held", reason="nas", updated=NOW - 119)))
        self.assertTrue(self.ok(st("held", reason="nas", updated=NOW - 120)))
        self.assertTrue(self.ok(st("held", reason="nas", updated=NOW - 120), "relay"))
        self.assertFalse(self.ok(st("held", reason="nas", updated=NOW - 5000), "nonas"))

    def test_untrusted_network(self):
        s = st("held", reason="network", network="Hotel")
        self.assertFalse(self.ok(s, net="Hotel"), "same network, still not trusted")
        self.assertTrue(self.ok(s, net="Cafe"), "moved: the script's net_guard decides again")
        self.assertTrue(self.ok(s, net="Hotel", trusted={"Hotel", "Home"}), "trusted since")
        self.assertFalse(self.ok(s, net=""), "offline")
        self.assertTrue(self.ok(s, "off", net="Cafe"), "Tailscale is the script's call, not a reason to wait")
        self.assertTrue(tray.should_resume(s, "direct", "Hotel", None, [], NOW), "no trusted file = no guard")

    def test_metered(self):
        s = st("held", reason="metered", network="Phone")
        self.assertFalse(self.ok(s, net="Phone"))
        self.assertFalse(self.ok(s, net="Phone", trusted={"Phone"}), "trusting doesn't unmeter it")
        self.assertFalse(self.ok(s, net="Phone", metered=True))
        self.assertTrue(self.ok(s, net="Phone", metered=False), "unmarked as metered")
        self.assertTrue(self.ok(s, net="Hotel"))
        self.assertFalse(self.ok(s, net=""))

    def test_never_for_check_errors_or_other_phases(self):
        self.assertFalse(self.ok(st("held", reason="check")))
        self.assertFalse(self.ok(st("held", reason="")))
        self.assertFalse(self.ok(st("held", reason="something-new")))
        for reason in ("copy", "mismatch", "push", "verify", "stopped", "tailscale", "nas"):
            self.assertFalse(self.ok(st("error", reason=reason, updated=NOW - 5000)), reason)
        for phase in ("idle", "uploading", "verified", "safe", "notsafe"):
            self.assertFalse(self.ok(st(phase, reason="tailscale")), phase)

    def test_no_loop_for_the_same_reason_and_network(self):
        s = st("held", reason="tailscale", network="Hotel")
        h = []
        self.assertTrue(self.ok(s, history=h))
        tray.note_resume(h, tray.resume_key(s, "Hotel"), NOW)
        # the script held it again although the cause looks clear to us: wait
        self.assertFalse(self.ok(s, history=h, now=NOW + 30))
        self.assertFalse(self.ok(s, history=h, now=NOW + 599))
        self.assertTrue(self.ok(s, history=h, now=NOW + 600), "10 minutes later")
        # another network is another key
        self.assertTrue(self.ok(s, net="Cafe", history=h, now=NOW + 30))

    def test_rearmed_when_the_cause_comes_back_and_clears_again(self):
        s = st("held", reason="tailscale", network="Hotel")
        h = []
        key = tray.resume_key(s, "Hotel")
        tray.note_resume(h, key, NOW)
        self.assertFalse(self.ok(s, history=h, now=NOW + 30))
        tray.rearm(h, key)                      # Tailscale seen off again
        self.assertFalse(self.ok(s, "off", history=h, now=NOW + 45))
        self.assertTrue(self.ok(s, "direct", history=h, now=NOW + 60))

    def test_hourly_cap(self):
        s = st("held", reason="tailscale", network="Hotel")
        h = []
        key = tray.resume_key(s, "Hotel")
        for i in range(tray.RESUME_PER_HOUR):
            now = NOW + i * 60
            self.assertTrue(self.ok(s, history=h, now=now), i)
            tray.note_resume(h, key, now)
            tray.rearm(h, key)                  # flapping link
        self.assertFalse(self.ok(s, history=h, now=NOW + 600))
        self.assertFalse(self.ok(s, net="Cafe", history=h, now=NOW + 600), "the cap is across all reasons")
        self.assertTrue(self.ok(s, history=h, now=NOW + 3601))
        tray.note_resume(h, key, NOW + 3 * 60 + 3601)
        self.assertEqual(len(h), 1, "old attempts are forgotten")

    def test_tray_never_bypasses_the_network_guard(self):
        src = SRC.read_text()
        self.assertNotIn("NETWORK_GUARD=0", src)
        self.assertNotIn('"NETWORK_GUARD"', src)


class Network(unittest.TestCase):
    def test_default_dev(self):
        self.assertEqual(tray.default_dev("default via 192.168.11.254 dev wlp0s20f3 proto dhcp metric 600 \n"
                                          "default via 10.0.0.1 dev eth0 metric 700\n"), "wlp0s20f3")
        self.assertEqual(tray.default_dev("default dev tailscale0 scope link\n"), "tailscale0")
        self.assertEqual(tray.default_dev(""), "")
        self.assertEqual(tray.default_dev("default via 1.2.3.4 dev"), "")

    def test_parse_uplink(self):
        self.assertEqual(tray.parse_uplink("GENERAL.CONNECTION:Hotel Lobby - Guest\nGENERAL.METERED:no (guessed)\n"),
                         ("Hotel Lobby - Guest", False))
        self.assertEqual(tray.parse_uplink("GENERAL.CONNECTION:Pixel\\: phone\nGENERAL.METERED:yes\n"),
                         ("Pixel\\: phone", True), "kept as nmcli prints it, like the script does")
        self.assertEqual(tray.parse_uplink("GENERAL.CONNECTION:x\nGENERAL.METERED:unknown\n"), ("x", False))
        self.assertEqual(tray.parse_uplink(""), ("", None))

    def test_trusted_networks_file(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "trusted-networks"
            with mock.patch.object(tray, "TRUSTED", f), mock.patch.object(tray, "conf_value", return_value=""):
                self.assertIsNone(tray.trusted_networks(), "no file: the script holds nothing back")
                f.write_text("Family Home 5G\nCafe WiFi\n\nHotel Lobby - Guest\n")
                self.assertEqual(tray.trusted_networks(), {"Family Home 5G", "Cafe WiFi", "Hotel Lobby - Guest"})
            other = Path(d) / "other"
            other.write_text("Only\n")
            with mock.patch.object(tray, "conf_value", return_value=str(other)):
                self.assertEqual(tray.trusted_networks(), {"Only"})


class Status(unittest.TestCase):
    OUT = ("config:  /home/u/.config/footage-ingest.conf\n"
           "nas:     user@192.0.2.10:/mnt/tank/footage/.incoming   bwlimit=0\n"
           "staging: /home/u/Videos/Luna Ultra/.batches\n"
           "\n"
           "BATCH                            SIZE  FILES STAGED PUSHED VERIFIED  FLAT\n"
           "2026-09-29_luna-sd               119G    270    yes    yes      yes   yes\n"
           "2026-10-10-0516_luna-sd           22G    100    yes    yes       no    no\n"
           "2026-10-10_luna-sd               120G    319    yes     no       no    no\n"
           "2026-10-11_luna-sd               1.5G      -     no     no       no    no\n")

    def test_parse_status(self):
        info, header, rows = tray.parse_status(self.OUT)
        self.assertEqual(header, ["BATCH", "SIZE", "FILES", "STAGED", "PUSHED", "VERIFIED", "FLAT"])
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[1], ["2026-10-10-0516_luna-sd", "22G", "100", "yes", "yes", "no", "no"])
        self.assertEqual(len(info), 3)
        self.assertTrue(info[1].startswith("nas:"))

    def test_pending_batches(self):
        _, header, rows = tray.parse_status(self.OUT)
        self.assertEqual(tray.pending_batches(header, rows), 2, "staged but not verified; unfinished copies don't count")
        self.assertEqual(tray.pending_batches(header, rows[:1]), 0)
        self.assertEqual(tray.pending_batches([], []), 0)
        self.assertEqual(tray.pending_batches(*tray.parse_status("error: something broke\n")[1:]), 0)

    def test_size_bytes(self):
        self.assertEqual(tray.size_bytes("119G"), 119e9)
        self.assertEqual(tray.size_bytes("1.5M"), 1.5e6)
        self.assertEqual(tray.size_bytes(""), 0)


class Background(unittest.TestCase):
    def run_job(self, fn, **kw):
        got = []
        finished = threading.Event()
        with mock.patch.object(tray.GLib, "idle_add", side_effect=lambda f: (f(), finished.set())), \
                mock.patch.object(tray, "log_exc"):
            tray.in_background(fn, got.append, **kw)
            self.assertTrue(finished.wait(5))
        return got

    def test_result_is_delivered(self):
        self.assertEqual(self.run_job(lambda: 7), [7])

    def test_done_runs_even_if_the_job_raises(self):
        def boom():
            raise RuntimeError("nope")
        self.assertEqual(self.run_job(boom), [None])
        self.assertEqual(self.run_job(boom, error=lambda e: (1, str(e))), [(1, "nope")])
        self.assertEqual(self.run_job(boom, error=lambda e: 1 / 0), [None], "a broken error handler too")

    def test_a_raising_done_is_contained(self):
        finished = threading.Event()
        with mock.patch.object(tray.GLib, "idle_add", side_effect=lambda f: (f(), finished.set())), \
                mock.patch.object(tray, "log_exc") as log:
            tray.in_background(lambda: 1, lambda res: 1 / 0)
            self.assertTrue(finished.wait(5))
        self.assertTrue(log.called)



class Messages(unittest.TestCase):
    def test_log_read_and_format(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(tray, "MESSAGES", Path(d) / "sub" / "messages.log"):
            self.assertEqual(tray.read_messages(), [])
            self.assertIn("No messages yet", tray.format_messages([]))
            tray.log_message("Camera ejected", "You can unplug\tnow.", now=NOW - 86400)
            tray.log_message("NOT safe", "line one\nline two", urgent=True, now=NOW)
            with tray.MESSAGES.open("a") as f:           # what the script writes, and a broken line
                f.write(f"{NOW + 60}\tnormal\tSafe to format\tAll verified\\nSD Card\n" + "garbage\n")
            msgs = tray.read_messages()
            self.assertEqual(msgs, [(NOW - 86400, False, "Camera ejected", "You can unplug now."),
                                    (NOW, True, "NOT safe", "line one\nline two"),
                                    (NOW + 60, False, "Safe to format", "All verified\nSD Card")])
            text = tray.format_messages(msgs, now=NOW)
            self.assertLess(text.index("Safe to format"), text.index("⚠ NOT safe"))      # newest first
            self.assertLess(text.index("Today"), text.index("Camera ejected"))
            self.assertIn("         line two", text)
            for i in range(2 * tray.MESSAGES_KEEP):
                tray.log_message(f"m{i}", "b", now=NOW)
            self.assertLessEqual(len(tray.read_messages()), 2 * tray.MESSAGES_KEEP)
            self.assertEqual(tray.read_messages()[-1][2], f"m{2 * tray.MESSAGES_KEEP - 1}")


if __name__ == "__main__":
    unittest.main()
