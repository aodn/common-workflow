#!/usr/bin/env bash
#
# engines/kiro/run.sh — run the review with the Kiro headless CLI (V3 engine).
#
#   In:   AI_CODE_REVIEW_REPO_DIR       PR checkout (git); the agent reads a copy of HEAD
#         AI_CODE_REVIEW_WORK_DIR       holds prompt.md; receives review.md and logs
#         AI_CODE_REVIEW_API_KEY        Kiro API key (passed to kiro-cli as KIRO_API_KEY)
#         AI_CODE_REVIEW_MODEL          optional model id
#         AI_CODE_REVIEW_AGENT_OVERLAY  optional project overlay on code-reviewer.json
#   Out:  $AI_CODE_REVIEW_WORK_DIR/review.md, and "credits=<n>" on stdout
#   Exit: 0 on success
#
set -euo pipefail
: "${AI_CODE_REVIEW_REPO_DIR:?}" "${AI_CODE_REVIEW_WORK_DIR:?}"
# Pinned release: the review depends on its CLI flags, permission model and
# event format, so upgrades are deliberate. See "Upgrading kiro-cli" in README.md.
kiro_version="3.5.0"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_CODE_REVIEW_WORK_DIR="$(realpath "$AI_CODE_REVIEW_WORK_DIR")"
repo="$(realpath "$AI_CODE_REVIEW_REPO_DIR")"
work="$AI_CODE_REVIEW_WORK_DIR/kiro"
# The agent's workspace: a copy of the checkout's HEAD commit. V3 fails closed
# on reads outside the workspace (a headless run cannot answer the approval
# prompt), so the copy is the sandbox boundary. It holds no .git, untracked
# files (.env on a workstation) or symlinks (which could point outside), and
# no .kiro/ directories, so the PR's own agents, hooks, steering and settings
# never load.
copy="$work/repo"
mkdir -p "$work/home/agents" "$copy"
# 1. Build the agent first, so a bad overlay fails before the download.
#    The base code-reviewer.json holds the sandbox. A project overlay may add to
#    the prompt, set description and model, narrow the tools and add deny rules;
#    everything else (name, hooks, MCP servers, resources, allow rules, ...)
#    stays the base.
overlay="${AI_CODE_REVIEW_AGENT_OVERLAY:-}"
if [[ -n "$overlay" ]]; then
  jq -e 'type == "object"' "$overlay" >/dev/null 2>&1 ||
    { echo "::error title=AI review::The agent file is not a JSON object." >&2; exit 1; }
  ignored="$(jq -r '[keys[] | select(IN("prompt", "description", "model", "tools", "permissions") | not)] | join(", ")' "$overlay")"
  [[ -z "$ignored" ]] || echo "::warning title=AI review::Agent file keys ignored (fixed by the shared agent): ${ignored}" >&2
  dropped="$(jq -r --slurpfile base "$here/code-reviewer.json" \
    '[.tools | arrays | .[]] - $base[0].tools | unique | map(tostring) | join(", ")' "$overlay")"
  [[ -z "$dropped" ]] || echo "::warning title=AI review::Agent file tools not allowed (read-only sandbox): ${dropped}" >&2
  skipped="$(jq -r '[try .permissions.rules[] catch empty | select(.effect != "deny")] | length' "$overlay")"
  [[ "$skipped" == 0 ]] || echo "::warning title=AI review::Agent file permission rules ignored (only deny rules are added): ${skipped}" >&2
else
  overlay="$work/no-overlay.json"
  echo '{}' >"$overlay"
fi
agent="$work/home/agents/code-reviewer.json"
jq --slurpfile overlay "$overlay" --arg copy "$copy" '
  $overlay[0] as $o
  | def str_list: if type == "array" then map(select(type == "string")) else [] end;
    # Deny globs are matched against absolute paths: anchor relative ones
    # (".env", "**/secrets/**") at the workspace copy.
    def anchor: map(if startswith("/") then . else $copy + "/" + ltrimstr("./") end);
    def deny($cap; $match): {capability: $cap, match: ($match | anchor), effect: "deny"};
  # A project can only narrow the base tools, never add one.
  if $o | has("tools") then ($o.tools | str_list) as $keep | .tools |= map(select(. as $t | $keep | any(. == $t)))
  else . end
  | if ($o.prompt | type) == "string" and $o.prompt != "" then .prompt += "\n\n" + $o.prompt else . end
  | if ($o.description | type) == "string" then .description = $o.description else . end
  | if ($o.model | type) == "string" and $o.model != "" then .model = $o.model else . end
  # Reads are allowed inside the copy only. Deny rules win over allow rules,
  # and project deny rules are additive only.
  | .permissions.rules = [
      {capability: "fs_read", match: [$copy, $copy + "/**"], effect: "allow"},
      deny("fs_read"; [".env", ".env.*", "**/.env", "**/.env.*"])
    ] + [
      (try $o.permissions.rules[] catch empty)
      | select(type == "object" and .effect == "deny" and (.capability | type) == "string")
      | (.match | str_list) as $m | select($m != [])
      | deny(.capability; $m)
    ]
' "$here/code-reviewer.json" >"$agent" || { echo "::error title=AI review::Could not build the Kiro agent." >&2; exit 1; }
# 2. Copy the checkout's HEAD into the workspace. The prompt names the checkout
#    path, so point it at the copy.
git -C "$repo" archive --format=tar HEAD | tar -x -C "$copy" ||
  { echo "::error title=AI review::Could not copy the checkout for the review." >&2; exit 1; }
find "$copy" -type l -delete
find "$copy" -name .kiro -prune -exec rm -r {} +
prompt="$(cat "$AI_CODE_REVIEW_WORK_DIR/prompt.md")"
prompt="${prompt//"$AI_CODE_REVIEW_REPO_DIR"/$copy}"
prompt="${prompt//"$repo"/$copy}"
printf '%s\n' "$prompt" >"$work/prompt.md"
# 3. Install the pinned build.
arch="$(uname -m)"
curl -fsSL --retry 3 -o "$work/kiro.tar.gz" \
  "https://prod.download.cli.kiro.dev/stable/${kiro_version}/kirocli-${arch}-linux.tar.gz"
tar -xzf "$work/kiro.tar.gz" -C "$work" && rm "$work/kiro.tar.gz"
export PATH="$work/kirocli/bin:$PATH"
# 4. Isolate Kiro in a private KIRO_HOME holding only our agent. Custom agents
#    skip default resources (steering, skills, AGENTS.md at the root), and the
#    code intelligence and knowledge tools stay off.
export KIRO_HOME="$work/home"
for setting in "telemetry.enabled false" "app.disableAutoupdates true" \
  "chat.disableInheritingDefaultResources true" "chat.enableCodeIntelligence false" "chat.enableKnowledge false"; do
  # shellcheck disable=SC2086 # key and value are split on purpose
  kiro-cli settings $setting >/dev/null
done
# 5. Run headless, streaming JSON Lines events. No --trust-tools or
#    --trust-all-tools: those override the deny rules, and the allow rule
#    already covers every read the review needs.
args=(chat --no-interactive --agent-engine v3 --output-format stream-json --agent code-reviewer)
[[ -n "${AI_CODE_REVIEW_MODEL:-}" ]] && args+=(--model "$AI_CODE_REVIEW_MODEL")
echo "kiro-cli ${kiro_version} (V3 engine), model ${AI_CODE_REVIEW_MODEL:-default}" >&2
(cd "$copy" && KIRO_API_KEY="${AI_CODE_REVIEW_API_KEY:-}" kiro-cli "${args[@]}") \
  <"$work/prompt.md" >"$work/events.jsonl" 2>"$work/stderr.log" ||
  { tail -n 20 "$work/stderr.log" >&2; exit 1; }
# 6. Read the final response, falling back to ACP chunks. Extract from the
#    first opening tag to the last closing tag, preserving tags in findings.
events="$work/events.jsonl"
if jq -se 'any(.[]; .type == "runError")' "$events" >/dev/null; then
  jq -r 'select(.type == "runError") | .data.message' "$events" >&2
  exit 1
fi
jq -se 'any(.[]; .type == "runFinished")' "$events" >/dev/null ||
  echo "::warning title=Kiro output format changed::No runFinished event; used ACP message chunks. Check kiro-cli ${kiro_version}."
jq -rs '
  ((map(select(.type == "runFinished")) | last | .data.finalText)
   // (map(select(.data.update.sessionUpdate? == "agent_message_chunk") | .data.update.content.text) | join("")))
  # Capture text directly: index/rindex byte offsets cannot safely slice Unicode.
  | ([capture("<review>(?<review>[\\s\\S]*)</review>")] | first) as $match
  | if $match != null then
      $match.review | sub("^\\s*"; "") | sub("\\s*$"; "")
    else . end' \
  "$events" >"$AI_CODE_REVIEW_WORK_DIR/review.md"
grep -q '[^[:space:]]' "$AI_CODE_REVIEW_WORK_DIR/review.md" || { echo "Empty review" >&2; exit 1; }
# The session's running total is in its last session_usage update.
echo "credits=$(jq -rs '[.[] | .data.update._meta.kiro? | select(.kind? == "session_usage") | .credits]
  | last // [] | map(.usage) | add // empty | . * 100 | round / 100' "$events")"
