"""audio.mojo check (needs libSDL3, no sound card: run with SDL_AUDIODRIVER=dummy): opens the playback stream, queues
0.1 s of a sine, reads the queue back, and sees it drain as the device consumes it. PASS / FAIL, exit 1 on a FAIL.

usage: SDL_AUDIODRIVER=dummy mojo run -I src tests/audio_test.mojo
"""
from std.math import sin
from std.time import sleep
from imkit.audio import Audio


def main() raises:
    var au = Audio(48000)
    var n = 4800
    var buf = List[Float32](length=n, fill=0)
    for i in range(n):
        buf[i] = Float32(sin(Float64(i) * 0.0654)) * 0.1
    au.put(buf.unsafe_ptr(), n)
    var q0 = au.queued()
    sleep(0.25)
    var q1 = au.queued()
    print("queued after put:", q0, "samples; 0.25 s later:", q1)
    if q0 <= 0 or q0 > n or q1 >= q0:
        raise Error("FAIL audio_test: the queue did not hold or drain")
    print("PASS audio_test")
