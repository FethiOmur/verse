"""Moonshine Voice sidecar for the Swift bench. Framed binary protocol on stdin, JSON lines on stdout.

stdin frames: 1 type byte + uint32 LE length + payload.
  'S' start a session (new stream), 'A' float32 mono 16 kHz audio, 'E' end the session (stop + flush), 'Q' quit.
stdout: JSON objects, one per line: ready / started / event / session_end.
Usage: python -I moonshine_worker.py <model_dir> <update_interval_s>
"""
import json
import resource
import struct
import sys
import time

import numpy as np
from moonshine_voice.moonshine_api import ModelArch
from moonshine_voice.transcriber import Transcriber


def out(o):
    sys.stdout.write(json.dumps(o) + "\n")
    sys.stdout.flush()


def cpu():
    r = resource.getrusage(resource.RUSAGE_SELF)
    return r.ru_utime + r.ru_stime


def read_exact(n):
    buf = b""
    while len(buf) < n:
        chunk = sys.stdin.buffer.read(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def main():
    model_dir, interval = sys.argv[1], float(sys.argv[2])
    t0 = time.perf_counter()
    tr = Transcriber(model_path=model_dir, model_arch=ModelArch.MEDIUM_STREAMING, update_interval=interval,
                     options={"return_audio_data": False})
    out({"type": "ready", "load_s": time.perf_counter() - t0, "version": tr.get_version()})

    stream = None
    n_events = 0

    def listener(ev):
        nonlocal n_events
        l = ev.line
        n_events += 1
        out({"type": "event", "kind": type(ev).__name__, "text": l.text, "start": l.start_time, "dur": l.duration,
             "id": l.line_id, "complete": bool(l.is_complete), "lat_ms": l.last_transcription_latency_ms})

    add_total = add_max = 0.0
    add_n = 0
    cpu0 = 0.0
    while True:
        hdr = read_exact(5)
        if hdr is None:
            break
        typ = hdr[:1]
        (ln,) = struct.unpack("<I", hdr[1:])
        payload = read_exact(ln) if ln else b""
        if typ == b"S":
            stream = tr.create_stream(update_interval=interval)
            stream.add_listener(listener)
            stream.start()
            add_total = add_max = 0.0
            add_n = 0
            n_events = 0
            cpu0 = cpu()
            out({"type": "started"})
        elif typ == b"A":
            a = np.frombuffer(payload, dtype="<f4").tolist()
            c0 = time.perf_counter()
            stream.add_audio(a, 16000)
            d = time.perf_counter() - c0
            add_total += d
            add_max = max(add_max, d)
            add_n += 1
        elif typ == b"E":
            c0 = time.perf_counter()
            stream.stop()
            stop_s = time.perf_counter() - c0
            stream.close()
            stream = None
            out({"type": "session_end", "cpu_s": cpu() - cpu0, "maxrss_mb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1048576.0,
                 "add_audio_s": add_total, "add_audio_n": add_n, "add_audio_max_s": add_max, "stop_s": stop_s,
                 "events": n_events})
        elif typ == b"Q":
            break
    tr.close()


if __name__ == "__main__":
    main()
