# /// script
# dependencies = []
# ///
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import termios
import time

ANSI = re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]')
BINARY = str(Path(__file__).resolve().parents[3] / 'zig-out/bin/origine')

def receive(fd, marker=b'\r\n> ', needle=b''):
    data = b''
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 0.1)[0]:
            data += os.read(fd, 65536)
            if needle in ANSI.sub(b'', data) and data.endswith(marker):
                return data
    raise AssertionError(('timeout', data[-2000:]))

def run(colors):
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    env = {**os.environ, 'TERM': 'xterm-256color'}
    if colors:
        env.pop('NO_COLOR', None)
    else:
        env['NO_COLOR'] = '1'
    proc = subprocess.Popen([BINARY], stdin=slave, stdout=slave, stderr=slave, env=env)
    def send(data, expected=b'', marker=b'\r\n> '):
        os.write(master, data)
        return receive(master, marker, expected)
    try:
        receive(master)
        data = send(b'{a:123,b:234}\n', b'\r\n{ a: 123, b: 234 }\r\n')
        assert (b'\x1b[33m123' in data) == colors
        send(b'const fruit = {apple: 7};\n', b'undefined')
        send(b'.complete fruit.app\n', b'fruit.apple')
        if colors:
            send(b'Math.ma', b'Math.ma', b'\x1b[u')
            # The ghost is visible but does not enter the buffer until Tab.
            data = send(b'\t(2,9)\n', b'\r\n9\r\n')
            send(b'Math.ma\x1b[C(3,8)\n', b'\r\n8\r\n')
            send(b'fruit.app\t\n', b'\r\n7\r\n')
        else:
            send(b'Math.ma\t(2,9)\n', b'\r\n9\r\n')
        send(b'2+3\n', b'\r\n5\r\n')
        send(b'\x1b[A\n', b'\r\n5\r\n')
        send(b'2+\x1b[A\x1b[B3\n', b'\r\n5\r\n')
        send(b'{\n', marker=b'\r\n... ')
        send(b'a:123,\n', marker=b'\r\n... ')
        send(b'b:234}\n', b'\r\n{ a: 123, b: 234 }\r\n')
        # readline shortcuts: kill/yank, word motion, transpose, undo, reverse search
        send(b'1+2 3\x01\x0b9+9\n', b'\r\n18\r\n')
        send(b'40 + 2 99\x17\n', b'\r\n42\r\n')
        send(b'2+3\x15(\x19)\n', b'\r\n5\r\n')
        send(b'1 + 2\x1b[1;5D\x1b[1;5D9\n', b'\r\n93\r\n')
        send(b'12\x14\n', b'\r\n21\r\n')
        send(b'12\x15\x1f3\n', b'\r\n123\r\n')
        send(b'1 + 2\x1b[H9\x1b[3~\n', b'\r\n11\r\n')
        send(b'7*6\n', b'\r\n42\r\n')
        send(b'\x127*\n', b'\r\n42\r\n')
        send(b'await Promise.resolve(5)\n', b'\r\n5\r\n')
        send(b'const late = await Promise.resolve(8)\n', b'undefined')
        send(b'late + 1\n', b'\r\n9\r\n')
        send(b'function twice(n: number): number {\n', marker=b'\r\n... ')
        send(b'return n * 2\n', marker=b'\r\n... ')
        send(b'}\n', b'undefined')
        send(b'twice(21) as number\n', b'\r\n42\r\n')
        send(b'\x03')
        send(b'.he\t\n', b'Tab')
        os.write(master, b'\x04')
        assert proc.wait(timeout=8) == 0
        restored = termios.tcgetattr(slave)
        # macOS toggles this kernel-managed retype bit on canonical restoration.
        original[3] &= ~getattr(termios, 'PENDIN', 0)
        restored[3] &= ~getattr(termios, 'PENDIN', 0)
        assert restored == original
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        os.close(master)
        os.close(slave)

run(True)
run(False)
p = subprocess.run([BINARY], input=b'{a:123,b:234}\n', capture_output=True, check=True)
assert p.stdout == b'{ a: 123, b: 234 }\n', p.stdout
print('PASS: exact object repro, multiline objects, lexical completion, Tab/Right acceptance, history/draft, command completion, colors/NO_COLOR, plain pipe, readline shortcuts, top-level await, TypeScript, terminal restoration')
