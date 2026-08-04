#!/usr/bin/env bash
#
# Start the Fireactions apply, but only when `main` has actually moved.
#
# Run BY SEMAPHORE, as a `bash` task template on a five-minute schedule, with
# this repository as the working directory. ADR-0125 §B.
#
# WHY THIS EXISTS AT ALL. Semaphore's schedules are cron and nothing else -
# there is no "run only when the repository has new commits" option - and an
# ungated five-minute cron would apply `main` to four hosts, one at a time,
# every five minutes forever. The play is idempotent so that is harmless, but
# ADR-0119 §D leans on Semaphore's task history as the ONLY answer to "is this
# host on the new configuration", and a log that is 99% no-op runs destroys the
# one signal it bought. ADR-0125 §E.
#
# WHAT IT COMPARES, AND WHY BOTH SIDES ARE FREE:
#
#   latest  = HEAD of the checkout Semaphore just made to run this script
#   applied = commit_hash of the newest SUCCESSFUL task for the apply template
#
# Neither needs a state file, a `git ls-remote`, or a credential. `commit_hash`
# is written by LocalJob at run time from the checkout the play actually used -
# not from what a poller saw a moment earlier - so there is no skew window.
#
# IT TALKS TO 127.0.0.1 AND READS ITS OWN CHECKOUT, AND THAT IS A REQUIREMENT.
# This tree is public. `labirin` vaults even hostnames, so a gate script that
# named the platform repository, an org, or an internal address would undo that
# for no gain. Everything environment-specific arrives as an environment
# variable from the Semaphore Environment attached to this template.
#
# `curl` and `jq` are both in the Semaphore image's apk list - see
# deployment/docker/server/Dockerfile. They are NOT pinned by anything in this
# repository, which is the sibling of ADR-0119 §H's unpinned-Ansible problem:
# a Semaphore image bump can change them with no commit here in between.
# ADR-0125 §H.

set -euo pipefail

readonly API_BASE="${SEMAPHORE_API_URL:-http://127.0.0.1:3000/api}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

require_env() {
  local name
  for name in "$@"; do
    [ -n "${!name:-}" ] || die "$name is not set. It comes from the Semaphore Environment attached to this template - see live/ansible/playbooks/semaphore/README.md."
  done
}

# Everything this script knows about where it is. Set as plain variables on the
# Environment, except the token, which is an Environment SECRET of type `env`
# so it is stored encrypted and never rendered in the task log.
require_env SEMAPHORE_PROJECT_ID SEMAPHORE_APPLY_TEMPLATE_ID SEMAPHORE_API_TOKEN

api() {
  local method="$1" path="$2"
  shift 2
  # --fail-with-body so a 4xx is an error AND its body is still readable; a bare
  # --fail prints nothing, which turns "the token expired" into "exit code 22".
  curl --silent --show-error --fail-with-body \
    --max-time 30 \
    --request "$method" \
    --header "Authorization: Bearer ${SEMAPHORE_API_TOKEN}" \
    --header 'Content-Type: application/json' \
    "$@" \
    "${API_BASE}${path}"
}

main() {
  # `git -C .` rather than bare `git`: Semaphore sets cmd.Dir to the checkout,
  # but PWD is inherited separately and the two have disagreed before.
  local latest
  latest="$(git -C "$(pwd)" rev-parse HEAD)" \
    || die "not a git checkout - Semaphore should have cloned the repository here"

  log "checkout HEAD is ${latest}"

  # THE PER-TEMPLATE PATH, NOT /project/{id}/tasks/last. Both exist; only this
  # one works here, and the difference is not cosmetic.
  #
  # The project-wide list is capped at 200 tasks across EVERY template. This
  # gate runs every five minutes, so it writes 288 tasks a day of its own -
  # which means the apply template's last success is pushed out of a 200-entry
  # shared window in well under a day. After that the gate reads "no successful
  # apply on record" and fires on every single run, forever. Server-side
  # filtering is what stops that.
  #
  # `router.go` registers /project/{id}/templates/{id}/tasks and .../tasks/last,
  # and GetTasksList calls GetTemplateTasks when a template is in context.
  # BOTH ARE ABSENT FROM api-docs.yml - that document is stale against the Go
  # model, and reading it alone concludes this endpoint does not exist.
  # Ordering is `id desc` in db/sql/task.go, which is what makes `first` below
  # the newest and not the oldest.
  local tasks
  tasks="$(api GET "/project/${SEMAPHORE_PROJECT_ID}/templates/${SEMAPHORE_APPLY_TEMPLATE_ID}/tasks/last?limit=200")" \
    || die "could not list tasks for template ${SEMAPHORE_APPLY_TEMPLATE_ID} - check SEMAPHORE_API_TOKEN, the project id, and the template id"

  # ===== Is one already in flight? =====
  # SEMAPHORE_MAX_PARALLEL_TASKS=1 stops two applies OVERLAPPING, but it does
  # not stop this script queuing a second one: a task that is `waiting` has not
  # written a commit_hash, so the comparison below would still see the old
  # value and fire again every five minutes until the first one finished. Each
  # of those would then run in turn against a `main` that had not moved.
  #
  # So the queue is not the guard - this is. `rejected` is deliberately in the
  # unfinished set, matching UnfinishedTaskStatuses() in pkg/task_logger.
  #
  # The template_id filter here and below is redundant against the per-template
  # endpoint, and kept: it costs nothing and it is what fails safe if that URL
  # is ever changed back to the project-wide one.
  local in_flight
  in_flight="$(printf '%s' "$tasks" | jq --argjson tid "$SEMAPHORE_APPLY_TEMPLATE_ID" '
    [ .[]
      | select(.template_id == $tid)
      | select(.status | IN("waiting","starting","waiting_confirmation","confirmed","rejected","running","stopping"))
    ] | length')"

  if [ "$in_flight" -gt 0 ]; then
    log "an apply is already queued or running (${in_flight} unfinished) - nothing to do"
    return 0
  fi

  # ===== What did the last good apply actually run? =====
  # commit_hash is a *string with omitempty, so it is ABSENT rather than null on
  # a task that never recorded one. `// empty` collapses both to the empty
  # string, which the comparison below reads as "unknown" and therefore fires -
  # correct, because a task whose commit is unknown cannot prove convergence,
  # and the run it triggers records one.
  local applied
  applied="$(printf '%s' "$tasks" | jq -r --argjson tid "$SEMAPHORE_APPLY_TEMPLATE_ID" '
    [ .[] | select(.template_id == $tid) | select(.status == "success") ]
    | first | .commit_hash // empty' )"

  if [ -z "$applied" ]; then
    log "no successful apply on record - firing"
  elif [ "${applied:0:40}" = "${latest:0:40}" ]; then
    log "already applied ${applied:0:12} - nothing to do"
    return 0
  else
    log "last applied ${applied:0:12}, checkout is ${latest:0:12} - firing"
  fi

  # ===== Fire =====
  # No commit_hash in the body ON PURPOSE. Supplying one makes LocalJob check
  # that commit out instead of pulling; omitting it makes the apply take
  # whatever `main` is at the moment it starts, and record that. Those differ
  # if something merges between this check and the task starting, and taking
  # the newer commit is the behaviour we want - the alternative pins the apply
  # to a commit that was already superseded.
  #
  # `message` is what the task list shows a human. It is not the gate.
  local response task_id
  response="$(api POST "/project/${SEMAPHORE_PROJECT_ID}/tasks" \
    --data "$(jq -nc --argjson tid "$SEMAPHORE_APPLY_TEMPLATE_ID" --arg msg "gate: main moved to ${latest:0:12}" \
      '{template_id: $tid, message: $msg}')")" \
    || die "could not start the apply task"

  task_id="$(printf '%s' "$response" | jq -r '.id // empty')"
  [ -n "$task_id" ] || die "task was accepted but the response carried no id: ${response}"

  log "started apply task ${task_id}"
}

main "$@"
