#!/usr/bin/env python3
"""Drives the Tray object itself against mocked GTK: what the timers and the
menu handlers do with a given state file. Nothing real is started — launch(),
spawn(), notify() and every script call are replaced."""
import sys
import tempfile
import time
import traceback
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_tray import tray  # noqa: E402  (also installs the gi mocks)

STATUS = ("staging: /x\n\n"
          "BATCH                            SIZE  FILES STAGED PUSHED VERIFIED  FLAT\n"
          "2026-10-10_luna-sd               120G    319    yes    {p}      {v}    no\n")
LINK = {"ts": ("direct", "🏠  Home connection: connected", ""), "net": "Hotel", "metered": False,
        "trusted": {"Home"}}


class TrayCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.state = Path(self.dir.name) / "state"
        self.link = dict(LINK)
        self.status = (0, STATUS.format(p="yes", v="yes"))
        self.captured = []
        self.locked = False

        def capture(*args, **kw):
            self.captured.append(args)
            return self.status if args == ("status",) else (0, "")

        def inline(fn, done, error=None):       # in_background, without the thread
            try:
                res = fn()
            except Exception as e:
                res = error(e) if error else None
            done(res)

        patches = {
            "STATE": self.state, "ICONS": Path(self.dir.name) / "icons",
            "launch": mock.DEFAULT, "spawn": mock.DEFAULT, "notify": mock.DEFAULT, "text_window": mock.DEFAULT,
            "run_capture": capture, "in_background": inline,
            "link_status": lambda: self.link, "current_uplink": lambda: (self.link["net"], self.link["metered"]),
            "run_in_progress": lambda: self.locked, "camera_mounts": lambda *a: self.mounts,
            "camera_being_read": lambda mps: False,
            "log_exc": mock.Mock(side_effect=lambda *a, **k: self.errors.append(traceback.format_exc())),
        }
        self.errors = []
        self.mounts = []
        p = mock.patch.multiple(tray, **patches)
        self.m = p.start()
        self.addCleanup(p.stop)
        self.addCleanup(self.dir.cleanup)
        p2 = mock.patch.object(tray.subprocess, "run", side_effect=AssertionError("no real processes in tests"))
        p2.start()
        self.addCleanup(p2.stop)

    def write(self, phase, title="t", detail="d", reason="", progress="", network="Hotel", age=5):
        self.state.write_text(f"phase={phase}\ntitle={title}\ndetail={detail}\nreason={reason}\n"
                              f"progress={progress}\nnetwork={network}\nupdated={int(time.time() - age)}\n")

    def launches(self):
        return [c.args for c in self.m["launch"].call_args_list]

    def notes(self):
        return [c.args[0] for c in self.m["notify"].call_args_list]

    def no_errors(self):
        self.assertEqual(self.errors, [])


class Timers(TrayCase):
    def test_refresh_survives_anything(self):
        t = tray.Tray()
        with mock.patch.object(t, "refresh_now", side_effect=RuntimeError("boom")):
            self.assertIs(t.refresh(), True)
        self.assertEqual(len(self.errors), 1)
        with mock.patch.object(t, "poll_tailscale", side_effect=RuntimeError("boom")):
            self.assertIs(t.poll_timer(), True)
        self.assertFalse(t.ts_busy)

    def test_no_duplicate_notification_for_script_phases(self):
        t = tray.Tray()
        for phase, reason in (("held", "check"), ("error", "push"), ("notsafe", ""), ("error", "stopped")):
            self.write(phase, reason=reason)
            t.refresh()
            self.assertEqual(t.last[0], phase)
        self.assertEqual(self.notes(), [])
        self.no_errors()

    def test_dead_run_is_shown_and_announced_once(self):
        self.write("uploading", progress="40", age=300)
        t = tray.Tray()
        t.refresh()
        t.refresh()
        self.assertEqual(t.last[0], "stopped")
        self.assertEqual(self.notes(), ["Stopped unexpectedly"])
        self.assertEqual(self.launches(), [], "a dead run is resumed by hand")
        self.locked = True                       # the same state with a lock held is simply busy
        t.refresh()
        self.assertEqual(t.last[0], "uploading")
        self.no_errors()

    def test_stale_safe_is_demoted_until_the_same_camera_is_there(self):
        self.write("safe", title="Safe to format", age=100)
        t = tray.Tray()
        self.assertEqual(t.last[0], "verified")
        self.mounts = [("SD Card", "/run/media/u/SD Card", "/dev/sda1")]
        t.refresh()                              # plugged in after the verdict: still not "safe"
        self.assertEqual(t.last[0], "verified")
        self.write("safe", title="Safe to format", age=-2)   # the script checks it and says so again
        t.refresh()
        self.assertEqual(t.last[0], "safe")
        self.mounts = []
        t.refresh()
        self.assertEqual(t.last[0], "verified")
        self.no_errors()

    def test_status_line_carries_the_colour_and_the_progress(self):
        t = tray.Tray()
        busy = t.text(tray.parse_state("phase=uploading\ntitle=Uploading to the NAS\nprogress=42\n"))
        done = t.text(tray.parse_state("phase=verified\ntitle=All uploads verified\nprogress=42\n"))
        self.assertEqual(busy["title"], ["🔵  Uploading to the NAS — 42%"])
        self.assertEqual(done["title"], ["🟢  All uploads verified"])
        long = t.text(tray.parse_state("phase=verified\ntitle=x\n"
                                       "detail=Camera unplugged — plug it in to confirm it's safe to format\n"))
        self.assertEqual(long["detail"], ["      Camera unplugged — plug it in to",
                                          "      confirm it's safe to format"])
        self.assertTrue(all(len(r) <= tray.MENU_WIDTH for r in long["detail"]))
        self.assertEqual(set(busy), {"title", "detail", "camera", "home"})

    def test_fix_action_is_the_one_thing_that_unsticks_it(self):
        t = tray.Tray()
        fix = lambda **kw: t.fix_action({"phase": "idle", "reason": "", "network": "", **kw})
        self.assertIsNone(fix())
        self.assertIsNone(fix(phase="verified"))
        self.assertIsNone(fix(phase="notsafe"))
        self.assertIsNone(fix(phase="held", reason="metered"))
        self.assertEqual(fix(phase="held", reason="network", network="Hotel")[0], "▶  Allow uploads on “Hotel”")
        self.assertEqual(fix(phase="held", reason="network")[0], "▶  Allow uploads on “this network”")
        self.assertEqual(fix(phase="held", reason="nas"), ("▶  Try again", t.upload_now))
        self.assertEqual(fix(phase="held", reason="tailscale"), ("▶  Try again", t.upload_now))   # link is up
        t.ts = ("off", "x", "")
        self.assertEqual(fix(phase="held", reason="tailscale"), ("▶  Connect to home", t.start_tailscale))
        self.assertEqual(fix(phase="stopped"), ("▶  Resume backup", t.upload_now))
        self.assertEqual(fix(phase="error", reason="stopped"), ("▶  Resume backup", t.upload_now))
        self.assertEqual(fix(phase="error", reason="push"), ("▶  Try again", t.upload_now))
        t.running = True
        self.assertIsNone(fix(phase="held", reason="nas"))
        self.no_errors()

    def test_every_menu_shape_builds(self):
        t = tray.Tray()
        for phase, reason in [("idle", ""), ("uploading", ""), ("held", "network"), ("held", "tailscale"),
                              ("held", "metered"), ("error", "push"), ("stopped", ""), ("safe", ""), ("notsafe", "")]:
            for cam in ("none", "ok", "busy"):
                for flags in ({}, {"running": True}, {"trusting": True}, {"ts_starting": True},
                              {"unmounting": True}, {"checking": True}, {"ts": ("off", "🏠  off", "")}):
                    t.running = t.trusting = t.ts_starting = t.unmounting = t.checking = False
                    t.ts = LINK["ts"]
                    t.cam = (cam, "📷  Camera")
                    for k, v in flags.items():
                        setattr(t, k, v)
                    t.build_menu({"phase": phase, "reason": reason, "title": "t", "detail": "d", "network": "Hotel"})
        self.no_errors()


class AutoResume(TrayCase):
    def test_held_for_tailscale_resumes_when_it_is_back(self):
        self.write("held", reason="tailscale")
        self.link["ts"] = ("off", "🏠  Home connection: off", "")
        t = tray.Tray()
        t.poll_timer()
        self.assertEqual(self.launches(), [])
        self.link["ts"] = LINK["ts"]
        t.poll_timer()
        self.assertEqual(self.launches(), [("camera",)])
        t.launched_at = 0                        # the run came and went, and the script held it again
        t.poll_timer()
        t.poll_timer()
        self.assertEqual(len(self.launches()), 1, "no loop")
        self.link["ts"] = ("off", "🏠  Home connection: off", "")
        t.poll_timer()
        self.link["ts"] = LINK["ts"]
        t.poll_timer()
        self.assertEqual(len(self.launches()), 2, "off and back on again is a new event")
        self.no_errors()

    def test_not_while_a_run_is_in_progress(self):
        self.write("held", reason="tailscale")
        self.locked = True
        t = tray.Tray()
        t.poll_timer()
        self.assertEqual(self.launches(), [])

    def test_untrusted_network_resumes_after_moving_or_trusting(self):
        self.write("held", reason="network", network="Hotel")
        t = tray.Tray()
        t.poll_timer()
        self.assertEqual(self.launches(), [])
        self.link["trusted"] = {"Home", "Hotel"}
        t.poll_timer()
        self.assertEqual(len(self.launches()), 1)
        self.no_errors()

    def test_check_and_errors_are_left_alone(self):
        t = tray.Tray()
        for phase, reason in (("held", "check"), ("error", "push"), ("error", "stopped"), ("notsafe", "")):
            self.write(phase, reason=reason, network="Elsewhere")
            t.poll_timer()
        self.assertEqual(self.launches(), [])

    def test_leftover_batches_after_a_restart(self):
        self.status = (0, STATUS.format(p=" no", v=" no"))
        t = tray.Tray()                          # no state file, as after a reboot
        t.poll_timer()
        self.assertIs(t.check_pending(), False)
        self.assertEqual(t.pending, 1)
        self.assertEqual(self.launches(), [("camera",)])
        t.launched_at = 0
        t.refresh()
        self.assertEqual(t.last[0], "pending")
        t.check_pending()
        self.assertEqual(len(self.launches()), 1, "same guard as a held upload")
        self.no_errors()

    def test_nothing_left_over_means_nothing_happens(self):
        t = tray.Tray()
        t.check_pending()
        self.assertEqual((t.pending, self.launches()), (0, []))
        self.status = (1, "error: no config")
        t.check_pending()
        self.assertEqual((t.pending, self.launches()), (0, []))

    def test_leftovers_do_not_override_what_the_script_said(self):
        self.status = (0, STATUS.format(p=" no", v=" no"))
        self.write("error", reason="push")
        t = tray.Tray()
        t.check_pending()
        self.assertEqual(self.launches(), [])
        self.assertEqual(t.last[0], "error")


class Handlers(TrayCase):
    def test_trust_refuses_when_the_network_changed(self):
        self.write("held", reason="network", network="Hotel")
        t = tray.Tray()
        self.link["net"] = "Phone tether"
        self.link["trusted"] = None              # keep auto-resume out of this one
        t.history = [{"t": time.time(), "key": ("network", "Phone tether"), "rearmed": False}]
        t.trust_and_upload("Hotel")
        self.assertNotIn(("trust-network",), self.captured)
        self.assertEqual(self.launches(), [])
        self.assertIn("Network changed to Phone tether — check the menu again", self.m["notify"].call_args.args[1])
        self.assertFalse(t.trusting)

    def test_trust_goes_ahead_on_the_network_shown(self):
        self.write("held", reason="network", network="Hotel")
        t = tray.Tray()
        t.trust_and_upload("Hotel")
        self.assertIn(("trust-network",), self.captured)
        self.assertEqual(self.launches(), [("camera",)])
        self.assertFalse(t.trusting)
        self.no_errors()

    def test_upload_now_ignores_a_double_click(self):
        t = tray.Tray()
        t.upload_now()
        t.upload_now()
        self.assertEqual(self.launches(), [("camera",)])
        self.assertTrue(t.running)

    def test_unmount_reports_and_clears_its_flag(self):
        self.mounts = [("SD Card", "/run/media/u/SD Card", "/dev/sda1")]
        t = tray.Tray()
        ok = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.object(tray.subprocess, "run", return_value=ok) as run:
            t.unmount_camera()
        self.assertEqual(run.call_args.args[0], ["udisksctl", "unmount", "-b", "/dev/sda1"])
        self.assertEqual(run.call_args.kwargs["timeout"], 30)
        self.assertEqual(self.notes()[-1], "Camera ejected")
        with mock.patch.object(tray.subprocess, "run",
                               side_effect=tray.subprocess.TimeoutExpired("udisksctl", 30)):
            t.unmount_camera()
        self.assertEqual(self.notes()[-1], "Couldn't eject the camera")
        with mock.patch.object(tray.subprocess, "run", side_effect=OSError("no udisksctl")):
            t.unmount_camera()
        self.assertEqual(self.notes()[-1], "Couldn't eject the camera")
        self.assertFalse(t.unmounting)

    def test_format_check_flag_clears_on_failure(self):
        self.mounts = [("SD Card", "/run/media/u/SD Card", "/dev/sda1")]
        t = tray.Tray()
        with mock.patch.object(tray, "run_capture", side_effect=RuntimeError("boom")):
            t.format_check()
        self.assertFalse(t.checking)
        self.assertEqual(self.notes()[-1], "⛔ NOT safe to format")


if __name__ == "__main__":
    unittest.main()
