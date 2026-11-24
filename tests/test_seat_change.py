#!/usr/bin/python3 -I
"""A seat change while the feed is reconnecting blacks out the webcam at once.

The case from the marketplace review: a camera has been streaming, its stream
drops, and the feed reconnects to the same camera. While the loop is stuck in
the requests to the console, the holder goes on writing that camera's last
picture. If another account takes the screen in that time, the holder itself
has to notice and black out the device, rather than leave it to the loop.

Runs without a console, a camera, ffmpeg or a v4l2loopback device: those are
replaced by stand-ins, and everything that decides what reaches the device is
the real code. Run it with `python3 -I tests/test_seat_change.py`, or pass the
path of another copy of the helper to test that one instead.
"""
import importlib.machinery
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "bin", "unifi-protect-webcam")

loader = importlib.machinery.SourceFileLoader("unifi_protect_webcam", HELPER)
spec = importlib.util.spec_from_loader(loader.name, loader)
upw = importlib.util.module_from_spec(spec)
loader.exec_module(upw)

WIDTH, HEIGHT = 64, 36
FRAME = WIDTH * HEIGHT * 3 // 2


class FakeLoopback:
    """Stands in for the device and remembers every frame written to it."""

    writes = []

    def __init__(self, width, height):
        self.width, self.height = width, height
        self.frame_size = width * height * 3 // 2

    def black(self):
        luma = self.width * self.height
        return bytearray(b"\x10" * luma + b"\x80" * (luma // 2))

    def write(self, frame):
        FakeLoopback.writes.append((time.monotonic(), bytes(frame) == bytes(self.black())))

    def close(self):
        pass


def main():
    workdir = tempfile.mkdtemp(prefix="upw-test-")
    device = os.path.join(workdir, "video")
    open(device, "w").close()
    rdir = os.open(workdir, os.O_RDONLY | os.O_DIRECTORY)

    seat = {"uid": os.geteuid()}
    upw.seat_owner = lambda: seat["uid"]
    upw.DEVICE = device
    upw.SIZES = {"small": (WIDTH, HEIGHT)}
    upw.device_state = lambda: {"ready": True}
    upw.Loopback = FakeLoopback

    feed = upw.Feed(rdir)
    feed.wanted = lambda: (("console.example", 443), "cam1", "small")

    reconnecting = threading.Event()
    calls = {"n": 0}

    def start_ffmpeg():
        calls["n"] += 1
        if calls["n"] == 1:
            # A camera that sends twenty real frames and then drops.
            script = (
                "import sys, time\n"
                f"for _ in range(20):\n"
                f"    sys.stdout.buffer.write(b'\\x55' * {FRAME}); sys.stdout.flush(); time.sleep(0.03)\n"
            )
            feed.process = subprocess.Popen([sys.executable, "-I", "-c", script],
                                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                            stderr=subprocess.DEVNULL)
            return
        # The reconnect: stuck in a request to the console for seconds.
        reconnecting.set()
        time.sleep(4.0)
        raise upw.Failure("the console did not answer", "network")

    feed.start_ffmpeg = start_ffmpeg

    flipped = {}

    def take_the_seat():
        if not reconnecting.wait(15):
            return
        time.sleep(0.6)
        flipped["at"] = time.monotonic()
        seat["uid"] = os.geteuid() + 1

    threading.Thread(target=take_the_seat, daemon=True).start()
    try:
        feed.serve()
    finally:
        os.close(rdir)
        shutil.rmtree(workdir, ignore_errors=True)

    failures = []
    if "at" not in flipped:
        failures.append("the feed never got to the reconnect")
    else:
        at = flipped["at"]
        reconnect = [w for w in FakeLoopback.writes if w[0] < at and not w[1]]
        after = [w for w in FakeLoopback.writes if w[0] >= at]
        pictures_after = [t - at for t, black in after if not black and t - at > 0.01]
        blacks_after = [t - at for t, black in after if black]
        if not reconnect:
            failures.append("no picture was written before the seat change; the case was not set up")
        if pictures_after:
            failures.append(f"{len(pictures_after)} pictures went out after the seat change, "
                            f"the last {max(pictures_after):.2f}s after it")
        if not blacks_after or min(blacks_after) > 0.2:
            failures.append("the device was not blacked out within 0.2s of the seat change")
        if feed.fatal != "another account is at the screen now":
            failures.append(f"the feed did not stop for the seat change (fatal={feed.fatal!r})")

    for line in failures:
        print("FAIL:", line)
    if not failures:
        print("ok: blacked out", f"{min(blacks_after) * 1000:.0f} ms after the seat change,",
              "no picture after it")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
