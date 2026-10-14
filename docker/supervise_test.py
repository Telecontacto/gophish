"""Portable supervisor unit tests; no real child processes, sockets or volumes."""
import importlib.util
from pathlib import Path
import signal
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("supervise", Path(__file__).with_name("supervise.py"))
supervise = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervise)


class Child:
    def __init__(self, pid, exited=False):
        self.pid = pid
        self.exited = exited
        self.waited = False

    def poll(self):
        return 0 if self.exited else None

    def wait(self):
        self.waited = True
        return 0


class SupervisorTest(unittest.TestCase):
    def simulate(self, failure=None, hang=False):
        app = Child(100, failure == "app")
        nginx = Child(200, failure == "nginx")
        handlers = {}
        sent = []
        clock = [0]

        def killpg(pid, sig):
            sent.append((pid, sig))
            if not hang or sig == signal.SIGKILL:
                (app if pid == 100 else nginx).exited = True

        def sleep(seconds):
            clock[0] += 1
            if failure is None:
                handlers[signal.SIGTERM](signal.SIGTERM, None)

        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "private.json"
            config.write_text("{}")
            with patch.object(supervise.signal, "SIGQUIT", 3, create=True), \
                    patch.object(supervise.signal, "SIGKILL", 9, create=True), \
                    patch.object(supervise.signal, "signal", side_effect=lambda sig, fn: handlers.update({sig: fn})), \
                    patch.object(supervise.os, "killpg", side_effect=killpg, create=True), \
                    patch.object(supervise.subprocess, "run") as validate, \
                    patch.object(supervise.subprocess, "Popen", side_effect=[app, nginx]) as start, \
                    patch.object(supervise.time, "sleep", side_effect=sleep), \
                    patch.object(supervise.time, "monotonic", side_effect=lambda: clock[0]), \
                    patch.object(supervise.sys, "argv", ["supervise.py", "./gophish", "--config", str(config), "--mode", "admin", "--disable-mailer"]), \
                    patch.dict(supervise.os.environ, {"GOPHISH_RUNTIME_CONFIG": str(config)}):
                result = supervise.main()
            self.assertFalse(config.exists())
        validate.assert_called_once()
        self.assertEqual(start.call_args_list[0].args[0][-3:], ["--mode", "admin", "--disable-mailer"])
        for call in start.call_args_list:
            self.assertTrue(call.kwargs["start_new_session"])
        self.assertTrue(app.waited and nginx.waited)
        return result, sent

    def test_signal_drains_both(self):
        result, sent = self.simulate()
        self.assertEqual(result, 0)
        self.assertEqual(sent[:2], [(200, 3), (100, signal.SIGTERM)])

    def test_app_clean_exit_is_failure(self):
        result, sent = self.simulate("app")
        self.assertEqual(result, 1)
        self.assertIn((200, 3), sent)

    def test_nginx_exit_stops_app(self):
        result, sent = self.simulate("nginx")
        self.assertEqual(result, 1)
        self.assertIn((100, signal.SIGTERM), sent)

    def test_timeout_kills_groups(self):
        result, sent = self.simulate(hang=True)
        self.assertEqual(result, 0)
        self.assertIn((100, 9), sent)
        self.assertIn((200, 9), sent)

    def test_invalid_nginx_never_starts_app(self):
        with patch.object(supervise.signal, "signal"), \
                patch.object(supervise.subprocess, "run", side_effect=OSError), \
                patch.object(supervise.subprocess, "Popen") as start, \
                patch.dict(supervise.os.environ, {}, clear=True):
            self.assertEqual(supervise.main(), 1)
        start.assert_not_called()

    def test_partial_start_failure_stops_app(self):
        app = Child(100)

        def killpg(pid, sig):
            app.exited = True

        with patch.object(supervise.signal, "signal"), \
                patch.object(supervise.signal, "SIGKILL", 9, create=True), \
                patch.object(supervise.subprocess, "run"), \
                patch.object(supervise.subprocess, "Popen", side_effect=[app, OSError]), \
                patch.object(supervise.os, "killpg", side_effect=killpg, create=True) as kill, \
                patch.object(supervise.sys, "argv", ["supervise.py", "./gophish"]), \
                patch.dict(supervise.os.environ, {}, clear=True):
            self.assertEqual(supervise.main(), 1)
        kill.assert_any_call(100, signal.SIGTERM)
        self.assertTrue(app.waited)


if __name__ == "__main__":
    unittest.main()
