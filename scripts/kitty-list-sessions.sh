#!/usr/bin/env bash
# Copied from https://github.com/linkarzu/dotfiles-latest.git
# Author: Linkarzu
# Filename: ~/github/dotfiles-latest/kitty/scripts/kitty-list-sessions.sh
# Shows open kitty tab titles in fzf and switches using `action goto_session`
# Adds a vim-like "mode":
# - Normal mode (default): j/k move, d closes, enter opens, i enters insert mode, esc quits
# - Insert mode: type to filter, enter opens, esc returns to normal mode

set -euo pipefail

set_cursor_block() {
  # DECSCUSR: steady block
  printf '\e[2 q' >/dev/tty
}

set_cursor_bar() {
  # DECSCUSR: steady bar
  printf '\e[6 q' >/dev/tty
}

# Always restore to bar on exit
trap 'set_cursor_bar' EXIT

kitty_bin="$(which kitty)"
sessions_dir="$HOME/.config/kitty/sessions"

# Requirements
if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf is not installed or not in PATH."
  echo "Install (brew): brew install fzf"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is not installed or not in PATH."
  echo "Install (brew): brew install jq"
  exit 1
fi

if [[ ! -x "$kitty_bin" ]]; then
  echo "kitty binary not found at: $kitty_bin"
  exit 1
fi

socks=()
while IFS= read -r s; do
  socks+=("$s")
done < <(ls /tmp/kitty-* 2>/dev/null || true)
if [[ ${#socks[@]} -eq 0 ]]; then
  echo "No kitty sockets found in /tmp (kitty not running, or remote control not available)."
  exit 1
fi

session_id_for_title() {
  local title="${1:-}"
  local file="${sessions_dir}/${title}.kitty-session"

  if [[ -f "$file" ]]; then
    printf "%s" "$file"
    return 0
  fi

  printf "%s" "$title"
}

build_menu_lines() {
  local all_tsv=""
  for s in "${socks[@]}"; do
    local tsv=""
    tsv="$(
      "$kitty_bin" @ --to "unix:${s}" ls 2>/dev/null | jq -r --arg sock "$s" '
        .[].tabs[]
        | [$sock, (.title|tostring), (.is_focused|tostring)]
        | @tsv
      ' 2>/dev/null || true
    )"
    if [[ -n "${tsv:-}" ]]; then
      all_tsv+="${tsv}"$'\n'
    fi
  done

  all_tsv="$(printf "%s" "$all_tsv" | sort -t$'\t' -k2,2 -u)"

  if [[ -z "${all_tsv:-}" ]]; then
    return 1
  fi

  # sock<TAB>raw_title<TAB>pretty_display
  printf "%s\n" "$all_tsv" | awk -F'\t' '{
    sock=$1
    title=$2
    focused=$3
    if (focused == "true") {
      printf "%s\t%s\t\033[31m[current]\033[0m %s\n", sock, title, title
    } else {
      printf "%s\t%s\t          %s\n", sock, title, title
    }
  }'
}

mode="normal"

while true; do
  menu_lines="$(build_menu_lines || true)"
  if [[ -z "${menu_lines:-}" ]]; then
    echo "No tabs found."
    exit 1
  fi

  fzf_out=""
  fzf_rc=0

  if [[ "$mode" == "normal" ]]; then
    # Normal mode:
    # - Search disabled (typing doesn't filter)
    # - j/k move
    # - d closes session
    # - enter opens session
    # - i enters insert mode
    # - esc quits
    # - --no-clear avoids a visible screen "flash"
    #   - We exit one fzf instance and immediately start another when switching modes
    #   - Prevents fzf from clearing/restoring the screen on exit
    set_cursor_block
    set +e
    fzf_out="$(
      printf "%s\n" "$menu_lines" |
        fzf --ansi --height=100% --reverse \
          --header="Normal: j/k move, d close, enter open, i insert, esc quit" \
          --prompt="Kitty > " \
          --no-multi --disabled \
          --with-nth=3.. \
          --expect=enter,d,i,esc \
          --bind 'j:down,k:up' \
          --bind 'enter:accept,d:accept,i:accept' \
          --bind 'esc:abort' \
          --no-clear \
          --bind 'start:execute-silent(printf "\033[2 q" > /dev/tty)'

    )"
    fzf_rc=$?
    set -e
  else
    # Insert mode:
    # - Search enabled (type to filter)
    # - enter opens session
    # - esc returns to normal mode
    # - --no-clear avoids a visible screen "flash"
    #   - We exit one fzf instance and immediately start another when switching modes
    #   - Prevents fzf from clearing/restoring the screen on exit

    set_cursor_bar
    set +e
    fzf_out="$(
      printf "%s\n" "$menu_lines" |
        fzf --ansi --height=100% --reverse \
          --header="Insert: type to filter, enter open, esc normal" \
          --prompt="Kitty (insert) > " \
          --no-multi \
          --with-nth=3.. \
          --expect=enter,esc \
          --bind 'enter:accept' \
          --bind 'esc:abort' \
          --no-clear \
          --bind 'start:execute-silent(printf "\033[6 q" > /dev/tty)'
    )"
    fzf_rc=$?
    set -e
  fi

  # If fzf aborted and gave no output, treat it like "esc"
  if [[ $fzf_rc -ne 0 && -z "${fzf_out:-}" ]]; then
    key="esc"
    sel=""
  else
    key="$(printf "%s\n" "$fzf_out" | head -n1)"
    sel="$(printf "%s\n" "$fzf_out" | sed -n '2p' || true)"
  fi

  # Selection line is: sock<TAB>raw_title<TAB>pretty_display
  selected_sock=""
  selected_title=""
  if [[ -n "${sel:-}" ]]; then
    selected_sock="$(printf "%s" "$sel" | awk -F'\t' '{print $1}')"
    selected_title="$(printf "%s" "$sel" | awk -F'\t' '{print $2}')"
  fi

  if [[ "$mode" == "insert" && "$key" == "esc" ]]; then
    mode="normal"
    continue
  fi

  if [[ "$mode" == "normal" && "$key" == "esc" ]]; then
    exit 0
  fi

  if [[ "$mode" == "normal" && "$key" == "i" ]]; then
    mode="insert"
    continue
  fi

  if [[ -z "${selected_title:-}" ]]; then
    # Nothing selected (likely esc)
    if [[ "$mode" == "normal" ]]; then
      exit 0
    fi
    mode="normal"
    continue
  fi

  if [[ "$mode" == "normal" && "$key" == "d" ]]; then
    session_id="$(session_id_for_title "$selected_title")"
    "$kitty_bin" @ --to "unix:${selected_sock}" action close_session "$session_id" >/dev/null 2>&1 || true
    continue
  fi

  if [[ "$key" == "enter" ]]; then
    "$kitty_bin" @ --to "unix:${selected_sock}" focus-window
    exit 0
  fi

  # Fallback behavior:
  # - In insert mode, abort returns here -> go back to normal
  # - In normal mode, unknown key -> exit
  if [[ "$mode" == "insert" ]]; then
    mode="normal"
    continue
  fi

  exit 0
done
