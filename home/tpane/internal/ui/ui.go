package ui

import (
	"fmt"
	"os"
	"strings"
	"time"

	"charm.land/bubbles/v2/help"
	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"

	"tpane/internal/tmux"
)

// Backend is the subset of *tmux.Client the UI drives.
type Backend interface {
	Tree() ([]tmux.Session, error)
	Capture(paneID string) (string, error)
	SwapPanes(srcID, dstID string) error
	MovePane(paneID string, index int) error
	BreakPane(paneID, name string) (string, error)
	JoinPane(srcPaneID, dstWindowID string, horizontal bool) error
	KillPane(paneID string) error
	ToggleZoom(paneID string) error
	SetPaneTitle(paneID, title string) error
	SwapWindows(srcID, dstID string) error
	MoveWindow(windowID string, index int) error
	RenameWindow(windowID, name string) error
	KillWindow(windowID string) error
	SelectLayout(windowID, layout string) error
	RenumberWindows(sessionID string) error
	RenameSession(sessionID, name string) error
	KillSession(sessionID string) error
	Focus(target string) error
}

type Options struct {
	Origin tmux.Location // where the cursor starts
}

const (
	refreshEvery = time.Second
	flashFor     = 3 * time.Second
	maxQueued    = 64
)

var layouts = []string{"tiled", "even-horizontal", "even-vertical", "main-horizontal", "main-vertical"}

type mode int

const (
	modeNormal mode = iota
	modeHelp
	modePrompt
	modeConfirm
	modePicker
)

// op is a backend mutation; it returns the success flash text.
type op func(Backend) (string, error)

type capture struct {
	text string
	err  error
}

type prompt struct {
	title  string
	input  textinput.Model
	submit func(string) (op, string) // nil op cancels, with the string as an error flash
}

type confirm struct {
	question string
	detail   string
	run      op
}

type pickTarget struct {
	windowID string
	label    string
}

type picker struct {
	paneID     string
	paneLabel  string
	targets    []pickTarget
	cursor     int
	horizontal bool
}

type Model struct {
	b      Backend
	origin tmux.Location
	home   string
	after  func(time.Duration, func(time.Time) tea.Msg) tea.Cmd

	tree    []tmux.Session
	loaded  bool
	primary string // session listed first and open by default
	rows    []row
	cursor  int
	selID   string
	offset  int
	open    map[string]bool // explicit expand state by id; absent means default

	captures map[string]capture
	seq      int
	applied  int
	busy     bool
	queue    []tea.KeyPressMsg

	mark      string
	layoutIdx map[string]int

	filter    textinput.Model
	filtering bool
	query     string

	mode    mode
	prompt  prompt
	confirm confirm
	picker  picker

	flash    string
	flashErr bool
	flashID  int

	w, h     int
	help     help.Model
	st       styles
	quitting bool
}

type treeMsg struct {
	seq      int
	tree     []tmux.Session
	err      error
	mutation bool
	flash    string
	opErr    error
}

type captureMsg struct {
	id string
	capture
}

type tickMsg struct{}

type flashExpireMsg struct{ id int }

type focusedMsg struct{ err error }

func New(b Backend, opts Options) *Model {
	home, _ := os.UserHomeDir()
	st := newStyles()
	m := &Model{
		b:         b,
		origin:    opts.Origin,
		home:      home,
		after:     tea.Tick,
		selID:     opts.Origin.PaneID,
		open:      map[string]bool{},
		captures:  map[string]capture{},
		layoutIdx: map[string]int{},
		help:      help.New(),
		st:        st,
	}
	m.help.Styles = st.help
	m.help.ShortSeparator = " · "
	m.filter = st.newInput("/ ")
	m.filter.Placeholder = "session, window, command, path…"
	return m
}

func (m *Model) Init() tea.Cmd {
	return tea.Batch(m.refreshCmd(), m.tickCmd())
}

func (m *Model) tickCmd() tea.Cmd {
	return m.after(refreshEvery, func(time.Time) tea.Msg { return tickMsg{} })
}

func (m *Model) refreshCmd() tea.Cmd {
	m.seq++
	seq, b := m.seq, m.b
	return func() tea.Msg {
		t, err := b.Tree()
		return treeMsg{seq: seq, tree: t, err: err}
	}
}

// mutate runs f and then re-reads the tree in the same command. Keys pressed
// meanwhile are queued, so a second J acts on the post-swap tree.
func (m *Model) mutate(f op) tea.Cmd {
	m.busy = true
	m.seq++
	seq, b := m.seq, m.b
	return func() tea.Msg {
		flash, err := f(b)
		t, terr := b.Tree()
		return treeMsg{seq: seq, tree: t, err: terr, mutation: true, flash: flash, opErr: err}
	}
}

func (m *Model) focusCmd(target string) tea.Cmd {
	m.busy = true
	b := m.b
	return func() tea.Msg { return focusedMsg{b.Focus(target)} }
}

func (m *Model) captureCmd(force bool) tea.Cmd {
	p := m.target()
	if p == nil {
		return nil
	}
	if _, ok := m.captures[p.ID]; ok && !force {
		return nil
	}
	id, b := p.ID, m.b
	return func() tea.Msg {
		s, err := b.Capture(id)
		return captureMsg{id, capture{s, err}}
	}
}

func (m *Model) setFlash(text string, isErr bool) tea.Cmd {
	m.flashID++
	m.flash, m.flashErr = text, isErr
	id := m.flashID
	return m.after(flashFor, func(time.Time) tea.Msg { return flashExpireMsg{id} })
}

func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		m.help.SetWidth(m.w - 2)
		m.filter.SetWidth(max(m.w-8, 10))
		m.prompt.input.SetWidth(m.promptInputWidth())
		m.ensureVisible()
		return m, nil

	case treeMsg:
		return m, m.onTree(msg)

	case captureMsg:
		m.captures[msg.id] = msg.capture
		return m, nil

	case tickMsg:
		cmds := []tea.Cmd{m.tickCmd()}
		if !m.busy {
			cmds = append(cmds, m.refreshCmd())
		}
		return m, tea.Batch(cmds...)

	case flashExpireMsg:
		if msg.id == m.flashID {
			m.flash = ""
		}
		return m, nil

	case focusedMsg:
		m.busy = false
		if msg.err == nil {
			m.quitting = true
			return m, tea.Quit
		}
		return m, tea.Batch(m.setFlash(errText(msg.err), true), m.drainQueue())

	case tea.KeyPressMsg:
		if msg.String() == "ctrl+c" {
			m.quitting = true
			return m, tea.Quit
		}
		if m.busy {
			if len(m.queue) < maxQueued {
				m.queue = append(m.queue, msg)
			}
			return m, nil
		}
		return m, m.handleKey(msg)

	case tea.MouseClickMsg:
		if m.mode == modeNormal && !m.busy && msg.Button == tea.MouseLeft {
			return m, m.click(msg.X, msg.Y)
		}
		return m, nil

	case tea.MouseWheelMsg:
		if m.mode == modeNormal && !m.busy {
			switch msg.Button {
			case tea.MouseWheelUp:
				return m, m.move(-1)
			case tea.MouseWheelDown:
				return m, m.move(1)
			}
		}
		return m, nil
	}

	var cmd tea.Cmd
	switch {
	case m.mode == modePrompt:
		m.prompt.input, cmd = m.prompt.input.Update(msg)
	case m.filtering && m.mode == modeNormal:
		m.filter, cmd = m.filter.Update(msg)
		if v := strings.TrimSpace(m.filter.Value()); v != m.query { // e.g. a paste
			m.query = v
			m.rebuild(true)
			cmd = tea.Batch(cmd, m.captureCmd(false))
		}
	}
	return m, cmd
}

func (m *Model) onTree(msg treeMsg) tea.Cmd {
	var cmds []tea.Cmd
	if msg.mutation {
		m.busy = false
		switch {
		case msg.opErr != nil:
			cmds = append(cmds, m.setFlash(errText(msg.opErr), true))
		case msg.flash != "":
			cmds = append(cmds, m.setFlash(msg.flash, false))
		}
	}
	switch {
	case msg.err != nil:
		if msg.opErr == nil {
			cmds = append(cmds, m.setFlash("refresh: "+errText(msg.err), true))
		}
	case msg.seq > m.applied:
		m.applied = msg.seq
		m.applyTree(msg.tree)
		cmds = append(cmds, m.captureCmd(true))
	}
	if msg.mutation {
		if msg.err != nil {
			// The tree is stale, so queued keys would act on the wrong panes.
			m.queue = nil
		}
		cmds = append(cmds, m.drainQueue())
	}
	return tea.Batch(cmds...)
}

func (m *Model) drainQueue() tea.Cmd {
	var cmds []tea.Cmd
	for len(m.queue) > 0 && !m.busy && !m.quitting {
		k := m.queue[0]
		m.queue = m.queue[1:]
		cmds = append(cmds, m.handleKey(k))
	}
	return tea.Batch(cmds...)
}

func (m *Model) applyTree(tree []tmux.Session) {
	m.tree = tree
	if !m.loaded {
		m.loaded = true
		m.primary = ""
		if find(tree, m.origin.SessionID).kind == rowSession {
			m.primary = m.origin.SessionID
		} else if len(tree) > 0 {
			m.primary = tree[0].ID
		}
		for _, id := range []string{m.origin.PaneID, m.origin.WindowID, m.origin.SessionID} {
			if id != "" && find(tree, id).id != "" {
				m.selID = id
				break
			}
		}
	}

	live := map[string]bool{}
	for _, s := range tree {
		live[s.ID] = true
		for _, w := range s.Windows {
			live[w.ID] = true
			for _, p := range w.Panes {
				live[p.ID] = true
			}
		}
	}
	for id := range m.captures {
		if !live[id] {
			delete(m.captures, id)
		}
	}
	for id := range m.open {
		if !live[id] {
			delete(m.open, id)
		}
	}
	for id := range m.layoutIdx {
		if !live[id] {
			delete(m.layoutIdx, id)
		}
	}
	if m.mark != "" && !live[m.mark] {
		m.mark = ""
	}
	if m.query == "" && m.selID != "" {
		m.reveal(m.selID)
	}
	m.rebuild(false)
}

func errText(err error) string {
	s := strings.TrimSpace(err.Error())
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return s
}

func paneName(p *tmux.Pane) string {
	return fmt.Sprintf("%s (%s)", p.ID, p.Command)
}
