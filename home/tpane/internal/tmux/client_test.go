package tmux

import (
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// newServer starts a private tmux server on its own -L socket and kills it
// (and only it) when the test ends. It never touches the user's server.
func newServer(t *testing.T) *Client {
	t.Helper()
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not on PATH")
	}
	name := fmt.Sprintf("tpane-test-%d-%x", os.Getpid(), rand.Uint64())
	c := NewSocket(name)
	if c.global[0] != "-L" || c.global[1] != name {
		t.Fatalf("NewSocket args %v", c.global)
	}
	for _, kv := range c.env {
		if strings.HasPrefix(kv, "TMUX=") || strings.HasPrefix(kv, "TMUX_PANE=") {
			t.Fatalf("NewSocket env still has %s", kv)
		}
	}
	c.global = append(c.global, "-f", "/dev/null")
	// A plain sh keeps the user's shell config out of the panes.
	c.env = append(slices.DeleteFunc(c.env, func(kv string) bool { return strings.HasPrefix(kv, "SHELL=") }), "SHELL=/bin/sh")
	var sock string
	t.Cleanup(func() {
		c.run("kill-server")
		if sock != "" {
			os.Remove(sock) // tmux leaves the socket file behind
		}
	})
	if _, err := c.run("new-session", "-d", "-s", "main", "-x", "200", "-y", "50", "sleep 3600"); err != nil {
		t.Fatal(err)
	}
	sock = out(t, c, "display-message", "-p", "#{socket_path}")
	return c
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func out(t *testing.T, c *Client, args ...string) string {
	t.Helper()
	s, err := c.run(args...)
	must(t, err)
	return strings.TrimSpace(s)
}

func split(t *testing.T, c *Client, target string, flags ...string) string {
	t.Helper()
	args := append([]string{"split-window", "-d", "-P", "-F", "#{pane_id}", "-t", target}, flags...)
	return out(t, c, append(args, "sleep 3600")...)
}

func newWindow(t *testing.T, c *Client, flags ...string) string {
	t.Helper()
	args := append([]string{"new-window", "-d", "-P", "-F", "#{window_id}"}, flags...)
	return out(t, c, append(args, "sleep 3600")...)
}

func tree(t *testing.T, c *Client) []Session {
	t.Helper()
	s, err := c.Tree()
	must(t, err)
	return s
}

func findWindow(t *testing.T, c *Client, id string) Window {
	t.Helper()
	for _, s := range tree(t, c) {
		for _, w := range s.Windows {
			if w.ID == id {
				return w
			}
		}
	}
	t.Fatalf("window %s not found", id)
	return Window{}
}

func findPane(t *testing.T, c *Client, id string) Pane {
	t.Helper()
	for _, s := range tree(t, c) {
		for _, w := range s.Windows {
			for _, p := range w.Panes {
				if p.ID == id {
					return p
				}
			}
		}
	}
	t.Fatalf("pane %s not found", id)
	return Pane{}
}

func paneOrder(w Window) []string {
	var ids []string
	for _, p := range w.Panes {
		ids = append(ids, p.ID)
	}
	return ids
}

func windowOrder(t *testing.T, c *Client, session string) []string {
	t.Helper()
	var ids []string
	for _, s := range tree(t, c) {
		if s.ID == session {
			for _, w := range s.Windows {
				ids = append(ids, fmt.Sprintf("%d%s", w.Index, w.ID))
			}
		}
	}
	return ids
}

// eventually retries until the pane's output has been processed by tmux.
func eventually(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("condition not met in time")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestCurrentAndTree(t *testing.T) {
	c := newServer(t)
	loc, err := c.Current()
	must(t, err)
	if !strings.HasPrefix(loc.SessionID, "$") || !strings.HasPrefix(loc.WindowID, "@") || !strings.HasPrefix(loc.PaneID, "%") {
		t.Fatalf("Current = %+v", loc)
	}
	ss := tree(t, c)
	if len(ss) != 1 || ss[0].ID != loc.SessionID || ss[0].Name != "main" || ss[0].Attached {
		t.Fatalf("Tree = %+v", ss)
	}
	w := ss[0].Windows[0]
	if w.ID != loc.WindowID || !w.Active || w.Width != 200 || w.Height != 50 || w.Layout == "" {
		t.Errorf("window = %+v", w)
	}
	p := w.Panes[0]
	if p.ID != loc.PaneID || !p.Active || p.PID <= 0 || p.Width != 200 || p.Height != 50 {
		t.Errorf("pane = %+v", p)
	}
	eventually(t, func() bool { return findPane(t, c, p.ID).Command == "sleep" })
}

func TestTreeOddNames(t *testing.T) {
	c := newServer(t)
	loc, err := c.Current()
	must(t, err)
	dir := filepath.Join(t.TempDir(), "a b:c\td\x1fe\nf ü")
	must(t, os.Mkdir(dir, 0o755))
	p2 := split(t, c, loc.PaneID, "-c", dir)

	sessName := `my sess: 日本 ü #S; a\b`
	winName := `-w: a  b #{pane_id} ##; c\\d`
	title := `t:i té #W #{x} 100%; e\f;`
	must(t, c.RenameSession(loc.SessionID, sessName))
	must(t, c.RenameWindow(loc.WindowID, winName))
	must(t, c.SetPaneTitle(p2, title))

	ss := tree(t, c)
	if ss[0].Name != sessName {
		t.Errorf("session name %q, want %q", ss[0].Name, sessName)
	}
	w := ss[0].Windows[0]
	if w.Name != winName {
		t.Errorf("window name %q, want %q", w.Name, winName)
	}
	p := w.Panes[1]
	if p.ID != p2 || p.Title != title {
		t.Errorf("pane %s title %q, want %q", p.ID, p.Title, title)
	}
	if want := strings.NewReplacer("\t", "?", "\x1f", "?", "\n", "?").Replace(dir); p.Path != want {
		t.Errorf("path %q, want %q", p.Path, want)
	}
	if err := c.SetPaneTitle(p2, "bad\ttitle"); err == nil {
		t.Error("control characters in title accepted")
	}
}

func TestCapture(t *testing.T) {
	c := newServer(t)
	id := out(t, c, "new-window", "-d", "-P", "-F", "#{pane_id}", `printf 'hello\n\033[31mred\033[0m\n\033[7m  \033[0m\n\n\n'; sleep 3600`)
	var got string
	eventually(t, func() bool {
		var err error
		got, err = c.Capture(id)
		must(t, err)
		return strings.Contains(got, "\x1b[7m")
	})
	if !strings.HasPrefix(got, "hello\n") || !strings.Contains(got, "\x1b[31mred") || !strings.Contains(got, "\x1b[7m  ") {
		t.Errorf("capture lacks text/ANSI: %q", got)
	}
	if strings.HasSuffix(got, "\n") || strings.TrimSpace(got) != got {
		t.Errorf("trailing blank lines not trimmed: %q", got)
	}
	if _, err := c.Capture("%999"); err == nil || !strings.Contains(err.Error(), "can't find pane") {
		t.Errorf("Capture(missing) err = %v", err)
	}
}

func TestDeadPane(t *testing.T) {
	c := newServer(t)
	out(t, c, "set-option", "-g", "remain-on-exit", "on")
	id := out(t, c, "new-window", "-d", "-P", "-F", "#{pane_id}", "true")
	eventually(t, func() bool { return findPane(t, c, id).Dead })
}

func TestSwapPanes(t *testing.T) {
	c := newServer(t)
	loc, _ := c.Current()
	a, b := loc.PaneID, split(t, c, loc.PaneID)
	must(t, c.SwapPanes(a, b))
	if got := paneOrder(findWindow(t, c, loc.WindowID)); !slices.Equal(got, []string{b, a}) {
		t.Errorf("after swap %v", got)
	}
	// a is active; swapping with it as the target must not move focus to b.
	must(t, c.SwapPanes(b, a))
	if got := paneOrder(findWindow(t, c, loc.WindowID)); !slices.Equal(got, []string{a, b}) {
		t.Errorf("after swap back %v", got)
	}
	if !findPane(t, c, a).Active || findPane(t, c, b).Active {
		t.Error("SwapPanes moved the active pane")
	}
	other := newWindow(t, c)
	o := findWindow(t, c, other).Panes[0].ID
	must(t, c.SwapPanes(a, o))
	if got := paneOrder(findWindow(t, c, loc.WindowID)); !slices.Equal(got, []string{o, b}) {
		t.Errorf("cross-window swap: %v", got)
	}
	if got := paneOrder(findWindow(t, c, other)); !slices.Equal(got, []string{a}) {
		t.Errorf("cross-window swap other: %v", got)
	}
	if err := c.SwapPanes(a, "%999"); err == nil || !strings.Contains(err.Error(), "find pane") {
		t.Errorf("swap with missing pane: %v", err)
	}
}

func TestMovePane(t *testing.T) {
	c := newServer(t)
	loc, _ := c.Current()
	a := loc.PaneID
	b := split(t, c, a)
	cc := split(t, c, b)
	d := split(t, c, cc)
	order := func() []string { return paneOrder(findWindow(t, c, loc.WindowID)) }
	if got := order(); !slices.Equal(got, []string{a, b, cc, d}) {
		t.Fatalf("setup order %v", got)
	}
	activeBefore := findPane(t, c, a).Active

	must(t, c.MovePane(a, 2))
	if got := order(); !slices.Equal(got, []string{b, cc, a, d}) {
		t.Errorf("move right: %v", got)
	}
	must(t, c.MovePane(d, 0))
	if got := order(); !slices.Equal(got, []string{d, b, cc, a}) {
		t.Errorf("move left: %v", got)
	}
	must(t, c.MovePane(b, 1))
	if got := order(); !slices.Equal(got, []string{d, b, cc, a}) {
		t.Errorf("no-op move: %v", got)
	}
	if findPane(t, c, a).Active != activeBefore {
		t.Error("MovePane changed the active pane")
	}
	for _, bad := range []int{4, -1, 99} {
		if err := c.MovePane(a, bad); err == nil {
			t.Errorf("MovePane(%d) succeeded", bad)
		}
	}
	if err := c.MovePane("%999", 0); err == nil {
		t.Error("MovePane(missing) succeeded")
	}
}

func TestBreakAndJoinPane(t *testing.T) {
	c := newServer(t)
	loc, _ := c.Current()
	a := loc.PaneID
	b := split(t, c, a)
	cc := split(t, c, b)

	w, err := c.BreakPane(b, "broken #S;")
	must(t, err)
	if !strings.HasPrefix(w, "@") || w == loc.WindowID {
		t.Fatalf("BreakPane returned %q", w)
	}
	bw := findWindow(t, c, w)
	if bw.Name != "broken #S;" || !slices.Equal(paneOrder(bw), []string{b}) || bw.Active {
		t.Errorf("broken window %+v", bw)
	}
	w2, err := c.BreakPane(cc, "")
	must(t, err)
	if w2 == w || !slices.Equal(paneOrder(findWindow(t, c, w2)), []string{cc}) {
		t.Errorf("unnamed break: %s", w2)
	}
	if !slices.Equal(paneOrder(findWindow(t, c, loc.WindowID)), []string{a}) {
		t.Error("source window still holds broken panes")
	}

	must(t, c.JoinPane(b, loc.WindowID, true))
	pa, pb := findPane(t, c, a), findPane(t, c, b)
	if pb.WindowID != loc.WindowID || pa.Top != pb.Top || pa.Left == pb.Left {
		t.Errorf("horizontal join not side by side: a=%+v b=%+v", pa, pb)
	}
	if !pa.Active {
		t.Error("join changed the active pane")
	}
	// join-pane splits the target window's active pane, which is still a.
	must(t, c.JoinPane(cc, loc.WindowID, false))
	pa, pc := findPane(t, c, a), findPane(t, c, cc)
	if pc.WindowID != loc.WindowID || pc.Left != pa.Left || pc.Top == pa.Top {
		t.Errorf("vertical join not stacked: a=%+v c=%+v", pa, pc)
	}
	if err := c.JoinPane("%999", loc.WindowID, true); err == nil {
		t.Error("join of missing pane succeeded")
	}
}

func TestBreakPaneStaysInItsSession(t *testing.T) {
	c := newServer(t)
	loc, _ := c.Current()
	b := split(t, c, loc.PaneID)
	alone := findPane(t, c, out(t, c, "new-window", "-d", "-P", "-F", "#{pane_id}", "sleep 3600"))
	// Created last, so it is tmux's "current" session, as a popup's would be.
	out(t, c, "new-session", "-d", "-s", "zz-other", "sleep 3600")

	for _, p := range []string{b, alone.ID} {
		w, err := c.BreakPane(p, "")
		must(t, err)
		if got := findWindow(t, c, w).SessionID; got != loc.SessionID {
			t.Errorf("BreakPane(%s) put window %s in %s, want %s", p, w, got, loc.SessionID)
		}
	}
}

func TestKillPaneZoomTitle(t *testing.T) {
	c := newServer(t)
	loc, _ := c.Current()
	a := loc.PaneID
	b := split(t, c, a, "-h")
	before := findPane(t, c, b)

	must(t, c.ToggleZoom(b))
	w := findWindow(t, c, loc.WindowID)
	if !w.Zoomed {
		t.Fatal("window not zoomed")
	}
	if z := findPane(t, c, b); z.Width != before.Width || z.Left != before.Left || z.Height != before.Height {
		t.Errorf("zoomed geometry %+v, want unzoomed %+v", z, before)
	}
	must(t, c.ToggleZoom(b))
	if findWindow(t, c, loc.WindowID).Zoomed {
		t.Error("window still zoomed")
	}

	must(t, c.SetPaneTitle(a, "hello world"))
	if got := findPane(t, c, a).Title; got != "hello world" {
		t.Errorf("title %q", got)
	}

	must(t, c.KillPane(b))
	if !slices.Equal(paneOrder(findWindow(t, c, loc.WindowID)), []string{a}) {
		t.Error("pane not killed")
	}
	if err := c.KillPane(b); err == nil {
		t.Error("killing a dead pane id succeeded")
	}
}

func TestSwapAndMoveWindows(t *testing.T) {
	c := newServer(t)
	loc, _ := c.Current()
	w0 := loc.WindowID
	w1 := newWindow(t, c)
	w2 := newWindow(t, c)
	w5 := newWindow(t, c, "-t", ":5")
	s := loc.SessionID
	if got := windowOrder(t, c, s); !slices.Equal(got, []string{"0" + w0, "1" + w1, "2" + w2, "5" + w5}) {
		t.Fatalf("setup %v", got)
	}
	out(t, c, "select-window", "-t", w1)
	out(t, c, "select-window", "-t", w0)
	kept := func(what string) {
		t.Helper()
		if cur, last := currentAndLast(t, c); cur != w0 || last != w1 {
			t.Errorf("%s: current/last window %s/%s, want %s/%s", what, cur, last, w0, w1)
		}
	}

	must(t, c.SwapWindows(w0, w2))
	if got := windowOrder(t, c, s); !slices.Equal(got, []string{"0" + w2, "1" + w1, "2" + w0, "5" + w5}) {
		t.Errorf("swap: %v", got)
	}
	must(t, c.SwapWindows(w1, w0)) // current window as the target
	if got := windowOrder(t, c, s); !slices.Equal(got, []string{"0" + w2, "1" + w0, "2" + w1, "5" + w5}) {
		t.Errorf("swap to current: %v", got)
	}
	must(t, c.SwapWindows(w1, w0))
	kept("SwapWindows")

	must(t, c.MoveWindow(w1, 3)) // free index
	if got := windowOrder(t, c, s); !slices.Equal(got, []string{"0" + w2, "2" + w0, "3" + w1, "5" + w5}) {
		t.Errorf("move to free: %v", got)
	}
	kept("MoveWindow free")
	must(t, c.MoveWindow(w5, 0)) // occupied, leftwards through gaps
	if got := windowOrder(t, c, s); !slices.Equal(got, []string{"0" + w5, "2" + w2, "3" + w0, "5" + w1}) {
		t.Errorf("move left: %v", got)
	}
	kept("MoveWindow left")
	must(t, c.MoveWindow(w5, 3)) // occupied, rightwards
	if got := windowOrder(t, c, s); !slices.Equal(got, []string{"0" + w2, "2" + w0, "3" + w5, "5" + w1}) {
		t.Errorf("move right: %v", got)
	}
	must(t, c.MoveWindow(w5, 3)) // no-op
	if got := windowOrder(t, c, s); !slices.Equal(got, []string{"0" + w2, "2" + w0, "3" + w5, "5" + w1}) {
		t.Errorf("no-op move: %v", got)
	}
	kept("MoveWindow")
	if err := c.MoveWindow(w5, -1); err == nil {
		t.Error("negative index accepted")
	}
	if err := c.MoveWindow("@999", 1); err == nil {
		t.Error("missing window accepted")
	}

	must(t, c.RenumberWindows(s))
	if got := windowOrder(t, c, s); !slices.Equal(got, []string{"0" + w2, "1" + w0, "2" + w5, "3" + w1}) {
		t.Errorf("renumber: %v", got)
	}
}

func TestWindowAndSessionOps(t *testing.T) {
	c := newServer(t)
	loc, _ := c.Current()
	w := loc.WindowID
	split(t, c, loc.PaneID)
	split(t, c, loc.PaneID)

	must(t, c.SelectLayout(w, "even-horizontal"))
	for _, p := range findWindow(t, c, w).Panes {
		if p.Top != 0 || p.Height != 50 {
			t.Errorf("even-horizontal pane %+v", p)
		}
	}
	must(t, c.SelectLayout(w, "even-vertical"))
	for _, p := range findWindow(t, c, w).Panes {
		if p.Left != 0 || p.Width != 200 {
			t.Errorf("even-vertical pane %+v", p)
		}
	}
	if err := c.SelectLayout(w, "bogus"); err == nil {
		t.Error("bogus layout accepted")
	}

	must(t, c.RenameWindow(w, "renamed"))
	if got := findWindow(t, c, w).Name; got != "renamed" {
		t.Errorf("window name %q", got)
	}
	other := newWindow(t, c)
	must(t, c.KillWindow(other))
	if len(tree(t, c)[0].Windows) != 1 {
		t.Error("window not killed")
	}

	out(t, c, "new-session", "-d", "-s", "second", "sleep 3600")
	ss := tree(t, c)
	if len(ss) != 2 || ss[0].Name != "main" || ss[1].Name != "second" {
		t.Fatalf("sessions %+v", ss)
	}
	sec := ss[1].ID
	must(t, c.RenameSession(sec, "-a first"))
	ss = tree(t, c)
	if ss[0].ID != sec || ss[0].Name != "-a first" {
		t.Errorf("rename/sort: %+v", ss)
	}
	must(t, c.KillSession(sec))
	if ss = tree(t, c); len(ss) != 1 || ss[0].ID != loc.SessionID {
		t.Errorf("session not killed: %+v", ss)
	}
	if err := c.KillSession(sec); err == nil || !strings.Contains(err.Error(), "kill-session") {
		t.Errorf("killing missing session err = %v", err)
	}
}

func TestFocus(t *testing.T) {
	c := newServer(t)
	loc, _ := c.Current()
	w := newWindow(t, c)
	p1 := findWindow(t, c, w).Panes[0].ID
	p2 := split(t, c, p1)
	if findWindow(t, c, w).Active || findPane(t, c, p2).Active {
		t.Fatal("setup: target already current")
	}

	// No client is attached, so switch-client fails; the selection still happens.
	if err := c.Focus(p2); err != nil && strings.HasPrefix(err.Error(), "select-pane") {
		t.Errorf("chain error labelled with the first command: %v", err)
	}
	if !findWindow(t, c, w).Active || !findPane(t, c, p2).Active || findPane(t, c, p1).Active {
		t.Error("Focus(pane) did not select its window and pane")
	}
	_ = c.Focus(loc.WindowID)
	if !findWindow(t, c, loc.WindowID).Active || findWindow(t, c, w).Active {
		t.Error("Focus(window) did not select it")
	}
	if err := c.Focus(loc.SessionID); err == nil || !strings.Contains(err.Error(), "client") {
		t.Errorf("Focus(session) without a client: %v", err)
	}
	if err := c.Focus("bogus"); err == nil {
		t.Error("invalid target accepted")
	}
}

func currentAndLast(t *testing.T, c *Client) (cur, last string) {
	t.Helper()
	for line := range strings.Lines(out(t, c, "list-windows", "-F", "#{window_id} #{window_active} #{window_last_flag}")) {
		f := strings.Fields(line)
		if f[1] == "1" {
			cur = f[0]
		}
		if f[2] == "1" {
			last = f[0]
		}
	}
	return cur, last
}

func TestFloatingAndZoom(t *testing.T) {
	c := newServer(t)
	loc, _ := c.Current()
	a := loc.PaneID
	b := split(t, c, a, "-h")
	fl := out(t, c, "new-pane", "-P", "-F", "#{pane_id}", "-t", loc.WindowID, "sleep 3600")
	if !findPane(t, c, fl).Active {
		t.Fatal("setup: floating pane not active")
	}
	order := paneOrder(findWindow(t, c, loc.WindowID))
	if order[len(order)-1] != fl {
		t.Fatalf("setup: floating pane not last: %v", order)
	}

	if err := c.MovePane(a, findPane(t, c, fl).Index); err == nil {
		t.Error("MovePane onto a floating pane succeeded")
	}
	if err := c.SwapPanes(b, fl); err == nil {
		t.Error("SwapPanes tiled<->floating succeeded")
	}

	// pane_floating_flag reads 0 in a zoomed window; the guards must still hold.
	must(t, c.ToggleZoom(fl))
	if err := c.MovePane(a, findPane(t, c, fl).Index); err == nil {
		t.Error("zoomed: MovePane onto a floating pane succeeded")
	}
	if err := c.SwapPanes(b, fl); err == nil {
		t.Error("zoomed: SwapPanes tiled<->floating succeeded")
	}
	other := newWindow(t, c)
	o := findWindow(t, c, other).Panes[0].ID
	must(t, c.JoinPane(o, loc.WindowID, true)) // active pane is floating
	if p := findPane(t, c, o); p.WindowID != loc.WindowID {
		t.Errorf("join into window with floating active pane: %+v", p)
	}
	if !slices.Equal(paneOrder(findWindow(t, c, loc.WindowID)), []string{a, b, o, fl}) &&
		!slices.Equal(paneOrder(findWindow(t, c, loc.WindowID)), []string{a, o, b, fl}) {
		t.Errorf("join order %v", paneOrder(findWindow(t, c, loc.WindowID)))
	}

	must(t, c.KillPane(fl))
	must(t, c.ToggleZoom(b))
	must(t, c.MovePane(a, findPane(t, c, b).Index))
	must(t, c.SwapPanes(a, o))
	if !findWindow(t, c, loc.WindowID).Zoomed {
		t.Error("reordering unzoomed the window")
	}
}
