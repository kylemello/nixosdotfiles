package minimap

import (
	"math"
	"math/rand"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

var (
	twoSide = []Box{
		{ID: "a", Label: "0 a", Left: 0, Top: 0, Width: 40, Height: 24},
		{ID: "b", Label: "1 b", Left: 41, Top: 0, Width: 40, Height: 24},
	}
	mainVertical = []Box{
		{ID: "a", Label: "0 a", Left: 0, Top: 0, Width: 40, Height: 24},
		{ID: "b", Label: "1 b", Left: 41, Top: 0, Width: 40, Height: 11},
		{ID: "c", Label: "2 c", Left: 41, Top: 12, Width: 40, Height: 12},
	}
	tiled = []Box{
		{ID: "a", Label: "0", Left: 0, Top: 0, Width: 40, Height: 11},
		{ID: "b", Label: "1", Left: 41, Top: 0, Width: 40, Height: 11},
		{ID: "c", Label: "2", Left: 0, Top: 12, Width: 40, Height: 12},
		{ID: "d", Label: "3", Left: 41, Top: 12, Width: 40, Height: 12},
	}
	staggered = []Box{
		{ID: "a", Label: "0", Left: 0, Top: 0, Width: 40, Height: 7},
		{ID: "b", Label: "1", Left: 41, Top: 0, Width: 40, Height: 15},
		{ID: "c", Label: "2", Left: 0, Top: 8, Width: 40, Height: 16},
		{ID: "d", Label: "3", Left: 41, Top: 16, Width: 40, Height: 8},
	}
	evenHorizontal = []Box{
		{ID: "a", Label: "0", Left: 0, Top: 0, Width: 26, Height: 24},
		{ID: "b", Label: "1", Left: 27, Top: 0, Width: 26, Height: 24},
		{ID: "c", Label: "2", Left: 54, Top: 0, Width: 26, Height: 24},
	}
)

func TestJunctions(t *testing.T) {
	tests := []struct {
		name       string
		boxes      []Box
		winW, winH int
		w, h       int
		want       []string
	}{
		{"two side by side", twoSide, 81, 24, 21, 7, []string{
			"╭─────────┬─────────╮",
			"│         │         │",
			"│         │         │",
			"│   0 a   │   1 b   │",
			"│         │         │",
			"│         │         │",
			"╰─────────┴─────────╯",
		}},
		{"main vertical", mainVertical, 81, 24, 21, 7, []string{
			"╭─────────┬─────────╮",
			"│         │   1 b   │",
			"│         │         │",
			"│   0 a   ├─────────┤",
			"│         │   2 c   │",
			"│         │         │",
			"╰─────────┴─────────╯",
		}},
		{"tiled four", tiled, 81, 24, 21, 7, []string{
			"╭─────────┬─────────╮",
			"│    0    │    1    │",
			"│         │         │",
			"├─────────┼─────────┤",
			"│    2    │    3    │",
			"│         │         │",
			"╰─────────┴─────────╯",
		}},
		{"staggered splits", staggered, 81, 24, 21, 7, []string{
			"╭─────────┬─────────╮",
			"│    0    │         │",
			"├─────────┤    1    │",
			"│         │         │",
			"│    2    ├─────────┤",
			"│         │    3    │",
			"╰─────────┴─────────╯",
		}},
		{"three even horizontal", evenHorizontal, 80, 24, 21, 3, []string{
			"╭──────┬─────┬──────╮",
			"│  0   │  1  │  2   │",
			"╰──────┴─────┴──────╯",
		}},
		{"no boxes", nil, 80, 24, 6, 3, []string{
			"╭────╮",
			"│    │",
			"╰────╯",
		}},
		{"zero window", twoSide, 0, 0, 4, 2, []string{
			"╭──╮",
			"╰──╯",
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := strings.Split(ansi.Strip(Render(tt.boxes, tt.winW, tt.winH, "", tt.w, tt.h, Styles{})), "\n")
			if strings.Join(got, "\n") != strings.Join(tt.want, "\n") {
				t.Errorf("got:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(tt.want, "\n"))
			}
		})
	}
}

func checkShape(t *testing.T, out string, w, h int) {
	t.Helper()
	if h <= 0 {
		if out != "" {
			t.Fatalf("h=%d: want empty output, got %q", h, out)
		}
		return
	}
	lines := strings.Split(out, "\n")
	if len(lines) != h {
		t.Fatalf("w=%d h=%d: got %d lines", w, h, len(lines))
	}
	for i, l := range lines {
		if got := lipgloss.Width(l); got != max(w, 0) {
			t.Fatalf("w=%d h=%d: line %d has width %d: %q", w, h, i, got, l)
		}
	}
}

func TestShape(t *testing.T) {
	odd := []Box{
		{ID: "one", Label: "x", Left: 0, Top: 0, Width: 1, Height: 1},
		{ID: "neg", Label: "neg", Left: -5, Top: -5, Width: 3, Height: 3},
		{ID: "out", Label: "out", Left: 500, Top: 500, Width: 10, Height: 10},
		{ID: "zero", Label: "zero", Left: 3, Top: 3, Width: 0, Height: 0},
		{ID: "huge", Label: "huge", Left: 0, Top: 0, Width: math.MaxInt / 4, Height: math.MaxInt / 4},
		{ID: "overlap", Label: "overlapping label", Left: 2, Top: 2, Width: 50, Height: 10},
	}
	var thin []Box
	for i := range 100 {
		thin = append(thin, Box{ID: string(rune('a' + i%26)), Label: "p", Left: i * 2, Top: 0, Width: 1, Height: 24})
	}
	layouts := []struct {
		boxes      []Box
		winW, winH int
	}{
		{nil, 80, 24},
		{nil, 0, 0},
		{twoSide, 81, 24},
		{mainVertical, 81, 24},
		{tiled, 81, 24},
		{staggered, 81, 24},
		{evenHorizontal, 80, 24},
		{tiled, 0, 24},
		{tiled, 81, -3},
		{tiled, 1, 1},
		{odd, 80, 24},
		{odd, math.MaxInt / 2, math.MaxInt / 2},
		{odd, math.MaxInt, math.MaxInt},
		{tiled, math.MaxInt, 24},
		{thin, 199, 24},
	}
	stylesets := []Styles{
		{},
		{
			Border:        lipgloss.NewStyle().Foreground(lipgloss.Color("#6c7086")),
			Selected:      lipgloss.NewStyle().Foreground(lipgloss.Color("#cba6f7")).Bold(true),
			Label:         lipgloss.NewStyle().Foreground(lipgloss.Color("#cdd6f4")),
			SelectedLabel: lipgloss.NewStyle().Foreground(lipgloss.Color("#cba6f7")),
		},
	}
	for _, l := range layouts {
		for _, st := range stylesets {
			for w := -1; w <= 30; w++ {
				for h := -1; h <= 12; h++ {
					for _, sel := range []string{"", "a", "one", "huge"} {
						checkShape(t, Render(l.boxes, l.winW, l.winH, sel, w, h, st), w, h)
					}
				}
			}
			checkShape(t, Render(l.boxes, l.winW, l.winH, "a", 300, 80, st), 300, 80)
		}
	}
}

// tile splits a window the way tmux does: every split leaves a 1-cell border.
func tile(r *rand.Rand, x, y, w, h, depth int, out *[]Box) {
	vertical := w >= 3 && (h < 3 || r.Intn(2) == 0)
	if depth == 0 || (w < 3 && h < 3) || r.Intn(5) == 0 {
		*out = append(*out, Box{ID: strconv.Itoa(len(*out)), Label: "pane", Left: x, Top: y, Width: w, Height: h})
		return
	}
	if vertical {
		a := 1 + r.Intn(w-2)
		tile(r, x, y, a, h, depth-1, out)
		tile(r, x+a+1, y, w-a-1, h, depth-1, out)
		return
	}
	a := 1 + r.Intn(h-2)
	tile(r, x, y, w, a, depth-1, out)
	tile(r, x, y+a+1, w, h-a-1, depth-1, out)
}

// Panes that share a tmux border share one scaled edge, edge panes sit on the
// frame, and no line ever runs through a pane's interior.
func TestTilingGeometry(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	for range 2000 {
		winW, winH := 1+r.Intn(250), 1+r.Intn(70)
		var boxes []Box
		tile(r, 0, 0, winW, winH, 5, &boxes)
		w, h := 2+r.Intn(80), 2+r.Intn(30)
		c := draw(boxes, winW, winH, boxes[r.Intn(len(boxes))].ID, w, h)
		fail := func(format string, args ...any) {
			t.Helper()
			t.Fatalf("win %dx%d out %dx%d %v: "+format, append([]any{winW, winH, w, h, boxes}, args...)...)
		}
		if len(c.placed) != len(boxes) {
			fail("placed %d of %d boxes", len(c.placed), len(boxes))
		}
		for i, a := range boxes {
			pa := c.placed[i]
			if a.Left == 0 && pa.x0 != 0 || a.Top == 0 && pa.y0 != 0 ||
				a.Left+a.Width == winW && pa.x1 != w-1 || a.Top+a.Height == winH && pa.y1 != h-1 {
				fail("box %s not on the frame: %+v", a.ID, pa)
			}
			for j, b := range boxes {
				pb := c.placed[j]
				if a.Left+a.Width+1 == b.Left && pa.x1 != pb.x0 {
					fail("vertical border %s|%s on columns %d and %d", a.ID, b.ID, pa.x1, pb.x0)
				}
				if a.Top+a.Height+1 == b.Top && pa.y1 != pb.y0 {
					fail("horizontal border %s/%s on rows %d and %d", a.ID, b.ID, pa.y1, pb.y0)
				}
			}
			for y := pa.y0 + 1; y < pa.y1; y++ {
				for x := pa.x0 + 1; x < pa.x1; x++ {
					if c.cells[y][x].mask != 0 {
						fail("line inside box %s at %d,%d", a.ID, x, y)
					}
				}
			}
		}
		for y, row := range c.cells {
			for x, cl := range row {
				if cl.mask&right != 0 && (x+1 == w || row[x+1].mask&left == 0) {
					fail("dangling line at %d,%d", x, y)
				}
				if cl.mask&down != 0 && (y+1 == h || c.cells[y+1][x].mask&up == 0) {
					fail("dangling line at %d,%d", x, y)
				}
			}
		}
		corners := map[[2]int]uint8{{0, 0}: down | right, {w - 1, 0}: down | left, {0, h - 1}: up | right, {w - 1, h - 1}: up | left}
		for p, want := range corners {
			if got := c.cells[p[1]][p[0]].mask; got != want {
				fail("corner %v: mask %b, want %b", p, got, want)
			}
		}
		checkShape(t, c.render(Styles{}), w, h)
	}
}

// pane-border-status puts a status row inside the window, so the outermost
// pane edge is one row in; it must still map onto the frame, not beside it.
func TestBorderStatus(t *testing.T) {
	top := []Box{
		{ID: "a", Label: "0", Left: 0, Top: 1, Width: 40, Height: 23},
		{ID: "b", Label: "1", Left: 41, Top: 1, Width: 40, Height: 23},
	}
	bottom := []Box{
		{ID: "a", Label: "0", Left: 0, Top: 0, Width: 40, Height: 23},
		{ID: "b", Label: "1", Left: 41, Top: 0, Width: 40, Height: 23},
	}
	for _, bs := range [][]Box{top, bottom} {
		lines := strings.Split(ansi.Strip(Render(bs, 81, 24, "", 30, 16, Styles{})), "\n")
		for y, l := range lines[1 : len(lines)-1] {
			if !strings.HasPrefix(l, "│") || !strings.HasSuffix(l, "│") {
				t.Fatalf("row %d is not an interior row: %q\n%s", y+1, l, strings.Join(lines, "\n"))
			}
		}
	}
}

// Styles that change a run's width (padding, per-rune underline splitting a
// ZWJ emoji) must not cost the frame its right edge.
func TestWidthChangingStyles(t *testing.T) {
	bad := []Styles{
		{SelectedLabel: lipgloss.NewStyle().Underline(true), Label: lipgloss.NewStyle().Strikethrough(true)},
		{Label: lipgloss.NewStyle().Padding(0, 2), SelectedLabel: lipgloss.NewStyle().Padding(1), Border: lipgloss.NewStyle().PaddingLeft(1)},
	}
	for _, label := range []string{"0 👨‍👩‍👧 x", "🇺🇸🇺", "0 nvim", "日本語"} {
		boxes := []Box{
			{ID: "a", Label: label, Left: 0, Top: 0, Width: 40, Height: 24},
			{ID: "b", Label: label, Left: 41, Top: 0, Width: 40, Height: 24},
		}
		for _, st := range bad {
			for w := 2; w <= 30; w++ {
				out := Render(boxes, 81, 24, "a", w, 5, st)
				checkShape(t, out, w, 5)
				for _, l := range strings.Split(ansi.Strip(out), "\n") {
					if r := []rune(l); r[len(r)-1] != '│' && r[len(r)-1] != '╮' && r[len(r)-1] != '╯' {
						t.Fatalf("label %q w=%d: right edge lost: %q", label, w, l)
					}
				}
			}
		}
	}
}

// styledCells reports, per display cell, whether it was rendered inside the
// SGR sequence open.
func styledCells(line, open string) []bool {
	var cells []bool
	in := false
	for len(line) > 0 {
		switch {
		case strings.HasPrefix(line, open):
			in = true
			line = line[len(open):]
		case strings.HasPrefix(line, "\x1b["):
			end := strings.IndexByte(line, 'm')
			in = false
			line = line[end+1:]
		default:
			_, size := utf8.DecodeRuneInString(line)
			cells = append(cells, in)
			line = line[size:]
		}
	}
	return cells
}

func sgrOpen(s lipgloss.Style) string {
	r := s.Render("X")
	return r[:strings.Index(r, "X")]
}

func TestSelectedStyle(t *testing.T) {
	st := Styles{
		Selected:      lipgloss.NewStyle().Foreground(lipgloss.Color("#ff0000")),
		SelectedLabel: lipgloss.NewStyle().Foreground(lipgloss.Color("#0000ff")),
	}
	// "b" is the top-right pane: columns 10..20, rows 0..3.
	out := Render(mainVertical, 81, 24, "b", 21, 7, st)
	lines := strings.Split(out, "\n")
	sel, lab := sgrOpen(st.Selected), sgrOpen(st.SelectedLabel)
	for y, l := range lines {
		got := styledCells(l, sel)
		if len(got) != 21 {
			t.Fatalf("line %d: %d cells", y, len(got))
		}
		for x, isSel := range got {
			want := y <= 3 && (x == 10 || x == 20) || (y == 0 || y == 3) && x >= 10
			if isSel != want {
				t.Errorf("cell %d,%d selected=%v, want %v\n%s", x, y, isSel, want, ansi.Strip(out))
			}
		}
	}
	labCells := styledCells(lines[1], lab)
	for x, in := range labCells {
		if want := x >= 14 && x <= 16; in != want {
			t.Errorf("label cell %d styled=%v, want %v", x, in, want)
		}
	}
	if strings.Contains(Render(mainVertical, 81, 24, "", 21, 7, st), sel) {
		t.Error("selected style used with nothing selected")
	}
	if strings.Contains(Render(mainVertical, 81, 24, "nope", 21, 7, st), sel) {
		t.Error("selected style used for an unknown id")
	}
}

func TestLabels(t *testing.T) {
	one := func(label string, w int) string {
		b := []Box{{ID: "a", Label: label, Left: 0, Top: 0, Width: 80, Height: 24}}
		return strings.Split(ansi.Strip(Render(b, 80, 24, "", w, 3, Styles{})), "\n")[1]
	}
	tests := []struct {
		label string
		w     int
		want  string
	}{
		{"0 nvim", 10, "│ 0 nvim │"},
		{"0 nvim", 7, "│0 nv…│"},
		{"0 nvim", 4, "│0…│"},
		{"0 nvim", 3, "│ │"},
		{"", 6, "│    │"},
		{"a\nb\tc", 7, "│a b c│"},
		{"\x1b[31mred\x1b[m", 7, "│ red │"},
		{"日本", 8, "│ 日本 │"},
		{"x؀", 6, "│    │"},
		{"日本語", 6, "│日… │"},
	}
	for _, tt := range tests {
		got := one(tt.label, tt.w)
		if got != tt.want {
			t.Errorf("label %q at w=%d: got %q, want %q", tt.label, tt.w, got, tt.want)
		}
		if lipgloss.Width(got) != tt.w {
			t.Errorf("label %q at w=%d: width %d", tt.label, tt.w, lipgloss.Width(got))
		}
	}
}

func TestScale(t *testing.T) {
	for n := 1; n < 300; n++ {
		s := span{-1, n}
		for out := 2; out < 120; out++ {
			if s.scale(-1, out) != 0 || s.scale(n, out) != out-1 {
				t.Fatalf("n=%d out=%d: frame maps to %d..%d", n, out, s.scale(-1, out), s.scale(n, out))
			}
			prev := 0
			for v := -1; v <= n; v++ {
				got := s.scale(v, out)
				if got < prev {
					t.Fatalf("n=%d out=%d: not monotonic at %d", n, out, v)
				}
				prev = got
			}
		}
	}
}
