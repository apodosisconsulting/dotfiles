#!/usr/bin/env python3
"""Type a partial command line into an interactive zsh and press Tab.

Usage:
    zsh-complete.py <dir> <line> <out>

Completion only runs inside zle, and zle only runs on a terminal, so a
`zsh -i -c` cannot exercise it: this starts `zsh -i` on a pseudo-terminal in
<dir>, waits for its first prompt, types <line> and a Tab, and waits for the
completion to finish.

It records nothing itself. The caller's ~/.zshrc.local does, because .zshrc
sources that last, after compinit, fzf's Tab binding and the plugins: a
compadd wrapper that writes each candidate compadd accepts to <out>, a precmd
hook that creates <out>.ready, and a comppostfuncs entry that creates
<out>.done. tests/test-zshrc.sh writes that file. HOME and the rest of the
environment are the caller's.

Exits non-zero, saying which, if the shell never reached a prompt or the
completion never finished, rather than leaving the caller to read an empty
<out> as "Tab offered nothing".
"""

import os
import pty
import signal
import sys
import time


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    cwd, line, out = sys.argv[1], sys.argv[2], sys.argv[3]

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.execvp("zsh", ["zsh", "-i"])
        os._exit(1)

    # Drain the shell's output while waiting, so it never blocks on a full
    # pty buffer, which would look exactly like a completion that never ended.
    os.set_blocking(fd, False)

    def wait_for(path, limit):
        end = time.time() + limit
        while time.time() < end:
            try:
                os.read(fd, 65536)
            except (BlockingIOError, OSError):
                pass
            if os.path.exists(path):
                return True
            time.sleep(0.05)
        return False

    # Generous, as in pty-client.py: a fresh HOME builds its completion dump
    # on the first start, and a loaded CI runner is slower still.
    rc = 0
    if not wait_for(out + ".ready", 30):
        sys.stderr.write("zsh-complete: the shell never reached a prompt\n")
        rc = 2
    else:
        os.write(fd, line.encode() + b"\t")
        if not wait_for(out + ".done", 30):
            sys.stderr.write("zsh-complete: the completion never finished\n")
            rc = 3

    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    sys.exit(rc)


if __name__ == "__main__":
    main()
