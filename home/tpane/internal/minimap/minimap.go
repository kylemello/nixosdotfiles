package minimap

import (
	"strings"
	"unicode"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// Box is one pane, in tmux window cells (pane_left/top/width/height).
type Box struct {
	ID                       string
	Label                    string
	Left, Top, Width, Height int
}

type Styles struct {
	Border        lipgloss.Style // outer frame and dividers
	Selected      lipgloss.Style // edges of the selected box
	Label         lipgloss.Style
	SelectedLabel lipgloss.Style
}

// Render draws the window layout scaled into exactly h lines of exactly w
// cells each. winW/winH are window_width/window_height; selected is a Box.ID,
// or "" for none.
func Render(boxes []Box, winW, winH int, selected string, w, h int, st Styles) string {
	if h <= 0 {
		return ""
	}
	if w <= 0 {
		return strings.Repeat("\n", h-1)
	}
	return draw(boxes, winW, winH, selected, w, h).render(st)
}

const (
	up uint8 = 1 << iota
	down
	left
	right
)

type kind uint8

// Ordered so that a stronger kind wins when two boxes touch the same cell.
const (
	empty kind = iota
	border
	selectedBorder
	label
	selectedLabel
)

type cell struct {
	mask    uint8
	kind    kind
	text    string // label text, on the label's first cell
	covered bool   // inside a label, after its first cell
}

type canvas struct {
	w, h   int
	cells  [][]cell
	placed []placed // scaled boxes, in input order minus skipped ones
}

type placed struct {
	id, label      string
	x0, y0, x1, y1 int
	sel            bool
}

// Far beyond tmux's own window size limit; keeps the scaling arithmetic from
// overflowing on garbage input.
const maxCells = 1 << 20

// draw lays the window out in "border space": tmux columns -1..winW, where
// -1 and winW are the outer frame and a pane's edges sit at Left-1 and
// Left+Width. Adjacent panes share an edge coordinate there (next.Left-1 ==
// prev.Left+prev.Width), and the scaling is monotonic, so a shared border
// always lands on one output column and boxes never cross.
func draw(boxes []Box, winW, winH int, selected string, w, h int) *canvas {
	c := &canvas{w: w, h: h, cells: make([][]cell, h)}
	for y := range c.cells {
		c.cells[y] = make([]cell, w)
	}
	if w < 2 || h < 2 {
		return c
	}
	c.rect(0, 0, w-1, h-1, border)
	if winW <= 0 || winH <= 0 {
		return c
	}
	winW, winH = min(winW, maxCells), min(winH, maxCells)

	type edges struct{ x0, y0, x1, y1 int }
	var raw []edges
	var valid []Box
	for _, b := range boxes {
		if b.Width <= 0 || b.Height <= 0 {
			continue
		}
		l, t := clampCells(b.Left), clampCells(b.Top)
		raw = append(raw, edges{l - 1, t - 1, l + clampCells(b.Width), t + clampCells(b.Height)})
		valid = append(valid, b)
	}
	// Map the panes' bounding box onto the frame rather than the window: with
	// pane-border-status on, tmux spends a row on the status line and the
	// outermost pane edge sits one row inside the window.
	sx, sy := span{-1, winW}, span{-1, winH}
	if len(raw) > 0 {
		bx, by := span{raw[0].x0, raw[0].x1}, span{raw[0].y0, raw[0].y1}
		for _, e := range raw[1:] {
			bx = span{min(bx.lo, e.x0), max(bx.hi, e.x1)}
			by = span{min(by.lo, e.y0), max(by.hi, e.y1)}
		}
		sx, sy = sx.within(bx), sy.within(by)
	}

	for i, b := range valid {
		e := raw[i]
		p := placed{
			id:    b.ID,
			label: b.Label,
			x0:    sx.scale(e.x0, w),
			x1:    sx.scale(e.x1, w),
			y0:    sy.scale(e.y0, h),
			y1:    sy.scale(e.y1, h),
			sel:   selected != "" && b.ID == selected,
		}
		k := border
		if p.sel {
			k = selectedBorder
		}
		c.rect(p.x0, p.y0, p.x1, p.y1, k)
		c.placed = append(c.placed, p)
	}
	// Labels go on only after every edge is drawn, so the emptiness check in
	// label sees all of them.
	for _, p := range c.placed {
		k := label
		if p.sel {
			k = selectedLabel
		}
		c.label(p.label, p.x0, p.y0, p.x1, p.y1, k)
	}
	return c
}

func clampCells(v int) int { return min(max(v, -maxCells), maxCells) }

// span is a border-space range whose ends map to the frame.
type span struct{ lo, hi int }

// within narrows s to b, keeping s when b is outside it or empty.
func (s span) within(b span) span {
	n := span{max(s.lo, b.lo), min(s.hi, b.hi)}
	if n.lo >= n.hi {
		return s
	}
	return n
}

// scale maps v in [lo, hi] onto [0, out-1], rounding to nearest.
func (s span) scale(v, out int) int {
	v = min(max(v, s.lo), s.hi) - s.lo
	n := s.hi - s.lo
	r := (2*v*(out-1) + n) / (2 * n)
	return min(max(r, 0), out-1)
}

func (c *canvas) mark(x, y int, bits uint8, k kind) {
	cl := &c.cells[y][x]
	cl.mask |= bits
	if k > cl.kind {
		cl.kind = k
	}
}

func (c *canvas) rect(x0, y0, x1, y1 int, k kind) {
	for _, y := range []int{y0, y1} {
		for x := x0; x <= x1; x++ {
			var bits uint8
			if x > x0 {
				bits |= left
			}
			if x < x1 {
				bits |= right
			}
			c.mark(x, y, bits, k)
		}
	}
	for _, x := range []int{x0, x1} {
		for y := y0; y <= y1; y++ {
			var bits uint8
			if y > y0 {
				bits |= up
			}
			if y < y1 {
				bits |= down
			}
			c.mark(x, y, bits, k)
		}
	}
}

func (c *canvas) label(s string, x0, y0, x1, y1 int, k kind) {
	iw, ih := x1-x0-1, y1-y0-1
	if iw < 1 || ih < 1 {
		return
	}
	s = sanitize(s)
	lw := ansi.StringWidth(s)
	if lw > iw {
		if iw < 2 {
			return
		}
		s = ansi.Truncate(s, iw, "…")
		lw = ansi.StringWidth(s)
	}
	// A trailing prepend mark would fuse with the next glyph into one grapheme.
	if lw == 0 || ansi.StringWidth(s+"│") != lw+1 || ansi.StringWidth(s+" ") != lw+1 {
		return
	}
	y := y0 + 1 + (ih-1)/2
	x := x0 + 1 + (iw-lw)/2
	row := c.cells[y]
	for i := x; i < x+lw; i++ {
		if row[i].mask != 0 || row[i].kind != empty || row[i].covered {
			return
		}
	}
	row[x].kind, row[x].text = k, s
	for i := x + 1; i < x+lw; i++ {
		row[i].kind, row[i].covered = k, true
	}
}

func sanitize(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, ansi.Strip(s))
}

var glyphs = [16]string{
	0:                        " ",
	up:                       "│",
	down:                     "│",
	up | down:                "│",
	left:                     "─",
	right:                    "─",
	left | right:             "─",
	down | right:             "╭",
	down | left:              "╮",
	up | right:               "╰",
	up | left:                "╯",
	up | down | right:        "├",
	up | down | left:         "┤",
	down | left | right:      "┬",
	up | left | right:        "┴",
	up | down | left | right: "┼",
}

func (c *canvas) render(st Styles) string {
	styles := map[kind]*lipgloss.Style{
		border:         &st.Border,
		selectedBorder: &st.Selected,
		label:          &st.Label,
		selectedLabel:  &st.SelectedLabel,
	}
	lines := make([]string, c.h)
	var line, run strings.Builder
	for y, row := range c.cells {
		line.Reset()
		cur := empty
		flush := func() {
			if run.Len() == 0 {
				return
			}
			raw := run.String()
			run.Reset()
			// A style that pads, or underlines rune by rune and so splits
			// graphemes, changes the width; drop it rather than misalign.
			if s := styles[cur]; s != nil {
				if r := s.Render(raw); !strings.Contains(r, "\n") && lipgloss.Width(r) == ansi.StringWidth(raw) {
					raw = r
				}
			}
			line.WriteString(raw)
		}
		for _, cl := range row {
			if cl.covered {
				continue
			}
			if cl.kind != cur {
				flush()
				cur = cl.kind
			}
			switch cl.kind {
			case label, selectedLabel:
				run.WriteString(cl.text)
			default:
				run.WriteString(glyphs[cl.mask])
			}
		}
		flush()
		lines[y] = fit(line.String(), c.w)
	}
	return strings.Join(lines, "\n")
}

// fit is a last guard on the exact width, e.g. if the cell widths of a label
// and its truncation disagree.
func fit(s string, w int) string {
	if lipgloss.Width(s) > w {
		s = ansi.Truncate(s, w, "")
	}
	if sw := lipgloss.Width(s); sw < w {
		s += strings.Repeat(" ", w-sw)
	}
	return s
}
