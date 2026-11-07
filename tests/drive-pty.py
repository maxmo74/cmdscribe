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
    # "system" means: do not source anything, and start the shell as a
    # login shell so it loads whatever the installer put in /etc. That is
    # how you test an actual installation instead of a manual source.
    system = entry == "system"
    timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 30.0
    # Capturing the terminal makes a silent no-record failure legible.
    transcript = sys.argv[4] if len(sys.argv) > 4 else None
    sink_log = open(transcript, "wb") if transcript else None

    cmds = [
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

    if not system:
        cmds.insert(0, ". %s\n" % entry)

    # CS_EXTRA="cmd;cmd" appends commands to the session. Exists so a failing
    # run can be made to diagnose itself -- dump `history`, PROMPT_COMMAND and
    # the HIST* variables from INSIDE the shell that misbehaved, and let the
    # transcript artifact carry the answer. Without this there is no way to see
    # what the shell thought its history was, from outside.
    extra = os.environ.get("CS_EXTRA")
    if extra:
        for part in extra.split(";"):
            part = part.strip()
            if part:
                cmds.insert(-1, part + "\n")

    pid, fd = pty.fork()
    if pid == 0:                                    # child
        os.environ.pop("ZDOTDIR", None)
        if system:
            # Exactly what sshd execs. No flags: on Debian zsh, `-d`
            # suppresses the *global* rc files as well as .zshenv, so
            # passing it here skips the very /etc/zsh/zshrc the installer
            # writes into and makes a correct install look dead. Measured,
            # not guessed: `zsh -d` -> rc not read, `zsh` -> rc read.
            os.execvp(shell, [shell, "-l"] if "bash" in shell else [shell])
        elif "zsh" in shell:
            os.execvp(shell, [shell, "-d"])
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

    def wait_ready(quiet=0.5, max_wait=20.0):
        """Block until the shell stops producing output, i.e. until it is
        sitting at a prompt waiting for input. Returns False if the child died.

        This replaces a fixed `drain(0.5)`, which was a race. On a loaded
        machine bash has not finished reading /etc/profile when the first
        command is written: the tty echoes it as type-ahead, the command runs,
        and the hook -- installed by the very rc files still being read --
        never sees it. Command number one is simply absent from the log.

        Measured, not theorised: the GitHub Actions runner lost `echo
        IT_PROBE` exactly this way while a quiet Debian box never did, which is
        the signature of a timing bug rather than a product bug. A human waits
        for the prompt; so does the harness now.
        """
        end_all = time.time() + max_wait
        last = time.time()
        while time.time() < end_all:
            r, _, _ = select.select([fd], [], [], 0.1)
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
                last = time.time()
            elif time.time() - last >= quiet:
                return True
        return True

    # Startup output is consumed; readiness is quiescence, not a stopwatch.
    wait_ready()
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
