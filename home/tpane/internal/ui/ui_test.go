package ui

import (
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"

	"tpane/internal/tmux"
)

// fake is an in-memory tmux server good enough to observe the UI's calls and
// to make the tree change the way tmux would.
type fake struct {
	mu       sync.Mutex
	sessions []tmux.Session
	calls    []string
	fail     map[string]error // method name → error
	nextWin  int
}

func newFake() *fake {
	pane := func(id, cmd, path string, active bool) tmux.Pane {
		return tmux.Pane{ID: id, Command: cmd, Path: path, Active: active, Width: 80, Height: 24, PID: 100}
	}
	f := &fake{fail: map[string]error{}, nextWin: 10}
	f.sessions = []tmux.Session{
		{ID: "$3", Name: "aaa", Windows: []tmux.Window{
			{ID: "@4", Index: 0, Name: "x", Active: true, Panes: []tmux.Pane{pane("%7", "vim", "/tmp", true)}},
		}},
		{ID: "$1", Name: "main", Attached: true, Windows: []tmux.Window{
			{ID: "@1", Index: 0, Name: "editor", Active: true, Width: 160, Height: 40, Panes: []tmux.Pane{
				pane("%1", "nvim", "/src", true), pane("%2", "fish", "/src", false), pane("%3", "htop", "/", false),
			}},
			{ID: "@2", Index: 1, Name: "shell", Panes: []tmux.Pane{pane("%4", "fish", "/home", true)}},
		}},
		{ID: "$2", Name: "work", Windows: []tmux.Window{
			{ID: "@3", Index: 0, Name: "logs", Active: true, Panes: []tmux.Pane{
				pane("%5", "tail", "/var/log", true), pane("%6", "less", "/var/log", false),
			}},
		}},
	}
	f.fix()
	return f
}

// fix restores the invariants Tree() promises: ids of parents, pane indexes.
func (f *fake) fix() {
	for si := range f.sessions {
		s := &f.sessions[si]
		for wi := range s.Windows {
			w := &s.Windows[wi]
			w.SessionID = s.ID
			for pi := range w.Panes {
				w.Panes[pi].Index = pi
				w.Panes[pi].WindowID = w.ID
				w.Panes[pi].SessionID = s.ID
			}
		}
		slices.SortFunc(s.Windows, func(a, b tmux.Window) int { return a.Index - b.Index })
	}
}

func (f *fake) record(name string, args ...any) error {
	f.calls = append(f.calls, strings.TrimSpace(name+" "+fmt.Sprintln(args...)))
	return f.fail[name]
}

func (f *fake) Calls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, c := range f.calls {
		if !strings.HasPrefix(c, "Tree") && !strings.HasPrefix(c, "Capture") {
			out = append(out, c)
		}
	}
	return out
}

func (f *fake) count(prefix string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.calls {
		if strings.HasPrefix(c, prefix) {
			n++
		}
	}
	return n
}

func (f *fake) locPane(id string) (si, wi, pi int) {
	for si, s := range f.sessions {
		for wi, w := range s.Windows {
			for pi, p := range w.Panes {
				if p.ID == id {
					return si, wi, pi
				}
			}
		}
	}
	panic("no pane " + id)
}

func (f *fake) locWindow(id string) (si, wi int) {
	for si, s := range f.sessions {
		for wi, w := range s.Windows {
			if w.ID == id {
				return si, wi
			}
		}
	}
	panic("no window " + id)
}

func (f *fake) removePane(id string) tmux.Pane {
	si, wi, pi := f.locPane(id)
	w := &f.sessions[si].Windows[wi]
	p := w.Panes[pi]
	w.Panes = slices.Delete(w.Panes, pi, pi+1)
	if len(w.Panes) == 0 {
		f.sessions[si].Windows = slices.Delete(f.sessions[si].Windows, wi, wi+1)
	}
	return p
}

func (f *fake) Tree() ([]tmux.Session, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.record("Tree"); err != nil {
		return nil, err
	}
	// Deep copy, so the UI never shares memory with the fake.
	out := slices.Clone(f.sessions)
	for i := range out {
		out[i].Windows = slices.Clone(out[i].Windows)
		for j := range out[i].Windows {
			out[i].Windows[j].Panes = slices.Clone(out[i].Windows[j].Panes)
		}
	}
	return out, nil
}

func (f *fake) Capture(id string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return "\x1b[32m$\x1b[0m " + id + "\nline two\n", f.record("Capture", id)
}

func (f *fake) SwapPanes(a, b string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.record("SwapPanes", a, b); err != nil {
		return err
	}
	as, aw, ap := f.locPane(a)
	bs, bw, bp := f.locPane(b)
	pa, pb := &f.sessions[as].Windows[aw].Panes[ap], &f.sessions[bs].Windows[bw].Panes[bp]
	*pa, *pb = *pb, *pa
	f.fix()
	return nil
}

func (f *fake) MovePane(id string, idx int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.record("MovePane", id, idx); err != nil {
		return err
	}
	si, wi, pi := f.locPane(id)
	w := &f.sessions[si].Windows[wi]
	if idx >= len(w.Panes) {
		return errors.New("index out of range")
	}
	p := w.Panes[pi]
	w.Panes = slices.Insert(slices.Delete(w.Panes, pi, pi+1), idx, p)
	f.fix()
	return nil
}

func (f *fake) BreakPane(id, name string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.record("BreakPane", id, fmt.Sprintf("%q", name)); err != nil {
		return "", err
	}
	si, _, _ := f.locPane(id)
	p := f.removePane(id)
	f.nextWin++
	wid := fmt.Sprintf("@%d", f.nextWin)
	s := &f.sessions[si]
	idx := 0
	for _, w := range s.Windows {
		idx = max(idx, w.Index+1)
	}
	if name == "" {
		name = p.Command
	}
	s.Windows = append(s.Windows, tmux.Window{ID: wid, Index: idx, Name: name, Panes: []tmux.Pane{p}})
	f.fix()
	return wid, nil
}

func (f *fake) JoinPane(src, dst string, horizontal bool) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.record("JoinPane", src, dst, horizontal); err != nil {
		return err
	}
	p := f.removePane(src)
	si, wi := f.locWindow(dst)
	p.Active = false
	f.sessions[si].Windows[wi].Panes = append(f.sessions[si].Windows[wi].Panes, p)
	f.fix()
	return nil
}

func (f *fake) KillPane(id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.record("KillPane", id); err != nil {
		return err
	}
	f.removePane(id)
	f.fix()
	return nil
}

func (f *fake) ToggleZoom(id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.record("ToggleZoom", id)
}

func (f *fake) SetPaneTitle(id, title string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.record("SetPaneTitle", id, fmt.Sprintf("%q", title))
}

func (f *fake) SwapWindows(a, b string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.record("SwapWindows", a, b); err != nil {
		return err
	}
	as, aw := f.locWindow(a)
	bs, bw := f.locWindow(b)
	wa, wb := &f.sessions[as].Windows[aw], &f.sessions[bs].Windows[bw]
	wa.Index, wb.Index = wb.Index, wa.Index
	f.fix()
	return nil
}

func (f *fake) MoveWindow(id string, idx int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.record("MoveWindow", id, idx); err != nil {
		return err
	}
	si, wi := f.locWindow(id)
	f.sessions[si].Windows[wi].Index = idx
	f.fix()
	return nil
}

func (f *fake) RenameWindow(id, name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.record("RenameWindow", id, fmt.Sprintf("%q", name)); err != nil {
		return err
	}
	si, wi := f.locWindow(id)
	f.sessions[si].Windows[wi].Name = name
	return nil
}

func (f *fake) KillWindow(id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.record("KillWindow", id); err != nil {
		return err
	}
	si, wi := f.locWindow(id)
	f.sessions[si].Windows = slices.Delete(f.sessions[si].Windows, wi, wi+1)
	return nil
}

func (f *fake) SelectLayout(id, layout string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.record("SelectLayout", id, layout)
}

func (f *fake) RenumberWindows(id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.record("RenumberWindows", id)
}

func (f *fake) RenameSession(id, name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.record("RenameSession", id, fmt.Sprintf("%q", name))
}

func (f *fake) KillSession(id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.record("KillSession", id); err != nil {
		return err
	}
	f.sessions = slices.DeleteFunc(f.sessions, func(s tmux.Session) bool { return s.ID == id })
	return nil
}

func (f *fake) Focus(target string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.record("Focus", target)
}

// harness drives a Model synchronously: every Cmd is run to completion and its
// Msg fed back, except timers, which never fire.
type harness struct {
	t    *testing.T
	f    *fake
	m    *Model
	quit bool
}

func start(t *testing.T, origin tmux.Location) *harness {
	t.Helper()
	f := newFake()
	m := New(f, Options{Origin: origin})
	m.home = "/home"
	m.after = func(time.Duration, func(time.Time) tea.Msg) tea.Cmd { return nil }
	h := &harness{t: t, f: f, m: m}
	h.send(tea.WindowSizeMsg{Width: 120, Height: 40})
	h.run(m.Init())
	return h
}

func (h *harness) run(cmd tea.Cmd) {
	pending := []tea.Cmd{cmd}
	for len(pending) > 0 {
		c := pending[0]
		pending = pending[1:]
		if c == nil {
			continue
		}
		switch msg := c().(type) {
		case nil:
		case tea.BatchMsg:
			pending = append(pending, msg...)
		case tea.QuitMsg:
			h.quit = true
		default:
			_, next := h.m.Update(msg)
			pending = append(pending, next)
		}
	}
}

func (h *harness) send(msg tea.Msg) {
	_, cmd := h.m.Update(msg)
	h.run(cmd)
}

func keyMsg(s string) tea.KeyPressMsg {
	switch s {
	case "enter":
		return tea.KeyPressMsg{Code: tea.KeyEnter}
	case "esc":
		return tea.KeyPressMsg{Code: tea.KeyEscape}
	case "tab":
		return tea.KeyPressMsg{Code: tea.KeyTab}
	case "space":
		return tea.KeyPressMsg{Code: tea.KeySpace, Text: " "}
	case "up":
		return tea.KeyPressMsg{Code: tea.KeyUp}
	case "down":
		return tea.KeyPressMsg{Code: tea.KeyDown}
	case "backspace":
		return tea.KeyPressMsg{Code: tea.KeyBackspace}
	}
	if c, ok := strings.CutPrefix(s, "ctrl+"); ok {
		return tea.KeyPressMsg{Code: rune(c[0]), Mod: tea.ModCtrl}
	}
	r := []rune(s)[0]
	return tea.KeyPressMsg{Code: r, Text: s}
}

// keys presses each key in turn, running everything each one triggers.
func (h *harness) keys(ks ...string) {
	for _, k := range ks {
		h.send(keyMsg(k))
	}
}

func (h *harness) typeText(s string) {
	for _, r := range s {
		h.send(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
}

func (h *harness) sel() string {
	h.t.Helper()
	return h.m.selID
}

func (h *harness) rowIDs() []string {
	var ids []string
	for _, r := range h.m.rows {
		ids = append(ids, r.id)
	}
	return ids
}

func (h *harness) goTo(id string) {
	h.t.Helper()
	h.m.reveal(id)
	h.m.rebuild(false)
	i := indexOf(h.m.rows, id)
	if i < 0 {
		h.t.Fatalf("row %s not visible: %v", id, h.rowIDs())
	}
	h.run(h.m.moveTo(i))
}

func (h *harness) wantCalls(want ...string) {
	h.t.Helper()
	got := h.f.Calls()
	if !slices.Equal(got, want) {
		h.t.Fatalf("calls:\n got  %q\n want %q", got, want)
	}
}

func (h *harness) wantSel(id string) {
	h.t.Helper()
	if h.sel() != id {
		h.t.Fatalf("selected %s, want %s (rows %v)", h.sel(), id, h.rowIDs())
	}
	if r := h.m.sel(); r == nil || r.id != id {
		h.t.Fatalf("cursor row is not %s", id)
	}
}

func origin() tmux.Location { return tmux.Location{SessionID: "$1", WindowID: "@1", PaneID: "%2"} }

func TestStartsOnOriginWithOriginSessionFirst(t *testing.T) {
	h := start(t, origin())
	h.wantSel("%2")
	want := []string{"$1", "@1", "%1", "%2", "%3", "@2", "%4", "$3", "$2"}
	if got := h.rowIDs(); !slices.Equal(got, want) {
		t.Fatalf("rows %v, want %v", got, want)
	}
	if h.f.count("Capture %2") == 0 {
		t.Fatal("selected pane was not captured")
	}
}

func TestMissingOriginFallsBack(t *testing.T) {
	h := start(t, tmux.Location{SessionID: "$2", WindowID: "@3", PaneID: "%99"})
	h.wantSel("@3")
	if h.rowIDs()[0] != "$2" {
		t.Fatalf("origin session not first: %v", h.rowIDs())
	}
	h = start(t, tmux.Location{})
	h.wantSel("$3")
}

func TestNavigation(t *testing.T) {
	h := start(t, origin())
	h.keys("j")
	h.wantSel("%3")
	h.keys("k", "k")
	h.wantSel("%1")
	h.keys("G")
	h.wantSel("$2")
	h.keys("g")
	h.wantSel("$1")
	h.keys("down", "down", "up")
	h.wantSel("@1")
}

func TestRepeatedSwapFollowsPane(t *testing.T) {
	h := start(t, tmux.Location{SessionID: "$1", WindowID: "@1", PaneID: "%1"})
	h.keys("J")
	h.wantSel("%1")
	h.keys("J")
	h.wantSel("%1")
	h.keys("J") // at the edge now
	h.wantCalls("SwapPanes %1 %2", "SwapPanes %1 %3")
	if !h.m.flashErr || !strings.Contains(h.m.flash, "last") {
		t.Fatalf("flash %q", h.m.flash)
	}
	if got := h.rowIDs()[2:5]; !slices.Equal(got, []string{"%2", "%3", "%1"}) {
		t.Fatalf("panes %v", got)
	}
	h.keys("K")
	h.wantSel("%1")
	h.wantCalls("SwapPanes %1 %2", "SwapPanes %1 %3", "SwapPanes %1 %3")
	h.goTo("%2")
	h.keys("K")
	h.wantCalls("SwapPanes %1 %2", "SwapPanes %1 %3", "SwapPanes %1 %3")
}

func TestKeysQueuedWhileBusy(t *testing.T) {
	h := start(t, tmux.Location{SessionID: "$1", WindowID: "@1", PaneID: "%1"})
	_, first := h.m.Update(keyMsg("J"))
	_, second := h.m.Update(keyMsg("J"))
	if second != nil {
		t.Fatal("second J ran while the first was in flight")
	}
	h.run(first)
	h.wantCalls("SwapPanes %1 %2", "SwapPanes %1 %3")
	h.wantSel("%1")
}

func TestStaleRefreshIgnored(t *testing.T) {
	h := start(t, origin())
	stale := h.m.refreshCmd()
	h.keys("J") // %2 swaps with %3, newer seq
	before := h.rowIDs()
	h.f.mu.Lock()
	h.f.sessions[1].Windows[0].Panes[0].Command = "changed"
	h.f.mu.Unlock()
	msg := stale().(treeMsg)
	h.send(msg)
	if !slices.Equal(h.rowIDs(), before) || h.m.rows[2].p.Command == "changed" {
		t.Fatal("older refresh replaced a newer tree")
	}
}

func TestCollapseStateSurvivesRefresh(t *testing.T) {
	h := start(t, origin())
	h.keys("h") // pane → its window
	h.wantSel("@1")
	h.keys("h") // collapse
	h.wantSel("@1")
	if slices.Contains(h.rowIDs(), "%1") {
		t.Fatal("window did not collapse")
	}
	h.goTo("$2")
	h.keys("space")
	h.keys("ctrl+r")
	h.send(tickMsg{})
	ids := h.rowIDs()
	if slices.Contains(ids, "%1") || !slices.Contains(ids, "@3") || !slices.Contains(ids, "%5") {
		t.Fatalf("collapse state lost: %v", ids)
	}
	h.wantSel("$2")
	h.keys("l") // already open → first child
	h.wantSel("@3")
	h.keys("tab")
	if slices.Contains(h.rowIDs(), "%5") {
		t.Fatal("tab did not fold the window")
	}
	h.keys("l")
	h.keys("j", "space") // pane row: fold its window, cursor to window
	h.wantSel("@3")
	h.goTo("$3")
	h.keys("l")
	h.keys("h")
	h.wantSel("$3")
	if slices.Contains(h.rowIDs(), "@4") {
		t.Fatal("h did not collapse the session")
	}
}

func TestFilter(t *testing.T) {
	h := start(t, origin())
	h.keys("/")
	h.typeText("TAIL")
	if got := h.rowIDs(); !slices.Equal(got, []string{"$2", "@3", "%5"}) {
		t.Fatalf("rows %v", got)
	}
	h.wantSel("%5")
	h.keys("backspace", "backspace", "backspace", "backspace")
	h.typeText("work")
	if got := h.rowIDs(); !slices.Equal(got, []string{"$2", "@3", "%5", "%6"}) {
		t.Fatalf("session match should show its contents: %v", got)
	}
	h.keys("enter", "j")
	h.wantSel("%6")
	h.keys("esc")
	if h.m.query != "" || h.quit {
		t.Fatal("esc should clear the filter, not quit")
	}
	h.wantSel("%6")
	if !slices.Contains(h.rowIDs(), "%1") {
		t.Fatalf("unfiltered rows not restored: %v", h.rowIDs())
	}
	h.keys("/")
	h.typeText("/var")
	if got := h.rowIDs(); !slices.Equal(got, []string{"$2", "@3", "%5", "%6"}) {
		t.Fatalf("path match: %v", got)
	}
	h.typeText("zzz")
	if len(h.rowIDs()) != 0 {
		t.Fatal("expected no rows")
	}
	h.send(tea.WindowSizeMsg{Width: 120, Height: 40})
	_ = h.m.View()
	h.keys("esc")
	if h.m.filtering || h.m.query != "" || len(h.rowIDs()) == 0 {
		t.Fatal("esc while typing should clear the filter")
	}
	h.keys("esc")
	if !h.quit {
		t.Fatal("esc with nothing to clear should quit")
	}
}

func TestKillConfirm(t *testing.T) {
	h := start(t, origin())
	h.keys("x")
	if h.m.mode != modeConfirm {
		t.Fatal("no confirm")
	}
	h.keys("n")
	h.keys("x", "esc")
	h.wantCalls()
	h.keys("x", "y")
	h.wantCalls("KillPane %2")
	h.wantSel("%3")
	h.goTo("@2")
	h.keys("x", "Y")
	h.goTo("$2")
	h.keys("x", "y")
	h.wantCalls("KillPane %2", "KillWindow @2", "KillSession $2")
	h.wantSel("$3")
}

func TestMarkAndSwap(t *testing.T) {
	h := start(t, origin())
	h.keys("s")
	if h.m.mark != "%2" {
		t.Fatal("not marked")
	}
	h.keys("esc")
	if h.m.mark != "" || h.quit {
		t.Fatal("esc should clear the mark")
	}
	h.keys("s", "s")
	if h.m.mark != "" {
		t.Fatal("s on the marked pane should unmark")
	}
	h.keys("s")
	h.goTo("%5")
	h.keys("s")
	h.wantCalls("SwapPanes %2 %5")
	if h.m.mark != "" {
		t.Fatal("mark not cleared after swap")
	}
	h.wantSel("%5")
	if r := h.m.sel(); r.w.ID != "@1" {
		t.Fatalf("cursor didn't follow %%5 into @1, at %s", r.w.ID)
	}
}

func TestMarkClearedWhenPaneDisappears(t *testing.T) {
	h := start(t, origin())
	h.keys("s")
	h.f.mu.Lock()
	h.f.removePane("%2")
	h.f.mu.Unlock()
	h.keys("ctrl+r")
	if h.m.mark != "" {
		t.Fatal("stale mark kept")
	}
}

func TestPicker(t *testing.T) {
	h := start(t, origin())
	h.keys("m")
	if h.m.mode != modePicker {
		t.Fatal("no picker")
	}
	var labels []string
	for _, p := range h.m.picker.targets {
		labels = append(labels, p.label)
	}
	if want := []string{"main:1 shell", "aaa:0 x", "work:0 logs"}; !slices.Equal(labels, want) {
		t.Fatalf("targets %v, want %v", labels, want)
	}
	h.keys("esc")
	h.wantCalls()
	if h.quit || h.m.mode != modeNormal {
		t.Fatal("esc should only close the picker")
	}
	h.keys("m", "j", "j", "j", "tab", "enter")
	h.wantCalls("JoinPane %2 @3 false")
	h.wantSel("%2")
	if r := h.m.sel(); r.w.ID != "@3" {
		t.Fatalf("cursor not on moved pane in @3: %s", r.w.ID)
	}
	h.keys("m", "enter")
	h.wantCalls("JoinPane %2 @3 false", "JoinPane %2 @1 true")
}

func TestBreak(t *testing.T) {
	h := start(t, origin())
	h.keys("b")
	h.wantCalls(`BreakPane %2 ""`)
	h.wantSel("%2")
	if r := h.m.sel(); r.w.ID == "@1" {
		t.Fatal("pane still in @1")
	}
	h.goTo("%3")
	h.keys("B")
	if h.m.mode != modePrompt || h.m.prompt.input.Value() != "" {
		t.Fatal("break prompt should start empty")
	}
	h.typeText("build")
	h.keys("enter")
	h.wantCalls(`BreakPane %2 ""`, `BreakPane %3 "build"`)
	h.wantSel("%3")
	h.keys("B", "esc")
	h.wantCalls(`BreakPane %2 ""`, `BreakPane %3 "build"`)
}

func TestPaneKeys(t *testing.T) {
	h := start(t, tmux.Location{SessionID: "$1", WindowID: "@1", PaneID: "%1"})
	h.keys("2")
	h.wantSel("%1")
	if r := h.m.sel(); r.p.Index != 2 {
		t.Fatalf("index %d", r.p.Index)
	}
	h.keys("2") // already there: no call
	h.keys("z", "t")
	h.typeText("hi")
	h.keys("enter")
	h.wantCalls("MovePane %1 2", "ToggleZoom %1", `SetPaneTitle %1 "hi"`)
	h.keys("enter")
	h.wantCalls("MovePane %1 2", "ToggleZoom %1", `SetPaneTitle %1 "hi"`, "Focus %1")
	if !h.quit {
		t.Fatal("enter should quit after focusing")
	}
}

func TestWindowKeys(t *testing.T) {
	h := start(t, origin())
	h.goTo("@1")
	h.keys("J")
	h.wantSel("@1")
	h.keys("J")
	h.keys("K")
	h.keys("5", "r")
	if v := h.m.prompt.input.Value(); v != "editor" {
		t.Fatalf("rename not prefilled: %q", v)
	}
	h.typeText("2")
	h.keys("enter")
	h.keys("L", "L", "R")
	h.keys("r", "ctrl+u", "enter") // empty name: refused, no call
	if !h.m.flashErr {
		t.Fatal("empty rename should flash an error")
	}
	h.wantCalls("SwapWindows @1 @2", "SwapWindows @1 @2", "MoveWindow @1 5", `RenameWindow @1 "editor2"`,
		"SelectLayout @1 tiled", "SelectLayout @1 even-horizontal", "RenumberWindows $1")
	h.wantSel("@1")
	h.keys("enter")
	if !h.quit || h.f.Calls()[len(h.f.Calls())-1] != "Focus @1" {
		t.Fatal("enter should focus the window and quit")
	}
}

func TestLayoutCycleWraps(t *testing.T) {
	h := start(t, origin())
	h.goTo("@2")
	h.keys("L", "L", "L", "L", "L", "L")
	h.wantCalls("SelectLayout @2 tiled", "SelectLayout @2 even-horizontal", "SelectLayout @2 even-vertical",
		"SelectLayout @2 main-horizontal", "SelectLayout @2 main-vertical", "SelectLayout @2 tiled")
	if h.m.flash != "layout tiled" {
		t.Fatalf("flash %q", h.m.flash)
	}
}

func TestSessionKeys(t *testing.T) {
	h := start(t, origin())
	h.goTo("$1")
	h.keys("r")
	if v := h.m.prompt.input.Value(); v != "main" {
		t.Fatalf("prefill %q", v)
	}
	h.keys("ctrl+u")
	h.typeText("dev")
	h.keys("enter", "R", "J", "1", "z")
	h.wantCalls(`RenameSession $1 "dev"`, "RenumberWindows $1")
	h.keys("enter")
	h.wantCalls(`RenameSession $1 "dev"`, "RenumberWindows $1", "Focus $1")
	if !h.quit {
		t.Fatal("enter should quit")
	}
}

func TestErrorsFlashAndKeepRunning(t *testing.T) {
	h := start(t, origin())
	h.f.fail["SwapPanes"] = errors.New("can't swap: no such pane\nextra")
	h.keys("J")
	if !h.m.flashErr || h.m.flash != "can't swap: no such pane" {
		t.Fatalf("flash %q", h.m.flash)
	}
	h.f.fail["Focus"] = errors.New("no client")
	h.keys("enter")
	if h.quit || h.m.busy || h.m.flash != "no client" {
		t.Fatal("failed focus should flash and stay open")
	}
	h.keys("j")
	h.wantSel("%3")
	h.f.fail["Tree"] = errors.New("server gone")
	h.keys("ctrl+r")
	if !strings.Contains(h.m.flash, "server gone") || len(h.m.rows) == 0 {
		t.Fatal("tree error should flash and keep the old tree")
	}
}

func TestFlashExpires(t *testing.T) {
	h := start(t, origin())
	h.keys("z")
	id := h.m.flashID
	h.send(flashExpireMsg{id - 1})
	if h.m.flash == "" {
		t.Fatal("older timer cleared a newer flash")
	}
	h.send(flashExpireMsg{id})
	if h.m.flash != "" {
		t.Fatal("flash did not clear")
	}
}

func TestTickSkipsRefreshWhileBusy(t *testing.T) {
	h := start(t, origin())
	n := h.f.count("Tree")
	h.m.busy = true
	_, cmd := h.m.Update(tickMsg{})
	h.run(cmd)
	if h.f.count("Tree") != n {
		t.Fatal("tick refreshed during a mutation")
	}
	h.m.busy = false
	h.send(tickMsg{})
	if h.f.count("Tree") != n+1 {
		t.Fatal("tick did not refresh")
	}
}

func TestMouse(t *testing.T) {
	h := start(t, origin())
	l := h.m.layout()
	h.send(tea.MouseClickMsg{X: l.treeX + 3, Y: l.treeY, Button: tea.MouseLeft})
	h.wantSel("$1")
	h.send(tea.MouseWheelMsg{Button: tea.MouseWheelDown})
	h.wantSel("@1")
	h.send(tea.MouseClickMsg{X: l.treeX + l.treeW + 5, Y: l.treeY + 3, Button: tea.MouseLeft})
	h.wantSel("@1")
}

func TestHelpOverlay(t *testing.T) {
	h := start(t, origin())
	h.keys("?")
	if h.m.mode != modeHelp {
		t.Fatal("no help")
	}
	h.keys("J")
	h.wantCalls()
	if h.m.mode != modeNormal {
		t.Fatal("any key should close help")
	}
}

func TestScrollKeepsCursorVisible(t *testing.T) {
	h := start(t, origin())
	h.send(tea.WindowSizeMsg{Width: 60, Height: 9})
	vis := h.m.treeHeight()
	for range len(h.m.rows) {
		h.keys("j")
		if h.m.cursor < h.m.offset || h.m.cursor >= h.m.offset+vis {
			t.Fatalf("cursor %d outside [%d,%d)", h.m.cursor, h.m.offset, h.m.offset+vis)
		}
	}
	h.keys("g")
	if h.m.offset != 0 {
		t.Fatal("offset not reset")
	}
}

func TestViewShape(t *testing.T) {
	sizes := [][2]int{{200, 60}, {120, 40}, {90, 20}, {89, 30}, {60, 12}, {40, 9}, {30, 8}, {20, 5}}
	setups := map[string]func(h *harness){
		"normal":  func(h *harness) {},
		"help":    func(h *harness) { h.keys("?") },
		"prompt":  func(h *harness) { h.keys("t") },
		"confirm": func(h *harness) { h.keys("x") },
		"picker":  func(h *harness) { h.keys("m") },
		"filter":  func(h *harness) { h.keys("/"); h.typeText("fi") },
		"mark":    func(h *harness) { h.keys("s") },
		"window":  func(h *harness) { h.goTo("@1") },
		"session": func(h *harness) { h.goTo("$3") },
	}
	for name, setup := range setups {
		for _, sz := range sizes {
			h := start(t, origin())
			h.send(tea.WindowSizeMsg{Width: sz[0], Height: sz[1]})
			setup(h)
			out := h.m.View().Content
			lines := strings.Split(out, "\n")
			if len(lines) != sz[1] {
				t.Errorf("%s %v: %d lines", name, sz, len(lines))
			}
			for i, ln := range lines {
				if w := ansi.StringWidth(ln); w > sz[0] {
					t.Errorf("%s %v: line %d is %d wide: %q", name, sz, i, w, ansi.Strip(ln))
				}
			}
		}
	}
}

func TestViewContent(t *testing.T) {
	h := start(t, origin())
	out := ansi.Strip(h.m.View().Content)
	for _, want := range []string{"tpane", "main", "editor", "nvim", "fish", "%2", "pid 100", "$ %2", "line two"} {
		if !strings.Contains(out, want) {
			t.Errorf("view lacks %q", want)
		}
	}
	h.send(tea.WindowSizeMsg{Width: 80, Height: 30})
	out = ansi.Strip(h.m.View().Content)
	if strings.Contains(out, "line two") {
		t.Error("narrow view should drop the preview")
	}
	if !strings.Contains(out, "pid 100") {
		t.Error("narrow view should keep details")
	}
}

func TestShortPath(t *testing.T) {
	for in, want := range map[string]string{
		"/home/kyle":      "~",
		"/home/kyle/src":  "~/src",
		"/home/kyleother": "/home/kyleother",
		"/":               "/",
	} {
		if got := shortPath(in, "/home/kyle"); got != want {
			t.Errorf("shortPath(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestHelpFitsCommonPopups(t *testing.T) {
	for _, sz := range [][2]int{{100, 22}, {160, 40}, {80, 30}, {60, 40}} {
		h := start(t, origin())
		h.send(tea.WindowSizeMsg{Width: sz[0], Height: sz[1]})
		h.keys("?")
		bw, bh := lipgloss.Size(h.m.helpBox())
		if bw > sz[0] || bh > sz[1] {
			t.Errorf("%v: help box %dx%d", sz, bw, bh)
		}
		if out := ansi.Strip(h.m.View().Content); sz[1] >= 22 && !strings.Contains(out, "renumber session") {
			t.Errorf("%v: help clipped", sz)
		}
	}
}

func TestBlankFilterIsNoFilter(t *testing.T) {
	h := start(t, origin())
	h.keys("/", "space", "space", "enter")
	if h.m.query != "" {
		t.Fatalf("query %q", h.m.query)
	}
	h.goTo("$2")
	h.keys("l")
	if !slices.Contains(h.rowIDs(), "@3") {
		t.Fatal("l should expand with a blank filter")
	}
}

func TestFilterMatchesShortenedPath(t *testing.T) {
	h := start(t, origin())
	h.keys("/")
	h.typeText("~")
	if got := h.rowIDs(); !slices.Equal(got, []string{"$1", "@2", "%4"}) {
		t.Fatalf("rows %v", got)
	}
}

func TestQueueDroppedWhenRefreshAfterMutationFails(t *testing.T) {
	h := start(t, tmux.Location{SessionID: "$1", WindowID: "@1", PaneID: "%1"})
	_, first := h.m.Update(keyMsg("J"))
	h.m.Update(keyMsg("J"))
	h.f.mu.Lock()
	h.f.fail["Tree"] = errors.New("flaky")
	h.f.mu.Unlock()
	h.run(first)
	h.wantCalls("SwapPanes %1 %2")
	if len(h.m.queue) != 0 || h.m.busy {
		t.Fatal("queue should be dropped")
	}
}
