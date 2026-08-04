#!/usr/bin/env bash
# Presence-only lookup for a project's supported local configuration.
# Usage: fm-project-local-env.sh check <KEY> [<KEY>...]
#        fm-project-local-env.sh brief-section
#        fm-project-local-env.sh --help
#
# The spawn boundary supplies FM_PRIMARY_PROJECT_DIR for the registered primary
# project, FM_PROJECT_LOCAL_ENV_ISOLATED_DIR for the isolated copy, and
# FM_PROJECT_LOCAL_ENV_FILE for the supported local source. The only supported
# source name is .env.local. Missing task-boundary path metadata or an unsafe
# source is indeterminate rather than proof that a credential is missing.
# An absent source file is allowed and contributes no matching key.
# The lookup also checks the worker process environment.
# For presence classification, a whitespace-delimited # suffix is an inline
# comment; an empty, "", or '' assignment before that suffix remains absent.
#
# Output contains only each requested key's present/absent result and a source
# category. It never prints, stores, exports, or returns a configuration value.
# Exit status is 0 when every key is non-empty in one allowed source, 1 when at
# least one key is absent from all allowed sources, and 2 for invalid arguments,
# missing or malformed task-boundary paths, or unsafe local files. Callers must
# report exit 2 as indeterminate rather than as a missing credential.
set -eu

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

error() {
  printf 'fm-project-local-env: error: %s\n' "$*" >&2
}

brief_section() {
  cat <<'EOF'
# Project-local configuration boundary
For project-local credential or configuration checks, the spawn exposes `FM_PROJECT_LOCAL_ENV_CHECK`, `FM_PRIMARY_PROJECT_DIR`, `FM_PROJECT_LOCAL_ENV_ISOLATED_DIR`, and `FM_PROJECT_LOCAL_ENV_FILE` as path-only task-boundary metadata.
Before concluding that a named credential or configuration is absent, run `"$FM_PROJECT_LOCAL_ENV_CHECK" check <KEY> [<KEY>...]` and follow its presence-only result.
The helper checks the process environment, the isolated copy's supported `.env.local`, and the registered primary project's supported `.env.local` without printing or exporting values.
An exit status of 2 means the task-boundary configuration is unsafe or indeterminate, not that the credential is absent.
Read the helper's `--help` before using it, and never source or copy the local environment file.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  brief-section)
    [ "$#" -eq 1 ] || { error 'brief-section accepts no arguments'; exit 2; }
    brief_section
    exit 0
    ;;
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

ISOLATED_DIR=${FM_PROJECT_LOCAL_ENV_ISOLATED_DIR:-}
[ -n "$ISOLATED_DIR" ] || {
  error 'FM_PROJECT_LOCAL_ENV_ISOLATED_DIR is required at the task boundary'
  exit 2
}
ISOLATED_DIR=$(canonical_dir FM_PROJECT_LOCAL_ENV_ISOLATED_DIR "$ISOLATED_DIR") || exit 2

PRIMARY_ENV_FILE="$PRIMARY_DIR/$SOURCE_NAME"
ISOLATED_ENV_FILE="$ISOLATED_DIR/$SOURCE_NAME"

scan_local_env_source() {
  local label=$1 file=$2 output status
  shift 2
  if output=$(perl -MFcntl=:DEFAULT -MErrno=ENOENT -e '
    my ($file, @keys) = @ARGV;
    sysopen(my $source, $file, O_RDONLY | O_NOFOLLOW)
      or exit($! == ENOENT ? 1 : 2);
    stat($source) or exit 2;
    exit 2 unless -f _;
    my %found = map { $_ => 0 } @keys;
    while (defined(my $line = <$source>)) {
      chomp $line;
      $line =~ s/\r\z//;
      for my $key (@keys) {
        next unless $line =~ /^\s*(?:export\s+)?\Q$key\E=(.*)\z/;
        my $value = $1;
        $value =~ s/\s+#.*\z//;
        $value =~ s/^\s+//;
        $value =~ s/\s+\z//;
        $found{$key} = $value ne q{} && $value ne q{""} && $value ne (chr(39) x 2);
      }
    }
    exit 2 unless eof($source);
    print "$_\n" for grep { $found{$_} } @keys;
  ' "$file" "$@"); then
    printf '%s' "$output"
    return 0
  else
    status=$?
  fi
  case "$status" in
    1) return 1 ;;
    *) error "$label is not a safe regular file or is unreadable: $file"; return 2 ;;
  esac
}

PRIMARY_ENV_KEYS=
if PRIMARY_ENV_KEYS=$(scan_local_env_source registered-primary-local-source "$PRIMARY_ENV_FILE" "$@"); then
  :
else
  file_status=$?
  [ "$file_status" = 1 ] || exit 2
fi
ISOLATED_ENV_KEYS=
if ISOLATED_ENV_KEYS=$(scan_local_env_source isolated-local-source "$ISOLATED_ENV_FILE" "$@"); then
  :
else
  file_status=$?
  [ "$file_status" = 1 ] || exit 2
fi

process_env_has_key() {
  local key=$1 value
  value=${!key-}
  [ -n "$value" ]
}

key_is_listed() {
  local key=$1 keys=$2
  case "
$keys
" in
    *"
$key
"*) return 0 ;;
    *) return 1 ;;
  esac
}

check_key() {
  local key=$1
  if process_env_has_key "$key"; then
    printf '%s: present source=process-environment\n' "$key"
    return 0
  fi
  if key_is_listed "$key" "$ISOLATED_ENV_KEYS"; then
    printf '%s: present source=isolated-project/.env.local\n' "$key"
    return 0
  fi
  if key_is_listed "$key" "$PRIMARY_ENV_KEYS"; then
    printf '%s: present source=registered-primary/.env.local\n' "$key"
    return 0
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
