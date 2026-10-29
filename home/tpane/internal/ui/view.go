package ui

import (
	"fmt"
	"image/color"
	"strings"

	"charm.land/bubbles/v2/help"
	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"

	"tpane/internal/minimap"
	"tpane/internal/tmux"
)

// Catppuccin Mocha, as in home/tmux-common.nix.
var (
	cPink     = lipgloss.Color("#f5c2e7")
	cMauve    = lipgloss.Color("#cba6f7")
	cRed      = lipgloss.Color("#f38ba8")
	cPeach    = lipgloss.Color("#fab387")
	cYellow   = lipgloss.Color("#f9e2af")
	cGreen    = lipgloss.Color("#a6e3a1")
	cBlue     = lipgloss.Color("#89b4fa")
	cLavender = lipgloss.Color("#b4befe")
	cText     = lipgloss.Color("#cdd6f4")
	cSubtext0 = lipgloss.Color("#a6adc8")
	cOverlay2 = lipgloss.Color("#9399b2")
	cOverlay1 = lipgloss.Color("#7f849c")
	cOverlay0 = lipgloss.Color("#6c7086")
	cSurface2 = lipgloss.Color("#585b70")
	cSurface1 = lipgloss.Color("#45475a")
	cSurface0 = lipgloss.Color("#313244")
	cCrust    = lipgloss.Color("#11111b")
)

const zoomGlyph = "󰹑"

type styles struct {
	help    help.Styles
	minimap minimap.Styles
}

func fg(c color.Color) lipgloss.Style { return lipgloss.NewStyle().Foreground(c) }

func newStyles() styles {
	h := help.DefaultDarkStyles()
	h.ShortKey = fg(cBlue)
	h.ShortDesc = fg(cOverlay1)
	h.ShortSeparator = fg(cSurface2)
	h.Ellipsis = fg(cSurface2)
	h.FullKey = fg(cBlue)
	h.FullDesc = fg(cOverlay1)
	h.FullSeparator = fg(cSurface2)
	return styles{
		help: h,
		minimap: minimap.Styles{
			Border:        fg(cSurface2),
			Selected:      fg(cMauve).Bold(true),
			Label:         fg(cOverlay1),
			SelectedLabel: fg(cMauve).Bold(true),
		},
	}
}

func (styles) newInput(prompt string) textinput.Model {
	in := textinput.New()
	in.Prompt = prompt
	s := textinput.DefaultDarkStyles()
	s.Focused.Prompt = fg(cMauve).Bold(true)
	s.Focused.Text = fg(cText)
	s.Focused.Placeholder = fg(cOverlay0)
	s.Blurred.Prompt = fg(cOverlay1)
	s.Blurred.Text = fg(cSubtext0)
	s.Cursor.Color = cMauve
	s.Cursor.Blink = false
	in.SetStyles(s)
	return in
}

type layout struct {
	wide                       bool
	bodyH                      int
	treePanelW, treePanelH     int
	treeX, treeY, treeW, treeH int // the row area, in screen cells
	rightW, mapH, previewH     int
}

func (m *Model) layout() layout {
	l := layout{bodyH: m.h - 3}
	l.wide = m.w >= 90 && l.bodyH >= 10
	l.treePanelW, l.treePanelH = m.w, l.bodyH-1
	if l.wide {
		l.treePanelW, l.treePanelH = clamp(m.w*2/5, 36, 64), l.bodyH
		l.rightW = m.w - l.treePanelW
		l.mapH = clamp(l.bodyH/3, 5, 14)
		l.previewH = l.bodyH - l.mapH - 1
		if l.previewH < 4 {
			l.mapH, l.previewH = l.bodyH-1, 0
		}
	}
	l.treeX, l.treeY = 1, 2
	l.treeW, l.treeH = l.treePanelW-2, l.treePanelH-2
	return l
}

func (m *Model) treeHeight() int {
	if m.h == 0 {
		return 20
	}
	return max(m.layout().treeH, 1)
}

func (m *Model) ensureVisible() {
	vis := m.treeHeight()
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset+vis {
		m.offset = m.cursor - vis + 1
	}
	m.offset = clamp(m.offset, 0, max(len(m.rows)-vis, 0))
}

func (m *Model) View() tea.View {
	v := tea.NewView(m.render())
	v.AltScreen = true
	v.MouseMode = tea.MouseModeCellMotion
	return v
}

func (m *Model) render() string {
	if m.quitting || m.w == 0 || m.h == 0 {
		return ""
	}
	if m.w < 30 || m.h < 8 {
		return lipgloss.Place(m.w, m.h, lipgloss.Center, lipgloss.Center,
			fg(cOverlay1).Render(ansi.Truncate("tpane needs a bigger popup", m.w, "…")))
	}
	l := m.layout()

	tree := m.renderTree(l)
	var body string
	if l.wide {
		body = lipgloss.JoinHorizontal(lipgloss.Top, tree, m.renderRight(l))
	} else {
		body = tree + "\n" + m.details(m.w)
	}
	lines := []string{m.header(), body, m.statusLine(), fit(" "+m.help.ShortHelpView(m.contextHelp()), m.w)}
	base := strings.Join(lines, "\n")

	var box string
	switch m.mode {
	case modeHelp:
		box = m.helpBox()
	case modePrompt:
		box = m.promptBox()
	case modeConfirm:
		box = m.confirmBox()
	case modePicker:
		box = m.pickerBox()
	default:
		return base
	}
	bw, bh := lipgloss.Size(box)
	x, y := max((m.w-bw)/2, 0), max((m.h-bh)/2-1, 0)
	comp := lipgloss.NewCompositor(
		lipgloss.NewLayer(base),
		lipgloss.NewLayer(box).X(x).Y(y).Z(1),
	)
	return lipgloss.NewCanvas(m.w, m.h).Compose(comp).Render()
}

func (m *Model) header() string {
	var nw, np int
	for _, s := range m.tree {
		nw += len(s.Windows)
		for _, w := range s.Windows {
			np += len(w.Panes)
		}
	}
	pill := lipgloss.NewStyle().Background(cMauve).Foreground(cCrust).Bold(true).Padding(0, 1).Render("tpane")
	dim, num := fg(cOverlay0), fg(cSubtext0)
	stat := func(n int, what string) string {
		return num.Render(fmt.Sprint(n)) + dim.Render(" "+what+plural(n))
	}
	left := " " + pill + "  " + stat(len(m.tree), "session") + dim.Render(" · ") +
		stat(nw, "window") + dim.Render(" · ") + stat(np, "pane")

	var right []string
	if m.busy {
		right = append(right, fg(cYellow).Render("working…"))
	}
	if m.query != "" && !m.filtering {
		right = append(right, fg(cBlue).Render("/ ")+fg(cText).Render(m.query))
	}
	right = append(right, fg(cBlue).Render("?")+dim.Render(" help"))
	return spread(left, strings.Join(right, dim.Render("  ·  "))+" ", m.w)
}

// spread puts left and right on one line of width w, truncating left first.
func spread(left, right string, w int) string {
	rw := ansi.StringWidth(right)
	if rw >= w {
		return ansi.Truncate(right, w, "")
	}
	left = ansi.Truncate(left, w-rw-1, "…")
	return left + strings.Repeat(" ", w-ansi.StringWidth(left)-rw) + right
}

// fit makes s exactly w cells wide.
func fit(s string, w int) string {
	if w <= 0 {
		return ""
	}
	s = ansi.Truncate(s, w, "…")
	return s + strings.Repeat(" ", max(w-ansi.StringWidth(s), 0))
}

// panel draws a rounded box of exactly w×h with a title in the top edge and
// an optional footer in the bottom edge. Body lines are fitted to the inside.
func panel(title, footer string, body []string, w, h, pad int, accent color.Color) string {
	if w < 4 || h < 2 {
		return strings.TrimSuffix(strings.Repeat(strings.Repeat(" ", max(w, 0))+"\n", max(h, 0)), "\n")
	}
	b := fg(cSurface1)
	edge := func(l, r, text string, st lipgloss.Style) string {
		inner := w - 2
		if text == "" || inner < 6 {
			return b.Render(l + strings.Repeat("─", inner) + r)
		}
		t := st.Render(ansi.Truncate(text, inner-4, "…"))
		fill := inner - 3 - ansi.StringWidth(t)
		return b.Render(l+"─ ") + t + b.Render(" "+strings.Repeat("─", max(fill, 0))+r)
	}
	out := make([]string, 0, h)
	out = append(out, edge("╭", "╮", title, fg(accent).Bold(true)))
	side, padS := b.Render("│"), strings.Repeat(" ", pad)
	for i := 0; i < h-2; i++ {
		line := ""
		if i < len(body) {
			line = body[i]
		}
		out = append(out, side+padS+fit(line, w-2-2*pad)+padS+side)
	}
	out = append(out, edge("╰", "╯", footer, fg(cOverlay0)))
	return strings.Join(out, "\n")
}

func (m *Model) renderTree(l layout) string {
	var body []string
	switch {
	case !m.loaded:
		body = []string{"", fg(cOverlay0).Render("  loading…")}
	case len(m.rows) == 0 && m.query != "":
		body = []string{"", fg(cOverlay0).Render("  nothing matches ") + fg(cText).Render(m.query)}
	case len(m.rows) == 0:
		body = []string{"", fg(cOverlay0).Render("  no sessions")}
	}
	end := min(m.offset+l.treeH, len(m.rows))
	for i := m.offset; i < end; i++ {
		body = append(body, m.renderRow(m.rows[i], l.treeW, i == m.cursor))
	}
	title := "Sessions"
	if m.query != "" {
		title = "Filter · " + m.query
	}
	footer := ""
	if len(m.rows) > l.treeH && len(m.rows) > 0 {
		footer = fmt.Sprintf("%d/%d", m.cursor+1, len(m.rows))
	}
	return panel(title, footer, body, l.treePanelW, l.treePanelH, 0, cLavender)
}

func (m *Model) renderRow(r row, w int, selected bool) string {
	paint := func(st lipgloss.Style, s string) string {
		if selected {
			st = st.Background(cSurface0)
		}
		return st.Render(s)
	}
	plain := lipgloss.NewStyle()
	var left, right strings.Builder
	if selected {
		left.WriteString(paint(fg(cMauve), "▌"))
	} else {
		left.WriteString(" ")
	}
	left.WriteString(paint(plain, " "))
	caret := func(open bool) string {
		if open || m.query != "" {
			return paint(fg(cOverlay1), "▾ ")
		}
		return paint(fg(cOverlay1), "▸ ")
	}
	tail := ""
	switch r.kind {
	case rowSession:
		s := r.s
		left.WriteString(caret(m.isOpen(s.ID, rowSession)))
		left.WriteString(paint(fg(cLavender).Bold(true), s.Name))
		if s.ID == m.origin.SessionID {
			left.WriteString(paint(fg(cOverlay0).Italic(true), "  current"))
		}
		if s.Attached {
			right.WriteString(paint(fg(cGreen), "● "))
		}
		right.WriteString(paint(fg(cOverlay1), fmt.Sprintf("%dw", len(s.Windows))))
	case rowWindow:
		w := r.w
		left.WriteString(paint(plain, "  "))
		left.WriteString(caret(m.isOpen(w.ID, rowWindow)))
		left.WriteString(paint(fg(cOverlay2), fmt.Sprintf("%d: ", w.Index)))
		if w.Active {
			left.WriteString(paint(fg(cPink).Bold(true), w.Name))
			left.WriteString(paint(fg(cPink), "*"))
		} else {
			left.WriteString(paint(fg(cBlue), w.Name))
		}
		if w.Zoomed {
			right.WriteString(paint(fg(cYellow), zoomGlyph+" "))
		}
		right.WriteString(paint(fg(cOverlay1), fmt.Sprintf("%dp", len(w.Panes))))
	case rowPane:
		p := r.p
		marked := p.ID == m.mark
		dot, dotSt, cmdSt := "○ ", fg(cOverlay0), fg(cText)
		switch {
		case marked:
			dot, dotSt, cmdSt = "◆ ", fg(cPeach), fg(cPeach).Bold(true)
		case p.Dead:
			dotSt, cmdSt = fg(cRed), fg(cRed)
		case p.Active:
			dot, dotSt, cmdSt = "● ", fg(cGreen), fg(cGreen).Bold(true)
		}
		left.WriteString(paint(plain, "      "))
		left.WriteString(paint(dotSt, dot))
		left.WriteString(paint(fg(cOverlay2), fmt.Sprintf("%d ", p.Index)))
		left.WriteString(paint(cmdSt, p.Command))
		tail = shortPath(p.Path, m.home)
		switch {
		case marked:
			right.WriteString(paint(fg(cPeach), "swap?"))
		case p.Dead:
			right.WriteString(paint(fg(cRed), "dead"))
		}
	}

	l, rt := left.String(), right.String()
	rw := ansi.StringWidth(rt)
	if rw > 0 && w-rw-3 < 8 {
		rt, rw = "", 0
	}
	avail := w - 1
	if rw > 0 {
		avail -= rw + 2
	}
	if tail != "" {
		if room := avail - ansi.StringWidth(l) - 2; room >= 6 {
			if ansi.StringWidth(tail) > room {
				tail = "…" + ansi.TruncateLeft(tail, ansi.StringWidth(tail)-room+1, "")
			}
			l += paint(plain, "  ") + paint(fg(cOverlay1), tail)
		}
	}
	l = ansi.Truncate(l, max(avail, 0), paint(fg(cOverlay0), "…"))
	gap := max(w-ansi.StringWidth(l)-rw-1, 0)
	return l + paint(plain, strings.Repeat(" ", gap)) + rt + paint(plain, " ")
}

func shortPath(p, home string) string {
	if home != "" && home != "/" && (p == home || strings.HasPrefix(p, home+"/")) {
		return "~" + p[len(home):]
	}
	return p
}

func (m *Model) details(w int) string {
	win, p := m.targetWP()
	if p == nil {
		return fit(fg(cOverlay0).Render(" no pane selected"), w)
	}
	sep := fg(cSurface2).Render("  ")
	parts := []string{
		fg(cMauve).Bold(true).Render(p.ID),
		fg(cText).Bold(true).Render(p.Command),
		fg(cBlue).Render(shortPath(p.Path, m.home)),
		fg(cSubtext0).Render(fmt.Sprintf("%d×%d", p.Width, p.Height)),
		fg(cOverlay1).Render(fmt.Sprintf("pid %d", p.PID)),
	}
	if win != nil && win.Zoomed {
		parts = append(parts, fg(cYellow).Render(zoomGlyph+" zoomed"))
	}
	if p.Dead {
		parts = append(parts, fg(cRed).Render("dead"))
	}
	return fit(" "+strings.Join(parts, sep), w)
}

func (m *Model) renderRight(l layout) string {
	win, p := m.targetWP()
	parts := []string{m.layoutMap(win, p, l.rightW, l.mapH), m.details(l.rightW)}
	if l.previewH > 0 {
		title := "Preview"
		if p != nil {
			title += " · " + p.ID + " " + p.Command
		}
		parts = append(parts, panel(title, "", m.previewLines(p, l.rightW-4, l.previewH-2), l.rightW, l.previewH, 1, cBlue))
	}
	return strings.Join(parts, "\n")
}

func (m *Model) layoutMap(win *tmux.Window, p *tmux.Pane, w, h int) string {
	if win == nil {
		return panel("Layout", "", nil, w, h, 1, cPink)
	}
	boxes := make([]minimap.Box, 0, len(win.Panes))
	for _, q := range win.Panes {
		boxes = append(boxes, minimap.Box{
			ID: q.ID, Label: fmt.Sprintf("%d %s", q.Index, q.Command),
			Left: q.Left, Top: q.Top, Width: q.Width, Height: q.Height,
		})
	}
	sel := ""
	if p != nil {
		sel = p.ID
	}
	title := fmt.Sprintf("%d %s", win.Index, win.Name)
	if s := find(m.tree, win.SessionID).s; s != nil {
		title = s.Name + ":" + title
	}
	head := " " + fg(cOverlay1).Render("Layout · ") + fg(cPink).Bold(true).Render(title)
	if win.Zoomed {
		head += fg(cYellow).Render(" " + zoomGlyph + " zoomed")
	}
	mm := minimap.Render(boxes, win.Width, win.Height, sel, w, h-1, m.st.minimap)
	return fit(head, w) + "\n" + mm
}

func (m *Model) previewLines(p *tmux.Pane, w, h int) []string {
	if p == nil || h <= 0 {
		return nil
	}
	c, ok := m.captures[p.ID]
	switch {
	case !ok:
		return []string{fg(cOverlay0).Render("capturing…")}
	case c.err != nil:
		return []string{fg(cRed).Render("capture failed: " + errText(c.err))}
	}
	lines := strings.Split(strings.ReplaceAll(c.text, "\t", "    "), "\n")
	for len(lines) > 0 && strings.TrimSpace(ansi.Strip(lines[len(lines)-1])) == "" {
		lines = lines[:len(lines)-1]
	}
	if len(lines) > h {
		lines = lines[len(lines)-h:]
	}
	out := make([]string, len(lines))
	for i, ln := range lines {
		ln = strings.TrimRight(ln, "\r")
		ln = ansi.Truncate(ln, w, "") + ansi.ResetStyle + ansi.ResetHyperlink()
		out[i] = ln + strings.Repeat(" ", max(w-ansi.StringWidth(ln), 0))
	}
	return out
}

func (m *Model) statusLine() string {
	var s string
	switch {
	case m.filtering:
		s = " " + m.filter.View()
	case m.flash != "" && m.flashErr:
		s = " " + fg(cRed).Render("✗ "+m.flash)
	case m.flash != "":
		s = " " + fg(cGreen).Render("✓ ") + fg(cSubtext0).Render(m.flash)
	case m.mark != "":
		s = " " + fg(cPeach).Render("◆ "+m.mark+" marked") +
			fg(cOverlay1).Render(" · s on another pane swaps them · esc clears")
	case m.query != "":
		s = " " + fg(cOverlay1).Render("filtered · / to edit · esc clears")
	}
	return fit(s, m.w)
}

// Overlays

func (m *Model) boxWidth(want int) int {
	return max(min(want, m.w-4), 20)
}

func box(accent color.Color, w int, lines ...string) string {
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(accent).
		Padding(0, 1).
		Width(w).
		Render(strings.Join(lines, "\n"))
}

func hint(pairs ...string) string {
	var parts []string
	for i := 0; i+1 < len(pairs); i += 2 {
		parts = append(parts, fg(cBlue).Render(pairs[i])+" "+fg(cOverlay1).Render(pairs[i+1]))
	}
	return strings.Join(parts, fg(cSurface2).Render(" · "))
}

func (m *Model) promptBox() string {
	w := m.boxWidth(64)
	inner := w - 4
	return box(cMauve, w,
		fg(cMauve).Bold(true).Render(ansi.Truncate(m.prompt.title, inner, "…")),
		"",
		m.prompt.input.View(),
		"",
		hint("enter", "confirm", "esc", "cancel"),
	)
}

func (m *Model) confirmBox() string {
	w := m.boxWidth(56)
	inner := w - 4
	lines := []string{fg(cRed).Bold(true).Render(ansi.Truncate(m.confirm.question, inner, "…"))}
	if m.confirm.detail != "" {
		lines = append(lines, fg(cOverlay1).Render(ansi.Truncate(m.confirm.detail, inner, "…")))
	}
	lines = append(lines, "", fg(cRed).Bold(true).Render("y")+" "+fg(cOverlay1).Render("kill")+
		fg(cSurface2).Render(" · ")+fg(cOverlay1).Render("any other key cancels"))
	return box(cRed, w, lines...)
}

func (m *Model) pickerBox() string {
	pk := m.picker
	w := m.boxWidth(60)
	inner := w - 4
	lines := []string{fg(cMauve).Bold(true).Render(ansi.Truncate("Move "+pk.paneLabel+" into…", inner, "…")), ""}

	vis := clamp(m.h-12, 1, len(pk.targets))
	off := clamp(pk.cursor-vis/2, 0, len(pk.targets)-vis)
	for i := off; i < off+vis; i++ {
		t := pk.targets[i]
		if i == pk.cursor {
			bg := lipgloss.NewStyle().Background(cSurface0)
			lines = append(lines, fg(cMauve).Background(cSurface0).Render("▌ ")+
				bg.Foreground(cText).Bold(true).Render(fit(t.label, inner-2)))
		} else {
			lines = append(lines, "  "+fg(cSubtext0).Render(ansi.Truncate(t.label, inner-2, "…")))
		}
	}
	if len(pk.targets) > vis {
		lines = append(lines, fg(cOverlay0).Render(fmt.Sprintf("  %d/%d", pk.cursor+1, len(pk.targets))))
	}

	on := lipgloss.NewStyle().Background(cMauve).Foreground(cCrust).Bold(true).Padding(0, 1)
	off2 := fg(cOverlay1).Padding(0, 1)
	side, stack := off2.Render("│ side by side"), off2.Render("─ stacked")
	if pk.horizontal {
		side = on.Render("│ side by side")
	} else {
		stack = on.Render("─ stacked")
	}
	lines = append(lines, "", fg(cOverlay1).Render("split ")+side+" "+stack, "",
		hint("enter", "move", "tab", "split", "esc", "cancel"))
	return box(cMauve, w, lines...)
}

func (m *Model) helpBox() string {
	secs := fullHelp()
	cols := make([]string, len(secs))
	for i, sec := range secs {
		kw := 0
		for _, b := range sec.keys {
			kw = max(kw, ansi.StringWidth(b.Help().Key))
		}
		lines := []string{fg(cMauve).Bold(true).Render(sec.title)}
		for _, b := range sec.keys {
			k := b.Help().Key
			lines = append(lines, fg(cBlue).Render(k+strings.Repeat(" ", kw-ansi.StringWidth(k)))+"  "+fg(cSubtext0).Render(b.Help().Desc))
		}
		cols[i] = strings.Join(lines, "\n")
	}
	join := func(cs ...string) string {
		var parts []string
		for i, c := range cs {
			if i > 0 {
				parts = append(parts, "   ")
			}
			parts = append(parts, c)
		}
		return lipgloss.JoinHorizontal(lipgloss.Top, parts...)
	}
	stack := func(cs ...string) string { return strings.Join(cs, "\n\n") }
	// Widest first; take the first arrangement that fits the popup.
	candidates := []string{
		join(cols...),
		join(cols[0], cols[1], stack(cols[2], cols[3])),
		join(stack(cols[0], cols[3]), stack(cols[1], cols[2])),
		stack(cols...),
	}
	maxW, maxH := m.w-2, m.h-4 // box border + title + blank line
	content := candidates[len(candidates)-1]
	for _, c := range candidates {
		if lipgloss.Width(c)+4 <= maxW && lipgloss.Height(c) < lipgloss.Height(content) {
			content = c
		}
		if lipgloss.Width(c)+4 <= maxW && lipgloss.Height(c) <= maxH {
			content = c
			break
		}
	}
	if lines := strings.Split(content, "\n"); len(lines) > maxH {
		lines = append(lines[:max(maxH-1, 0)], fg(cOverlay0).Render("… enlarge the popup for more"))
		content = strings.Join(lines, "\n")
	}
	title := fg(cMauve).Bold(true).Render("Keys") + fg(cOverlay0).Render(" · any key closes")
	w := min(lipgloss.Width(content)+4, maxW)
	return box(cMauve, w, title, "", content)
}

func (m *Model) promptInputWidth() int {
	return max(m.boxWidth(64)-4-ansi.StringWidth("› ")-1, 1)
}
