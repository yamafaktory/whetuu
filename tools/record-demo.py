#!/usr/bin/env python3
"""Drive a real fish session with whetuu active and write an asciicast v2 file.

Everything recorded is genuine program output; only the keystrokes and their
timing are scripted. fish is used because the up-arrow history-picker binding
is part of the fish integration only.
"""
import json, os, pty, re, select, shutil, signal, subprocess, sys, tempfile, time, fcntl, termios, struct

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WHETUU = os.environ.get("WHETUU_BIN", os.path.join(REPO, "zig-out", "bin", "whetuu"))
COLS, ROWS = 92, 24
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "docs", "demo.cast")
ROOT = os.path.join(tempfile.mkdtemp(prefix="whetuu-demo-"), "env")
HARD_DEADLINE = 120

if not os.access(WHETUU, os.X_OK):
    sys.exit(f"record-demo: no whetuu binary at {WHETUU} — run `zig build` first")
if shutil.which("fish") is None:
    sys.exit("record-demo: fish not found; the picker binding ships only in the fish integration")


def sh(cmd, cwd, env):
    subprocess.run(cmd, shell=True, cwd=cwd, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)


def build_env():
    shutil.rmtree(ROOT, ignore_errors=True)
    home = os.path.join(ROOT, "home")
    proj = os.path.join(home, "whetuu")
    os.makedirs(os.path.join(proj, "src"))

    with open(os.path.join(proj, "build.zig.zon"), "w") as f:
        f.write('.{\n    .name = .whetuu,\n    .version = "0.1.0",\n}\n')
    with open(os.path.join(proj, "build.zig"), "w") as f:
        f.write('const std = @import("std");\n')
    with open(os.path.join(proj, "src", "main.zig"), "w") as f:
        f.write("pub fn main() void {}\n")

    genv = dict(os.environ, HOME=home,
                GIT_CONFIG_GLOBAL=os.path.join(home, ".gitconfig"))
    sh("git init -q -b main", proj, genv)
    sh("git config user.email demo@example.com && git config user.name demo", proj, genv)
    sh("git config commit.gpgsign false", proj, genv)
    sh("git add -A && git commit -qm 'Initial commit'", proj, genv)
    with open(os.path.join(proj, "src", "main.zig"), "a") as f:
        f.write("// tweak\n")
    open(os.path.join(proj, "notes.md"), "w").write("scratch\n")

    cfg = os.path.join(home, ".config", "fish")
    os.makedirs(cfg)
    with open(os.path.join(cfg, "config.fish"), "w") as f:
        f.write("set -g fish_greeting\n")
        f.write(f'set -gx PATH {os.path.dirname(WHETUU)} $PATH\n')
        f.write("whetuu init fish | source\n")

    # Seed history from a second directory, through whetuu's own recorder, so
    # the scope toggle has something to reveal instead of showing one list twice.
    notes = os.path.join(home, "notes")
    os.makedirs(notes)
    henv = dict(os.environ, HOME=home,
                XDG_DATA_HOME=os.path.join(home, ".local", "share"))
    for cmd in ("cargo build --release", "rg TODO --stats",
                "hyperfine './bench --iters 100'", "tar -czf notes.tar.gz ."):
        subprocess.run([WHETUU, "history", "add", "--status", "0", "--", cmd],
                       cwd=notes, env=henv, check=True)
        time.sleep(0.05)
    return home, proj


def main():
    home, proj = build_env()
    env = dict(os.environ, HOME=home,
               XDG_CONFIG_HOME=os.path.join(home, ".config"),
               XDG_DATA_HOME=os.path.join(home, ".local", "share"),
               TERM="xterm-256color", COLUMNS=str(COLS), LINES=str(ROWS))

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(proj)
        os.execve(shutil.which("fish"), ["fish", "-i"], env)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    events, start = [], time.time()

    def respond(chunk):
        """fish probes the terminal on startup and blocks until it gets answers."""
        out = b""
        if b"\x1b[?u" in chunk:                       # kitty keyboard protocol
            out += b"\x1b[?0u"
        if b"\x1b]11;?" in chunk:                     # background colour
            out += b"\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\"
        for _ in re.finditer(rb"\x1bP\+q[0-9a-fA-F]+\x1b\\", chunk):
            out += b"\x1bP0+r\x1b\\"                  # XTGETTCAP: unsupported
        if b"\x1b[6n" in chunk:                       # cursor position report
            out += b"\x1b[1;1R"
        if b"\x1b[0c" in chunk or b"\x1b[c" in chunk:  # primary DA, sent last
            out += b"\x1b[?62;22c"
        return out

    def drain(seconds):
        end = time.time() + seconds
        while True:
            left = min(end - time.time(), HARD_DEADLINE - (time.time() - start))
            if left <= 0:
                return
            try:
                r, _, _ = select.select([fd], [], [], left)
            except OSError:
                return
            if not r:
                continue
            try:
                data = os.read(fd, 65536)
            except OSError:
                return
            if not data:
                return
            reply = respond(data)
            if reply:
                os.write(fd, reply)
            events.append([round(time.time() - start, 4), "o",
                           data.decode("utf8", "replace")])

    def send(text, per_char=0.06):
        for ch in text:
            os.write(fd, ch.encode())
            drain(per_char)

    def line(cmd, settle=1.2):
        send(cmd)
        drain(0.4)
        os.write(fd, b"\r")
        drain(settle)

    try:
        drain(1.6)                              # first prompt
        line("git status --short", 1.4)
        drain(0.6)
        line("git switch -q -c feature/demo", 1.4)
        drain(0.6)
        line("sleep 2", 3.2)                    # cmd_duration appears
        drain(0.6)

        # A typo fails, turning the star red. The next up-arrow brings it back at
        # the top of the picker in red, so it is fixed on the search line rather
        # than retyped. Running the fix clears it and returns the star to purple.
        line("gti status", 1.6)                 # unknown command: fails, star red
        drain(0.8)
        os.write(fd, b"\x1b[A")                 # up-arrow: the failed command, red
        drain(2.4)
        os.write(fd, b"\t")                     # copy it onto the search line
        drain(1.4)
        for _ in range(len("gti status ")):     # clear the copied text
            os.write(fd, b"\x7f")
            drain(0.07)
        send("git status", 0.08)                # retype it correctly
        drain(1.8)
        os.write(fd, b"\r")                      # run the fix (succeeds)
        drain(1.8)

        # The history picker, shown properly: open, navigate, toggle scope,
        # filter, run.
        os.write(fd, b"\x1b[A")                 # up-arrow opens it
        drain(2.2)

        for _ in range(3):                      # walk back through time
            os.write(fd, b"\x1b[A")
            drain(0.85)
        for _ in range(2):                      # and forward again
            os.write(fd, b"\x1b[B")
            drain(0.85)
        drain(0.8)

        os.write(fd, b"\x07")                   # Ctrl+G: this dir -> all
        drain(2.2)
        for _ in range(2):                      # the other directory's commands
            os.write(fd, b"\x1b[A")
            drain(0.9)
        drain(1.0)

        os.write(fd, b"\x07")                   # Ctrl+G: back to this dir
        drain(2.0)

        # Filter to a single entry, then Tab it into the search field and append
        # a flag: once the text stops matching anything, Enter runs it as typed.
        send("stat", 0.2)
        drain(2.2)
        os.write(fd, b"\t")                     # copy the selection to the query
        drain(2.2)
        send("--branch", 0.16)                  # Tab already left a trailing space
        drain(2.4)
        os.write(fd, b"\r")                     # runs the edited command
        drain(3.5)
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        except Exception:
            pass
        try:
            os.close(fd)
        except Exception:
            pass

    header = {"version": 2, "width": COLS, "height": ROWS,
              "timestamp": int(start), "title": "whetuu",
              "env": {"SHELL": "fish", "TERM": "xterm-256color"}}
    with open(OUT, "w") as f:
        f.write(json.dumps(header) + "\n")
        for e in events:
            f.write(json.dumps(e) + "\n")
    dur = events[-1][0] if events else 0
    print(f"wrote {OUT}: {len(events)} events, {dur:.1f}s")


main()
