---
name: project-local-env
description: >-
  Presence-only project-local credential and configuration resolution at isolated
  worker boundaries. Use before declaring a project-local value absent when the
  task runs from an isolated copy or when Firstmate evaluates that conclusion.
user-invocable: false
metadata:
  internal: true
---

# project-local-env

Load this before declaring a project-local credential or configuration absent when a task runs from an isolated copy, or before Firstmate accepts that conclusion.

`bin/fm-project-local-env.sh` is the executable owner of the lookup and its `--help` output owns the exact interface.
The spawn supplies `FM_PRIMARY_PROJECT_DIR`, `FM_PROJECT_LOCAL_ENV_ISOLATED_DIR`, `FM_PROJECT_LOCAL_ENV_FILE`, and `FM_PROJECT_LOCAL_ENV_CHECK` as path-only task-boundary metadata for ship and scout workers.

Run `"$FM_PROJECT_LOCAL_ENV_CHECK" check <KEY> [<KEY>...]` for the names required by the task.
The command checks the process environment, the isolated copy's supported `.env.local`, and the registered primary project's supported `.env.local` without printing or exporting values.
Exit 0 means every requested name is non-empty in an allowed source.
Exit 1 means at least one requested name is absent from every allowed source.
Exit 2 means the task boundary is incomplete, malformed, or unsafe, including a non-regular source or a source path that changes during the lookup, and is indeterminate, never proof of absence.

Do not source, copy, parse into a report, or add any local environment value to a brief, status line, metadata record, log, evidence bundle, commit, or public response.
Do not add another environment filename or propagate a value without an explicit contract change and least-privilege review.
The mechanism is shell-boundary metadata plus a presence-only executable, so it does not depend on the selected harness or runtime backend.
