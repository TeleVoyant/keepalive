#!/usr/bin/env python3
"""Render captured terminal output into the screen a user would actually see.

Usage: vt-render.py <capture-file> <cols> <rows>

Implements just enough of a VT: cursor positioning, erase-in-display, erase-in-line,
newline scrolling. That is sufficient to catch the class of bug where a frame redraws
shorter content over longer content and leaves the old tail visible, which is invisible
to a test that only inspects the byte stream.
"""
import re
import sys

CSI = re.compile(r'\x1b\[([0-9;?]*)([A-Za-z])')


class Screen:
    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.buf = [[' '] * cols for _ in range(rows)]
        self.x = self.y = 0

    def scroll(self):
        self.buf.pop(0)
        self.buf.append([' '] * self.cols)
        self.y -= 1

    def newline(self):
        self.y += 1
        if self.y >= self.rows:
            self.scroll()

    def put(self, ch):
        if ch == '\n':
            self.x = 0
            self.newline()
            return
        if ch == '\r':
            self.x = 0
            return
        if ch == '\t':
            self.x = min(self.cols - 1, (self.x // 8 + 1) * 8)
            return
        if self.x >= self.cols:
            self.x = 0
            self.newline()
        if 0 <= self.y < self.rows:
            self.buf[self.y][self.x] = ch
        self.x += 1

    def erase_display(self, mode):
        if mode == 2:
            self.buf = [[' '] * self.cols for _ in range(self.rows)]
        elif mode == 0:
            for i in range(self.x, self.cols):
                self.buf[self.y][i] = ' '
            for row in range(self.y + 1, self.rows):
                self.buf[row] = [' '] * self.cols

    def erase_line(self, mode):
        if mode == 0:
            for i in range(self.x, self.cols):
                self.buf[self.y][i] = ' '
        elif mode == 2:
            self.buf[self.y] = [' '] * self.cols

    def text(self):
        return '\n'.join(''.join(row).rstrip() for row in self.buf)


def render(data, cols, rows):
    screen = Screen(cols, rows)
    i = 0
    while i < len(data):
        ch = data[i]
        if ch == '\x1b':
            match = CSI.match(data, i)
            if match:
                params, final = match.group(1), match.group(2)
                nums = [int(p) for p in params.split(';') if p.isdigit()]
                if final == 'H':
                    screen.y = (nums[0] - 1) if nums else 0
                    screen.x = (nums[1] - 1) if len(nums) > 1 else 0
                elif final == 'J':
                    screen.erase_display(nums[0] if nums else 0)
                elif final == 'K':
                    screen.erase_line(nums[0] if nums else 0)
                i = match.end()
                continue
            if data[i:i + 3] == '\x1b(B':
                i += 3
                continue
            i += 1
            continue
        screen.put(ch)
        i += 1
    return screen.text()


def main():
    data = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
    print(render(data, int(sys.argv[2]), int(sys.argv[3])))
    return 0


if __name__ == '__main__':
    sys.exit(main())
