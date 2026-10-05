#!/usr/bin/env python3
"""Headless ScreenBeam viewer for testing the Mac app without a phone.

Connects, sends a hello, and reports configs, frame rate, bitrate and keyframes.
Usage: python3 test_client.py [host] [port] [seconds]
"""
import socket
import struct
import sys
import threading
import time

host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 7878
duration = float(sys.argv[3]) if len(sys.argv) > 3 else 5

sock = socket.create_connection((host, port), timeout=5)
sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
lock = threading.Lock()


def send(msg_type, payload=b""):
    with lock:
        sock.sendall(struct.pack(">BI", msg_type, len(payload)) + payload)


def recv_exact(n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed by Mac")
        buf += chunk
    return bytes(buf)


import subprocess
name = b"test-client"
pin = subprocess.run(["defaults", "read", "com.screenbeam.mac", "pairingCode"], capture_output=True, text=True).stdout.strip().encode()
send(1, b"SBM1" + struct.pack(">BBIIH", 4, 0b11, 8192, 4320, len(name)) + name + bytes([len(pin)]) + pin + bytes([2]))
if "--wiggle" in sys.argv:  # remote input test: nudge the Mac's cursor
    def wiggle():
        time.sleep(1)
        for dx in (40, -40):
            send(20, struct.pack(">hh", dx, 0))
            time.sleep(0.3)
    threading.Thread(target=wiggle, daemon=True).start()


def pinger():
    while True:
        try:
            send(3, struct.pack(">Q", time.monotonic_ns()))
        except OSError:
            return
        time.sleep(1)


threading.Thread(target=pinger, daemon=True).start()

start = time.time()
frames = keyframes = total = audio_bytes = 0
rtts = []
while time.time() - start < duration:
    msg_type, length = struct.unpack(">BI", recv_exact(5))
    payload = recv_exact(length)
    total += length + 5
    if msg_type == 10:
        codec, w, h, count = struct.unpack(">BIIB", payload[:10])
        print(f"config: {'HEVC' if codec == 2 else 'H.264'} {w}x{h}, {count} parameter sets")
    elif msg_type == 11:
        frames += 1
        send(4, payload[1:9])  # ack: pretend it was displayed immediately
        if payload[0] & 1:
            keyframes += 1
            assert payload[9:13] == b"\x00\x00\x00\x01", "frame is not Annex-B"
    elif msg_type == 12:
        rtts.append((time.monotonic_ns() - struct.unpack(">Q", payload)[0]) / 1e6)
    elif msg_type == 15:
        audio_bytes += length - 8
    elif msg_type == 14:
        lat, kbps, fps, skipped = struct.unpack(">HIHH", payload[:10])
        print(f"stats: {lat} ms latency, {kbps / 1000:.0f} Mbps target, {fps} encoded, {skipped} skipped")
    elif msg_type == 13:
        print(f"error from Mac (code {payload[0]}): {payload[1:].decode()}")
        sys.exit(1)

elapsed = time.time() - start
print(f"{frames} frames ({keyframes} key) in {elapsed:.1f}s = {frames / elapsed:.1f} fps, "
      f"{total * 8 / elapsed / 1e6:.1f} Mbps, rtt {min(rtts) if rtts else 0:.1f} ms, audio {audio_bytes / 4 / elapsed / 1000:.1f}k frames/s")
sock.close()
