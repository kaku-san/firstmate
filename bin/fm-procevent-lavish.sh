#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh open <artifact.html> [--no-open] [--no-gate] [--reopen]
#   fm-procevent-lavish.sh stage <artifact.html>
#   fm-procevent-lavish.sh arm <artifact.html>
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html>
#
# open       Atomically stage the authored HTML privately, open the staged path
#            with lavish-axi, and print lavish-axi's usable session result.
# stage      Print the stable private staged path without opening a session.
# arm        Stage the authored HTML, then register a poll against that same
#            staged path so opening and process-event waiting share one path.
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, missing, or unknown.
# terminal   Exit 0 when the captured result means this Lavish source will never
#            produce another result, so the runner may retire it; any other exit
#            keeps it armed. This is the generic adapter contract bin/fm-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
#
# `open` and `stage` preserve the authored file as source of truth. The staged
# copy lives under `${XDG_DATA_HOME:-$HOME/.local/share}/firstmate/lavish`, in a
# private per-home directory, and is always replaced atomically at mode 0600.
# The staging boundary rejects symlinked source or destination path components.
#
# This adapter owns the Lavish-specific open/stage boundary, canonical source
# identity, the argv for the currently published poll command, and how to read a
# completed result. Ownership, durable capture, publication, and restart
# recovery all belong to bin/fm-procevent.sh.
#
# It wraps ONLY the currently published interface, verified against 0.1.45:
#   Usage: lavish-axi poll <html-file> [--agent-reply "..."]
# and that command "long-polls indefinitely" server-side. The adapter therefore
# runs the plain blocking form with no timeout flag, so results arrive as real
# server-side events. It adds no periodic discovery, no timer fallback, and no
# dependency on any unreleased capability.
#
# LOSS LIMITATION, stated plainly. The published poll destructively clears
# feedback before returning it. A result lost after that clearing and before the
# runner reads the process output is unrecoverable, and no Firstmate wrapper can
# close that source-side handoff window. Never describe this path as
# at-least-once, no-loss, or lossless. The only durability this proves is the
# runner's own: output that reached the runner is stored before it is announced.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,47p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,16)}'
  else
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,16)}'
  fi
}

lexical_absolute() {
  local path=${1-} cwd
  case "$path" in
    *$'\n'*) return 1 ;;
    /*) perl -MFile::Spec -e 'print File::Spec->canonpath($ARGV[0]), "\n"' "$path" ;;
    *)
      cwd=$(pwd -P) || return 1
      perl -MFile::Spec -e 'print File::Spec->canonpath(File::Spec->catfile($ARGV[1], $ARGV[0])), "\n"' "$path" "$cwd"
      ;;
  esac
}

allowed_system_symlink() {
  case "$1:$(readlink "$1" 2>/dev/null)" in
    /tmp:/private/tmp|/tmp:private/tmp|/var:/private/var|/var:private/var|/etc:/private/etc|/etc:private/etc)
      return 0
      ;;
  esac
  return 1
}

path_contains_symlink() {
  local path=$1 current=$1 parent
  while [ "$current" != "/" ]; do
    if [ -L "$current" ] && ! allowed_system_symlink "$current"; then
      return 0
    fi
    parent=${current%/*}
    [ -n "$parent" ] || parent=/
    [ "$parent" = "$current" ] && parent=/
    current=$parent
  done
  return 1
}

ensure_private_tree() {
  local directory=$1 absolute rest component current=/
  absolute=$(lexical_absolute "$directory") || die "cannot normalize staging directory: $directory"
  rest=${absolute#/}
  while [ -n "$rest" ]; do
    component=${rest%%/*}
    if [ "$component" = "$rest" ]; then
      rest=
    else
      rest=${rest#*/}
    fi
    if [ "$current" = / ]; then
      current="/$component"
    else
      current="$current/$component"
    fi
    if [ -L "$current" ] && ! allowed_system_symlink "$current"; then
      die "staging path contains a symlink: $current"
    fi
    if [ -e "$current" ]; then
      [ -d "$current" ] || die "staging path is not a directory: $current"
    else
      (umask 077 && mkdir -m 700 "$current") || die "cannot create staging directory: $current"
    fi
  done
  [ -d "$absolute" ] && [ ! -L "$absolute" ] || die "staging path is not a private directory: $absolute"
  chmod 700 "$absolute" || die "cannot protect staging directory: $absolute"
  printf '%s\n' "$absolute"
}

stage_artifact() {
  local artifact=${1-} source_abs home_abs stage_root stage_home base source_key
  local destination temporary
  [ -n "$artifact" ] || usage
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  source_abs=$(lexical_absolute "$artifact") || die "cannot normalize artifact path: $artifact"
  path_contains_symlink "$source_abs" && die "artifact path contains a symlink: $artifact"
  [ -f "$source_abs" ] || die "artifact does not exist or is not a regular file: $artifact"
  case "$source_abs" in
    *.html|*.htm|*.HTML|*.HTM) ;;
    *) die "artifact must be an HTML file: $artifact" ;;
  esac
  [ -n "${FM_HOME:-}" ] || die "FM_HOME is required to isolate Lavish artifacts"
  case "$FM_HOME" in *$'\n'*) die "FM_HOME cannot contain newlines" ;; esac
  home_abs=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$FM_HOME" 2>/dev/null) \
    || die "cannot resolve FM_HOME for Lavish staging: $FM_HOME"
  [ -n "${HOME:-}" ] || die "HOME is required for Lavish staging"
  if [ -n "${XDG_DATA_HOME:-}" ]; then
    case "$XDG_DATA_HOME" in /*) ;; *) die "XDG_DATA_HOME must be an absolute path" ;; esac
  fi
  stage_root=${XDG_DATA_HOME:-$HOME/.local/share}/firstmate/lavish
  case "$stage_root" in *$'\n'*) die "Lavish staging root cannot contain newlines" ;; esac
  stage_root=$(ensure_private_tree "$stage_root") || exit 1
  stage_home="$stage_root/$(hash_text "$home_abs")"
  stage_home=$(ensure_private_tree "$stage_home") || exit 1
  source_key=$(hash_text "$source_abs")
  base=${source_abs##*/}
  destination="$stage_home/${source_key}-${base}"
  [ ! -L "$destination" ] || die "staged artifact path is a symlink: $destination"
  if [ -e "$destination" ] && [ ! -f "$destination" ]; then
    die "staged artifact path is not a regular file: $destination"
  fi
  temporary=$(umask 077 && mktemp "$stage_home/.fm-lavish-stage.XXXXXX") \
    || die "cannot create atomic staging file in: $stage_home"
  if [ -L "$temporary" ]; then
    rm -f "$temporary"
    die "atomic staging file is a symlink: $temporary"
  fi
  chmod 600 "$temporary" || { rm -f "$temporary"; die "cannot protect atomic staging file: $temporary"; }
  if ! cp "$source_abs" "$temporary"; then
    rm -f "$temporary"
    die "cannot copy artifact into staging path: $artifact"
  fi
  chmod 600 "$temporary" || { rm -f "$temporary"; die "cannot protect staged artifact: $destination"; }
  [ ! -L "$destination" ] || { rm -f "$temporary"; die "staged artifact path became a symlink: $destination"; }
  if ! mv -f "$temporary" "$destination"; then
    rm -f "$temporary"
    die "cannot atomically install staged artifact: $destination"
  fi
  chmod 600 "$destination" || die "cannot protect staged artifact: $destination"
  [ -f "$destination" ] && [ ! -L "$destination" ] \
    || die "staged artifact is not a regular file: $destination"
  cmp -s "$source_abs" "$destination" \
    || die "staged artifact bytes differ from source: $artifact"
  printf '%s\n' "$destination"
}

cmd_open() {
  local artifact='' arg staged output
  local lavish_args=()
  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
      --no-open|--no-gate|--reopen) lavish_args+=("$arg") ;;
      --)
        shift
        [ "$#" -eq 1 ] || usage
        artifact=$1
        shift
        break
        ;;
      -*) die "unsupported Lavish open option: $arg" ;;
      *) [ -z "$artifact" ] || usage; artifact=$arg ;;
    esac
    shift
  done
  [ -n "$artifact" ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  staged=$(stage_artifact "$artifact") || exit 1
  printf 'staged: %s\n' "$staged" >&2
  if ! output=$(lavish-axi "$staged" "${lavish_args[@]}" 2>&1); then
    printf '%s\n' "$output" >&2
    die "Lavish could not open staged artifact: $staged"
  fi
  [ -n "$output" ] || die "Lavish returned no session result for staged artifact: $staged"
  printf '%s\n' "$output" | grep '^session:' >/dev/null \
    || die "Lavish returned no usable session result for staged artifact: $staged"
  printf '%s\n' "$output"
}

# Canonical identity is physical, not the path string: Lavish itself keys a
# session on the realpath of the artifact, so two names for one file are one
# source and must never become two owners.
cmd_source_id() {
  local artifact=${1-} real
  [ -n "$artifact" ] || usage
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  [ -f "$real" ] || die "artifact does not exist: $artifact"
  if command -v shasum >/dev/null 2>&1; then
    printf 'lavish-%s\n' "$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'lavish-%s\n' "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

cmd_arm() {
  local artifact=${1-} id staged
  [ -n "$artifact" ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  staged=$(stage_artifact "$artifact") || exit 1
  id=$(cmd_source_id "$artifact") || exit 1
  # The plain blocking form: no --timeout-ms, so completion is a server event.
  "$SCRIPT_DIR/fm-procevent.sh" register lavish "$id" -- lavish-axi poll "$staged" || exit 1
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$staged"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# Read one field of the response's leading `session:` block. Those fields are
# INDENTED, so each is read as the first indented match inside that block rather
# than an anchored whole-line match; anchoring on "^status:" silently never
# matches and treats every ended review as feedback. Confining the read to the
# leading block is also what stops prompt payload text from forging a session
# field. <field> is a fixed field name supplied by this adapter, never by input.
session_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z_]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

# Classify a completed result into a lifecycle state for the handler.
cmd_classify() {
  local file=${1-} status error_code error_message
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(session_field "$file" status)
  case "$status" in
    feedback) printf 'feedback\n'; return 0 ;;
    ended)    printf 'ended\n'; return 0 ;;
    waiting)  printf 'waiting\n'; return 0 ;;
  esac
  error_message=$(awk 'NR == 1 && /^error:[[:space:]]*/ { sub(/^error:[[:space:]]*/, ""); print }' "$file")
  error_code=$(awk '
    NR == 1 && /^error:[[:space:]]*/ { in_error=1; next }
    in_error && /^code:[[:space:]]*[A-Z_]+[[:space:]]*$/ {
      sub(/^code:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
    in_error { exit }
  ' "$file")
  if [ "$error_code" = NOT_FOUND ] || [[ "$error_message" == "No active Lavish Editor session"* ]]; then
    printf 'missing\n'
  else
    printf 'unknown\n'
  fi
}

# Whether a captured result ends this source, for the generic runner's automatic
# retirement. Lavish's notion of "ended" lives here and nowhere else: an ended
# session produces nothing further, a missing session has nothing left to
# produce, and the published poll delivers the final feedback of a `Send & End`
# review marked with session_ended and returns only empty ended sessions after
# it. Anything else - including an unreadable result - keeps the source armed.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(cmd_classify "$file")" in
    ended|missing) return 0 ;;
  esac
  case "$(session_field "$file" session_ended)" in
    true|True|TRUE) return 0 ;;
  esac
  return 1
}

case "${1-}" in
  open)      shift; cmd_open "$@" ;;
  stage)     shift; [ "$#" -eq 1 ] || usage; stage_artifact "$1" ;;
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
