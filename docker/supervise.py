#!/usr/bin/env python3
"""Fail-closed, non-root supervisor for the application and admin proxy."""
import os
import signal
import subprocess
import sys
import tempfile
import time


def main():
    stopping = False
    children = []

    def stop(signum, frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    result = 0
    with tempfile.TemporaryDirectory(prefix="gophish-proxy-") as runtime:
        try:
            for directory in ("body", "proxy", "fastcgi", "uwsgi", "scgi"):
                os.mkdir(os.path.join(runtime, directory), 0o700)
            nginx = ["nginx", "-e", "/dev/null", "-p", runtime + "/", "-c", "/opt/gophish/nginx.conf"]
            # Fail before starting the application on invalid proxy configuration.
            subprocess.run(nginx + ["-t", "-q"], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            if not stopping:
                children.append((subprocess.Popen(sys.argv[1:], start_new_session=True), signal.SIGTERM))
            if not stopping:
                children.append((subprocess.Popen(nginx + ["-g", "daemon off;"],
                                                  start_new_session=True), signal.SIGQUIT))
            while not stopping:
                if any(child.poll() is not None for child, _ in children):
                    # Even an unexpected clean exit must restart the whole service.
                    result = 1
                    break
                time.sleep(0.1)
        except (OSError, subprocess.SubprocessError):
            print("Supervisor: process startup failed", file=sys.stderr)
            result = 1
        finally:
            # Stop accepting proxy requests first; let both servers drain.
            for child, shutdown_signal in reversed(children):
                if child.poll() is None:
                    try:
                        os.killpg(child.pid, shutdown_signal)
                    except ProcessLookupError:
                        pass
            deadline = time.monotonic() + 25
            while any(child.poll() is None for child, _ in children) and time.monotonic() < deadline:
                time.sleep(0.1)
            for child, _ in children:
                # Kill remaining group members too, including orphaned workers.
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait()
            # Generated configuration never survives process shutdown.
            config = os.environ.get("GOPHISH_RUNTIME_CONFIG")
            if config:
                try:
                    os.unlink(config)
                except FileNotFoundError:
                    pass
    return result


if __name__ == "__main__":
    sys.exit(main())
