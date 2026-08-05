#!/usr/bin/env bash
# Behavior tests for the presence-only project-local configuration boundary.
#
# The regression fixture is a real git project copy whose .env.local exists only
# in the registered primary. It uses dummy values and asserts only presence,
# source categories, and redaction. The spawn case executes a harmless fake
# harness through a fake tmux backend to prove the isolated worker can invoke
# the inherited checker without receiving local values.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-project-local-env.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-local-env)
REAL_PERL=$(command -v perl)

write_dummy_env() {
  local project=$1
  printf '%s\n' \
    'PARALLEL_API_KEY=dummy-parallel-value' \
    'OPENROUTER_API_KEY=dummy-openrouter-value' \
    'UNRELATED_LOCAL_SECRET=dummy-unrelated-value' > "$project/.env.local"
  chmod 600 "$project/.env.local"
}

run_check() {
  local primary=$1 isolated=$2
  shift 2
  unset PARALLEL_API_KEY OPENROUTER_API_KEY UNRELATED_LOCAL_SECRET
  FM_PRIMARY_PROJECT_DIR="$primary" \
    FM_PROJECT_LOCAL_ENV_ISOLATED_DIR="$isolated" \
    FM_PROJECT_LOCAL_ENV_FILE=.env.local \
    "$CHECK" check "$@"
}

test_primary_local_presence_is_found_without_exposing_values() {
  local case_dir primary isolated out status
  case_dir="$TMP_ROOT/primary-presence"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  fm_git_init_commit "$primary"
  cp -R "$primary" "$isolated"
  write_dummy_env "$primary"
  rm -f "$isolated/.env.local"

  out=$(run_check "$primary" "$isolated" PARALLEL_API_KEY OPENROUTER_API_KEY)
  status=$?
  expect_code 0 "$status" "primary-local presence should satisfy the exact provider keys"
  assert_contains "$out" 'PARALLEL_API_KEY: present source=registered-primary/.env.local' \
    "primary local PARALLEL_API_KEY presence was not reported"
  assert_contains "$out" 'OPENROUTER_API_KEY: present source=registered-primary/.env.local' \
    "primary local OPENROUTER_API_KEY presence was not reported"
  assert_not_contains "$out" 'dummy-parallel-value' \
    "the presence result exposed the parallel dummy value"
  assert_not_contains "$out" 'dummy-openrouter-value' \
    "the presence result exposed the OpenRouter dummy value"
  assert_not_contains "$out" 'UNRELATED_LOCAL_SECRET' \
    "an unrelated local secret was inspected or propagated"
  pass "primary .env.local presence is found without exposing or propagating values"
}

test_true_absence_remains_absent() {
  local case_dir primary isolated out status
  case_dir="$TMP_ROOT/true-absence"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  fm_git_init_commit "$primary"
  cp -R "$primary" "$isolated"

  out=$(run_check "$primary" "$isolated" PARALLEL_API_KEY OPENROUTER_API_KEY)
  status=$?
  expect_code 1 "$status" "true absence should remain an absence result"
  assert_contains "$out" 'PARALLEL_API_KEY: absent' \
    "true absence did not report PARALLEL_API_KEY as absent"
  assert_contains "$out" 'OPENROUTER_API_KEY: absent' \
    "true absence did not report OPENROUTER_API_KEY as absent"

  printf '%s\n' 'PARALLEL_API_KEY=' 'OPENROUTER_API_KEY=""' > "$isolated/.env.local"
  out=$(run_check "$primary" "$isolated" PARALLEL_API_KEY OPENROUTER_API_KEY)
  status=$?
  expect_code 1 "$status" "empty local assignments should remain absent"
  assert_contains "$out" 'PARALLEL_API_KEY: absent' \
    "an empty local assignment was treated as present"
  assert_contains "$out" 'OPENROUTER_API_KEY: absent' \
    "an empty quoted local assignment was treated as present"

  printf '%s\n' \
    'PARALLEL_API_KEY= # intentionally unset' \
    'OPENROUTER_API_KEY="" # TODO' > "$isolated/.env.local"
  out=$(run_check "$primary" "$isolated" PARALLEL_API_KEY OPENROUTER_API_KEY)
  status=$?
  expect_code 1 "$status" "commented empty local assignments should remain absent"
  assert_contains "$out" 'PARALLEL_API_KEY: absent' \
    "an empty local assignment with an inline comment was treated as present"
  assert_contains "$out" 'OPENROUTER_API_KEY: absent' \
    "an empty quoted local assignment with an inline comment was treated as present"
  pass "true absence, including empty local assignments, remains absent"
}

test_process_and_isolated_sources_are_presence_only() {
  local case_dir primary isolated out status
  case_dir="$TMP_ROOT/source-order"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  fm_git_init_commit "$primary"
  cp -R "$primary" "$isolated"
  write_dummy_env "$primary"
  printf '%s\n' 'OPENROUTER_API_KEY=dummy-isolated-value' > "$isolated/.env.local"
  chmod 600 "$isolated/.env.local"
  export PARALLEL_API_KEY=dummy-process-value

  out=$(FM_PRIMARY_PROJECT_DIR="$primary" \
    FM_PROJECT_LOCAL_ENV_ISOLATED_DIR="$isolated" \
    FM_PROJECT_LOCAL_ENV_FILE=.env.local \
    "$CHECK" check PARALLEL_API_KEY OPENROUTER_API_KEY)
  status=$?
  unset PARALLEL_API_KEY
  expect_code 0 "$status" "process and isolated sources should satisfy requested keys"
  assert_contains "$out" 'PARALLEL_API_KEY: present source=process-environment' \
    "process environment presence was not recognized"
  assert_contains "$out" 'OPENROUTER_API_KEY: present source=isolated-project/.env.local' \
    "isolated local presence was not recognized"
  assert_not_contains "$out" 'dummy-process-value' \
    "process environment value leaked into the result"
  assert_not_contains "$out" 'dummy-isolated-value' \
    "isolated local value leaked into the result"
  pass "process and isolated sources are checked without exposing values"
}

test_multiline_process_environment_does_not_spoof_presence() {
  local case_dir primary isolated out status
  case_dir="$TMP_ROOT/multiline-process-environment"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  fm_git_init_commit "$primary"
  cp -R "$primary" "$isolated"
  export UNRELATED_MULTILINE_VALUE=$'unrelated\nPARALLEL_API_KEY=dummy-decoy-value'

  out=$(run_check "$primary" "$isolated" PARALLEL_API_KEY)
  status=$?
  unset UNRELATED_MULTILINE_VALUE
  expect_code 1 "$status" "an unrelated multiline process value must not spoof key presence"
  assert_contains "$out" 'PARALLEL_API_KEY: absent' \
    "an unrelated multiline process value spoofed PARALLEL_API_KEY presence"
  assert_not_contains "$out" 'dummy-decoy-value' \
    "the unrelated multiline process value leaked into the result"
  pass "process presence checks query only the requested variable"
}

# write_swap_perl <fakebin>: install a `perl` shim that once renames
# FM_TEST_SWAP_PATH aside and leaves a symlink to FM_TEST_SWAP_TARGET in its
# place - the same swap for a file or a directory. The selected phase fires on
# either the scan invocation (`-MFcntl=:DEFAULT`) or directory resolution.
write_swap_perl() {
  local fakebin=$1
  cat > "$fakebin/perl" <<'SH'
#!/usr/bin/env bash
set -u
case "${FM_TEST_SWAP_PHASE:-scan}: $*" in
  scan:*" -MFcntl=:DEFAULT "*|resolve:*" -MCwd=realpath "*)
    if [ -n "${FM_TEST_SWAP_PATH:-}" ] && [ ! -e "$FM_TEST_SWAP_DONE" ]; then
      mv -- "$FM_TEST_SWAP_PATH" "$FM_TEST_SWAP_PATH.moved"
      ln -s -- "$FM_TEST_SWAP_TARGET" "$FM_TEST_SWAP_PATH"
      : > "$FM_TEST_SWAP_DONE"
    fi
    ;;
esac
exec "$FM_REAL_PERL" "$@"
SH
  chmod +x "$fakebin/perl"
}

test_local_source_swap_stops_safely() {
  local case_dir primary isolated outside swap_done fakebin out status
  case_dir="$TMP_ROOT/local-source-swap"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  outside="$case_dir/outside.env"
  swap_done="$case_dir/swap.done"
  fm_git_init_commit "$primary"
  cp -R "$primary" "$isolated"
  printf '%s\n' 'PARALLEL_API_KEY=dummy-original-value' > "$primary/.env.local"
  printf '%s\n' 'PARALLEL_API_KEY=dummy-outside-value' > "$outside"
  fakebin=$(fm_fakebin "$case_dir/fake")
  write_swap_perl "$fakebin"

  out=$(FM_TEST_SWAP_PATH="$primary/.env.local" FM_TEST_SWAP_TARGET="$outside" \
    FM_TEST_SWAP_DONE="$swap_done" FM_REAL_PERL="$REAL_PERL" PATH="$fakebin:$PATH" \
    FM_PRIMARY_PROJECT_DIR="$primary" FM_PROJECT_LOCAL_ENV_ISOLATED_DIR="$isolated" \
    FM_PROJECT_LOCAL_ENV_FILE=.env.local \
    "$CHECK" check PARALLEL_API_KEY 2>&1)
  status=$?
  expect_code 2 "$status" "a local source swapped to a symlink must stop safely"
  assert_contains "$out" 'not a safe regular file or is unreadable' \
    "the swapped local source refusal did not explain the safety boundary"
  assert_not_contains "$out" 'PARALLEL_API_KEY: present' \
    "a swapped local source produced a false presence result"
  assert_not_contains "$out" 'dummy-' \
    "a swapped local source exposed a value"
  [ "$(cat "$outside")" = 'PARALLEL_API_KEY=dummy-outside-value' ] || \
    fail "the swapped local source target was modified"
  [ "$(cat "$primary/.env.local.moved")" = 'PARALLEL_API_KEY=dummy-original-value' ] || \
    fail "the swapped-away local source was modified"
  pass "local sources are opened once without following a replacement symlink"
}

test_special_local_sources_are_rejected_without_hanging() {
  local case_dir primary isolated out status
  case_dir="$TMP_ROOT/special-local-sources"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  fm_git_init_commit "$primary"
  cp -R "$primary" "$isolated"

  mkfifo "$primary/.env.local"
  out=$(fm_run_with_deadline 10 run_check "$primary" "$isolated" PARALLEL_API_KEY 2>&1)
  status=$?
  expect_code 2 "$status" "a FIFO primary local source must stop safely without hanging"
  assert_contains "$out" 'not a safe regular file or is unreadable' \
    "the FIFO primary local source refusal did not explain the safety boundary"
  assert_not_contains "$out" 'PARALLEL_API_KEY: present' \
    "a FIFO primary local source produced a false presence result"
  rm -f "$primary/.env.local"

  mkfifo "$isolated/.env.local"
  out=$(fm_run_with_deadline 10 run_check "$primary" "$isolated" PARALLEL_API_KEY 2>&1)
  status=$?
  expect_code 2 "$status" "a FIFO isolated local source must stop safely without hanging"
  assert_contains "$out" 'not a safe regular file or is unreadable' \
    "the FIFO isolated local source refusal did not explain the safety boundary"
  rm -f "$isolated/.env.local"

  mkdir "$primary/.env.local"
  out=$(fm_run_with_deadline 10 run_check "$primary" "$isolated" PARALLEL_API_KEY 2>&1)
  status=$?
  expect_code 2 "$status" "a directory at the local source path must stop safely"
  assert_contains "$out" 'not a safe regular file or is unreadable' \
    "the directory local source refusal did not explain the safety boundary"
  pass "FIFOs and other non-regular local sources are rejected promptly without hanging"
}

test_parent_directory_swap_stops_safely() {
  local case_dir primary isolated outside swap_done fakebin out status
  case_dir="$TMP_ROOT/parent-directory-swap"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  outside="$case_dir/outside"
  swap_done="$case_dir/swap.done"
  fm_git_init_commit "$primary"
  cp -R "$primary" "$isolated"
  printf '%s\n' 'PARALLEL_API_KEY=dummy-real-value' > "$primary/.env.local"
  mkdir -p "$outside"
  printf '%s\n' 'PARALLEL_API_KEY=dummy-outside-value' > "$outside/.env.local"
  fakebin=$(fm_fakebin "$case_dir/fake")
  write_swap_perl "$fakebin"

  out=$(FM_TEST_SWAP_PATH="$primary" FM_TEST_SWAP_TARGET="$outside" \
    FM_TEST_SWAP_DONE="$swap_done" FM_REAL_PERL="$REAL_PERL" PATH="$fakebin:$PATH" \
    FM_PRIMARY_PROJECT_DIR="$primary" FM_PROJECT_LOCAL_ENV_ISOLATED_DIR="$isolated" \
    FM_PROJECT_LOCAL_ENV_FILE=.env.local \
    fm_run_with_deadline 10 "$CHECK" check PARALLEL_API_KEY 2>&1)
  status=$?
  expect_code 2 "$status" "a primary directory swapped to a symlink must stop safely"
  assert_contains "$out" 'not a stable real directory' \
    "the swapped primary directory refusal did not explain the pinning boundary"
  assert_not_contains "$out" 'PARALLEL_API_KEY: present' \
    "a swapped primary directory produced a false presence result"
  assert_not_contains "$out" 'dummy-outside-value' \
    "a swapped primary directory exposed the replacement's value"
  [ "$(cat "$primary.moved/.env.local")" = 'PARALLEL_API_KEY=dummy-real-value' ] || \
    fail "the swapped-away primary local source was modified"
  pass "a parent-directory swap between resolution and read fails closed"
}

test_parent_directory_swap_during_resolution_stops_safely() {
  local case_dir primary isolated outside swap_done fakebin out status
  case_dir="$TMP_ROOT/parent-directory-resolution-swap"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  outside="$case_dir/outside"
  swap_done="$case_dir/swap.done"
  fm_git_init_commit "$primary"
  cp -R "$primary" "$isolated"
  printf '%s\n' 'PARALLEL_API_KEY=dummy-real-value' > "$primary/.env.local"
  mkdir -p "$outside"
  printf '%s\n' 'PARALLEL_API_KEY=dummy-outside-value' > "$outside/.env.local"
  fakebin=$(fm_fakebin "$case_dir/fake")
  write_swap_perl "$fakebin"

  out=$(FM_TEST_SWAP_PHASE=resolve FM_TEST_SWAP_PATH="$primary" FM_TEST_SWAP_TARGET="$outside" \
    FM_TEST_SWAP_DONE="$swap_done" FM_REAL_PERL="$REAL_PERL" PATH="$fakebin:$PATH" \
    FM_PRIMARY_PROJECT_DIR="$primary" FM_PROJECT_LOCAL_ENV_ISOLATED_DIR="$isolated" \
    FM_PROJECT_LOCAL_ENV_FILE=.env.local \
    fm_run_with_deadline 10 "$CHECK" check PARALLEL_API_KEY 2>&1)
  status=$?
  expect_code 2 "$status" "a primary directory swapped during resolution must stop safely"
  assert_contains "$out" 'cannot resolve FM_PRIMARY_PROJECT_DIR' \
    "the resolution-time swap refusal did not explain the pinning boundary"
  assert_not_contains "$out" 'PARALLEL_API_KEY: present' \
    "a resolution-time directory swap produced a false presence result"
  assert_not_contains "$out" 'dummy-outside-value' \
    "a resolution-time directory swap exposed the replacement's value"
  [ "$(cat "$primary.moved/.env.local")" = 'PARALLEL_API_KEY=dummy-real-value' ] || \
    fail "the resolution-time swapped-away local source was modified"
  pass "a parent-directory swap during resolution fails closed"
}

test_unsafe_boundary_stops_safely() {
  local case_dir primary isolated unsafe out status
  case_dir="$TMP_ROOT/unsafe"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  fm_git_init_commit "$primary"
  cp -R "$primary" "$isolated"
  write_dummy_env "$primary"

  out=$(
    unset FM_PROJECT_LOCAL_ENV_ISOLATED_DIR
    FM_PRIMARY_PROJECT_DIR="$primary" "$CHECK" check PARALLEL_API_KEY 2>&1
  )
  status=$?
  expect_code 2 "$status" "a missing isolated-directory boundary should stop safely"
  assert_contains "$out" 'FM_PROJECT_LOCAL_ENV_ISOLATED_DIR is required at the task boundary' \
    "missing isolated-directory metadata did not explain the boundary"
  assert_not_contains "$out" 'PARALLEL_API_KEY: absent' \
    "missing isolated-directory metadata was mistaken for credential absence"

  unsafe="$case_dir/primary-link"
  ln -s "$primary" "$unsafe"
  out=$(FM_PRIMARY_PROJECT_DIR="$unsafe" FM_PROJECT_LOCAL_ENV_ISOLATED_DIR="$isolated" \
    "$CHECK" check PARALLEL_API_KEY 2>&1)
  status=$?
  expect_code 2 "$status" "a symlinked primary directory should stop safely"
  assert_contains "$out" 'not a real directory' \
    "unsafe primary directory refusal did not explain the boundary"
  assert_not_contains "$out" 'PARALLEL_API_KEY: absent' \
    "unsafe primary directory was mistaken for credential absence"

  rm -f "$primary/.env.local"
  printf '%s\n' 'outside=dummy-outside-value' > "$case_dir/outside.env"
  ln -s "$case_dir/outside.env" "$primary/.env.local"
  out=$(FM_PRIMARY_PROJECT_DIR="$primary" FM_PROJECT_LOCAL_ENV_ISOLATED_DIR="$isolated" \
    "$CHECK" check PARALLEL_API_KEY 2>&1)
  status=$?
  expect_code 2 "$status" "a symlinked local environment file should stop safely"
  assert_contains "$out" 'not a safe regular file' \
    "unsafe local source refusal did not explain the boundary"
  assert_not_contains "$out" 'PARALLEL_API_KEY: absent' \
    "unsafe local source was mistaken for credential absence"

  out=$(FM_PRIMARY_PROJECT_DIR="$primary" FM_PROJECT_LOCAL_ENV_ISOLATED_DIR="$isolated" \
    FM_PROJECT_LOCAL_ENV_FILE=.env "$CHECK" check PARALLEL_API_KEY 2>&1)
  status=$?
  expect_code 2 "$status" "an unsupported local source should stop safely"
  assert_contains "$out" 'supported .env.local source name' \
    "unsupported source refusal did not name the supported boundary"
  pass "malformed and unsafe paths stop safely instead of producing missing conclusions"
}

write_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{window_name}"*) exit 0 ;;
  *"#{window_id}"*) printf '%%1\n'; exit 0 ;;
  *"#S"*) printf 'fake-session\n'; exit 0 ;;
  *"pane_id"*) printf '%%1\n'; exit 0 ;;
esac
if [ "${1:-}" = send-keys ]; then
  prev=
  last=
  literal=0
  for arg in "$@"; do
    if [ "$prev" = -l ]; then
      printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
      printf '%s\n' "$arg" > "$FM_FAKE_PENDING_LAUNCH"
      literal=1
    fi
    prev=$arg
    last=$arg
  done
  if [ "$literal" -eq 0 ] && [ "$last" = Enter ] && [ -s "$FM_FAKE_PENDING_LAUNCH" ]; then
    launch=$(cat "$FM_FAKE_PENDING_LAUNCH")
    (cd "$FM_FAKE_PANE_PATH" && bash -c "$launch") > "$FM_FAKE_WORKER_LOG" 2>&1
    printf '%s\n' "$?" > "$FM_FAKE_WORKER_STATUS"
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/local-env-worker" <<'SH'
#!/usr/bin/env bash
set -u
printf 'worker-cwd=%s\n' "$(pwd -P)"
exec "$FM_PROJECT_LOCAL_ENV_CHECK" check PARALLEL_API_KEY OPENROUTER_API_KEY
SH
  chmod +x "$fakebin/local-env-worker"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

test_spawn_worker_resolves_primary_local_presence() {
  local case_dir home primary isolated isolated_real log pending worker_log
  local worker_status worker_out fakebin id out status launch
  case_dir="$TMP_ROOT/spawn-boundary"
  home="$case_dir/home"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  log="$case_dir/tmux.log"
  pending="$case_dir/pending-launch"
  worker_log="$case_dir/worker.log"
  worker_status="$case_dir/worker.status"
  id=local-env-spawn-z1
  mkdir -p "$home/data/$id" "$home/state" "$home/config"
  fm_git_worktree "$primary" "$isolated" spawn-boundary
  isolated_real=$(cd "$isolated" && pwd -P)
  write_dummy_env "$primary"
  printf 'legacy brief\n' > "$home/data/$id/brief.md"
  fakebin=$(write_spawn_fakebin "$case_dir/fake")

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$isolated" \
    FM_FAKE_LAUNCH_LOG="$log" FM_FAKE_PENDING_LAUNCH="$pending" \
    FM_FAKE_WORKER_LOG="$worker_log" FM_FAKE_WORKER_STATUS="$worker_status" \
    TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$primary" "$fakebin/local-env-worker --check-boundary" \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "spawn should publish the local-env task boundary"
  launch=$(cat "$log")
  assert_contains "$launch" 'FM_PROJECT_LOCAL_ENV_CHECK=' \
    "spawn did not expose the executable local-env checker"
  assert_contains "$launch" 'FM_PRIMARY_PROJECT_DIR=' \
    "spawn did not expose the registered primary project path"
  assert_contains "$launch" 'FM_PROJECT_LOCAL_ENV_ISOLATED_DIR=' \
    "spawn did not expose the isolated project path"
  assert_contains "$launch" 'FM_PROJECT_LOCAL_ENV_FILE=.env.local' \
    "spawn did not expose the supported local source name"
  assert_grep '# Project-local configuration boundary' "$home/data/$id/brief.md" \
    "spawn did not add the executable-owned boundary to the legacy brief"
  assert_grep 'Before concluding that a named credential or configuration is absent' \
    "$home/data/$id/brief.md" \
    "spawn did not enforce the presence-only check in the legacy brief"
  worker_out=$(cat "$worker_log")
  expect_code 0 "$(cat "$worker_status")" \
    "the isolated fake harness should resolve primary-local provider presence"
  assert_contains "$worker_out" "worker-cwd=$isolated_real" \
    "the fake harness did not execute from the isolated project copy"
  assert_contains "$worker_out" 'PARALLEL_API_KEY: present source=registered-primary/.env.local' \
    "the worker did not find primary-local PARALLEL_API_KEY presence"
  assert_contains "$worker_out" 'OPENROUTER_API_KEY: present source=registered-primary/.env.local' \
    "the worker did not find primary-local OPENROUTER_API_KEY presence"
  assert_not_contains "$launch" 'dummy-parallel-value' \
    "spawn copied the parallel dummy value into the worker command"
  assert_not_contains "$launch" 'dummy-openrouter-value' \
    "spawn copied the OpenRouter dummy value into the worker command"
  assert_not_contains "$launch" 'dummy-unrelated-value' \
    "spawn propagated an unrelated local secret"
  assert_not_contains "$out" 'dummy-' \
    "spawn output exposed a local value"
  assert_not_contains "$worker_out" 'dummy-' \
    "the worker checker output exposed a local value"
  assert_not_contains "$worker_out" 'UNRELATED_LOCAL_SECRET' \
    "the worker checker inspected or propagated an unrelated local secret"
  assert_no_grep 'dummy-' "$home/state/$id.meta" \
    "spawn metadata retained a local value"
  assert_no_grep 'dummy-' "$home/data/$id/brief.md" \
    "the legacy brief upgrade retained a local value"
  pass "isolated worker resolves primary-local presence through path-only metadata"
}

test_spawn_legacy_upgrade_uses_unpredictable_staging_name() {
  local case_dir home primary isolated log pending worker_log worker_status
  local fakebin id hookdir stage_name out status
  case_dir="$TMP_ROOT/spawn-random-stage"
  home="$case_dir/home"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  log="$case_dir/tmux.log"
  pending="$case_dir/pending-launch"
  worker_log="$case_dir/worker.log"
  worker_status="$case_dir/worker.status"
  id=local-env-random-stage-z2
  hookdir="$case_dir/perl-hook"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$hookdir"
  fm_git_worktree "$primary" "$isolated" spawn-random-stage
  write_dummy_env "$primary"
  printf 'legacy brief\n' > "$home/data/$id/brief.md"
  cat > "$hookdir/fm_test_staging_name.pm" <<'PERL'
package fm_test_staging_name;
use strict;
use warnings;

BEGIN {
  *main::rename = sub {
    my ($source, $destination) = @_;
    if ($source =~ /^\.brief\.md\.fm-/) {
      open my $record, '>', $ENV{FM_TEST_STAGING_NAME} or die "open staging record: $!\n";
      print {$record} "$source\n" or die "write staging record: $!\n";
      close $record or die "close staging record: $!\n";
    }
    return CORE::rename($source, $destination);
  };
}

1;
PERL
  fakebin=$(write_spawn_fakebin "$case_dir/fake")

  out=$(FM_TEST_STAGING_NAME="$case_dir/staging-name" PERL5LIB="$hookdir${PERL5LIB:+:$PERL5LIB}" \
    PERL5OPT=-Mfm_test_staging_name FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$isolated" FM_FAKE_LAUNCH_LOG="$log" \
    FM_FAKE_PENDING_LAUNCH="$pending" FM_FAKE_WORKER_LOG="$worker_log" \
    FM_FAKE_WORKER_STATUS="$worker_status" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$primary" "$fakebin/local-env-worker --check-boundary" \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "spawn should upgrade a legacy brief through private staging: $out"
  stage_name=$(cat "$case_dir/staging-name")
  printf '%s\n' "$stage_name" | LC_ALL=C grep -Eq '^\.brief\.md\.fm-[0-9a-f]{64}$' \
    || fail "legacy brief upgrade did not use an unguessable private staging name: $stage_name"
  pass "legacy brief upgrade uses an unguessable private staging name"
}

test_spawn_rejects_swapped_legacy_staging_file() {
  local case_dir home primary isolated log pending worker_log worker_status
  local id fakebin hookdir out status
  case_dir="$TMP_ROOT/swapped-legacy-staging"
  home="$case_dir/home"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  log="$case_dir/tmux.log"
  pending="$case_dir/pending-launch"
  worker_log="$case_dir/worker.log"
  worker_status="$case_dir/worker.status"
  id=local-env-swapped-stage-z3
  hookdir="$case_dir/perl-hook"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$hookdir"
  fm_git_worktree "$primary" "$isolated" swapped-legacy-staging
  write_dummy_env "$primary"
  printf 'legacy brief\n' > "$home/data/$id/brief.md"
  cat > "$hookdir/fm_test_swapped_staging.pm" <<'PERL'
package fm_test_swapped_staging;
use strict;
use warnings;

BEGIN {
  sub swap_staging {
    my ($source, $destination) = @_;
    if ($source =~ /^\.brief\.md\.fm-/) {
      unlink($source) or die "unlink staging: $!\n";
      open my $replacement, '>', $source or die "open staging replacement: $!\n";
      print {$replacement} "attacker brief\n" or die "write staging replacement: $!\n";
      close $replacement or die "close staging replacement: $!\n";
    }
    return CORE::rename($source, $destination);
  }
  *CORE::GLOBAL::rename = \&swap_staging;
  *main::rename = \&swap_staging;
}

1;
PERL
  fakebin=$(write_spawn_fakebin "$case_dir/fake")

  out=$(PERL5LIB="$hookdir${PERL5LIB:+:$PERL5LIB}" PERL5OPT=-Mfm_test_swapped_staging \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$isolated" FM_FAKE_LAUNCH_LOG="$log" \
    FM_FAKE_PENDING_LAUNCH="$pending" FM_FAKE_WORKER_LOG="$worker_log" \
    FM_FAKE_WORKER_STATUS="$worker_status" \
    TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$primary" "$fakebin/local-env-worker --check-boundary" \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "a swapped legacy staging file must be refused"
  assert_contains "$out" 'could not atomically add' \
    "swapped legacy staging refusal lost its message"
  assert_absent "$home/data/$id/brief.md" "swapped staging content was published as the legacy brief"
  assert_absent "$log" "swapped legacy staging reached endpoint creation"
  if find "$home/data" -name '.brief.md.fm-*' | grep -q .; then
    fail "swapped legacy staging refusal left a staging file behind"
  fi
  pass "legacy brief upgrade rejects a staging-file swap"
}

test_spawn_replaces_raced_legacy_final_atomically() {
  local case_dir home primary isolated log pending worker_log worker_status
  local id fakebin hookdir out status
  case_dir="$TMP_ROOT/raced-legacy-final"
  home="$case_dir/home"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  log="$case_dir/tmux.log"
  pending="$case_dir/pending-launch"
  worker_log="$case_dir/worker.log"
  worker_status="$case_dir/worker.status"
  id=local-env-raced-final-z4
  hookdir="$case_dir/perl-hook"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$hookdir"
  fm_git_worktree "$primary" "$isolated" raced-legacy-final
  write_dummy_env "$primary"
  printf 'legacy brief\n' > "$home/data/$id/brief.md"
  cat > "$hookdir/fm_test_raced_final.pm" <<'PERL'
package fm_test_raced_final;
use strict;
use warnings;

BEGIN {
  *CORE::GLOBAL::rename = sub {
    my ($source, $destination) = @_;
    if ($source =~ /^\.brief\.md\.fm-/ && $destination eq q{brief.md}) {
      open my $raced, q{>}, $destination or die "open raced brief: $!\n";
      print {$raced} "attacker brief\n" or die "write raced brief: $!\n";
      close $raced or die "close raced brief: $!\n";
    }
    return CORE::rename($source, $destination);
  };
  *CORE::GLOBAL::unlink = sub {
    my ($path) = @_;
    die "legacy final was unlinked\n" if $path eq q{brief.md};
    return CORE::unlink($path);
  };
}

1;
PERL
  fakebin=$(write_spawn_fakebin "$case_dir/fake")

  out=$(PERL5LIB="$hookdir${PERL5LIB:+:$PERL5LIB}" PERL5OPT=-Mfm_test_raced_final \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$isolated" FM_FAKE_LAUNCH_LOG="$log" \
    FM_FAKE_PENDING_LAUNCH="$pending" FM_FAKE_WORKER_LOG="$worker_log" \
    FM_FAKE_WORKER_STATUS="$worker_status" \
    TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$primary" "$fakebin/local-env-worker --check-boundary" \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "a raced legacy final should be atomically replaced: $out"
  assert_grep '# Project-local configuration boundary' "$home/data/$id/brief.md" \
    "atomic legacy replacement did not publish the upgraded brief"
  assert_no_grep 'attacker brief' "$home/data/$id/brief.md" \
    "raced final content survived the atomic legacy replacement"
  assert_present "$log" "atomic legacy replacement did not reach endpoint creation"
  pass "legacy brief upgrade atomically replaces a raced final path"
}

test_spawn_rejects_symlinked_legacy_brief() {
  local case_dir home primary isolated outside target log id fakebin out status
  case_dir="$TMP_ROOT/symlinked-legacy-brief"
  home="$case_dir/home"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  outside="$case_dir/outside"
  target="$outside/brief.md"
  log="$case_dir/tmux.log"
  id=local-env-symlink-z3
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$outside"
  fm_git_worktree "$primary" "$isolated" symlinked-legacy-brief
  printf '%s\n' 'outside brief remains unchanged' > "$target"
  ln -s "$target" "$home/data/$id/brief.md"
  fakebin=$(write_spawn_fakebin "$case_dir/fake")

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$isolated" \
    FM_FAKE_LAUNCH_LOG="$log" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$primary" "$fakebin/local-env-worker --check-boundary" \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "spawn should refuse a symlinked legacy brief"
  assert_contains "$out" 'non-symlink regular file' \
    "symlinked legacy brief refusal did not explain the safety boundary"
  [ "$(cat "$target")" = 'outside brief remains unchanged' ] || \
    fail "symlinked legacy brief target was modified"
  assert_absent "$log" "symlinked legacy brief reached endpoint creation"
  pass "legacy brief upgrade refuses symlink targets before mutation"
}

test_spawn_rejects_hardlinked_legacy_brief() {
  local case_dir home primary isolated outside target log id fakebin out status
  case_dir="$TMP_ROOT/hardlinked-legacy-brief"
  home="$case_dir/home"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  outside="$case_dir/outside"
  target="$outside/brief.md"
  log="$case_dir/tmux.log"
  id=local-env-hardlink-z4
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$outside"
  fm_git_worktree "$primary" "$isolated" hardlinked-legacy-brief
  printf '%s\n' 'outside brief remains unchanged' > "$target"
  ln "$target" "$home/data/$id/brief.md"
  fakebin=$(write_spawn_fakebin "$case_dir/fake")

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$isolated" \
    FM_FAKE_LAUNCH_LOG="$log" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$primary" "$fakebin/local-env-worker --check-boundary" \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "spawn should refuse a hardlinked legacy brief"
  assert_contains "$out" 'regular file with one link' \
    "hardlinked legacy brief refusal did not explain the safety boundary"
  [ "$(cat "$target")" = 'outside brief remains unchanged' ] || \
    fail "hardlinked legacy brief target was modified"
  assert_absent "$log" "hardlinked legacy brief reached endpoint creation"
  pass "legacy brief upgrade refuses hard links before mutation"
}

test_spawn_rejects_swapped_legacy_brief() {
  local case_dir home primary isolated outside target swap_done log id fakebin out status
  case_dir="$TMP_ROOT/swapped-legacy-brief"
  home="$case_dir/home"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  outside="$case_dir/outside"
  target="$outside/brief.md"
  swap_done="$case_dir/swap.done"
  log="$case_dir/tmux.log"
  id=local-env-swap-z5
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$outside"
  fm_git_worktree "$primary" "$isolated" swapped-legacy-brief
  printf '%s\n' 'legacy brief' > "$home/data/$id/brief.md"
  printf '%s\n' 'outside brief remains unchanged' > "$target"
  fakebin=$(write_spawn_fakebin "$case_dir/fake")
  write_swap_perl "$fakebin"

  out=$(FM_TEST_SWAP_PATH="$home/data/$id/brief.md" FM_TEST_SWAP_TARGET="$target" \
    FM_TEST_SWAP_DONE="$swap_done" FM_REAL_PERL="$REAL_PERL" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$isolated" \
    FM_FAKE_LAUNCH_LOG="$log" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$primary" "$fakebin/local-env-worker --check-boundary" \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "spawn should refuse a legacy brief swapped to a symlink"
  assert_contains "$out" 'non-symlink regular file' \
    "swapped legacy brief refusal did not explain the safety boundary"
  [ "$(cat "$target")" = 'outside brief remains unchanged' ] || \
    fail "swapped legacy brief target was modified"
  assert_absent "$log" "swapped legacy brief reached endpoint creation"
  pass "legacy brief upgrade refuses a replacement symlink before mutation"
}

test_spawn_rejects_fifo_legacy_brief() {
  local case_dir home primary isolated log id fakebin out status
  case_dir="$TMP_ROOT/fifo-legacy-brief"
  home="$case_dir/home"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  log="$case_dir/tmux.log"
  id=local-env-fifo-z6
  mkdir -p "$home/data/$id" "$home/state" "$home/config"
  fm_git_worktree "$primary" "$isolated" fifo-legacy-brief
  mkfifo "$home/data/$id/brief.md"
  fakebin=$(write_spawn_fakebin "$case_dir/fake")

  out=$(fm_run_with_deadline 20 env \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$isolated" \
    FM_FAKE_LAUNCH_LOG="$log" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$primary" "$fakebin/local-env-worker --check-boundary" \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "spawn should refuse a FIFO legacy brief without hanging"
  assert_contains "$out" 'non-symlink regular file' \
    "FIFO legacy brief refusal did not explain the safety boundary"
  assert_absent "$log" "FIFO legacy brief reached endpoint creation"
  pass "legacy brief upgrade rejects a FIFO promptly without hanging"
}

test_spawn_rejects_swapped_task_data_directory() {
  local case_dir home primary isolated outside swap_done log id fakebin out status
  case_dir="$TMP_ROOT/swapped-task-data-directory"
  home="$case_dir/home"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  outside="$case_dir/outside"
  swap_done="$case_dir/swap.done"
  log="$case_dir/tmux.log"
  id=local-env-dirswap-z7
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$outside"
  fm_git_worktree "$primary" "$isolated" swapped-task-data-directory
  printf '%s\n' 'legacy brief' > "$home/data/$id/brief.md"
  printf '%s\n' 'outside brief remains unchanged' > "$outside/brief.md"
  fakebin=$(write_spawn_fakebin "$case_dir/fake")
  write_swap_perl "$fakebin"

  out=$(FM_TEST_SWAP_PATH="$home/data/$id" FM_TEST_SWAP_TARGET="$outside" \
    FM_TEST_SWAP_DONE="$swap_done" FM_REAL_PERL="$REAL_PERL" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$isolated" \
    FM_FAKE_LAUNCH_LOG="$log" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$primary" "$fakebin/local-env-worker --check-boundary" \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "spawn should refuse a task data directory swapped to a symlink"
  assert_contains "$out" 'not a stable real directory' \
    "swapped task data directory refusal did not explain the pinning boundary"
  [ "$(cat "$outside/brief.md")" = 'outside brief remains unchanged' ] || \
    fail "swapped task data directory target was modified"
  assert_absent "$log" "swapped task data directory reached endpoint creation"
  pass "legacy brief upgrade pins the task data directory against a parent swap"
}

test_spawn_rejects_swapped_data_parent_directory() {
  local case_dir home primary isolated outside swap_done log id fakebin out status
  case_dir="$TMP_ROOT/swapped-data-parent-directory"
  home="$case_dir/home"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  outside="$case_dir/outside"
  swap_done="$case_dir/swap.done"
  log="$case_dir/tmux.log"
  id=local-env-dataparent-z8
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$outside/$id"
  fm_git_worktree "$primary" "$isolated" swapped-data-parent-directory
  printf '%s\n' 'legacy brief' > "$home/data/$id/brief.md"
  printf '%s\n' 'outside brief remains unchanged' > "$outside/$id/brief.md"
  fakebin=$(write_spawn_fakebin "$case_dir/fake")
  write_swap_perl "$fakebin"

  out=$(FM_TEST_SWAP_PHASE=resolve FM_TEST_SWAP_PATH="$home/data" FM_TEST_SWAP_TARGET="$outside" \
    FM_TEST_SWAP_DONE="$swap_done" FM_REAL_PERL="$REAL_PERL" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$isolated" \
    FM_FAKE_LAUNCH_LOG="$log" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$primary" "$fakebin/local-env-worker --check-boundary" \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "spawn should refuse a data parent directory swapped before task resolution"
  assert_contains "$out" 'task data parent directory' \
    "swapped data parent refusal did not explain the pinning boundary"
  [ "$(cat "$outside/$id/brief.md")" = 'outside brief remains unchanged' ] || \
    fail "swapped data parent redirected the legacy brief upgrade"
  assert_absent "$log" "swapped data parent reached endpoint creation"
  pass "legacy brief upgrade rejects a startup data parent replacement"
}

test_brief_carries_the_boundary_contract() {
  local home brief id
  home="$TMP_ROOT/brief"
  id=local-env-brief-z2
  mkdir -p "$home/data"
  FM_HOME="$home" "$BRIEF" "$id" fixture-project --mode direct-PR >/dev/null
  brief="$home/data/$id/brief.md"
  assert_grep 'FM_PROJECT_LOCAL_ENV_CHECK' "$brief" \
    "generated brief omitted the local-env executable interface"
  assert_grep 'registered primary project' "$brief" \
    "generated brief omitted the primary-project source"
  assert_grep 'An exit status of 2 means' "$brief" \
    "generated brief omitted the unsafe/indeterminate interpretation"
  assert_no_grep 'dummy-' "$brief" \
    "generated brief retained a credential value"
  pass "generated briefs require the presence-only local-env boundary"
}

test_primary_local_presence_is_found_without_exposing_values
test_true_absence_remains_absent
test_process_and_isolated_sources_are_presence_only
test_multiline_process_environment_does_not_spoof_presence
test_unsafe_boundary_stops_safely
test_local_source_swap_stops_safely
test_special_local_sources_are_rejected_without_hanging
test_parent_directory_swap_stops_safely
test_parent_directory_swap_during_resolution_stops_safely
test_spawn_worker_resolves_primary_local_presence
test_spawn_legacy_upgrade_uses_unpredictable_staging_name
test_spawn_rejects_swapped_legacy_staging_file
test_spawn_replaces_raced_legacy_final_atomically
test_spawn_rejects_symlinked_legacy_brief
test_spawn_rejects_hardlinked_legacy_brief
test_spawn_rejects_swapped_legacy_brief
test_spawn_rejects_fifo_legacy_brief
test_spawn_rejects_swapped_task_data_directory
test_spawn_rejects_swapped_data_parent_directory
test_brief_carries_the_boundary_contract
printf '# all fm-project-local-env tests passed\n'
