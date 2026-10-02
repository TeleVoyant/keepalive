#!/usr/bin/env python3
"""Drive an interactive command through a real pseudo-terminal.

Usage: pty-drive.py <cols> <rows> <settle-seconds> <keys> -- <command> [args...]

<keys> is a comma-separated list. Each item is either a literal string, one of the names
below, "@text", which waits until "text" has appeared in the output before continuing,
or CAPTURE/STOP, which kills and reaps the child after the preceding barrier.
Waiting on expected output instead of guessing with sleeps is what makes these tests
deterministic: a fixed settle races against however long the client takes to draw.

Prints the child's exit status as "exit=<n>" (or "exit=TIMEOUT") on stderr, and the
raw terminal output on stdout, so a shell test can assert on either.

This exists because the TUI's key handling, navigation, and `set -e` behaviour are
invisible to a suite that only calls functions directly: three real defects once hid
behind a fully green run.
"""
import os
import pty
import select
import signal
import struct
import sys
import termios
import fcntl
import time

NAMED_KEYS = {
    'ESC': b'\x1b',
    'ENTER': b'\r',
    'TAB': b'\t',
    'UP': b'\x1b[A',
    'DOWN': b'\x1b[B',
    'RIGHT': b'\x1b[C',
    'LEFT': b'\x1b[D',
    'HOME': b'\x1b[1~',
    'END': b'\x1b[4~',
    'PGUP': b'\x1b[5~',
    'PGDN': b'\x1b[6~',
    'F1': b'\x1bOP',
    'F5': b'\x1b[15~',
    'PASTE': b'\x1b[200~',
    'CTRLD': b'\x04',
}


def drive(cols, rows, settle, keys, command, timeout=40.0):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        os.execvp(command[0], command)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    captured = bytearray()

    def pump(duration):
        end = time.time() + duration
        while time.time() < end:
            readable, _, _ = select.select([fd], [], [], 0.05)
            if not readable:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return False
            if not chunk:
                return False
            captured.extend(chunk)
        return True

    # Waits must look only at output produced since the last key, not at the whole
    # transcript: a screen drawn once at startup would otherwise satisfy every later
    # wait instantly, turning them back into unsynchronised sleeps.
    scan = {'pos': 0}

    def wait_for(needle, limit=30.0):
        end = time.time() + limit
        while time.time() < end:
            if needle in captured[scan['pos']:].decode('utf-8', 'replace'):
                scan['pos'] = len(captured)
                return True
            if not pump(0.1):
                return False
        return False

    # Let the first frame settle before sending anything.
    pump(max(settle, 1.0))
    sent_any = False
    status = None
    for key in keys:
        if isinstance(key, tuple):
            if key[0] == 'stop':
                # CAPTURE/STOP is only valid after its preceding output barrier. Kill and
                # reap immediately so the capture cannot spend the normal 40 s timeout.
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    status = 'CAPTURE-FAILED'
                else:
                    try:
                        os.waitpid(pid, 0)
                    except ChildProcessError:
                        status = 'CAPTURE-FAILED'
                    else:
                        status = 'CAPTURED'
                break
            if not wait_for(key[1]):
                # Report the missed synchronisation instead of sending the rest of the
                # keys blind, which surfaces later as a confusing exit timeout.
                #
                # A wait that fails before any key was sent means the client never got as
                # far as drawing, which is an environment problem - a slow or busy daemon -
                # rather than anything the keys did. Naming it separately lets a caller
                # retry that case without also retrying a key that wrongly exited a view.
                label = 'WAIT-TIMEOUT:' if sent_any else 'START-TIMEOUT:'
                status = label + key[1]
                break
            continue
        sent_any = True
        scan['pos'] = len(captured)
        os.write(fd, key)
        if not pump(settle):
            break
    if status is not None and status != 'CAPTURED':
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    if status is None:
        pump(settle)
        deadline = time.time() + timeout
        while time.time() < deadline:
            reaped, raw = os.waitpid(pid, os.WNOHANG)
            if reaped:
                status = os.waitstatus_to_exitcode(raw)
                break
            pump(0.1)
        if status is None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            status = 'TIMEOUT'
    try:
        os.close(fd)
    except OSError:
        pass
    return status, bytes(captured)


def main():
    separator = sys.argv.index('--')
    cols, rows = int(sys.argv[1]), int(sys.argv[2])
    settle = float(sys.argv[3])
    raw_keys = sys.argv[4]
    command = sys.argv[separator + 1:]
    keys = []
    for item in (raw_keys.split(',') if raw_keys else []):
        if item in ('CAPTURE', 'STOP'):
            keys.append(('stop', ''))
        elif item.startswith('@'):
            keys.append(('wait', item[1:]))
        else:
            keys.append(NAMED_KEYS.get(item, item.encode()))
    status, output = drive(cols, rows, settle, keys, command)
    sys.stderr.write('exit=%s\n' % status)
    sys.stdout.buffer.write(output)
    return 0 if status == 0 or status == 'CAPTURED' else 1


if __name__ == '__main__':
    sys.exit(main())
