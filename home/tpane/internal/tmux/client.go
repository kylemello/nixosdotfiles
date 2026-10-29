package tmux

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"strings"
	"time"
)

const runTimeout = 10 * time.Second

type Client struct {
	global []string // args before the command, e.g. -L name
	env    []string // nil inherits the process environment
}

// New talks to the server $TMUX points at.
func New() *Client { return &Client{} }

// NewSocket talks to `tmux -L name` with TMUX/TMUX_PANE removed from the
// environment, so it can never reach the server this process runs in.
func NewSocket(name string) *Client {
	env := slices.DeleteFunc(os.Environ(), func(kv string) bool {
		return strings.HasPrefix(kv, "TMUX=") || strings.HasPrefix(kv, "TMUX_PANE=")
	})
	return &Client{global: []string{"-L", name}, env: env}
}

// cmdSep chains commands in one run call; run turns it into tmux's ";".
// It contains a NUL, so no real argument can equal it.
const cmdSep = "\x00;"

func (c *Client) run(args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), runTimeout)
	defer cancel()
	argv := make([]string, 0, len(c.global)+len(args))
	argv = append(argv, c.global...)
	for _, a := range args {
		argv = append(argv, escapeArg(a))
	}
	cmd := exec.CommandContext(ctx, "tmux", argv...)
	cmd.Env = c.env
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		// In a chain we can't tell which command failed.
		name := "tmux"
		if len(args) > 0 && !slices.Contains(args, cmdSep) {
			name = args[0]
		}
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return "", fmt.Errorf("%s: %s", name, msg)
		}
		return "", fmt.Errorf("%s: %w", name, err)
	}
	return stdout.String(), nil
}

// escapeArg keeps tmux from treating a trailing ";" as a command separator,
// which would turn the following arguments into a new command.
func escapeArg(a string) string {
	if a == cmdSep {
		return ";"
	}
	if strings.HasSuffix(a, ";") {
		return a[:len(a)-1] + `\;`
	}
	return a
}

// escapeFormat protects text passed to commands that format-expand it
// (rename-window, rename-session, select-pane -T).
func escapeFormat(s string) string { return strings.ReplaceAll(s, "#", "##") }

// rows runs a list command and splits its output into n-field rows.
func (c *Client) rows(n int, args ...string) ([][]string, error) {
	out, err := c.run(args...)
	if err != nil {
		return nil, err
	}
	var rows [][]string
	for line := range strings.Lines(out) {
		f := strings.Split(strings.TrimRight(line, "\n"), sep)
		if len(f) != n {
			return nil, fmt.Errorf("%s: unexpected output %q", args[0], line)
		}
		rows = append(rows, f)
	}
	return rows, nil
}

func (c *Client) Current() (Location, error) {
	rows, err := c.rows(3, "display-message", "-p", "#{session_id}"+sep+"#{window_id}"+sep+"#{pane_id}")
	if err != nil {
		return Location{}, err
	}
	if len(rows) != 1 {
		return Location{}, errors.New("display-message: no output")
	}
	return Location{SessionID: rows[0][0], WindowID: rows[0][1], PaneID: rows[0][2]}, nil
}

func (c *Client) Capture(paneID string) (string, error) {
	out, err := c.run("capture-pane", "-p", "-e", "-t", paneID)
	if err != nil {
		return "", err
	}
	// Only plain blank lines: styled spaces (a TUI's status bar) are content.
	lines := strings.Split(out, "\n")
	for len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
		lines = lines[:len(lines)-1]
	}
	return strings.Join(lines, "\n"), nil
}

// activeOf returns the flagged id among rows of (id, flag).
func activeOf(rows [][]string, col int) string {
	for _, r := range rows {
		if r[col] == "1" {
			return r[0]
		}
	}
	return ""
}

// swapPane swaps keep the window zoomed (-Z) and the active pane where it is (-d).
var swapPane = []string{"swap-pane", "-d", "-Z"}

var errFloating = errors.New("swap-pane: can't swap a floating pane with a tiled one")

const paneRowFormat = "#{pane_id}" + sep + "#{pane_index}" + sep + "#{pane_active}" + sep +
	"#{pane_floating_flag}" + sep + "#{window_layout}"

// windowPanes lists the panes of the window holding target as rows of
// (id, index, active, floating). Floating also comes from the layout, since
// pane_floating_flag is 0 for every pane of a zoomed window.
func (c *Client) windowPanes(target string) ([][]string, error) {
	rows, err := c.rows(5, "list-panes", "-t", target, "-F", paneRowFormat)
	if err != nil {
		return nil, err
	}
	if len(rows) > 0 {
		fl := floatingIn(rows[0][4]) // one window, one layout
		for _, r := range rows {
			if fl[r[0]] {
				r[3] = "1"
			}
		}
	}
	return rows, nil
}

func floatingOf(rows [][]string, id string) (floating, found bool) {
	for _, r := range rows {
		if r[0] == id {
			return r[3] == "1", true
		}
	}
	return false, false
}

// SwapPanes swaps two panes, possibly in different windows. With -d tmux
// leaves the -s pane active if either was, so when the target is its
// window's active pane it goes in -s instead, keeping focus on the same pane.
// Floating status belongs to the position, so tiled/floating swaps are refused.
func (c *Client) SwapPanes(srcID, dstID string) error {
	rows, err := c.windowPanes(srcID)
	if err != nil {
		return err
	}
	dstRows, err := c.windowPanes(dstID)
	if err != nil {
		return err
	}
	srcFl, ok1 := floatingOf(rows, srcID)
	dstFl, ok2 := floatingOf(dstRows, dstID)
	if !ok1 || !ok2 {
		return fmt.Errorf("swap-pane: can't find pane %s or %s", srcID, dstID)
	}
	if srcFl != dstFl {
		return errFloating
	}
	if activeOf(rows, 2) == dstID {
		srcID, dstID = dstID, srcID
	}
	_, err = c.run(append(slices.Clone(swapPane), "-s", srcID, "-t", dstID)...)
	return err
}

// MovePane moves a pane to the given index within its window; the panes in
// between shift one place, like inserting into a list.
func (c *Client) MovePane(paneID string, index int) error {
	rows, err := c.windowPanes(paneID)
	if err != nil {
		return err
	}
	from, to := -1, -1
	for i, r := range rows {
		if r[0] == paneID {
			from = i
		}
		if r[1] == strconv.Itoa(index) {
			to = i
		}
	}
	if from < 0 {
		return fmt.Errorf("move-pane: pane %s not found", paneID)
	}
	if to < 0 {
		return fmt.Errorf("move-pane: no pane index %d in its window", index)
	}
	if from == to {
		return nil
	}
	for _, r := range rows[min(from, to) : max(from, to)+1] {
		if r[3] == "1" {
			return errors.New("move-pane: can't reorder past a floating pane")
		}
	}
	_, err = c.run(bubble(swapPane, column(rows, 0), from, to, activeOf(rows, 2))...)
	return err
}

// bubble returns the swaps that move ids[from] to position to, each with its
// neighbour. The active id always goes in -s so it stays active.
func bubble(swap []string, ids []string, from, to int, active string) []string {
	step := 1
	if to < from {
		step = -1
	}
	var args []string
	for i := from; i != to; i += step {
		if len(args) > 0 {
			args = append(args, cmdSep)
		}
		src, dst := ids[from], ids[i+step]
		if dst == active {
			src, dst = dst, src
		}
		args = append(append(args, swap...), "-s", src, "-t", dst)
	}
	return args
}

func column(rows [][]string, col int) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r[col]
	}
	return out
}

func (c *Client) BreakPane(paneID, name string) (string, error) {
	// Without -t the new window lands in tmux's current session, which from a
	// popup is the popup's, not the pane's.
	rows, err := c.rows(1, "display-message", "-p", "-t", paneID, "#{session_id}")
	if err != nil {
		return "", err
	}
	if len(rows) != 1 {
		return "", fmt.Errorf("break-pane: can't find pane %s", paneID)
	}
	args := []string{"break-pane", "-d", "-s", paneID, "-t", rows[0][0] + ":", "-P", "-F", "#{window_id}"}
	if name != "" {
		args = append(args, "-n", name)
	}
	out, err := c.run(args...)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(out), nil
}

// JoinPane splits the destination window's active pane, or its first tiled
// pane when the active one is floating (tmux can't split those).
func (c *Client) JoinPane(srcPaneID, dstWindowID string, horizontal bool) error {
	rows, err := c.windowPanes(dstWindowID)
	if err != nil {
		return err
	}
	target := ""
	for _, r := range rows {
		if r[3] != "1" && (target == "" || r[2] == "1") {
			target = r[0]
		}
	}
	if target == "" {
		return fmt.Errorf("join-pane: window %s has no tiled pane", dstWindowID)
	}
	dir := "-v"
	if horizontal {
		dir = "-h"
	}
	_, err = c.run("join-pane", "-d", dir, "-s", srcPaneID, "-t", target)
	return err
}

func (c *Client) KillPane(paneID string) error {
	_, err := c.run("kill-pane", "-t", paneID)
	return err
}

func (c *Client) ToggleZoom(paneID string) error {
	_, err := c.run("resize-pane", "-Z", "-t", paneID)
	return err
}

func (c *Client) SetPaneTitle(paneID, title string) error {
	// tmux silently ignores such titles.
	if strings.ContainsFunc(title, isControl) {
		return errors.New("select-pane: title contains control characters")
	}
	_, err := c.run("select-pane", "-t", paneID, "-T", escapeFormat(title))
	return err
}

const windowRowFormat = "#{window_id}" + sep + "#{window_index}" + sep + "#{window_active}" + sep +
	"#{window_last_flag}" + sep + "#{session_id}"

// sessionWindows lists the windows of the session holding target as rows
// of (id, index, active, last, session).
func (c *Client) sessionWindows(target string) ([][]string, error) {
	return c.rows(5, "list-windows", "-t", target, "-F", windowRowFormat)
}

// windowChange runs a window swap/move and then puts the session's current
// and last windows back if tmux changed them: swap-window can change the
// current window even with -d (seen on tmux 3.8), and moving a window drops
// it from the last-window stack. Re-selecting only on change avoids clearing
// alert flags needlessly.
func (c *Client) windowChange(before [][]string, args ...string) error {
	if _, err := c.run(args...); err != nil {
		return err
	}
	if len(before) == 0 {
		return nil
	}
	after, err := c.sessionWindows(before[0][4])
	if err != nil {
		return err
	}
	cur, last := activeOf(before, 2), activeOf(before, 3)
	if cur == activeOf(after, 2) && last == activeOf(after, 3) {
		return nil
	}
	var fix []string
	if last != "" {
		fix = append(fix, "select-window", "-t", last, cmdSep)
	}
	if cur != "" {
		fix = append(fix, "select-window", "-t", cur)
	}
	if len(fix) == 0 {
		return nil
	}
	_, err = c.run(fix...)
	return err
}

func (c *Client) SwapWindows(srcID, dstID string) error {
	rows, err := c.sessionWindows(srcID)
	if err != nil {
		return err
	}
	return c.windowChange(rows, "swap-window", "-d", "-s", srcID, "-t", dstID)
}

// MoveWindow moves a window to index within its session. A free index is a
// plain move; an occupied one shifts the windows in between by one slot.
func (c *Client) MoveWindow(windowID string, index int) error {
	if index < 0 {
		return fmt.Errorf("move-window: invalid index %d", index)
	}
	rows, err := c.sessionWindows(windowID)
	if err != nil {
		return err
	}
	from, to := -1, -1
	for i, r := range rows {
		if r[0] == windowID {
			from = i
		}
		if r[1] == strconv.Itoa(index) {
			to = i
		}
	}
	if from < 0 {
		return fmt.Errorf("move-window: window %s not found", windowID)
	}
	if from == to {
		return nil
	}
	if to < 0 {
		return c.windowChange(rows, "move-window", "-d", "-s", windowID, "-t", rows[from][4]+":"+strconv.Itoa(index))
	}
	return c.windowChange(rows, bubble([]string{"swap-window", "-d"}, column(rows, 0), from, to, activeOf(rows, 2))...)
}

func (c *Client) RenameWindow(windowID, name string) error {
	_, err := c.run("rename-window", "-t", windowID, "--", escapeFormat(name))
	return err
}

func (c *Client) KillWindow(windowID string) error {
	_, err := c.run("kill-window", "-t", windowID)
	return err
}

func (c *Client) SelectLayout(windowID, layout string) error {
	_, err := c.run("select-layout", "-t", windowID, layout)
	return err
}

func (c *Client) RenumberWindows(sessionID string) error {
	_, err := c.run("move-window", "-r", "-t", sessionID)
	return err
}

func (c *Client) RenameSession(sessionID, name string) error {
	_, err := c.run("rename-session", "-t", sessionID, "--", escapeFormat(name))
	return err
}

func (c *Client) KillSession(sessionID string) error {
	_, err := c.run("kill-session", "-t", sessionID)
	return err
}

// Focus makes a pane, window or session current. The select-* commands run
// first so they take effect even if switch-client fails (no attached client).
func (c *Client) Focus(target string) error {
	var args []string
	switch {
	case strings.HasPrefix(target, "%"):
		args = []string{"select-pane", "-t", target, cmdSep, "select-window", "-t", target, cmdSep}
	case strings.HasPrefix(target, "@"):
		args = []string{"select-window", "-t", target, cmdSep}
	case strings.HasPrefix(target, "$"):
	default:
		return fmt.Errorf("focus: invalid target %q", target)
	}
	_, err := c.run(append(args, "switch-client", "-t", target)...)
	return err
}

func isControl(r rune) bool { return r < 0x20 || r == 0x7f }
