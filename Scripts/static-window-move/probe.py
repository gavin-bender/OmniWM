#!/usr/bin/env python3
"""Read-only inventory by default. Run with --window ID or --restore JOURNAL."""
import argparse
import contextlib
import ctypes
import json
import os
from pathlib import Path
import pwd
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time

BUILD = '26B8132'
# braun-steven/yabai-sb 9c461d281ce2a63ef08f131cc66684fc4702d66d, osax/common.h
VERSION = b'2.1.45'
DOCK = '/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock'


def request(opcode, body=b''):
    path = '/tmp/yabai-sa_' + pwd.getpwuid(os.getuid()).pw_name + '.socket'
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        raise RuntimeError("No running yabai-sb Dock service was found. No move was submitted.") from None
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        raise RuntimeError('Unexpected scripting-addition socket type or owner')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(2)
        conn.connect(path)
        # Darwin SOL_LOCAL / LOCAL_PEERPID. Verify the serving executable for every request.
        peer = conn.getsockopt(0, 2)
        buf = ctypes.create_string_buffer(4096)
        if ctypes.CDLL('/usr/lib/libproc.dylib').proc_pidpath(peer, buf, len(buf)) <= 0 or os.fsdecode(buf.value) != DOCK:
            raise RuntimeError('Socket peer is not Dock')
        conn.sendall(struct.pack('<HB', 1 + len(body), opcode) + body)
        conn.shutdown(socket.SHUT_WR)
        reply = bytearray()
        while len(reply) < 256:
            chunk = conn.recv(256 - len(reply))
            if not chunk:
                return bytes(reply)
            reply.extend(chunk)
        raise RuntimeError('Oversized scripting-addition reply')


def move(wid, x, y):
    reply = request(6, struct.pack('<Iii', wid, x, y))
    if reply != b'\0':
        raise RuntimeError(f'Dock did not acknowledge move ({reply.hex()})')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--window', type=int)
    group.add_argument('--restore', type=Path)
    args = parser.parse_args()
    build = subprocess.check_output(['sw_vers', '-buildVersion'], text=True).strip()
    if build != BUILD:
        raise RuntimeError(f'Expected {BUILD}, found {build}')
    with tempfile.TemporaryDirectory() as temp, contextlib.ExitStack() as stack:
        binary = Path(temp) / 'geometry'
        subprocess.run(['xcrun', 'swiftc', str(Path(__file__).with_name('Geometry.swift')), '-o', binary], check=True)
        observer = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        stack.callback(observer.wait)
        stack.callback(observer.stdin.close)

        def observe(points=()):
            print(' '.join(map(str, points)), file=observer.stdin, flush=True)
            return json.loads(observer.stdout.readline())

        state = observe()
        if args.window is None and args.restore is None:
            print(json.dumps(state['windows'], indent=2))
            return
        if os.getuid() == 0:
            raise RuntimeError('Run as the logged-in user')
        reply = request(1)
        if len(reply) != len(VERSION) + 6 or not reply.startswith(VERSION + b'\0') or reply[-1:] != b'\n':
            raise RuntimeError('Expected the compatible 2.1.45 Dock service')
        if args.window is not None:
            print('Bring the target window to the front. Sampling begins in four seconds.', flush=True)
            time.sleep(4)
            state = observe()
        saved = json.loads(args.restore.read_text()) if args.restore else None
        wid = saved['id'] if saved else args.window

        def target(snapshot):
            return next((w for w in snapshot['windows'] if w['id'] == wid), None)

        window = target(state)
        if not window or (saved and (window['pid'], window['bundle']) != (saved['pid'], saved['bundle'])):
            raise RuntimeError('Target missing or changed owner')
        original = (saved or window)['frame']
        x, y, width, height = original
        if x != int(x) or y != int(y):
            raise RuntimeError('Cannot restore fractional origin using this mover')

        def restore():
            current = target(observe())
            if not current or (current['pid'], current['bundle']) != (window['pid'], window['bundle']):
                raise RuntimeError('Target identity changed before restoration')
            move(wid, int(x), int(y))
            time.sleep(.25)
            if target(observe()) != dict(window, frame=original):
                raise RuntimeError('Original frame restoration could not be confirmed')

        if saved:
            restore()
            print('Original frame restored.')
            return
        left, right = max(x, 0), min(x + width, state['screen'][0])
        end_y = -120
        upper = max(40, y + 20)
        lower = min(y + height - 8, state['screen'][1] - 8)
        if (right - left < 60 or y < 0 or lower <= end_y + height + 4
                or upper >= end_y + height - 4):
            raise RuntimeError('Choose a visible main-display window with room for both hit-test points')
        if any(ox < x + width and ox + ow > x and oy < 0 and oy + oh > end_y
               for ox, oy, ow, oh in state['otherDisplays']):
            raise RuntimeError('A second display occupies the intended off-screen area')
        mid = (left + right) / 2
        points = (mid, upper, mid, lower)
        for _ in range(6):
            before = observe(points)
            if target(before) != window or before['hits'] != [wid, wid]:
                raise RuntimeError('Bring the target to the front and wait for a stationary frame')
            time.sleep(.05)
        expected = [x, end_y, width, height]
        with tempfile.NamedTemporaryFile(mode='w', prefix='omni-frame-', suffix='.json', delete=False) as f:
            json.dump(window, f)
            journal = Path(f.name)
        print(f'Recovery journal: {journal}', flush=True)
        try:
            move(wid, int(x), end_y)
            time.sleep(.12)
            samples = []
            for _ in range(20):
                snap = observe(points)
                w = target(snap)
                samples.append((w['frame'] if w else None, snap['hits']))
                time.sleep(.035)
            print(json.dumps({'bundle': window['bundle'], 'original': original, 'requested': expected,
                              'samples': samples}))
            passed = all(frame == expected and hits[0] == wid and hits[1] != wid for frame, hits in samples)
        finally:
            restore()
            journal.unlink()
        if not passed:
            raise RuntimeError('Static move did not meet the full-size geometry and hit-test criteria')
        print('PASS. Full-size move observed and original frame restored.')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as e:
        sys.exit(str(e))
