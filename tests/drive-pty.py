#!/usr/bin/env python3

# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.
# Drive a real pty on the LOCAL machine and emit through cmdscribe.
#
# Used by tests/integration.sh. This exists instead of `ssh -tt host
# zsh -i <<EOF` because that deadlocks: -tt hands the remote shell a pty
# whose input comes from a heredoc, so the shell keeps waiting for input
# that has already all been buffered, the ssh channel never sees EOF, and
# the caller blocks forever with no timeout that can reach it.
#
# A pty created on the target by python is bounded, deterministic, and
# needs no ssh pty at all.

import os
import pty
import select
import sys
import time

def main() -> int:
    shell = sys.argv[1]
    entry = sys.argv[2]
    timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 30.0
    # Capturing the terminal makes a silent no-record failure legible.
    transcript = sys.argv[4] if len(sys.argv) > 4 else None
    sink_log = open(transcript, "wb") if transcript else None

    cmds = [
        ". %s\n" % entry,
        "echo IT_PROBE\n",
        "false\n",
        "cd /tmp\n",
        "ls; whoami\n",
        # A quoted newline spans two terminal lines; both shells continue
        # with PS2 and hand the hook ONE command containing a newline.
        # emit() must collapse it into a single record, or the newline
        # forges a second syslog line.
        "echo 'IT_NL1\nIT_NL2'\n",
        "exit\n",
    ]

    pid, fd = pty.fork()
    if pid == 0:                                    # child
        os.environ.pop("ZDOTDIR", None)
        if "zsh" in shell:
            os.execvp(shell, [shell, "-d"])         # -d skips .zshenv only
        else:
            os.execvp(shell, [shell, "--norc", "-i"])

    deadline = time.time() + timeout

    def drain(budget):
        end = time.time() + budget
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    return False
                if not chunk:
                    return False
                if sink_log:
                    sink_log.write(chunk)
                    sink_log.flush()
        return True

    if not drain(0.5):
        pass
    for c in cmds:
        if time.time() > deadline:
            break
        try:
            os.write(fd, c.encode())
        except OSError:
            break
        drain(min(0.8, max(0.2, deadline - time.time())))

    # Never leave a shell running on the target if we ran out of time.
    try:
        os.kill(pid, 9)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    if sink_log:
        sink_log.close()
    return 0

if __name__ == "__main__":
    sys.exit(main())
