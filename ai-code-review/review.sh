#!/usr/bin/env bash
#
# review.sh — prepare the prompt, run the review engine, check its output.
#
#   In:   the AI_CODE_REVIEW_* variables used by prepare-context.sh
#         AI_CODE_REVIEW_ENGINE_NAME  engine folder under engines/ (e.g. kiro)
#         AI_CODE_REVIEW_ENGINE       optional engine executable path (tests only)
#         AI_CODE_REVIEW_AGENT_FILE   optional engine agent overlay, in the PR head
#         AI_CODE_REVIEW_API_KEY      engine credential, checked against the output
#   Out:  $AI_CODE_REVIEW_WORK_DIR/review.md, and "status=ok|empty|failed" plus
#         "credits=<n>" appended to $GITHUB_OUTPUT (stdout when run locally)
#
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
review="$AI_CODE_REVIEW_WORK_DIR/review.md"
engine_out="$AI_CODE_REVIEW_WORK_DIR/engine.out"

# Real credential shapes only: a review may legitimately name a prefix such as
# github_pat_ (for example when it reviews this very check).
credential='gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{80,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

# Caller paths are repository-relative: no absolute paths, no "..", no odd
# characters. Never fall back to a shared file.
valid_path() { [[ "$1" =~ ^[A-Za-z0-9._/-]+$ && "$1" != /* && "/$1/" != */../* ]]; }
check_paths() {
  local path
  while IFS= read -r path; do
    [[ -z "$path" ]] || valid_path "$path" || {
      echo "::error title=AI review::Invalid file input '${path}': use a path relative to the repository root."
      return 1
    }
  done < <(printf '%s\n' "${AI_CODE_REVIEW_PROMPT_FILE:-}" "${AI_CODE_REVIEW_AGENT_FILE:-}" "${AI_CODE_REVIEW_INSTRUCTION_FILES:-}")
}

# An engine is a folder under engines/, chosen by a simple name.
resolve_engine() {
  if [[ -n "${AI_CODE_REVIEW_ENGINE:-}" ]]; then
    engine="$AI_CODE_REVIEW_ENGINE"
  elif [[ "${AI_CODE_REVIEW_ENGINE_NAME:-}" =~ ^[a-z0-9-]+$ ]]; then
    engine="$here/engines/$AI_CODE_REVIEW_ENGINE_NAME/run.sh"
  else
    echo "::error title=AI review::Invalid engine name '${AI_CODE_REVIEW_ENGINE_NAME:-}'."
    return 1
  fi
  [[ -x "$engine" ]] || { echo "::error title=AI review::No executable review engine at '${engine}'."; return 1; }
}

# Stage the overlay from git, not the working tree, so a symlink is never
# followed. A missing overlay is a warning: the engine's base agent still runs.
stage_overlay() {
  unset AI_CODE_REVIEW_AGENT_OVERLAY
  [[ -n "${AI_CODE_REVIEW_AGENT_FILE:-}" ]] || return 0
  local head_sha overlay="$AI_CODE_REVIEW_WORK_DIR/agent-overlay.json"
  head_sha="$(jq -r .head.sha "$AI_CODE_REVIEW_WORK_DIR/pr.json")"
  if git -C "$AI_CODE_REVIEW_REPO_DIR" show "${head_sha}:${AI_CODE_REVIEW_AGENT_FILE}" >"$overlay" 2>/dev/null; then
    export AI_CODE_REVIEW_AGENT_OVERLAY="$overlay"
  else
    echo "::warning title=AI review::Agent file '${AI_CODE_REVIEW_AGENT_FILE}' not found at ${head_sha:0:7}; using the engine's base agent."
  fi
}

status=failed
if ! check_paths || ! resolve_engine; then
  :
elif ! prepared="$("$here/prepare-context.sh")"; then
  echo "::error title=AI review::Could not prepare the review context."
elif [[ "$prepared" == empty=true ]]; then
  status=empty
elif ! stage_overlay; then
  echo "::error title=AI review::Could not stage the agent file."
elif ! timeout 15m "$engine" | tee "$engine_out"; then
  echo "::error title=AI review::The review engine failed or timed out."
elif ! grep -q '[^[:space:]]' "$review" 2>/dev/null; then
  echo "::error title=AI review::The review engine produced no review."
elif [[ -n "${AI_CODE_REVIEW_API_KEY:-}" ]] && grep -qF -- "$AI_CODE_REVIEW_API_KEY" "$review"; then
  echo "::error title=AI review::The review contained the engine API key and was withheld."
elif match="$(grep -oE -m1 "$credential" "$review")"; then
  # Log only the first 4 characters, never the match itself.
  echo "::error title=AI review::The review matched a credential pattern (${match:0:4}...) and was withheld."
else
  status=ok
fi

{
  grep '^credits=' "$engine_out" 2>/dev/null
  echo "status=$status"
} >>"${GITHUB_OUTPUT:-/dev/stdout}"
