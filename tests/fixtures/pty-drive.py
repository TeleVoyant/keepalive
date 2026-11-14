#!/usr/bin/env python3
"""Drive an interactive command through a real pseudo-terminal.

Usage: pty-drive.py <cols> <rows> <settle-seconds> <keys> -- <command> [args...]

<keys> is a comma-separated list. Each item is either a literal string, one of the names
below, "@text", which waits until "text" has appeared in the output before continuing,
or CAPTURE/STOP, which kills and reaps the child after the preceding barrier. Before
single-key input, the driver waits for Bash to put the PTY into noncanonical mode. Text
for a recognized line prompt is sent in canonical mode, where it is buffered until Enter.

Prints the child's exit status as "exit=<n>" on stderr, and raw terminal output on stdout.
The settle-seconds argument is kept for caller compatibility and controls the upper bound
for event polling; it never causes a fixed delay before or after input.
"""
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
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
PROMPT_LABELS = (
    'Custom interval in minutes',
    'New message',
    'Edit message',
    'Secondary message',
    'Secondary interval in minutes',
)


# Role: Read currently available PTY output without introducing an intentional delay.
def pump(fd, captured, timeout):
    try:
        readable, _, _ = select.select([fd], [], [], timeout)
    except InterruptedError:
        return True
    if not readable:
        return True
    try:
        chunk = os.read(fd, 65536)
    except OSError:
        return False
    if not chunk:
        return False
    captured.extend(chunk)
    return True


# Role: Wait for new screen output after the previous key or output barrier.
def wait_for(fd, captured, scan, needle, timeout, poll):
    encoded = needle.encode()
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        found = captured.find(encoded, scan['pos'])
        if found >= 0:
            scan['barrier_start'] = scan['pos']
            scan['barrier_end'] = found + len(encoded)
            scan['pos'] = len(captured)
            return True
        if not pump(fd, captured, poll):
            return False
    return False


# Role: Finish a captured terminal frame after its text barrier matched mid-render.
def wait_for_frame_end(fd, captured, scan, timeout, poll):
    start = scan.get('barrier_end', len(captured))
    frame_start = scan.get('barrier_start', start)
    if b'\x1b[' not in captured[frame_start:start]:
        return True
    end_marker = b'\x1b[J'
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if end_marker in captured[start:]:
            return True
        if not pump(fd, captured, poll):
            return False
    return False


# Role: Wait for canonical line input or an active noncanonical single-key read.
def wait_for_mode(pid, fd, captured, canonical, timeout, poll):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            active = bool(termios.tcgetattr(fd)[3] & termios.ICANON)
        except OSError:
            return False
        if active == canonical:
            return True
        try:
            reaped, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return False
        if reaped:
            return False
        if not pump(fd, captured, poll):
            return False
    return False


# Role: Stop and reap a child process, ignoring the race where it already exited.
def stop_child(pid):
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


# Role: Run one scripted PTY session with output barriers and terminal-read readiness.
def drive(cols, rows, poll, keys, command, timeout=40.0):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        os.execvp(command[0], command)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    captured = bytearray()
    scan = {'pos': 0}
    line_input = False
    line_text = ''
    line_echoed = False
    sent_any = False
    status = None

    for item in keys:
        if item in ('CAPTURE', 'STOP'):
            if not wait_for_frame_end(fd, captured, scan, 30.0, poll):
                status = 'WAIT-TIMEOUT:frame-end'
                break
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

        if item.startswith('@'):
            needle = item[1:]
            if not wait_for(fd, captured, scan, needle, 30.0, poll):
                label = 'WAIT-TIMEOUT:' if sent_any else 'START-TIMEOUT:'
                status = label + needle
                break
            if any(label in needle for label in PROMPT_LABELS):
                line_input = True
                line_text = ''
                line_echoed = False
            elif line_input and line_text and needle in line_text:
                line_echoed = True
            continue

        key = NAMED_KEYS.get(item, item.encode())
        if line_input and key in (b'\r', b'\n') and line_text and not line_echoed:
            if not wait_for(fd, captured, scan, line_text, 30.0, poll):
                status = 'WAIT-TIMEOUT:line-input-echo'
                break
            line_echoed = True
        if not wait_for_mode(pid, fd, captured, line_input, 30.0, poll):
            label = 'WAIT-TIMEOUT:' if sent_any else 'START-TIMEOUT:'
            status = label + 'read-ready'
            break
        sent_any = True
        scan['pos'] = len(captured)
        try:
            os.write(fd, key)
        except OSError:
            status = 'WAIT-TIMEOUT:write-key'
            break
        if line_input and key in (b'\r', b'\n'):
            line_input = False
            line_text = ''
            line_echoed = False
        elif line_input:
            line_text += item

    if status is not None and status != 'CAPTURED':
        stop_child(pid)
    elif status is None:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                reaped, raw = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                status = 'EXIT-UNKNOWN'
                break
            if reaped:
                status = os.waitstatus_to_exitcode(raw)
                break
            if not pump(fd, captured, poll):
                # The PTY has closed but the child is not yet reaped; pace the
                # exit poll instead of spinning on an immediate EOF.
                time.sleep(poll)
        if status is None:
            stop_child(pid)
            status = 'TIMEOUT'

    try:
        os.close(fd)
    except OSError:
        pass
    return status, bytes(captured)


# Role: Parse the fixture-compatible arguments and publish status plus raw terminal bytes.
def main():
    separator = sys.argv.index('--')
    cols, rows = int(sys.argv[1]), int(sys.argv[2])
    poll = min(max(float(sys.argv[3]), 0.001), 0.05)
    raw_keys = sys.argv[4]
    command = sys.argv[separator + 1:]
    keys = raw_keys.split(',') if raw_keys else []
    status, output = drive(cols, rows, poll, keys, command)
    sys.stderr.write('exit=%s\n' % status)
    sys.stdout.buffer.write(output)
    return 0 if status == 0 or status == 'CAPTURED' else 1


if __name__ == '__main__':
    sys.exit(main())
