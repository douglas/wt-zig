#!/usr/bin/env python3
import fcntl
import os
import select
import subprocess
import sys
import termios
import time


PROMPT = b"Allow and remember project commands?"
TIMEOUT_SECONDS = 10


def fail(message: str) -> int:
    print(f"pty-run failed: {message}", file=sys.stderr)
    return 124


def main() -> int:
    if len(sys.argv) < 5:
        print("Usage: pty-run.py <input> <cwd> <command> [args...]", file=sys.stderr)
        return 2

    response = sys.argv[1].encode() + b"\n"
    cwd = sys.argv[2]
    argv = sys.argv[3:]

    master_fd, slave_fd = os.openpty()

    def child_setup() -> None:
        os.setsid()
        fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)

    try:
        child = subprocess.Popen(
            argv,
            cwd=cwd,
            env=os.environ.copy(),
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            close_fds=True,
            preexec_fn=child_setup,
        )
    finally:
        os.close(slave_fd)

    output = bytearray()
    sent_response = False
    deadline = time.monotonic() + TIMEOUT_SECONDS

    while True:
        if time.monotonic() > deadline:
            child.kill()
            child.wait()
            os.close(master_fd)
            return fail("timed out waiting for child process")

        readable, _, _ = select.select([master_fd], [], [], 0.1)
        if readable:
            try:
                chunk = os.read(master_fd, 4096)
            except OSError:
                chunk = b""
            if chunk:
                output.extend(chunk)
                if not sent_response and PROMPT in output:
                    os.write(master_fd, response)
                    sent_response = True

        if child.poll() is not None:
            while True:
                readable, _, _ = select.select([master_fd], [], [], 0)
                if not readable:
                    break
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)
            os.close(master_fd)
            sys.stdout.buffer.write(output)
            return child.returncode


if __name__ == "__main__":
    raise SystemExit(main())
