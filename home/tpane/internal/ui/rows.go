package ui

import (
	"strings"

	"tpane/internal/tmux"
)

type rowKind int

const (
	rowNone rowKind = iota
	rowSession
	rowWindow
	rowPane
)

// row points into Model.tree; rows are rebuilt whenever the tree is replaced.
type row struct {
	kind  rowKind
	id    string
	s     *tmux.Session
	w     *tmux.Window
	p     *tmux.Pane
	match bool // matched the filter itself, not just as an ancestor
}

func find(tree []tmux.Session, id string) row {
	for si := range tree {
		s := &tree[si]
		if s.ID == id {
			return row{kind: rowSession, id: id, s: s}
		}
		for wi := range s.Windows {
			w := &s.Windows[wi]
			if w.ID == id {
				return row{kind: rowWindow, id: id, s: s, w: w}
			}
			for pi := range w.Panes {
				if p := &w.Panes[pi]; p.ID == id {
					return row{kind: rowPane, id: id, s: s, w: w, p: p}
				}
			}
		}
	}
	return row{}
}

func (m *Model) isOpen(id string, kind rowKind) bool {
	if v, ok := m.open[id]; ok {
		return v
	}
	return kind == rowWindow || id == m.primary
}

// sessionOrder lists the primary session first, the rest in Tree order.
func (m *Model) sessionOrder() []*tmux.Session {
	out := make([]*tmux.Session, 0, len(m.tree))
	for i := range m.tree {
		if m.tree[i].ID == m.primary {
			out = append(out, &m.tree[i])
		}
	}
	for i := range m.tree {
		if m.tree[i].ID != m.primary {
			out = append(out, &m.tree[i])
		}
	}
	return out
}

func (m *Model) buildRows() []row {
	var rows []row
	q := strings.ToLower(strings.TrimSpace(m.query))
	has := func(s string) bool { return q != "" && strings.Contains(strings.ToLower(s), q) }

	for _, s := range m.sessionOrder() {
		if q == "" {
			rows = append(rows, row{kind: rowSession, id: s.ID, s: s})
			if !m.isOpen(s.ID, rowSession) {
				continue
			}
			for wi := range s.Windows {
				w := &s.Windows[wi]
				rows = append(rows, row{kind: rowWindow, id: w.ID, s: s, w: w})
				if !m.isOpen(w.ID, rowWindow) {
					continue
				}
				for pi := range w.Panes {
					p := &w.Panes[pi]
					rows = append(rows, row{kind: rowPane, id: p.ID, s: s, w: w, p: p})
				}
			}
			continue
		}

		// Filtering ignores collapse state: a match shows its ancestors and,
		// for sessions and windows, everything under it.
		sMatch := has(s.Name)
		var sub []row
		for wi := range s.Windows {
			w := &s.Windows[wi]
			wMatch := has(w.Name)
			var panes []row
			for pi := range w.Panes {
				p := &w.Panes[pi]
				pMatch := has(p.Command) || has(p.Path) || has(shortPath(p.Path, m.home)) || has(p.Title)
				if sMatch || wMatch || pMatch {
					panes = append(panes, row{kind: rowPane, id: p.ID, s: s, w: w, p: p, match: pMatch})
				}
			}
			if sMatch || wMatch || len(panes) > 0 {
				sub = append(sub, row{kind: rowWindow, id: w.ID, s: s, w: w, match: wMatch})
				sub = append(sub, panes...)
			}
		}
		if sMatch || len(sub) > 0 {
			rows = append(rows, row{kind: rowSession, id: s.ID, s: s, match: sMatch})
			rows = append(rows, sub...)
		}
	}
	return rows
}

func indexOf(rows []row, id string) int {
	for i, r := range rows {
		if r.id == id {
			return i
		}
	}
	return -1
}

// rebuild recomputes rows, keeping the cursor on selID. If it's gone, the
// cursor goes to the nearest surviving neighbour from the previous rows (or,
// with preferMatch, to the first filter match).
func (m *Model) rebuild(preferMatch bool) {
	old, oldCur := m.rows, m.cursor
	m.rows = m.buildRows()
	m.cursor = m.locate(old, oldCur, preferMatch)
	if len(m.rows) > 0 {
		m.selID = m.rows[m.cursor].id
	}
	m.ensureVisible()
}

func (m *Model) locate(old []row, oldCur int, preferMatch bool) int {
	if len(m.rows) == 0 {
		return 0
	}
	if i := indexOf(m.rows, m.selID); i >= 0 {
		return i
	}
	if preferMatch {
		for i, r := range m.rows {
			if r.match {
				return i
			}
		}
	}
	for d := 1; d < len(old); d++ {
		for _, j := range []int{oldCur + d, oldCur - d} {
			if j >= 0 && j < len(old) {
				if i := indexOf(m.rows, old[j].id); i >= 0 {
					return i
				}
			}
		}
	}
	return clamp(oldCur, 0, len(m.rows)-1)
}

// reveal opens the ancestors of id so its row is visible unfiltered.
func (m *Model) reveal(id string) {
	r := find(m.tree, id)
	if r.kind == rowWindow || r.kind == rowPane {
		if !m.isOpen(r.s.ID, rowSession) {
			m.open[r.s.ID] = true
		}
	}
	if r.kind == rowPane && !m.isOpen(r.w.ID, rowWindow) {
		m.open[r.w.ID] = true
	}
}

func (m *Model) sel() *row {
	if m.cursor < 0 || m.cursor >= len(m.rows) {
		return nil
	}
	return &m.rows[m.cursor]
}

// target is the pane the details/map/preview describe: the selected pane, or
// the active pane of the selected window, or of the session's active window.
func (m *Model) target() *tmux.Pane {
	_, p := m.targetWP()
	return p
}

func (m *Model) targetWP() (*tmux.Window, *tmux.Pane) {
	r := m.sel()
	if r == nil {
		return nil, nil
	}
	switch r.kind {
	case rowPane:
		return r.w, r.p
	case rowWindow:
		return r.w, activePane(r.w)
	case rowSession:
		if len(r.s.Windows) == 0 {
			return nil, nil
		}
		w := &r.s.Windows[0]
		for i := range r.s.Windows {
			if r.s.Windows[i].Active {
				w = &r.s.Windows[i]
				break
			}
		}
		return w, activePane(w)
	}
	return nil, nil
}

func activePane(w *tmux.Window) *tmux.Pane {
	for i := range w.Panes {
		if w.Panes[i].Active {
			return &w.Panes[i]
		}
	}
	if len(w.Panes) > 0 {
		return &w.Panes[0]
	}
	return nil
}

func clamp(v, lo, hi int) int {
	if hi < lo {
		return lo
	}
	return max(lo, min(v, hi))
}
