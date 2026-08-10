#!/usr/bin/env bash
# Filesystem identity helpers for safety checks that must treat alternate
# spellings of the same path as equal.
#
# fm_path_identity_token <path>
#   Prints a stable identity for an existing path.
#   Prefer device+inode, falling back to a case-normalized physical path only
#   when neither BSD nor GNU stat is available.
# fm_path_identity_equal <left> <right>
#   Succeeds only when both existing paths name the same filesystem object.

fm_path_identity_stat_style() {
  if stat -c '%d:%i' / >/dev/null 2>&1; then
    printf '%s\n' gnu
  elif stat -f '%d:%i' / >/dev/null 2>&1; then
    printf '%s\n' bsd
  else
    printf '%s\n' none
  fi
}

fm_path_identity_token() {  # <existing-path>
  local path=$1 style real
  style=$(fm_path_identity_stat_style) || return 1
  case "$style" in
    bsd) stat -f '%d:%i' "$path" ;;
    gnu) stat -c '%d:%i' "$path" ;;
    none)
      real=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || return 1
      printf '%s\n' "$real" | LC_ALL=C tr '[:upper:]' '[:lower:]'
      ;;
  esac
}

fm_path_identity_equal() {  # <left-existing-path> <right-existing-path>
  local left=$1 right=$2 left_token right_token
  left_token=$(fm_path_identity_token "$left") || return 1
  right_token=$(fm_path_identity_token "$right") || return 1
  [ "$left_token" = "$right_token" ]
}
