#!/usr/bin/env bash
#
# prepare-context.sh — build the review prompt for a pull request. Tool-agnostic.
#
#   In:   AI_CODE_REVIEW_REPO_DIR           PR head checkout, with base history
#         AI_CODE_REVIEW_WORK_DIR           holds pr.json; receives prompt.md
#         AI_CODE_REVIEW_PROMPT_FILE        project review prompt, in the PR head (required)
#         AI_CODE_REVIEW_INSTRUCTION_FILES  optional newline-separated files, in the PR head
#         AI_CODE_REVIEW_EXCLUDE_PATHS      optional newline-separated globs left out of the diff
#         AI_CODE_REVIEW_MAX_DIFF_BYTES     optional diff limit (default 150000)
#   Out:  $AI_CODE_REVIEW_WORK_DIR/prompt.md, and "empty=true|false" on stdout
#
set -euo pipefail

: "${AI_CODE_REVIEW_REPO_DIR:?}" "${AI_CODE_REVIEW_WORK_DIR:?}"

prompt_file="${AI_CODE_REVIEW_PROMPT_FILE:-.github/ai-code-review/prompt.md}"
instruction_files="${AI_CODE_REVIEW_INSTRUCTION_FILES-.github/ai-code-review/instructions.md}"
max_diff_bytes="${AI_CODE_REVIEW_MAX_DIFF_BYTES:-150000}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pr() { jq -r "$1 // empty" "$AI_CODE_REVIEW_WORK_DIR/pr.json"; }
repo_git() { git -C "$AI_CODE_REVIEW_REPO_DIR" -c core.quotepath=false "$@"; }

[[ "$max_diff_bytes" =~ ^[0-9]+$ ]] || {
  echo "::error title=AI review::max-diff-bytes must be a whole number, got '$max_diff_bytes'." >&2
  exit 1
}

repository="$(pr .base.repo.full_name)"
base_sha="$(pr .base.sha)"
head_sha="$(pr .head.sha)"
# Diff from the merge base, like GitHub's "Files changed" tab.
merge_base="$(repo_git merge-base "$base_sha" "$head_sha")" || {
  echo "::error title=AI review::No merge base for ${base_sha:0:7}..${head_sha:0:7}; is the full history checked out?" >&2
  exit 1
}

excludes=()
if [[ -n "${AI_CODE_REVIEW_EXCLUDE_PATHS+set}" ]]; then
  while IFS= read -r glob; do
    glob="${glob#"${glob%%[![:space:]]*}"}"
    glob="${glob%"${glob##*[![:space:]]}"}"
    if [[ -n "$glob" ]]; then excludes+=(":(exclude,glob)$glob"); fi
  done <<<"$AI_CODE_REVIEW_EXCLUDE_PATHS"
else
  excludes=(
    ':(exclude,glob)**/*.lock'
    ':(exclude,glob)**/package-lock.json'
    ':(exclude,glob)**/pnpm-lock.yaml'
    ':(exclude,glob)**/dist/**'
    ':(exclude,glob)**/*.min.js'
    ':(exclude,glob)**/*.map'
    ':(exclude,glob)**/*.snap'
    ':(exclude,glob)**/*.png'
    ':(exclude,glob)**/*.jpg'
    ':(exclude,glob)**/*.svg'
  )
fi

diff="$(repo_git diff --no-color -M "$merge_base" "$head_sha" -- . "${excludes[@]}")"
# Limit bytes in a subshell so the rest of the script keeps its locale.
diff="$(
  export LC_ALL=C
  if (( ${#diff} > max_diff_bytes )); then
    diff="${diff:0:max_diff_bytes}"
    # Discard the partial final line, including any split UTF-8 character.
    if [[ "$diff" == *$'\n'* ]]; then
      diff="${diff%$'\n'*}"
    else
      diff=""
    fi
    diff+=$'\n[... diff truncated: the review is partial; say so in the Summary ...]'
  fi
  printf '%s' "$diff"
)"

# Same excludes as the diff, and a cap, so mass-generated changes cannot bloat
# the prompt.
max_changed_files=500
changed_files="$(repo_git diff --name-status -M "$merge_base" "$head_sha" -- . "${excludes[@]}")"
changed_count="$(grep -c '' <<<"$changed_files" || true)"
if (( changed_count > max_changed_files )); then
  changed_files="$(head -n "$max_changed_files" <<<"$changed_files")
[... and $((changed_count - max_changed_files)) more files ...]"
fi

# head -c counts bytes; iconv -c drops a UTF-8 character split at the cut.
description="$(pr .body | head -c 4000 | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || true)"

# Project files come from the PR head commit, so a PR's config changes apply to
# its own review (only same-repository PRs get here). git show returns a
# symlink's target text rather than following it.
project_prompt="$(repo_git show "${head_sha}:${prompt_file}" 2>/dev/null)" || {
  echo "::error title=AI review::Review prompt '${prompt_file}' not found at ${head_sha:0:7}." >&2
  exit 1
}

instructions=""
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  if text="$(repo_git show "${head_sha}:${file}" 2>/dev/null)"; then
    instructions+="${instructions:+$'\n\n'}$text"
  else
    echo "::warning title=AI review::Instruction file '${file}' not found at ${head_sha:0:7}; skipped." >&2
  fi
done <<<"$instruction_files"

# A random tag, so PR content cannot forge the end of the untrusted block.
tag="untrusted-pr-content-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"

# Header and footer are shared: they describe the sandbox, the untrusted-content
# rules and the output contract, which projects cannot override.
prompt="$(cat "$here/prompt/header.md")

${project_prompt}

## Repository-specific guidance

${instructions:-None.}

$(cat "$here/prompt/footer.md")"
prompt="${prompt//\{\{REPOSITORY\}\}/$repository}"
prompt="${prompt//\{\{REPO_DIR\}\}/$AI_CODE_REVIEW_REPO_DIR}"
prompt="${prompt//\{\{HEAD_SHA\}\}/$head_sha}"

cat >"$AI_CODE_REVIEW_WORK_DIR/prompt.md" <<EOF
$prompt

## Pull request #$(pr .number)

<$tag>
<title>$(pr .title)</title>
<description>
$description
</description>
<changed-files>
$changed_files
</changed-files>
<diff>
$diff
</diff>
</$tag>
EOF

echo "empty=$([[ -z "$diff" ]] && echo true || echo false)"
