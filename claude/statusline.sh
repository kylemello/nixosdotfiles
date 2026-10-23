#!/usr/bin/env bash
# Claude Code status line. Mirrors the info line of fish_prompt in home/fish.nix
# (catppuccin-mocha colors), with session info right-aligned in place of timing.
# Kept bash-3.2 safe for macOS.

{
  read -r dir; read -r model; read -r effort
  read -r ctx; read -r five; read -r seven
  read -r cost; read -r added; read -r removed
} < <(jq -r '
  .workspace.current_dir // .cwd // "",
  .model.display_name // "",
  .effort.level // "",
  (.context_window.used_percentage,
   .rate_limits.five_hour.used_percentage,
   .rate_limits.seven_day.used_percentage
   | if type == "number" then floor else "" end),
  (.cost.total_cost_usd // 0 | if . > 0 then . else "" end),
  .cost.total_lines_added // 0,
  .cost.total_lines_removed // 0')

reset=$'\033[m'
user_c=$'\033[38;2;148;226;213m'
host_c=$'\033[38;2;137;180;250m'
[ -n "$SSH_TTY" ] && host_c=$'\033[38;2;166;227;161m'
cwd_c=$'\033[38;2;249;226;175m'
vcs_c=$'\033[95m'
dim_c=$'\033[90m'
warn_c=$'\033[38;2;249;226;175m'
crit_c=$'\033[38;2;243;139;168m'
add_c=$'\033[38;2;166;227;161m'
del_c=$'\033[38;2;243;139;168m'

host=${HOSTNAME:-$(uname -n)}
host=${host%%.*}

case $dir in
  "$HOME") shown="~" ;;
  "$HOME"/*) shown="~${dir#"$HOME"}" ;;
  *) shown=$dir ;;
esac

branch=$(git -C "$dir" --no-optional-locks symbolic-ref --short -q HEAD 2>/dev/null \
  || git -C "$dir" --no-optional-locks rev-parse --short HEAD 2>/dev/null)

left="${user_c}${USER:-$(id -un)}${reset}@${host_c}${host}${reset} ${cwd_c}${shown}"
[ -n "$branch" ] && left+="${vcs_c} (${branch})"
left+="${reset}"

# Gray under 50%, yellow from 50%, red from 80%.
heat() {
  if [ "$1" -ge 80 ]; then hc=$crit_c
  elif [ "$1" -ge 50 ]; then hc=$warn_c
  else hc=$dim_c
  fi
}

segs=()
name="${model}${effort:+ $effort}"
[ -n "$name" ] && segs+=("${dim_c}${name# }")
if [ -n "$ctx" ]; then heat "$ctx"; segs+=("${hc}${ctx}% ctx"); fi
if [ -n "$five" ]; then heat "$five"; segs+=("${hc}5h ${five}%"); fi
if [ -n "$seven" ]; then heat "$seven"; segs+=("${hc}7d ${seven}%"); fi
[ -n "$cost" ] && segs+=("${dim_c}$(printf '$%.2f' "$cost")")
[ $((added + removed)) -gt 0 ] && segs+=("${add_c}+${added} ${del_c}−${removed}")

[ ${#segs[@]} -eq 0 ] && { printf '%s' "$left"; exit; }
right=${segs[0]}
for s in "${segs[@]:1}"; do right+="${dim_c} · ${s}"; done
right+=$reset

width() {
  local s
  s=$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g')
  echo "${#s}"
}

# COLUMNS is the full terminal width; margin leaves room for Claude Code's own
# row spacing. Raise it if the right edge wraps, lower it if it sits short.
margin=4
pad=$(( ${COLUMNS:-80} - $(width "$left") - $(width "$right") - margin ))

# Too narrow for one line: put the session info on a second row instead.
if [ "$pad" -lt 2 ]; then
  printf '%s\n%s' "$left" "$right"
else
  printf '%s%*s%s' "$left" "$pad" '' "$right"
fi
