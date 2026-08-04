#!/usr/bin/env bash
# Presence-only lookup for a project's supported local configuration.
# Usage: fm-project-local-env.sh check <KEY> [<KEY>...]
#        fm-project-local-env.sh --help
#
# The spawn boundary supplies FM_PRIMARY_PROJECT_DIR for the registered primary
# project, FM_PROJECT_LOCAL_ENV_ISOLATED_DIR for the isolated copy, and
# FM_PROJECT_LOCAL_ENV_FILE for the supported local source. The only supported
# source name is .env.local; an absent or unsafe source is never treated as a
# missing credential. The lookup also checks the worker process environment.
# For presence classification, a whitespace-delimited # suffix is an inline
# comment; an empty, "", or '' assignment before that suffix remains absent.
#
# Output contains only each requested key's present/absent result and a source
# category. It never prints, stores, exports, or returns a configuration value.
# Exit status is 0 when every key is non-empty in one allowed source, 1 when at
# least one key is absent from all allowed sources, and 2 for invalid arguments,
# missing task-boundary paths, or malformed/unsafe local files. Callers must
# report exit 2 as indeterminate rather than as a missing credential.
set -eu

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

error() {
  printf 'fm-project-local-env: error: %s\n' "$*" >&2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  check) shift ;;
  *) error 'usage: fm-project-local-env.sh check <KEY> [<KEY>...]'; exit 2 ;;
esac

[ "$#" -gt 0 ] || { error 'check requires at least one key'; exit 2; }

validate_key() {
  case "$1" in
    ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*)
      error "invalid environment key: $1"
      return 1
      ;;
  esac
}

for key in "$@"; do
  validate_key "$key" || exit 2
done

SOURCE_NAME=${FM_PROJECT_LOCAL_ENV_FILE:-.env.local}
[ "$SOURCE_NAME" = .env.local ] || {
  error 'FM_PROJECT_LOCAL_ENV_FILE must be the supported .env.local source name'
  exit 2
}

canonical_dir() {
  local label=$1 path=$2 resolved
  case "$path" in
    /*) ;;
    *) error "$label must be an absolute canonical directory"; return 1 ;;
  esac
  [ -d "$path" ] && [ ! -L "$path" ] || {
    error "$label is not a real directory: $path"
    return 1
  }
  resolved=$(CDPATH='' cd -P -- "$path" 2>/dev/null && pwd -P) || {
    error "cannot resolve $label: $path"
    return 1
  }
  printf '%s\n' "$resolved"
}

PRIMARY_DIR=${FM_PRIMARY_PROJECT_DIR:-}
[ -n "$PRIMARY_DIR" ] || {
  error 'FM_PRIMARY_PROJECT_DIR is required at the task boundary'
  exit 2
}
PRIMARY_DIR=$(canonical_dir FM_PRIMARY_PROJECT_DIR "$PRIMARY_DIR") || exit 2

ISOLATED_DIR=${FM_PROJECT_LOCAL_ENV_ISOLATED_DIR:-$PWD}
ISOLATED_DIR=$(canonical_dir FM_PROJECT_LOCAL_ENV_ISOLATED_DIR "$ISOLATED_DIR") || exit 2

validate_optional_env_file() {
  local label=$1 file=$2
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || {
      error "$label is not a safe regular file: $file"
      return 2
    }
    [ -r "$file" ] || {
      error "$label is not readable: $file"
      return 2
    }
    return 0
  fi
  return 1
}

PRIMARY_ENV_FILE="$PRIMARY_DIR/$SOURCE_NAME"
ISOLATED_ENV_FILE="$ISOLATED_DIR/$SOURCE_NAME"
PRIMARY_ENV_STATE=absent
ISOLATED_ENV_STATE=absent
if validate_optional_env_file registered-primary-local-source "$PRIMARY_ENV_FILE"; then
  PRIMARY_ENV_STATE=present
else
  file_status=$?
  [ "$file_status" = 1 ] || exit 2
fi
if validate_optional_env_file isolated-local-source "$ISOLATED_ENV_FILE"; then
  ISOLATED_ENV_STATE=present
else
  file_status=$?
  [ "$file_status" = 1 ] || exit 2
fi

process_env_has_key() {
  local key=$1
  env | awk -v key="$key" '
    BEGIN { prefix=key "="; found=0 }
    index($0, prefix) == 1 {
      value=substr($0, length(prefix) + 1)
      if (value != "") found=1
      exit
    }
    END { exit(found ? 0 : 1) }
  ' >/dev/null
}

local_env_file_has_key() {
  local key=$1 file=$2 status
  awk -v key="$key" '
    BEGIN { prefix="^[[:space:]]*(export[[:space:]]+)?" key "="; found=0 }
    $0 ~ prefix {
      value=$0
      sub(prefix, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (value == "" || value ~ /^""[[:space:]]*$/ || value ~ /^\047\047[[:space:]]*$/) found=0
      else found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$file" >/dev/null 2>&1
  status=$?
  case "$status" in
    0|1) return "$status" ;;
    *) error "could not inspect local source safely: $file"; return 2 ;;
  esac
}

check_key() {
  local key=$1
  if process_env_has_key "$key"; then
    printf '%s: present source=process-environment\n' "$key"
    return 0
  fi
  if [ "$ISOLATED_ENV_STATE" = present ]; then
    if local_env_file_has_key "$key" "$ISOLATED_ENV_FILE"; then
      printf '%s: present source=isolated-project/.env.local\n' "$key"
      return 0
    else
      source_status=$?
      [ "$source_status" = 1 ] || return 2
    fi
  fi
  if [ "$PRIMARY_ENV_STATE" = present ]; then
    if local_env_file_has_key "$key" "$PRIMARY_ENV_FILE"; then
      printf '%s: present source=registered-primary/.env.local\n' "$key"
      return 0
    else
      source_status=$?
      [ "$source_status" = 1 ] || return 2
    fi
  fi
  printf '%s: absent\n' "$key"
  return 1
}

result=0
for key in "$@"; do
  if check_key "$key"; then
    :
  else
    key_status=$?
    case "$key_status" in
      1) [ "$result" = 2 ] || result=1 ;;
      *) result=2 ;;
    esac
  fi
done
exit "$result"
