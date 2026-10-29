package ui

import (
	"fmt"
	"strings"

	"charm.land/bubbles/v2/key"
	tea "charm.land/bubbletea/v2"

	"tpane/internal/tmux"
)

func (m *Model) handleKey(k tea.KeyPressMsg) tea.Cmd {
	switch m.mode {
	case modeHelp:
		m.mode = modeNormal
		return nil
	case modeConfirm:
		return m.keyConfirm(k)
	case modePrompt:
		return m.keyPrompt(k)
	case modePicker:
		return m.keyPicker(k)
	}
	if m.filtering {
		return m.keyFilter(k)
	}
	return m.keyNormal(k)
}

func (m *Model) keyNormal(k tea.KeyPressMsg) tea.Cmd {
	switch {
	case k.String() == "esc":
		switch {
		case m.query != "":
			m.query = ""
			m.filter.SetValue("")
			m.reveal(m.selID)
			m.rebuild(false)
			return m.captureCmd(false)
		case m.mark != "":
			m.mark = ""
			return m.setFlash("mark cleared", false)
		}
		m.quitting = true
		return tea.Quit
	case key.Matches(k, keys.Quit):
		m.quitting = true
		return tea.Quit
	case key.Matches(k, keys.Up):
		return m.move(-1)
	case key.Matches(k, keys.Down):
		return m.move(1)
	case key.Matches(k, keys.PgUp):
		return m.move(-max(m.treeHeight()-1, 1))
	case key.Matches(k, keys.PgDown):
		return m.move(max(m.treeHeight()-1, 1))
	case key.Matches(k, keys.Top):
		return m.moveTo(0)
	case key.Matches(k, keys.Bottom):
		return m.moveTo(len(m.rows) - 1)
	case key.Matches(k, keys.Collapse):
		return m.collapse()
	case key.Matches(k, keys.Expand):
		return m.expand()
	case key.Matches(k, keys.Toggle):
		return m.toggle()
	case key.Matches(k, keys.Filter):
		m.filtering = true
		m.filter.SetValue(m.query)
		m.filter.CursorEnd()
		return m.filter.Focus()
	case key.Matches(k, keys.Help):
		m.mode = modeHelp
		return nil
	case key.Matches(k, keys.Refresh):
		return m.refreshCmd()
	}

	r := m.sel()
	if r == nil {
		return nil
	}
	switch r.kind {
	case rowPane:
		return m.paneKey(k, r)
	case rowWindow:
		return m.windowKey(k, r)
	case rowSession:
		return m.sessionKey(k, r)
	}
	return nil
}

func (m *Model) paneKey(k tea.KeyPressMsg, r *row) tea.Cmd {
	p, w := r.p, r.w
	id := p.ID
	switch {
	case key.Matches(k, keys.Enter):
		return m.focusCmd(id)
	case key.Matches(k, keys.SwapDown), key.Matches(k, keys.SwapUp):
		down := key.Matches(k, keys.SwapDown)
		i := paneIndex(w, id)
		j := i + 1
		if !down {
			j = i - 1
		}
		if j < 0 || j >= len(w.Panes) {
			if down {
				return m.setFlash("already the last pane in "+w.Name, true)
			}
			return m.setFlash("already the first pane in "+w.Name, true)
		}
		other := w.Panes[j].ID
		return m.mutate(func(b Backend) (string, error) {
			return "", b.SwapPanes(id, other)
		})
	case key.Matches(k, keys.MoveTo):
		idx := int(k.String()[0] - '0')
		if idx == p.Index {
			return m.setFlash(fmt.Sprintf("%s is already pane %d", id, idx), false)
		}
		return m.mutate(func(b Backend) (string, error) {
			return fmt.Sprintf("moved %s to index %d", id, idx), b.MovePane(id, idx)
		})
	case key.Matches(k, keys.Break):
		return m.mutate(breakOp(id, ""))
	case key.Matches(k, keys.BreakNamed):
		m.openPrompt("Break "+paneName(p)+" into a new window named", "", func(v string) (op, string) {
			return breakOp(id, strings.TrimSpace(v)), ""
		})
		return nil
	case key.Matches(k, keys.Join):
		return m.openPicker(r)
	case key.Matches(k, keys.Mark):
		switch m.mark {
		case "":
			m.mark = id
			return nil
		case id:
			m.mark = ""
			return m.setFlash("mark cleared", false)
		}
		src := m.mark
		m.mark = ""
		return m.mutate(func(b Backend) (string, error) {
			return fmt.Sprintf("swapped %s ⇄ %s", src, id), b.SwapPanes(src, id)
		})
	case key.Matches(k, keys.Kill):
		m.openConfirm("Kill pane "+paneName(p)+"?", shortPath(p.Path, m.home), func(b Backend) (string, error) {
			return "killed pane " + id, b.KillPane(id)
		})
		return nil
	case key.Matches(k, keys.Zoom):
		return m.mutate(func(b Backend) (string, error) {
			return "toggled zoom on " + id, b.ToggleZoom(id)
		})
	case key.Matches(k, keys.Title):
		m.openPrompt("Title for "+paneName(p), p.Title, func(v string) (op, string) {
			return func(b Backend) (string, error) {
				return "set title of " + id, b.SetPaneTitle(id, v)
			}, ""
		})
		return nil
	}
	return nil
}

func breakOp(id, name string) op {
	return func(b Backend) (string, error) {
		wid, err := b.BreakPane(id, name)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("broke %s out into window %s", id, wid), nil
	}
}

func (m *Model) windowKey(k tea.KeyPressMsg, r *row) tea.Cmd {
	s, w := r.s, r.w
	id, name := w.ID, w.Name
	switch {
	case key.Matches(k, keys.Enter):
		return m.focusCmd(id)
	case key.Matches(k, keys.SwapDown), key.Matches(k, keys.SwapUp):
		down := key.Matches(k, keys.SwapDown)
		i := windowIndex(s, id)
		j := i + 1
		if !down {
			j = i - 1
		}
		if j < 0 || j >= len(s.Windows) {
			if down {
				return m.setFlash("already the last window in "+s.Name, true)
			}
			return m.setFlash("already the first window in "+s.Name, true)
		}
		other := s.Windows[j].ID
		return m.mutate(func(b Backend) (string, error) {
			return "", b.SwapWindows(id, other)
		})
	case key.Matches(k, keys.MoveTo):
		idx := int(k.String()[0] - '0')
		if idx == w.Index {
			return m.setFlash(fmt.Sprintf("%s is already window %d", w.Name, idx), false)
		}
		return m.mutate(func(b Backend) (string, error) {
			return fmt.Sprintf("moved %s to index %d", name, idx), b.MoveWindow(id, idx)
		})
	case key.Matches(k, keys.Rename):
		m.openPrompt("Rename window "+windowLabel(s, w), w.Name, func(v string) (op, string) {
			v = strings.TrimSpace(v)
			if v == "" {
				return nil, "window name can't be empty"
			}
			return func(b Backend) (string, error) {
				return "renamed window to " + v, b.RenameWindow(id, v)
			}, ""
		})
		return nil
	case key.Matches(k, keys.Layout):
		i := m.layoutIdx[id] % len(layouts)
		m.layoutIdx[id] = i + 1
		layout := layouts[i]
		return m.mutate(func(b Backend) (string, error) {
			return "layout " + layout, b.SelectLayout(id, layout)
		})
	case key.Matches(k, keys.Renumber):
		return m.renumber(s)
	case key.Matches(k, keys.Kill):
		detail := fmt.Sprintf("%d pane%s", len(w.Panes), plural(len(w.Panes)))
		m.openConfirm("Kill window "+windowLabel(s, w)+"?", detail, func(b Backend) (string, error) {
			return "killed window " + name, b.KillWindow(id)
		})
		return nil
	}
	return nil
}

func (m *Model) sessionKey(k tea.KeyPressMsg, r *row) tea.Cmd {
	s := r.s
	id, name := s.ID, s.Name
	switch {
	case key.Matches(k, keys.Enter):
		return m.focusCmd(id)
	case key.Matches(k, keys.Rename):
		m.openPrompt("Rename session "+s.Name, s.Name, func(v string) (op, string) {
			v = strings.TrimSpace(v)
			if v == "" {
				return nil, "session name can't be empty"
			}
			return func(b Backend) (string, error) {
				return "renamed session to " + v, b.RenameSession(id, v)
			}, ""
		})
		return nil
	case key.Matches(k, keys.Renumber):
		return m.renumber(s)
	case key.Matches(k, keys.Kill):
		detail := fmt.Sprintf("%d window%s", len(s.Windows), plural(len(s.Windows)))
		if id == m.origin.SessionID {
			detail += " · this is the session you're in"
		}
		m.openConfirm("Kill session "+s.Name+"?", detail, func(b Backend) (string, error) {
			return "killed session " + name, b.KillSession(id)
		})
		return nil
	}
	return nil
}

func (m *Model) renumber(s *tmux.Session) tea.Cmd {
	id, name := s.ID, s.Name
	return m.mutate(func(b Backend) (string, error) {
		return "renumbered windows in " + name, b.RenumberWindows(id)
	})
}

func paneIndex(w *tmux.Window, id string) int {
	for i, p := range w.Panes {
		if p.ID == id {
			return i
		}
	}
	return -1
}

func windowIndex(s *tmux.Session, id string) int {
	for i, w := range s.Windows {
		if w.ID == id {
			return i
		}
	}
	return -1
}

func windowLabel(s *tmux.Session, w *tmux.Window) string {
	return fmt.Sprintf("%s:%d %s", s.Name, w.Index, w.Name)
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

// Navigation

func (m *Model) move(d int) tea.Cmd {
	return m.moveTo(m.cursor + d)
}

func (m *Model) moveTo(i int) tea.Cmd {
	if len(m.rows) == 0 {
		return nil
	}
	m.cursor = clamp(i, 0, len(m.rows)-1)
	m.selID = m.rows[m.cursor].id
	m.ensureVisible()
	return m.captureCmd(false)
}

func (m *Model) setOpen(r *row, open bool) {
	m.open[r.id] = open
	m.rebuild(false)
}

func (m *Model) collapse() tea.Cmd {
	r := m.sel()
	if r == nil {
		return nil
	}
	switch r.kind {
	case rowPane:
		return m.moveTo(indexOf(m.rows, r.w.ID))
	case rowWindow:
		if m.query == "" && m.isOpen(r.id, rowWindow) {
			m.setOpen(r, false)
			return nil
		}
		return m.moveTo(indexOf(m.rows, r.s.ID))
	case rowSession:
		if m.query == "" && m.isOpen(r.id, rowSession) {
			m.setOpen(r, false)
		}
	}
	return nil
}

func (m *Model) expand() tea.Cmd {
	r := m.sel()
	if r == nil || r.kind == rowPane {
		return nil
	}
	if m.query == "" && !m.isOpen(r.id, r.kind) {
		m.setOpen(r, true)
		return nil
	}
	if m.cursor+1 < len(m.rows) && m.rows[m.cursor+1].kind > r.kind {
		return m.move(1)
	}
	return nil
}

func (m *Model) toggle() tea.Cmd {
	r := m.sel()
	if r == nil || m.query != "" {
		return nil
	}
	if r.kind == rowPane {
		wid := r.w.ID
		m.open[wid] = false
		m.selID = wid
		m.rebuild(false)
		return m.captureCmd(false)
	}
	m.setOpen(r, !m.isOpen(r.id, r.kind))
	return nil
}

// Filter

func (m *Model) keyFilter(k tea.KeyPressMsg) tea.Cmd {
	switch k.String() {
	case "esc":
		m.filtering = false
		m.filter.Blur()
		m.filter.SetValue("")
		m.query = ""
		m.reveal(m.selID)
		m.rebuild(false)
		return m.captureCmd(false)
	case "enter":
		m.filtering = false
		m.filter.Blur()
		return nil
	case "up", "ctrl+p", "ctrl+k":
		return m.move(-1)
	case "down", "ctrl+n", "ctrl+j":
		return m.move(1)
	}
	var cmd tea.Cmd
	m.filter, cmd = m.filter.Update(k)
	if v := strings.TrimSpace(m.filter.Value()); v != m.query {
		m.query = v
		if v == "" {
			m.reveal(m.selID)
		}
		m.rebuild(true)
		return tea.Batch(cmd, m.captureCmd(false))
	}
	return cmd
}

// Overlays

func (m *Model) openPrompt(title, value string, submit func(string) (op, string)) {
	in := m.st.newInput("› ")
	in.SetValue(value)
	in.CursorEnd()
	in.Focus()
	in.SetWidth(m.promptInputWidth())
	m.prompt = prompt{title: title, input: in, submit: submit}
	m.mode = modePrompt
}

func (m *Model) keyPrompt(k tea.KeyPressMsg) tea.Cmd {
	switch k.String() {
	case "esc":
		m.mode = modeNormal
		return nil
	case "enter":
		m.mode = modeNormal
		f, msg := m.prompt.submit(m.prompt.input.Value())
		if f == nil {
			return m.setFlash(msg, true)
		}
		return m.mutate(f)
	}
	var cmd tea.Cmd
	m.prompt.input, cmd = m.prompt.input.Update(k)
	return cmd
}

func (m *Model) openConfirm(question, detail string, run op) {
	m.confirm = confirm{question: question, detail: detail, run: run}
	m.mode = modeConfirm
}

func (m *Model) keyConfirm(k tea.KeyPressMsg) tea.Cmd {
	m.mode = modeNormal
	if key.Matches(k, keys.Confirm) {
		return m.mutate(m.confirm.run)
	}
	return nil
}

func (m *Model) openPicker(r *row) tea.Cmd {
	var targets []pickTarget
	for _, s := range m.sessionOrder() {
		for wi := range s.Windows {
			w := &s.Windows[wi]
			if w.ID == r.w.ID {
				continue
			}
			targets = append(targets, pickTarget{windowID: w.ID, label: windowLabel(s, w)})
		}
	}
	if len(targets) == 0 {
		return m.setFlash("no other windows to move into", true)
	}
	m.picker = picker{paneID: r.p.ID, paneLabel: paneName(r.p), targets: targets, horizontal: true}
	m.mode = modePicker
	return nil
}

func (m *Model) keyPicker(k tea.KeyPressMsg) tea.Cmd {
	pk := &m.picker
	switch {
	case key.Matches(k, keys.Up):
		pk.cursor = clamp(pk.cursor-1, 0, len(pk.targets)-1)
	case key.Matches(k, keys.Down):
		pk.cursor = clamp(pk.cursor+1, 0, len(pk.targets)-1)
	case key.Matches(k, keys.Top):
		pk.cursor = 0
	case key.Matches(k, keys.Bottom):
		pk.cursor = len(pk.targets) - 1
	case key.Matches(k, keys.PickToggle):
		pk.horizontal = !pk.horizontal
	case key.Matches(k, keys.Accept):
		m.mode = modeNormal
		src, t, h := pk.paneID, pk.targets[pk.cursor], pk.horizontal
		return m.mutate(func(b Backend) (string, error) {
			return fmt.Sprintf("moved %s into %s", src, t.label), b.JoinPane(src, t.windowID, h)
		})
	case k.String() == "esc", key.Matches(k, keys.Quit):
		m.mode = modeNormal
	}
	return nil
}

// Mouse

func (m *Model) click(x, y int) tea.Cmd {
	l := m.layout()
	if x < l.treeX || x >= l.treeX+l.treeW || y < l.treeY || y >= l.treeY+l.treeH {
		return nil
	}
	i := m.offset + y - l.treeY
	if i >= len(m.rows) {
		return nil
	}
	return m.moveTo(i)
}
