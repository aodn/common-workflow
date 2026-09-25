#!/usr/bin/env bash
#
# test.sh — tests for the AI review scripts, using throwaway git repositories,
# a stub gh and fake review engines, so no AI credits are used.
# Run: ai-code-review/test.sh
#
# shellcheck disable=SC2016 # fake engine bodies expand when the engine runs
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prepare="$here/prepare-context.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

check() { # check <description> <command...>
  if "${@:2}"; then echo "  ok   $1"; else echo "  FAIL $1"; failures=$((failures + 1)); fi
}
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }
# in_order <file> <text...>: each text first appears after the previous one.
in_order() {
  local file="$1" last=0 line
  shift
  for text in "$@"; do
    line="$(grep -nF -m1 -- "$text" "$file" | cut -d: -f1)"
    [[ -n "$line" ]] && (( line > last )) || return 1
    last="$line"
  done
}

# new_repo <name>: a repo whose base commit on main has the default project
# prompt; prints its path.
new_repo() {
  local repo="$tmp/$1"
  git init -q -b main "$repo"
  mkdir -p "$repo/.github/ai-code-review"
  printf '%s\n' "PROJECT PROMPT for {{REPOSITORY}}" >"$repo/.github/ai-code-review/prompt.md"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m base
  echo "$repo"
}
commit() { # commit <repo> <file> <content>
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@t commit -q -m "$2"
}
pr_json() { # pr_json <repo> <base-ref> <head-ref>; PR_BODY sets the description
  jq -n --arg base "$(git -C "$1" rev-parse "$2")" --arg head "$(git -C "$1" rev-parse "$3")" \
    --arg body "${PR_BODY-}" \
    '{number: 7, title: "Test PR", body: $body, base: {sha: $base, repo: {full_name: "o/r"}},
      head: {sha: $head, repo: {full_name: "o/r"}}}'
}

# prepare <repo> <base-ref> <head-ref>: runs prepare-context.sh like the
# workflow does; the prompt ends up in <repo>.out/prompt.md.
prepare() {
  local out="$1.out"
  rm -rf "$out" && mkdir -p "$out"
  pr_json "$1" "$2" "$3" >"$out/pr.json"
  AI_CODE_REVIEW_REPO_DIR="$1" AI_CODE_REVIEW_WORK_DIR="$out" \
    "$prepare" >"$out/stdout" 2>"$out/stderr"
}

echo "resolve-pr.sh: metadata, step outputs and the fork gate"
resolve_out="$tmp/resolve"
mkdir -p "$resolve_out/bin"
cat >"$resolve_out/bin/gh" <<'SH'
#!/usr/bin/env bash
[[ "$*" == "api repos/o/r/pulls/7" ]] || exit 2
[[ "$MOCK_STATE" != api-error ]] || exit 1
jq -n --arg state "$MOCK_STATE" --argjson head_repo "${MOCK_HEAD_REPO:-\"o/r\"}" \
  '{state: $state, base: {repo: {full_name: "o/r"}},
    head: {sha: "abcdef1234", repo: (if $head_repo then {full_name: $head_repo} else null end)}}'
SH
chmod +x "$resolve_out/bin/gh"
resolve_pr() {
  : >"$resolve_out/outputs"
  PATH="$resolve_out/bin:$PATH" MOCK_STATE="$1" HAS_KEY="$2" \
    GITHUB_REPOSITORY=o/r PR_NUMBER=7 AI_CODE_REVIEW_WORK_DIR="$resolve_out" \
    GITHUB_OUTPUT="$resolve_out/outputs" "$here/resolve-pr.sh" >"$resolve_out/log" 2>&1
}
resolve_pr open true
check "outputs PR head" has "$resolve_out/outputs" "head_sha=abcdef1234"
check "outputs credential availability" has "$resolve_out/outputs" "has_key=true"
check "a same-repo PR is reviewed" has "$resolve_out/outputs" "same_repo=true"
check "saves metadata" has "$resolve_out/pr.json" '"state": "open"'
resolve_pr open false
check "missing credential is reported" has "$resolve_out/outputs" "has_key=false"
MOCK_HEAD_REPO='"someone/r"' resolve_pr open true
check "a fork PR is not reviewed" has "$resolve_out/outputs" "same_repo=false"
check "a fork PR is reported" has "$resolve_out/log" "is from a fork; skipped"
MOCK_HEAD_REPO=null resolve_pr open true
check "a deleted fork (null head repo) is not reviewed" has "$resolve_out/outputs" "same_repo=false"
for state in closed api-error; do
  if resolve_pr "$state" true; then result=0; else result=$?; fi
  check "$state fails" test "$result" -ne 0
  check "$state emits no success outputs" test ! -s "$resolve_out/outputs"
done

echo "diverged branch: only the PR's own changes are reviewed"
repo="$(new_repo diverged)"
git -C "$repo" checkout -q -b pr
commit "$repo" src/feature.ts "export const feature = 1;"
git -C "$repo" checkout -q main
commit "$repo" src/unrelated.ts "landed on main after the PR branched"
prepare "$repo" main pr
check "includes the PR's change" has "$repo.out/prompt.md" "src/feature.ts"
check "excludes commits that landed on main later" lacks "$repo.out/prompt.md" "landed on main after"

echo "prompt assembly: shared header and footer around the project files"
repo="$(new_repo assembly)"
commit "$repo" .github/ai-code-review/instructions.md "INSTRUCTIONS ONE"
git -C "$repo" checkout -q -b pr
commit "$repo" src/a.ts "export const a = 1;"
prepare "$repo" main pr
check "order: header, project prompt, instructions, footer, PR block" in_order "$repo.out/prompt.md" \
  "## What you have" "PROJECT PROMPT" "## Repository-specific guidance" "INSTRUCTIONS ONE" \
  "## Untrusted content" "## Output format" "## Pull request #7" "</untrusted-pr-content-"
check "placeholders are substituted in the project prompt" has "$repo.out/prompt.md" "PROJECT PROMPT for o/r"
check "placeholders are substituted in the shared header" lacks "$repo.out/prompt.md" "{{REPO_DIR}}"

echo "project files come from the PR head, so a PR's config changes apply"
repo="$(new_repo head-config)"
commit "$repo" .github/ai-code-review/instructions.md "BASE GUIDANCE"
git -C "$repo" checkout -q -b pr
commit "$repo" .github/ai-code-review/instructions.md "PR GUIDANCE"
commit "$repo" .github/ai-code-review/prompt.md "PR PROMPT"
prepare "$repo" main pr
check "uses the PR's instructions" in_order "$repo.out/prompt.md" \
  "## Repository-specific guidance" "PR GUIDANCE" "## Untrusted content"
check "base instructions appear only inside the diff" \
  test "$(grep -c "BASE GUIDANCE" "$repo.out/prompt.md")" = 1
check "uses the PR's prompt" in_order "$repo.out/prompt.md" "## What you have" "PR PROMPT" "## Repository-specific guidance"
# The checkout is left on main: files are read from the head commit, not the working tree.
git -C "$repo" checkout -q main
prepare "$repo" main pr
check "reads the head commit, not the working tree" in_order "$repo.out/prompt.md" \
  "## Repository-specific guidance" "PR GUIDANCE" "## Untrusted content"

echo "instruction-files: several files in order, a missing one is skipped"
repo="$(new_repo instruction-files)"
git -C "$repo" checkout -q -b pr
commit "$repo" docs/second.md "SECOND FILE"
commit "$repo" AGENTS.md "FIRST FILE"
out="$repo.out"
mkdir -p "$out" && pr_json "$repo" main pr >"$out/pr.json"
AI_CODE_REVIEW_REPO_DIR="$repo" AI_CODE_REVIEW_WORK_DIR="$out" \
  AI_CODE_REVIEW_INSTRUCTION_FILES=$'AGENTS.md\nmissing.md\ndocs/second.md\n' "$prepare" >"$out/stdout" 2>"$out/stderr"
check "joins the files in the given order" in_order "$out/prompt.md" "## Repository-specific guidance" "FIRST FILE" "SECOND FILE"
check "warns about the missing file" has "$out/stderr" "Instruction file 'missing.md' not found"
AI_CODE_REVIEW_REPO_DIR="$repo" AI_CODE_REVIEW_WORK_DIR="$out" AI_CODE_REVIEW_INSTRUCTION_FILES="" \
  "$prepare" >"$out/stdout" 2>"$out/stderr"
check "no instruction files gives None." has "$out/prompt.md" $'None.'

echo "a missing or symlinked prompt file"
repo="$(new_repo prompt-missing)"
git -C "$repo" checkout -q -b pr
git -C "$repo" rm -q .github/ai-code-review/prompt.md
commit "$repo" src/a.ts "a"
rc=0; prepare "$repo" main pr || rc=$?
check "a missing prompt fails" test "$rc" -ne 0
check "a missing prompt is reported" has "$repo.out/stderr" "Review prompt '.github/ai-code-review/prompt.md' not found"
repo="$(new_repo prompt-symlink)"
echo "TOP SECRET RUNNER FILE" >"$tmp/secret.txt"
git -C "$repo" checkout -q -b pr
ln -sf "$tmp/secret.txt" "$repo/.github/ai-code-review/prompt.md"
git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m symlink
prepare "$repo" main pr
check "a symlinked prompt is not followed" lacks "$repo.out/prompt.md" "TOP SECRET RUNNER FILE"

echo "excluded paths and empty diffs"
repo="$(new_repo excluded)"
git -C "$repo" checkout -q -b pr
commit "$repo" yarn.lock "lockfile content"
commit "$repo" web/dist/app.js "bundled output"
prepare "$repo" main pr
check "drops excluded content" lacks "$repo.out/prompt.md" "lockfile content"
check "reports empty=true" has "$repo.out/stdout" "empty=true"
AI_CODE_REVIEW_EXCLUDE_PATHS=$'  **/dist/**\n\n' prepare "$repo" main pr
check "exclude-paths replaces the defaults" has "$repo.out/prompt.md" "lockfile content"
check "exclude-paths globs still apply" lacks "$repo.out/prompt.md" "bundled output"
commit "$repo" src/real.ts "real change"
prepare "$repo" main pr
check "reports empty=false once real code changes" has "$repo.out/stdout" "empty=false"

echo "large diffs are truncated"
repo="$(new_repo large)"
git -C "$repo" checkout -q -b pr
commit "$repo" big.txt "$(seq 1 40000)"
prepare "$repo" main pr
check "marks the diff as truncated" has "$repo.out/prompt.md" "diff truncated"
check "keeps the prompt under ~160 KB" test "$(wc -c <"$repo.out/prompt.md")" -lt 160000
AI_CODE_REVIEW_MAX_DIFF_BYTES=2000 prepare "$repo" main pr
check "max-diff-bytes sets the limit" test "$(wc -c <"$repo.out/prompt.md")" -lt 10000
rc=0; AI_CODE_REVIEW_MAX_DIFF_BYTES=lots prepare "$repo" main pr || rc=$?
check "a non-numeric max-diff-bytes fails" test "$rc" -ne 0

echo "multibyte diffs respect the byte limit under a UTF-8 locale"
repo="$(new_repo multibyte)"
git -C "$repo" checkout -q -b pr
commit "$repo" unicode.txt "$(awk 'BEGIN { for (i = 0; i < 20000; i++) print "€€€€" }')"
LC_ALL=C.UTF-8 prepare "$repo" main pr
check "multibyte diff is truncated" has "$repo.out/prompt.md" "diff truncated"
check "multibyte prompt stays under ~160 KB" test "$(wc -c <"$repo.out/prompt.md")" -lt 160000
check "truncated prompt remains valid UTF-8" iconv -f UTF-8 -t UTF-8 "$repo.out/prompt.md" -o /dev/null
check "retains complete diff lines" has "$repo.out/prompt.md" "+€€€€"

repo="$(new_repo multibyte-long-line)"
git -C "$repo" checkout -q -b pr
commit "$repo" unicode.txt "$(awk 'BEGIN { for (i = 0; i < 60000; i++) printf "€" }')"
LC_ALL=C.UTF-8 prepare "$repo" main pr
check "oversized Unicode line is truncated" has "$repo.out/prompt.md" "diff truncated"
check "drops the incomplete Unicode line" lacks "$repo.out/prompt.md" "€"
check "long-line prompt remains valid UTF-8" iconv -f UTF-8 -t UTF-8 "$repo.out/prompt.md" -o /dev/null

echo "the description is cut on a character boundary"
repo="$(new_repo description)"
git -C "$repo" checkout -q -b pr
commit "$repo" x.ts "x"
# 3999 ASCII bytes, then a 3-byte character that the 4000-byte cut would split.
PR_BODY="$(printf 'a%.0s' $(seq 1 3999))€tail" prepare "$repo" main pr
check "long description is cut" lacks "$repo.out/prompt.md" "tail"
check "cut description remains valid UTF-8" iconv -f UTF-8 -t UTF-8 "$repo.out/prompt.md" -o /dev/null
PR_BODY="short € body" prepare "$repo" main pr
check "short description is kept whole" has "$repo.out/prompt.md" "short € body"

echo "the changed-files list is filtered and capped"
repo="$(new_repo many-files)"
git -C "$repo" checkout -q -b pr
mkdir -p "$repo/gen" "$repo/dist"
for i in $(seq 1 600); do echo "$i" >"$repo/gen/f$i.ts"; done
echo "bundle" >"$repo/dist/out.js"
commit "$repo" src/real.ts "real change"
prepare "$repo" main pr
check "excluded paths are left out of the list" lacks "$repo.out/prompt.md" "dist/out.js"
check "the list is capped" has "$repo.out/prompt.md" "and 101 more files"
check "files past the cap are left out" test "$(grep -c '^A	gen/f' "$repo.out/prompt.md")" -lt 501

echo "missing base history fails clearly"
repo="$(new_repo orphan)"
git -C "$repo" checkout -q --orphan other
commit "$repo" x.ts "x"
rc=0; prepare "$repo" main other 2>/dev/null || rc=$?
check "exits non-zero without a merge base" test "$rc" -ne 0

# review <repo> <engine-body> [api-key]: runs review.sh with a fake engine whose
# body is given as shell; output lands in <repo>.review/stdout. Extra AI_CODE_REVIEW_*
# variables can be set by the caller.
review() {
  local out="$1.review"
  rm -rf "$out" && mkdir -p "$out" # review.sh appends to GITHUB_OUTPUT
  pr_json "$1" main pr >"$out/pr.json"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$out/engine.sh"
  chmod +x "$out/engine.sh"
  AI_CODE_REVIEW_REPO_DIR="$1" AI_CODE_REVIEW_WORK_DIR="$out" \
    AI_CODE_REVIEW_ENGINE="${AI_CODE_REVIEW_ENGINE_OVERRIDE-$out/engine.sh}" AI_CODE_REVIEW_API_KEY="${3:-}" \
    GITHUB_OUTPUT="$out/stdout" "${REVIEW_SH:-$here/review.sh}" >"$out/log" 2>&1
}
# writes <text>: an engine body that writes <text> as the review.
writes() { printf "printf '%%s\\\\n' '%s' >\"\$AI_CODE_REVIEW_WORK_DIR/review.md\"; echo credits=0.5" "$1"; }
ran() { printf 'touch "$AI_CODE_REVIEW_WORK_DIR/engine-ran"; %s' "$(writes ok)"; }

echo "review.sh: outcomes and the credential check"
repo="$(new_repo reviewed)"
git -C "$repo" checkout -q -b pr
commit "$repo" src/a.ts "export const a = 1;"

review "$repo" "$(writes "Looks good.")"
check "clean review is ok" has "$repo.review/stdout" "status=ok"
check "credits are passed through" has "$repo.review/stdout" "credits=0.5"

review "$repo" "$(writes "Looks good.")" ""
check "no API key set (local run) is still ok" has "$repo.review/stdout" "status=ok"

review "$repo" "$(writes "The guard greps for github_pat_ and gh[pousr]_[A-Za-z0-9]{36}.")" "secret-key"
check "naming token prefixes is not withheld (CI false positive)" has "$repo.review/stdout" "status=ok"

token="ghp_$(printf 'A%.0s' {1..36})"
review "$repo" "$(writes "leaked $token")" "secret-key"
check "a real token shape is withheld" has "$repo.review/stdout" "status=failed"
check "the log does not repeat the token" lacks "$repo.review/log" "$token"

review "$repo" "$(writes "leaked secret-key-123")" "secret-key-123"
check "the engine API key is withheld" has "$repo.review/stdout" "status=failed"

review "$repo" "exit 3"
check "an engine failure is failed" has "$repo.review/stdout" "status=failed"

review "$repo" "echo credits=0.5"
check "no review.md is failed" has "$repo.review/stdout" "status=failed"
check "no review.md is reported" has "$repo.review/log" "produced no review"
review "$repo" "$(writes "   ")"
check "a blank review.md is failed" has "$repo.review/stdout" "status=failed"

AI_CODE_REVIEW_ENGINE_OVERRIDE=/nonexistent review "$repo" "true"
check "a missing engine is failed" has "$repo.review/stdout" "status=failed"
check "a missing engine is reported" has "$repo.review/log" "No executable review engine"

for name in ../x "Kiro" ""; do
  AI_CODE_REVIEW_ENGINE_OVERRIDE="" AI_CODE_REVIEW_ENGINE_NAME="$name" review "$repo" "$(ran)"
  check "engine name '$name' is rejected" has "$repo.review/log" "Invalid engine name"
done
AI_CODE_REVIEW_ENGINE_OVERRIDE="" AI_CODE_REVIEW_ENGINE_NAME=nope review "$repo" "$(ran)"
check "an unknown engine name is failed" has "$repo.review/stdout" "status=failed"

for path in /etc/passwd ../outside.md "docs/../../x.md" "has space.md"; do
  AI_CODE_REVIEW_PROMPT_FILE="$path" review "$repo" "$(ran)"
  check "prompt-file '$path' is rejected" has "$repo.review/log" "Invalid file input"
  check "prompt-file '$path' does not run the engine" test ! -e "$repo.review/engine-ran"
done
AI_CODE_REVIEW_INSTRUCTION_FILES=$'AGENTS.md\n../x.md' review "$repo" "$(ran)"
check "an invalid instruction file is rejected" has "$repo.review/stdout" "status=failed"
AI_CODE_REVIEW_AGENT_FILE=/etc/x.json review "$repo" "$(ran)"
check "an invalid agent file is rejected" has "$repo.review/stdout" "status=failed"

AI_CODE_REVIEW_PROMPT_FILE=missing/prompt.md review "$repo" "$(ran)"
check "a missing prompt file is failed" has "$repo.review/stdout" "status=failed"
check "a missing prompt file does not run the engine" test ! -e "$repo.review/engine-ran"

repo="$(new_repo only-excluded)"
git -C "$repo" checkout -q -b pr
commit "$repo" yarn.lock "lockfile"
review "$repo" "$(ran)"
check "an empty diff is empty" has "$repo.review/stdout" "status=empty"
check "the engine is not called for an empty diff" test ! -e "$repo.review/engine-ran"

echo "review.sh: engines are chosen by name (a second, non-Kiro engine)"
tools="$tmp/tools"
mkdir -p "$tools/engines/fake"
cp -r "$here/prompt" "$here"/*.sh "$tools/"
cat >"$tools/engines/fake/run.sh" <<'SH'
#!/usr/bin/env bash
grep -q "## Output format" "$AI_CODE_REVIEW_WORK_DIR/prompt.md" || exit 1
echo "fake engine review, model ${AI_CODE_REVIEW_MODEL:-default}" >"$AI_CODE_REVIEW_WORK_DIR/review.md"
echo credits=1
SH
chmod +x "$tools/engines/fake/run.sh"
repo="$(new_repo fake-engine)"
git -C "$repo" checkout -q -b pr
commit "$repo" src/a.ts "a"
REVIEW_SH="$tools/review.sh" AI_CODE_REVIEW_ENGINE_OVERRIDE="" AI_CODE_REVIEW_ENGINE_NAME=fake AI_CODE_REVIEW_MODEL=m1 \
  review "$repo" "true"
check "the fake engine runs end to end" has "$repo.review/stdout" "status=ok"
check "the fake engine's credits are passed through" has "$repo.review/stdout" "credits=1"
check "the fake engine gets the model" has "$repo.review/review.md" "model m1"

echo "review.sh: the agent overlay is staged from the PR head"
repo="$(new_repo overlay-stage)"
git -C "$repo" checkout -q -b pr
commit "$repo" .github/ai-code-review/kiro-agent.json '{"prompt": "HEAD OVERLAY"}'
printf '%s\n' '{"prompt": "WORKING TREE"}' >"$repo/.github/ai-code-review/kiro-agent.json"
copy_overlay='cat "${AI_CODE_REVIEW_AGENT_OVERLAY:-/dev/null}" >"$AI_CODE_REVIEW_WORK_DIR/review.md"; echo "overlay=${AI_CODE_REVIEW_AGENT_OVERLAY:-none}" >>"$AI_CODE_REVIEW_WORK_DIR/review.md"'
AI_CODE_REVIEW_AGENT_FILE=.github/ai-code-review/kiro-agent.json review "$repo" "$copy_overlay"
check "the engine gets the PR head's overlay" has "$repo.review/review.md" "HEAD OVERLAY"
check "the working tree copy is not used" lacks "$repo.review/review.md" "WORKING TREE"
AI_CODE_REVIEW_AGENT_FILE=.github/ai-code-review/none.json review "$repo" "$copy_overlay"
check "a missing overlay still reviews" has "$repo.review/stdout" "status=ok"
check "a missing overlay passes none to the engine" has "$repo.review/review.md" "overlay=none"
check "a missing overlay warns" has "$repo.review/log" "not found"
review "$repo" "$copy_overlay"
check "no agent-file passes no overlay" has "$repo.review/review.md" "overlay=none"

# publish <status> <previous-ids> [post-exit-code]: runs publish.sh with a stub
# gh that records its calls; the list query "returns" <previous-ids>.
publish() {
  local out="$tmp/publish"
  rm -rf "$out" && mkdir -p "$out/bin"
  printf '%s\n' "Looks good." >"$out/review.md"
  cat >"$out/bin/gh" <<STUB
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *minimizeComment*) [[ "\$args" =~ id=([A-Za-z0-9_]+) ]] && echo "minimize \${BASH_REMATCH[1]}" >>"$out/calls" ;;
  *"graphql"*) echo list >>"$out/calls"; printf '%s\\n' $2 ;;
  *"-X POST"*) echo post >>"$out/calls"; exit ${3:-0} ;;
esac
STUB
  chmod +x "$out/bin/gh"
  PATH="$out/bin:$PATH" STATUS="$1" AI_CODE_REVIEW_WORK_DIR="$out" AI_CODE_REVIEW_ENGINE_NAME=kiro PR_NUMBER=7 HEAD_SHA=abcdef1234 \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1 GITHUB_STEP_SUMMARY="$out/summary" \
    "$here/publish.sh" >"$out/log" 2>&1
}
calls() { tr '\n' ' ' <"$tmp/publish/calls" | sed 's/ $//'; }

echo "publish.sh: a new comment per run, earlier ones collapsed"
publish ok "IC_1 IC_2"
check "lists, posts, then collapses the earlier reviews" \
  test "$(calls)" = "list post minimize IC_1 minimize IC_2"
check "the comment carries the marker" has "$tmp/publish/comment.md" "<!-- ai-code-review -->"
check "the summary gets the review" has "$tmp/publish/summary" "Looks good."
check "the footer names the engine" has "$tmp/publish/comment.md" "\`abcdef1\` · kiro"

publish ok ""
check "first review: nothing to collapse" test "$(calls)" = "list post"

publish ok "IC_1" 1
check "a failed post collapses nothing (last review stays visible)" test "$(calls)" = "list post"
check "a failed post is only a warning" has "$tmp/publish/log" "Could not post the AI review comment"

publish skipped ""
check "the skipped text is engine-neutral" lacks "$tmp/publish/comment.md" "KIRO_API_KEY"
check "the skipped text names the engine secret" has "$tmp/publish/comment.md" "engine API key secret"

# Exercise engines/kiro/run.sh with a fake CLI archive; no network or AI calls.
# The fake CLI records the installed agent, its working directory and key.
kiro_test="$tmp/kiro"
mkdir -p "$kiro_test/bin" "$kiro_test/archive/kirocli/bin" "$kiro_test/repo/.kiro"
cat >"$kiro_test/archive/kirocli/bin/kiro-cli" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == settings ]] && exit 0
cp "$KIRO_HOME/agents/code-reviewer.json" "$KIRO_TEST_DIR/agent.json"
pwd >"$KIRO_TEST_DIR/cwd"
echo "${KIRO_API_KEY:-}" >"$KIRO_TEST_DIR/key"
cat "$KIRO_TEST_DIR/events.jsonl"
STUB
cat >"$kiro_test/bin/curl" <<'STUB'
#!/usr/bin/env bash
while (( $# )); do
  if [[ "$1" == -o ]]; then cp "$KIRO_TEST_ARCHIVE" "$2"; exit; fi
  shift
done
exit 1
STUB
chmod +x "$kiro_test/archive/kirocli/bin/kiro-cli" "$kiro_test/bin/curl"
tar -czf "$kiro_test/cli.tar.gz" -C "$kiro_test/archive" kirocli
# kiro_run [overlay-json]: runs the Kiro engine; the review lands in work/review.md.
kiro_run() {
  local work="$kiro_test/work"
  rm -rf "$work" "$kiro_test/agent.json" && mkdir -p "$work"
  echo "Review this PR" >"$work/prompt.md"
  local overlay=""
  if [[ $# -gt 0 ]]; then overlay="$kiro_test/overlay.json"; printf '%s\n' "$1" >"$overlay"; fi
  PATH="$kiro_test/bin:$PATH" KIRO_TEST_ARCHIVE="$kiro_test/cli.tar.gz" KIRO_TEST_DIR="$kiro_test" \
    AI_CODE_REVIEW_WORK_DIR="$work" AI_CODE_REVIEW_REPO_DIR="$kiro_test/repo" AI_CODE_REVIEW_API_KEY=kiro-key \
    AI_CODE_REVIEW_AGENT_OVERLAY="$overlay" "$here/engines/kiro/run.sh" >"$kiro_test/log" 2>&1
}
agent() { jq -c "$1" "$kiro_test/agent.json"; }

echo "engines/kiro/run.sh: preserve review content when stripping outer tags"
review_text=$'### Summary\n🤖 Review summary — Important summary.\n### Findings\nThe parser treats `</review>` and `<review>` in code as boundaries.\n### Tests\nAdd coverage.'
wrapped=$'<review>\n'"$review_text"$'\n</review>'
jq -n --arg text "$wrapped" '{type:"runFinished",data:{finalText:$text}}' >"$kiro_test/events.jsonl"
kiro_run
check "keeps the full summary and literal tags" test "$(cat "$kiro_test/work/review.md")" = "$review_text"
narrated=$'🤖 Review progress — I will examine the changes.\n'"$wrapped"$'\nReview complete.'
jq -n --arg text "$narrated" '{type:"runFinished",data:{finalText:$text}}' >"$kiro_test/events.jsonl"
kiro_run
check "removes Unicode narration without losing the summary or literal tags" test "$(cat "$kiro_test/work/review.md")" = "$review_text"
jq -n --arg text "$review_text" '{type:"runFinished",data:{finalText:$text}}' >"$kiro_test/events.jsonl"
kiro_run
check "keeps unwrapped output unchanged" test "$(cat "$kiro_test/work/review.md")" = "$review_text"
jq -n --arg text "$narrated" '{data:{update:{sessionUpdate:"agent_message_chunk",content:{text:$text}}}}' >"$kiro_test/events.jsonl"
kiro_run
check "ACP fallback also preserves literal tags" test "$(cat "$kiro_test/work/review.md")" = "$review_text"
jq -n '{type:"runFinished",data:{finalText:"<review> \n </review>"}}' >"$kiro_test/events.jsonl"
if kiro_run; then result=0; else result=$?; fi
check "empty wrapped output fails" test "$result" -ne 0

echo "engines/kiro/run.sh: sandbox and the base agent"
jq -n '{type:"runFinished",data:{finalText:"<review>ok</review>"}}' >"$kiro_test/events.jsonl"
kiro_run
check "no overlay installs the base agent" test "$(agent '[.name, .tools, .hooks, .mcpServers, .includeMcpJson]')" = \
  '["code-reviewer",["read","glob","grep"],{},{},false]'
check "runtime denied paths are appended" test "$(agent '.toolsSettings.read.deniedPaths | index("/proc/**") != null')" = true
check "runs from an empty directory, not the checkout (its .kiro/ never loads)" \
  test "$(cat "$kiro_test/cwd")" = "$(realpath "$kiro_test/work")/kiro/cwd"
check "passes the key to kiro-cli as KIRO_API_KEY" test "$(cat "$kiro_test/key")" = kiro-key

echo "engines/kiro/run.sh: project overlay can extend, never widen"
kiro_run '{"prompt": "Focus on Java.", "model": "m2", "description": "backend"}'
check "overlay prompt is appended after the base prompt" \
  test "$(agent '.prompt | test("^You are a read-only CI code reviewer[\\s\\S]*\n\nFocus on Java\\.$")')" = true
check "overlay model and description apply" test "$(agent '[.model, .description]')" = '["m2","backend"]'
kiro_run '{"tools": ["read", "shell"], "allowedTools": ["read", "shell", "grep"], "hooks": {"agentSpawn": [{"command": "curl x"}]},
  "mcpServers": {"x": {"command": "x"}}, "includeMcpJson": true, "name": "evil"}'
check "tools are narrowed, never widened" test "$(agent '[.tools, .allowedTools]')" = '[["read"],["read","grep"]]'
check "sandbox keys stay the base's" test "$(agent '[.name, .hooks, .mcpServers, .includeMcpJson]')" = '["code-reviewer",{},{},false]'
check "ignored keys are warned about" has "$kiro_test/log" "keys ignored (fixed by the shared agent): hooks, includeMcpJson, mcpServers, name"
check "disallowed tools are warned about" has "$kiro_test/log" "tools not allowed (read-only sandbox): shell"
kiro_run '{"toolsSettings": {"read": {"deniedPaths": ["/data/**"], "allowedPaths": ["/"]}, "grep": {"deniedPaths": "x"}}}'
check "overlay denied paths are added" test "$(agent '.toolsSettings.read.deniedPaths | (index("/data/**") != null) and (index("/proc/**") != null)')" = true
check "other tool settings are ignored" test "$(agent '.toolsSettings.read | has("allowedPaths")')" = false
check "a malformed deniedPaths adds nothing" test "$(agent '.toolsSettings.grep.deniedPaths | index("x")')" = null
if kiro_run '{not json'; then result=0; else result=$?; fi
check "invalid overlay JSON fails" test "$result" -ne 0
if kiro_run '["read"]'; then result=0; else result=$?; fi
check "a non-object overlay fails" test "$result" -ne 0

echo
if (( failures )); then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
