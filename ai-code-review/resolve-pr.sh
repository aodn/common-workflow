#!/usr/bin/env bash
# Resolve the PR into $AI_CODE_REVIEW_WORK_DIR/pr.json for the review scripts.
# In: GITHUB_REPOSITORY, PR_NUMBER, GH_TOKEN, HAS_KEY, AI_CODE_REVIEW_WORK_DIR.
# Out: head_sha, has_key and same_repo in GITHUB_OUTPUT; fail if the PR is not open.
set -euo pipefail

mkdir -p "$AI_CODE_REVIEW_WORK_DIR"
pr_json="$AI_CODE_REVIEW_WORK_DIR/pr.json"
gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER" >"$pr_json"
if [[ "$(jq -r .state "$pr_json")" != open ]]; then
  echo "::error::PR #$PR_NUMBER is not open."
  exit 1
fi

# The review prompt, instructions and agent overlay come from the PR head, so
# only branches in this repository (written by trusted developers) are
# reviewed. A deleted fork has a null head repo and counts as a fork.
same_repo=false
if [[ "$(jq -r '.head.repo.full_name // empty' "$pr_json")" == "$(jq -r .base.repo.full_name "$pr_json")" ]]; then
  same_repo=true
else
  echo "::notice title=AI review::PR #$PR_NUMBER is from a fork; skipped."
fi
{
  echo "head_sha=$(jq -r .head.sha "$pr_json")"
  echo "has_key=$HAS_KEY"
  echo "same_repo=$same_repo"
} >>"$GITHUB_OUTPUT"
