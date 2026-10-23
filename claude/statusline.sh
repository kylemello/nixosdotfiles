#!/usr/bin/env bash
# Claude Code status line. Mirrors the info line of fish_prompt in home/fish.nix
# (catppuccin-mocha colors), then the model and context used in place of timing.
# Kept bash-3.2 safe for macOS.

{ read -r dir; read -r model; read -r ctx; } < <(jq -r '
  .workspace.current_dir // .cwd // "",
  .model.display_name // "",
  (.context_window.used_percentage // "" | if type == "number" then floor else . end)')

reset=$'\033[m'
user_c=$'\033[38;2;148;226;213m'
host_c=$'\033[38;2;137;180;250m'
[ -n "$SSH_TTY" ] && host_c=$'\033[38;2;166;227;161m'
cwd_c=$'\033[38;2;249;226;175m'
vcs_c=$'\033[95m'
dim_c=$'\033[90m'

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

extra=$model
[ -n "$ctx" ] && extra+="${extra:+ · }${ctx}% ctx"
[ -z "$extra" ] && { printf '%s' "$left"; exit; }
right="${dim_c}${extra}${reset}"

width() {
  local s
  s=$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g')
  echo "${#s}"
}

# COLUMNS is the full terminal width; margin leaves room for Claude Code's own
# row spacing. Raise it if the right edge wraps, lower it if it sits short.
margin=4
pad=$(( ${COLUMNS:-80} - $(width "$left") - $(width "$right") - margin ))
[ "$pad" -lt 2 ] && pad=2

printf '%s%*s%s' "$left" "$pad" '' "$right"
