#!/usr/bin/env bash
# Keeps PRs into main moving when the event-driven merge alone would stall:
#  - re-runs CI that never got a runner. GitHub's macOS arm64 pool runs short
#    ("The job was not acquired by Runner of type hosted even after multiple
#    attempts") and the run ends red with no step executed;
#  - merges PRs whose CI on the current head passed.
# A run where any step executed and failed is a real failure: left alone.
# DRY_RUN=1 prints what it would do.
set -euo pipefail
REPO="${REPO:?set REPO=owner/name}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-5}"
owner="${REPO%%/*}"

act() {
  if [ "${DRY_RUN:-}" = 1 ]; then echo "  would: $*"; else "$@"; fi
}

gh pr list --repo "$REPO" --base main --state open \
  --json number,isDraft,headRefOid,headRepositoryOwner \
  --jq ".[] | select(.isDraft | not) | select(.headRepositoryOwner.login == \"$owner\") | \"\(.number) \(.headRefOid)\"" |
while read -r pr sha; do
  run=$(gh run list --repo "$REPO" --workflow CI --commit "$sha" --event pull_request --limit 1 \
          --json databaseId,status,conclusion,attempt \
          --jq '.[0] // empty | "\(.databaseId)|\(.status)|\(.conclusion)|\(.attempt)"')
  if [ -z "$run" ]; then echo "#$pr: no CI run for ${sha:0:7} yet"; continue; fi
  # `|` keeps an empty conclusion (still queued) from shifting the fields.
  IFS='|' read -r id status conclusion attempt <<<"$run"
  echo "#$pr: CI ${status} ${conclusion} (attempt ${attempt})"
  [ "$status" = completed ] || continue

  case "$conclusion" in
    success)
      act gh pr merge "$pr" --repo "$REPO" --merge --match-head-commit "$sha" || echo "  merge refused"
      ;;
    failure|cancelled|timed_out|startup_failure)
      steps=$(gh api "repos/$REPO/actions/runs/$id/jobs" --jq '[.jobs[].steps | length] | add // 0')
      if [ "$conclusion" = failure ] && [ "$steps" -gt 0 ]; then
        echo "  real failure (steps ran): leaving it"
      elif [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "  no runner after $attempt attempts: giving up"
      else
        act gh run rerun "$id" --repo "$REPO"
      fi
      ;;
  esac
done
