#!/usr/bin/env bash
# Behavior tests for the presence-only project-local configuration boundary.
#
# The regression fixture is a real git project copy whose .env.local exists only
# in the registered primary. It uses dummy values and asserts only presence,
# source categories, and redaction. The spawn case captures the public launch
# command through a fake tmux backend to prove path metadata is propagated but
# local values are not.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-project-local-env.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-local-env)

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

test_unsafe_boundary_stops_safely() {
  local case_dir primary isolated unsafe out status
  case_dir="$TMP_ROOT/unsafe"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  fm_git_init_commit "$primary"
  cp -R "$primary" "$isolated"
  write_dummy_env "$primary"

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
  local dir=$1 fakebin log wt
  fakebin=$(fm_fakebin "$dir")
  log=$2
  wt=$3
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\\n' '$wt'; exit 0 ;;
  *"send-keys"*) printf '%s\\n' "\$*" >> '$log'; exit 0 ;;
  *"#{window_name}"*) exit 0 ;;
  *"#{window_id}"*) printf '%%1\\n'; exit 0 ;;
  *"#S"*) printf 'fake-session\\n'; exit 0 ;;
  *"pane_id"*) printf '%%1\\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

test_spawn_exports_only_path_metadata() {
  local case_dir home primary isolated log fakebin id out status launch
  case_dir="$TMP_ROOT/spawn-boundary"
  home="$case_dir/home"
  primary="$case_dir/primary"
  isolated="$case_dir/isolated"
  log="$case_dir/tmux.log"
  id=local-env-spawn-z1
  mkdir -p "$home/data/$id" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$primary" "$isolated" spawn-boundary
  write_dummy_env "$primary"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fakebin=$(write_spawn_fakebin "$case_dir/fake" "$log" "$isolated")

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$primary" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "spawn should publish the local-env task boundary"
  launch=$(grep -F -- '-l ' "$log" | tail -n 1)
  assert_contains "$launch" 'FM_PROJECT_LOCAL_ENV_CHECK=' \
    "spawn did not expose the executable local-env checker"
  assert_contains "$launch" 'FM_PRIMARY_PROJECT_DIR=' \
    "spawn did not expose the registered primary project path"
  assert_contains "$launch" 'FM_PROJECT_LOCAL_ENV_ISOLATED_DIR=' \
    "spawn did not expose the isolated project path"
  assert_contains "$launch" 'FM_PROJECT_LOCAL_ENV_FILE=.env.local' \
    "spawn did not expose the supported local source name"
  assert_not_contains "$launch" 'dummy-parallel-value' \
    "spawn copied the parallel dummy value into the worker command"
  assert_not_contains "$launch" 'dummy-openrouter-value' \
    "spawn copied the OpenRouter dummy value into the worker command"
  assert_not_contains "$launch" 'dummy-unrelated-value' \
    "spawn propagated an unrelated local secret"
  assert_not_contains "$out" 'dummy-' \
    "spawn output exposed a local value"
  assert_no_grep 'dummy-' "$home/state/$id.meta" \
    "spawn metadata retained a local value"
  pass "spawn propagates path-only local-env metadata without exporting local values"
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
test_unsafe_boundary_stops_safely
test_spawn_exports_only_path_metadata
test_brief_carries_the_boundary_contract
printf '# all fm-project-local-env tests passed\n'
