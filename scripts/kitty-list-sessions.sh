#!/usr/bin/env bash
# Copied from https://github.com/linkarzu/dotfiles-latest.git
# Author: Linkarzu
# fzf-based switcher for kitty sessions (multi-socket) or tabs (single socket)
# Usage: kitty-list-sessions.sh [session|tab]
#   session (default): lists tabs across all sockets, focus-window brings OS window forward
#   tab: lists tabs in current socket, focus-window --match switches tab
# Vim-like modes:
# - Normal mode (default): j/k move, d closes, enter opens, i enters insert mode, esc quits
# - Insert mode: type to filter, enter opens, esc returns to normal mode

set -euo pipefail

switch_mode="${1:-session}"

set_cursor_block() {
  printf '\e[2 q' >/dev/tty
}

set_cursor_bar() {
  printf '\e[6 q' >/dev/tty
}

trap 'set_cursor_bar' EXIT

kitty_bin="$(which kitty)"
sessions_dir="$HOME/.config/kitty/sessions"

if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf is not installed or not in PATH."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is not installed or not in PATH."
  exit 1
fi

if [[ ! -x "$kitty_bin" ]]; then
  echo "kitty binary not found at: $kitty_bin"
  exit 1
fi

# Discover sockets
socks=()
if [[ "$switch_mode" == "tab" ]]; then
  # Tab mode: current kitty instance only
  if [[ -n "${KITTY_LISTEN_ON:-}" ]]; then
    socks=("${KITTY_LISTEN_ON#unix:}")
  else
    while IFS= read -r s; do
      socks+=("$s")
    done < <(ls /tmp/kitty-* 2>/dev/null || true)
    if [[ ${#socks[@]} -gt 0 ]]; then
      socks=("${socks[0]}")
    fi
  fi
else
  # Session mode: all sockets
  while IFS= read -r s; do
    socks+=("$s")
  done < <(ls /tmp/kitty-* 2>/dev/null || true)
fi

if [[ ${#socks[@]} -eq 0 ]]; then
  echo "No kitty sockets found."
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
  local idx=0
  for s in "${socks[@]}"; do
    idx=$((idx + 1))
    local tsv=""
    tsv="$(
      "$kitty_bin" @ --to "unix:${s}" ls 2>/dev/null | jq -r --arg sock "$s" --arg idx "$idx" '
        .[].tabs[]
        | [$sock, $idx, (.windows[0].id|tostring), (.title|tostring), (.is_focused|tostring)]
        | @tsv
      ' 2>/dev/null || true
    )"
    if [[ -n "${tsv:-}" ]]; then
      all_tsv+="${tsv}"$'\n'
    fi
  done

  all_tsv="$(printf "%s" "$all_tsv" | sort -t$'\t' -k2,2n -k4,4)"

  if [[ -z "${all_tsv:-}" ]]; then
    return 1
  fi

  # sock<TAB>wid<TAB>raw_title<TAB>pretty_display
  printf "%s\n" "$all_tsv" | awk -F'\t' -v smode="$switch_mode" '{
    sock=$1
    sidx=$2
    wid=$3
    title=$4
    focused=$5
    labels="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    if (smode == "session") {
      pre = "[" substr(labels, sidx, 1) "] "
    } else {
      pre = ""
    }
    if (focused == "true") {
      printf "%s\t%s\t%s\t%s\033[31m[current]\033[0m %s\n", sock, wid, title, pre, title
    } else {
      printf "%s\t%s\t%s\t%s          %s\n", sock, wid, title, pre, title
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
    set_cursor_block
    set +e
    fzf_out="$(
      printf "%s\n" "$menu_lines" |
        fzf --ansi --height=100% --reverse \
          --header="Normal: j/k move, d close, enter open, i insert, esc quit" \
          --prompt="Kitty (${switch_mode}) > " \
          --no-multi --disabled \
          --with-nth=4.. \
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
    set_cursor_bar
    set +e
    fzf_out="$(
      printf "%s\n" "$menu_lines" |
        fzf --ansi --height=100% --reverse \
          --header="Insert: type to filter, enter open, esc normal" \
          --prompt="Kitty (${switch_mode}/insert) > " \
          --no-multi \
          --with-nth=4.. \
          --expect=enter,esc \
          --bind 'enter:accept' \
          --bind 'esc:abort' \
          --no-clear \
          --bind 'start:execute-silent(printf "\033[6 q" > /dev/tty)'
    )"
    fzf_rc=$?
    set -e
  fi

  if [[ $fzf_rc -ne 0 && -z "${fzf_out:-}" ]]; then
    key="esc"
    sel=""
  else
    key="$(printf "%s\n" "$fzf_out" | head -n1)"
    sel="$(printf "%s\n" "$fzf_out" | sed -n '2p' || true)"
  fi

  # Selection line is: sock<TAB>wid<TAB>raw_title<TAB>pretty_display
  selected_sock=""
  selected_wid=""
  selected_title=""
  if [[ -n "${sel:-}" ]]; then
    selected_sock="$(printf "%s" "$sel" | awk -F'\t' '{print $1}')"
    selected_wid="$(printf "%s" "$sel" | awk -F'\t' '{print $2}')"
    selected_title="$(printf "%s" "$sel" | awk -F'\t' '{print $3}')"
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
    if [[ "$mode" == "normal" ]]; then
      exit 0
    fi
    mode="normal"
    continue
  fi

  if [[ "$mode" == "normal" && "$key" == "d" ]]; then
    if [[ "$switch_mode" == "tab" ]]; then
      "$kitty_bin" @ --to "unix:${selected_sock}" close-tab --match "id:${selected_wid}" >/dev/null 2>&1 || true
    else
      session_id="$(session_id_for_title "$selected_title")"
      "$kitty_bin" @ --to "unix:${selected_sock}" action close_session "$session_id" >/dev/null 2>&1 || true
    fi
    continue
  fi

  if [[ "$key" == "enter" ]]; then
    if [[ "$switch_mode" == "tab" ]]; then
      "$kitty_bin" @ --to "unix:${selected_sock}" focus-window --match "id:${selected_wid}"
    else
      "$kitty_bin" @ --to "unix:${selected_sock}" focus-window
    fi
    exit 0
  fi

  if [[ "$mode" == "insert" ]]; then
    mode="normal"
    continue
  fi

  exit 0
done
