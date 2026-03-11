#!/usr/bin/env python3
"""Terminal VU meter: reads raw s16le PCM from stdin, prints level bars."""

import sys
import struct
import math

RATE = 48000
CHUNK_FRAMES = 2400  # 50ms at 48kHz
CHUNK_BYTES = CHUNK_FRAMES * 2  # s16le = 2 bytes per frame (mono)
BAR_WIDTH = 30

while True:
    data = sys.stdin.buffer.read(CHUNK_BYTES)
    if not data:
        break
    samples = struct.unpack(f"<{len(data)//2}h", data)
    rms = math.sqrt(sum(s * s for s in samples) / len(samples))
    db = 20 * math.log10(rms / 32768 + 1e-10)
    db = max(db, -60)
    level = int((db + 60) / 60 * BAR_WIDTH)
    bar = "\u2588" * level + "\u2591" * (BAR_WIDTH - level)
    sys.stderr.write(f"\r  [{bar}] {db:+5.1f} dB ")
    sys.stderr.flush()
