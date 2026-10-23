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

line="${user_c}${USER:-$(id -un)}${reset}@${host_c}${host}${reset} ${cwd_c}${shown}"
[ -n "$branch" ] && line+="${vcs_c} (${branch})"
line+="${reset}"

extra=$model
[ -n "$ctx" ] && extra+="${extra:+ · }${ctx}% ctx"
[ -n "$extra" ] && line+="  ${dim_c}${extra}${reset}"

printf '%s' "$line"
