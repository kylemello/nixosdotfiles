"""q — ask Claude for a shell command, then run / edit / copy / refine it.

Invoked by the `q` fish function in home/q.nix, which reads this program's exit
code to decide whether to `eval` what came back on stdout:

    0  stdout holds a command to run
    1  nothing to do (cancelled, copied, or explained) — stdout empty
    2  something failed; the message is already on stderr

That contract is the reason for the single strictest rule in here: **stdout
carries the command and nothing else.** Every byte of interface — spinner,
panel, menu, prompts, errors — goes to stderr or straight to /dev/tty. A stray
print() to stdout becomes a command fish tries to execute.

The predecessor was a fish function (home/fish.nix, until 2026-09-15). Two
things it could not do motivated the port: its spinner could not animate,
because a fish background job blocks the `claude` call it is meant to spin in
front of; and it parsed free-form model output with `string` builtins, which
died the moment the model answered a question in prose instead of with a
command — a line beginning with "- " was read as a flag.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import termios
import time
import tty

from rich.console import Console, Group
from rich.padding import Padding
from rich.panel import Panel
from rich.syntax import Syntax
from rich.table import Table
from rich.text import Text

# --- Contract with the Nix wrapper (home/q.nix) ----------------------------
#
# Resolved in Nix and passed in rather than looked up here, the same way
# home/wip.nix pins WIP_*: PATH drift must not be able to change which binary
# this talks to.
CLAUDE = os.environ.get("Q_CLAUDE", "claude")
PLATFORM = os.environ.get("Q_PLATFORM", "an unknown platform")
# Shell aliases, newline-separated "name=value" — Nix already knows them, so
# passing them in is the difference between being told `ls -la` and being told
# `ll`, which is what this machine actually has.
ALIASES = os.environ.get("Q_ALIASES", "")

TIMEOUT = 90
DEFAULT_MODEL = "sonnet"
DEFAULT_EFFORT = "low"
# Per claude process, so a refine loop can spend this much again each round.
MAX_BUDGET_USD = os.environ.get("Q_MAX_BUDGET_USD", "0.25")

# Reported to the model as present-or-absent so it suggests tools this machine
# actually has. shutil.which only, no subprocesses — the whole probe is a few
# hundred stat calls, well under a millisecond.
PROBE_TOOLS = [
    "eza", "fd", "rg", "ncdu", "dust", "duf", "delta", "jq", "yq", "bat", "sd",
    "btop", "htop", "gh", "glab", "kubectl", "helm", "k9s", "docker", "nix",
    "atuin", "zoxide", "croc", "fzf", "yazi", "lazygit", "tldr", "xh",
    "ffmpeg", "yt-dlp", "tofu", "terraform", "ansible", "aws", "az", "gcloud",
    "infisical", "sqlite3", "psql", "uv", "bun", "deno", "pnpm", "go", "cargo",
    "gitleaks", "nvim", "tmux", "rsync", "typst", "tesseract",
]

SCHEMA = json.dumps(
    {
        "type": "object",
        "properties": {
            "command": {"type": "string"},
            "explanation": {"type": "string"},
        },
        "required": ["command", "explanation"],
        "additionalProperties": False,
    },
    separators=(",", ":"),
)

# Catppuccin-ish, to sit alongside the rest of the terminal (home/catppuccin.nix).
C_BORDER = "#89b4fa"
C_DANGER = "#f38ba8"
C_WARN = "#f9e2af"
C_OK = "#a6e3a1"
C_DIM = "#6c7086"

err = Console(stderr=True, highlight=False, soft_wrap=False)


# --- Danger guard ----------------------------------------------------------
#
# Local pattern match, no second API call: a model asked to grade its own
# output as dangerous is exactly the wrong thing to rely on. Two tiers, because
# a blanket "are you sure" on every `sudo` trains the reflex to mash Enter.
DANGER_RED = [
    (r"\brm\s+(-[a-zA-Z]*[rR][a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*[rR])", "recursive forced delete"),
    (r"\brm\s+-[a-zA-Z]*r[a-zA-Z]*\s+/(\s|$)", "recursive delete of /"),
    (r"\bdd\b.*\bof=/dev/", "raw write to a block device"),
    (r"\bmkfs(\.|\s)", "makes a filesystem — destroys the target"),
    (r"\b(fdisk|parted|sgdisk)\b", "repartitions a disk"),
    (r">\s*/dev/(sd|nvme|vd|disk)", "redirect onto a block device"),
    (r"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z|fi|da)?sh\b", "pipes the network into a shell"),
    (r"\bchmod\s+(-[a-zA-Z]+\s+)*777\b", "world-writable"),
    (r"\bchown\b.*\s/(\s|$)", "chowns /"),
    (r":\(\)\s*\{.*\|.*&.*\}\s*;?\s*:", "fork bomb"),
    (r"\bgit\s+push\b.*(--force|-f)\b.*\b(master|main)\b", "force-push to the default branch"),
    (r"\bgit\s+push\b.*\b(master|main)\b.*(--force|-f)\b", "force-push to the default branch"),
    (r"\bkill\s+-9\s+-1\b", "kills every process"),
    (r"\b(shutdown|reboot|poweroff|halt)\b", "powers the machine down"),
    (r"\bnix-collect-garbage\b.*(-d|--delete-old)", "deletes every old generation"),
]

DANGER_YELLOW = [
    (r"\bsudo\b", "runs as root"),
    (r"\bnixos-rebuild\b|\bhome-manager\s+switch\b", "rebuilds the system"),
    (r"\bdocker\s+(system\s+prune|volume\s+rm)", "removes docker state"),
    (r"\bgit\s+(reset\s+--hard|clean\s+-[a-zA-Z]*[dfx])", "discards uncommitted work"),
    (r"\b(truncate|shred)\b", "destroys file contents"),
    (r"\bmv\b.*\s/dev/null", "moves into /dev/null"),
]


def danger_check(cmd: str) -> tuple[str | None, list[str]]:
    """Return ("red"|"yellow"|None, reasons) for a command string."""
    red = [why for pat, why in DANGER_RED if re.search(pat, cmd)]
    if red:
        return "red", red
    yellow = [why for pat, why in DANGER_YELLOW if re.search(pat, cmd)]
    if yellow:
        return "yellow", yellow
    return None, []


# --- tty plumbing ----------------------------------------------------------
#
# stdin is normally still the terminal (the fish wrapper only pipes stdout),
# but stdout is a pipe — so anything that echoes, above all readline, has to be
# pointed at the tty explicitly or its prompt lands in the command.


def tty_fd() -> int | None:
    try:
        return os.open("/dev/tty", os.O_RDWR)
    except OSError:
        return None


def read_key(fd: int) -> str:
    """One keypress, no Enter. Returns 'enter', 'esc', 'ctrl-c', or the char."""
    saved = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        ch = os.read(fd, 1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
    if ch in (b"\r", b"\n"):
        return "enter"
    if ch == b"\x1b":
        return "esc"
    if ch == b"\x03":
        return "ctrl-c"
    if ch == b"\x04":
        return "esc"
    return ch.decode("utf-8", "replace").lower()


class on_tty:
    """Point fds 0 and 1 at the terminal for the duration of the block.

    readline writes its prompt and echo to fd 1. Ours is a pipe feeding fish,
    so without this the editor's own output would be captured as part of the
    command.
    """

    def __init__(self, fd: int):
        self.fd = fd

    def __enter__(self):
        sys.stdout.flush()
        self.saved = (os.dup(0), os.dup(1))
        os.dup2(self.fd, 0)
        os.dup2(self.fd, 1)
        return self

    def __exit__(self, *exc):
        sys.stdout.flush()
        os.dup2(self.saved[0], 0)
        os.dup2(self.saved[1], 1)
        os.close(self.saved[0])
        os.close(self.saved[1])
        return False


def ask_line(fd: int, prompt: str, prefill: str = "") -> str | None:
    """A prompt_toolkit-free editable line. None if the user bailed."""
    import readline

    def hook():
        readline.insert_text(prefill)
        readline.redisplay()

    readline.set_startup_hook(hook)
    try:
        with on_tty(fd):
            return input(prompt)
    except (EOFError, KeyboardInterrupt):
        return None
    finally:
        readline.set_startup_hook()


def edit_command(fd: int, cmd: str) -> str | None:
    """Inline readline edit for one-liners, $EDITOR for anything multi-line."""
    if "\n" not in cmd:
        return ask_line(fd, "  ", cmd)

    editor = os.environ.get("EDITOR") or os.environ.get("VISUAL") or "vi"
    with tempfile.NamedTemporaryFile("w+", suffix=".fish", delete=False) as fh:
        fh.write(cmd if cmd.endswith("\n") else cmd + "\n")
        path = fh.name
    try:
        with on_tty(fd):
            subprocess.call([*editor.split(), path])
        with open(path) as fh:
            return fh.read().strip() or None
    finally:
        os.unlink(path)


def copy(cmd: str, fd: int | None) -> str:
    """Clipboard, best effort. Returns what to tell the user."""
    for tool, argv in (
        ("wl-copy", ["wl-copy"]),
        ("pbcopy", ["pbcopy"]),
        ("xclip", ["xclip", "-selection", "clipboard"]),
        ("xsel", ["xsel", "--clipboard", "--input"]),
        ("clip.exe", ["clip.exe"]),
    ):
        if shutil.which(tool):
            try:
                subprocess.run(argv, input=cmd.encode(), check=True)
                return f"copied ({tool})"
            except (OSError, subprocess.CalledProcessError):
                pass

    # No clipboard tool is declared anywhere in this repo, and WSL hides the
    # Windows ones (wsl.interop.includePath = false in hosts/wsl.nix), so this
    # is the path that actually runs on artemis: OSC 52 hands the text to the
    # terminal emulator itself, which also means it survives ssh.
    if fd is None:
        return "no clipboard available"

    seq = f"\033]52;c;{base64.b64encode(cmd.encode()).decode()}\a".encode()
    os.write(fd, seq)

    # Inside tmux the sequence reaches tmux, not the terminal, and home/tmux.nix
    # sets neither set-clipboard nor allow-passthrough — so also write straight
    # to the attached client's real tty, which is what fish_clipboard_copy does.
    if os.environ.get("TMUX"):
        try:
            client = subprocess.run(
                ["tmux", "display-message", "-p", "#{client_tty}"],
                capture_output=True, text=True, timeout=1,
            ).stdout.strip()
            if client and os.access(client, os.W_OK):
                with open(client, "wb") as fh:
                    fh.write(seq)
        except (OSError, subprocess.SubprocessError):
            pass
    return "copied (terminal clipboard)"


# --- Context ---------------------------------------------------------------


def build_context() -> str:
    if os.environ.get("Q_CONTEXT") == "0":
        return ""

    bits = [f"Platform: {PLATFORM}", "Shell: fish"]

    cwd = os.getcwd()
    home = os.path.expanduser("~")
    bits.append(f"Cwd: {'~' + cwd[len(home):] if cwd.startswith(home) else cwd}")

    try:
        branch = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True, timeout=2,
        )
        if branch.returncode == 0:
            bits.append(f"Git branch: {branch.stdout.strip()}")
    except (OSError, subprocess.SubprocessError):
        pass

    present = [t for t in PROBE_TOOLS if shutil.which(t)]
    if present:
        bits.append("Installed: " + " ".join(present))

    if ALIASES.strip():
        bits.append("Aliases:\n" + ALIASES.strip())

    try:
        names = sorted(os.listdir(cwd))
        if names:
            shown = names[:40]
            more = f" (+{len(names) - 40} more)" if len(names) > 40 else ""
            bits.append("Files here: " + " ".join(shown) + more)
    except OSError:
        pass

    return "\n".join(bits)


SYSTEM = """You generate a single shell command for the fish shell.

Rules:
- One command. If several steps are needed, join them with `;` or `&&`.
- fish syntax, not bash: no `$(...)` (use `(...)`), no `&&`-only idioms that
  depend on bash builtins, no `export VAR=x` (use `set -x VAR x`).
- Prefer tools the machine actually has, listed under Installed below.
- `explanation` is one or two sentences on why this command, or what the
  non-obvious flags do. It is read by someone who knows the shell well, so
  skip the basics.
- Even when the request is phrased as a question, `command` must be a command,
  never prose.
"""

SYSTEM_EXPLAIN = """You explain an existing shell command.

Return the command unchanged in `command`. Put the explanation in
`explanation`: what it does, and what any non-obvious flag means. Two to four
sentences. The reader knows the shell well — skip the basics. If the command
is wrong or dangerous, say so first.
"""


def prompt_for(args, query: str, previous: dict | None) -> tuple[str, str]:
    ctx = build_context()

    if args.explain:
        system = SYSTEM_EXPLAIN
        user = f"Explain this command:\n\n{query}"
    elif args.fix:
        system = SYSTEM
        user = (
            f"This command failed with exit status {args.last_status}:\n\n"
            f"{args.last_command}\n\n"
            "Give a corrected command."
        )
        if query:
            user += f"\n\nExtra detail from the user: {query}"
    else:
        system = SYSTEM
        user = query

    if previous:
        user = (
            f"Your previous answer was:\n\ncommand: {previous['command']}\n"
            f"explanation: {previous['explanation']}\n\n"
            f"The user wants it changed: {query}"
        )

    if ctx:
        system = f"{system}\n\n--- This machine ---\n{ctx}\n"
    return system, user


# --- The model call --------------------------------------------------------


def ask(model: str, effort: str, system: str, user: str) -> dict:
    argv = [
        CLAUDE, "-p",
        "--model", model,
        "--effort", effort,
        "--tools", "",
        "--no-session-persistence",
        # Without these four, `claude -p` loads every global MCP server, plugin
        # and skill into the system prompt: measured at ~236k tokens on
        # 2026-09-15, over the 200k request limit, so the call failed outright
        # depending on the day's config. A command suggester needs no tools,
        # no skills and no project settings.
        "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
        "--setting-sources", "",
        "--disable-slash-commands",
        "--max-budget-usd", MAX_BUDGET_USD,
        # The reason the fish version could crash is gone here: the model
        # cannot answer in prose, because the schema is enforced upstream.
        "--json-schema", SCHEMA,
        "--system-prompt", system,
        user,
    ]

    started = time.monotonic()

    # Temp files rather than PIPEs. The spinner loop below polls instead of
    # calling communicate(), so nothing would be draining a pipe while claude
    # writes — and claude writes plenty to stderr when it thinks it has a
    # terminal. The 64KB pipe buffer fills, claude blocks on write, q blocks on
    # poll, and the only thing that ends it is the timeout. (Seen: a call that
    # takes 11s with output going to a file hung the full 90s under a pty.)
    with tempfile.TemporaryFile() as fout, tempfile.TemporaryFile() as ferr:
        try:
            proc = subprocess.Popen(
                argv,
                # DEVNULL, not inherited: claude reading from the same tty
                # would race the raw-mode keypress read the menu does later.
                stdin=subprocess.DEVNULL, stdout=fout, stderr=ferr,
            )
        except OSError as exc:
            raise QError(f"could not run {CLAUDE}: {exc}") from exc

        # A real spinner, which is most of why this is Python: rich renders it
        # on its own thread, so it animates while the subprocess blocks.
        with err.status("", spinner="dots", spinner_style=C_BORDER) as status:
            while proc.poll() is None:
                elapsed = time.monotonic() - started
                if elapsed > TIMEOUT:
                    proc.kill()
                    proc.wait(2)
                    raise QError(f"claude did not answer within {TIMEOUT}s")
                status.update(
                    Text.assemble(("thinking ", ""), (f"{model} · {elapsed:0.1f}s", C_DIM))
                )
                time.sleep(0.08)

        fout.seek(0)
        ferr.seek(0)
        out = fout.read().decode("utf-8", "replace")
        errout = ferr.read().decode("utf-8", "replace")

    if proc.returncode != 0:
        detail = (errout or out or "").strip().splitlines()
        raise QError(detail[-1] if detail else f"claude exited {proc.returncode}")

    text = out.strip()
    if not text:
        raise QError("claude returned nothing")
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        # --json-schema should make this unreachable; if the CLI ever changes
        # shape, show what it actually said rather than a traceback.
        raise QError(f"expected JSON, got: {text[:300]}") from None
    if not isinstance(data, dict) or "command" not in data:
        raise QError(f"no command in response: {text[:300]}")
    data.setdefault("explanation", "")
    return data


class QError(Exception):
    pass


# --- Rendering -------------------------------------------------------------


def render(data: dict, mode: str) -> None:
    cmd = data["command"].strip()
    title = cmd.split()[0] if cmd.split() else "q"
    level, reasons = danger_check(cmd)

    body: list = [Syntax(cmd, "fish", theme="ansi_dark", background_color="default", word_wrap=True)]
    if data.get("explanation"):
        body += [Text(""), Text(data["explanation"].strip(), style=C_DIM)]
    if level == "red":
        body += [Text(""), Text("⚠ " + "; ".join(reasons), style=f"bold {C_DANGER}")]
    elif level == "yellow":
        body += [Text(""), Text("• " + "; ".join(reasons), style=C_WARN)]

    err.print()
    err.print(
        Panel(
            Group(*body),
            title=f"[{C_DIM}]{title}[/]",
            title_align="left",
            border_style=C_DANGER if level == "red" else C_BORDER,
            padding=(0, 1),
        )
    )

    keys = [("↵", "run"), ("e", "edit"), ("c", "copy"), ("r", "refine"), ("q", "quit")]
    if mode == "explain":
        keys = [("↵", "run"), ("e", "edit"), ("c", "copy"), ("q", "quit")]
    err.print(
        "  " + "   ".join(f"[bold]{k}[/] [{C_DIM}]{label}[/]" for k, label in keys)
    )


def confirm_danger(fd: int | None, cmd: str) -> bool:
    level, reasons = danger_check(cmd)
    if level != "red":
        return True
    err.print(f"  [bold {C_DANGER}]{'; '.join(reasons)}[/] — type [bold]yes[/] to run")
    if fd is None:
        return False
    answer = ask_line(fd, "  ")
    return (answer or "").strip().lower() == "yes"


# --- Main ------------------------------------------------------------------


HELP = [
    ("Ask", [
        ("q <what you want>", "describe it in plain English"),
        ("q --fix", "fix the command that just failed"),
        ("q --explain <command>", "explain a command you already have"),
    ]),
    ("Options", [
        ("--haiku", "fast and cheap"),
        ("--opus", "slower, better at the awkward ones"),
        ("--model <name>", f"any alias or full id (default: {DEFAULT_MODEL})"),
        ("--effort low|medium|high", f"thinking budget (default: {DEFAULT_EFFORT})"),
        ("--no-context", "do not send cwd, git branch or filenames"),
        ("-h, --help", "this"),
    ]),
    ("Keys", [
        ("↵", "run it"),
        ("e", "edit first — inline, or $EDITOR if multi-line"),
        ("c", "copy to the clipboard"),
        ("r", "refine: say what to change and ask again"),
        ("q", "quit"),
    ]),
    ("Examples", [
        ("q find files over 100MB modified this week", ""),
        ("q --haiku rename every .jpeg here to .jpg", ""),
        ("ls /nope; q --fix", ""),
        ("q --explain 'tar xzf a.tgz -C /opt --strip-components=2'", ""),
    ]),
]


def show_help() -> int:
    """Pretty help — on stderr, because stdout is the command channel.

    argparse's own --help writes to stdout and exits 0, which through the fish
    wrapper would be captured and handed to `eval`. That is why add_help is off.
    """
    err.print()
    err.print(f"  [bold]q[/]  [{C_DIM}]ask Claude for a shell command, then run it[/]")

    for heading, rows in HELP:
        err.print()
        err.print(f"  [{C_BORDER}]{heading}[/]")
        table = Table(box=None, show_header=False, pad_edge=False, padding=(0, 2))
        table.add_column(no_wrap=True)
        table.add_column(style=C_DIM, overflow="fold")
        for left, right in rows:
            table.add_row(Text(left, style="bold" if right else C_OK), right)
        err.print(Padding(table, (0, 0, 0, 4)))

    err.print()
    err.print(f"  [{C_DIM}]Destructive commands are flagged and need a typed[/] [bold]yes[/][{C_DIM}].[/]")
    err.print()
    return 1


class _Parser(argparse.ArgumentParser):
    """Raise instead of dumping argparse's own usage.

    Its usage line would expose --last-status/--last-command, which are the
    fish wrapper's business and not something to put in front of anyone.
    """

    def error(self, message):
        raise QError(message)


def parse_args(argv: list[str]):
    # add_help=False: see show_help(). -h/--help is intercepted in main().
    p = _Parser(prog="q", add_help=False)
    p.add_argument("--opus", action="store_true", help="use opus")
    p.add_argument("--haiku", action="store_true", help="use haiku")
    p.add_argument("--model", help="model alias or full name")
    p.add_argument("--effort", choices=["low", "medium", "high"], default=DEFAULT_EFFORT)
    p.add_argument("--fix", action="store_true", help="fix the command that just failed")
    p.add_argument("--explain", action="store_true", help="explain a command instead of writing one")
    p.add_argument("--no-context", action="store_true", help="do not send cwd, branch or filenames")
    p.add_argument("--last-status", type=int, default=0, help=argparse.SUPPRESS)
    p.add_argument("--last-command", default="", help=argparse.SUPPRESS)
    p.add_argument("query", nargs="*")
    args = p.parse_args(argv)

    args.model = args.model or ("opus" if args.opus else "haiku" if args.haiku else DEFAULT_MODEL)
    if args.no_context:
        os.environ["Q_CONTEXT"] = "0"
    return args


def main(argv: list[str]) -> int:
    if not argv or "-h" in argv or "--help" in argv:
        return show_help()

    try:
        args = parse_args(argv)
    except QError as exc:
        err.print(f"  [{C_DANGER}]{exc}[/]")
        err.print(f"  [{C_DIM}]try[/] [bold]q --help[/]")
        return 2

    query = " ".join(args.query).strip()

    if args.fix:
        if not args.last_command:
            err.print(f"  [{C_DANGER}]nothing in history to fix[/]")
            return 2
        if args.last_status == 0:
            err.print(f"  [{C_WARN}]the last command succeeded[/] [{C_DIM}]— fixing it anyway[/]")
    elif not query:
        # Bare `q` never reaches the `not argv` check above — the fish wrapper
        # always passes --last-status/--last-command — so it lands here.
        return show_help()

    mode = "explain" if args.explain else "fix" if args.fix else "ask"
    fd = tty_fd()
    interactive = fd is not None and sys.stderr.isatty()

    previous = None
    try:
        data = ask(args.model, args.effort, *prompt_for(args, query, None))
    except QError as exc:
        err.print(f"  [{C_DANGER}]{exc}[/]")
        return 2

    # Non-interactive (piped, or no tty): the command is the whole output.
    if not interactive:
        print(data["command"].strip())
        return 0

    while True:
        render(data, mode)
        try:
            key = read_key(fd)
        except OSError:
            return 1

        if key == "enter":
            cmd = data["command"].strip()
            if not confirm_danger(fd, cmd):
                err.print(f"  [{C_DIM}]cancelled[/]")
                return 1
            print(cmd)
            return 0

        if key == "e":
            edited = edit_command(fd, data["command"].strip())
            if not edited:
                err.print(f"  [{C_DIM}]cancelled[/]")
                return 1
            if not confirm_danger(fd, edited):
                err.print(f"  [{C_DIM}]cancelled[/]")
                return 1
            print(edited)
            return 0

        if key == "c":
            err.print(f"  [{C_OK}]{copy(data['command'].strip(), fd)}[/]")
            return 1

        if key == "r" and mode != "explain":
            correction = ask_line(fd, "  refine: ")
            if not correction or not correction.strip():
                err.print(f"  [{C_DIM}]cancelled[/]")
                return 1
            previous = data
            try:
                data = ask(
                    args.model, args.effort,
                    *prompt_for(args, correction.strip(), previous),
                )
            except QError as exc:
                err.print(f"  [{C_DANGER}]{exc}[/]")
                return 2
            continue

        if key in ("q", "n", "esc", "ctrl-c"):
            err.print(f"  [{C_DIM}]cancelled[/]")
            return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        err.print()
        sys.exit(1)
