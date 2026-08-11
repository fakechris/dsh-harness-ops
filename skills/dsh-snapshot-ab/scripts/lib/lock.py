#!/usr/bin/env python3
"""lock.py — portable advisory lock for the A/B rotation.

macOS ships no `flock` binary, so we use python3's fcntl (works on macOS and
Linux). The lock is exclusive and non-blocking for --lock: it exits 0 on
acquire, 1 if already held (printing the holder), and never spins.

Usage:
  lock.py --lock <file> <holder>    acquire; exit 0 or 1
  lock.py --unlock <file>           release (no-op if not held)
  lock.py --held <file>             exit 0 if held, 1 if free
"""
import fcntl
import sys

MODE = sys.argv[1]
path = sys.argv[2]


def main() -> int:
    if MODE == "--held":
        try:
            with open(path, "r") as f:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(f, fcntl.LOCK_UN)
            return 1  # free
        except OSError:
            return 0  # held
    if MODE == "--unlock":
        try:
            with open(path, "r") as f:
                fcntl.flock(f, fcntl.LOCK_UN)
        except OSError:
            pass
        return 0
    if MODE == "--lock":
        holder = sys.argv[3]
        f = open(path, "a+")
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            with open(path, "r") as g:
                h = g.read().strip()
            print(f"lock held by {h or 'unknown'}", file=sys.stderr)
            return 1
        f.truncate(0)
        f.write(holder)
        f.flush()
        # keep the fd open for the process lifetime; fcntl releases on close/exit
        return 0
    print(f"unknown mode {MODE}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
