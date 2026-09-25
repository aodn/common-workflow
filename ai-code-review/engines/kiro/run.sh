#!/usr/bin/env bash
#
# engines/kiro/run.sh — run the review with the Kiro headless CLI.
#
#   In:   AI_CODE_REVIEW_REPO_DIR       PR checkout the agent may read
#         AI_CODE_REVIEW_WORK_DIR       holds prompt.md; receives review.md and logs
#         AI_CODE_REVIEW_API_KEY        Kiro API key (passed to kiro-cli as KIRO_API_KEY)
#         AI_CODE_REVIEW_MODEL          optional model id
#         AI_CODE_REVIEW_AGENT_OVERLAY  optional project overlay on code-reviewer.json
#   Out:  $AI_CODE_REVIEW_WORK_DIR/review.md, and "credits=<n>" on stdout
#   Exit: 0 on success
#
set -euo pipefail

: "${AI_CODE_REVIEW_REPO_DIR:?}" "${AI_CODE_REVIEW_WORK_DIR:?}"

# Pinned release: the review depends on its CLI flags and event format, so
# upgrades are deliberate. See "Upgrading kiro-cli" in README.md.
kiro_version="2.23.1"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Real paths, so the deniedPaths globs below match what Kiro checks.
AI_CODE_REVIEW_WORK_DIR="$(realpath "$AI_CODE_REVIEW_WORK_DIR")"
repo="$(realpath "$AI_CODE_REVIEW_REPO_DIR")"
work="$AI_CODE_REVIEW_WORK_DIR/kiro"
mkdir -p "$work/cwd"

# 1. Build the agent first, so a bad overlay fails before the download.
#    The base code-reviewer.json holds the sandbox. A project overlay may add to the
#    prompt, set description and model, narrow the tools and add denied paths;
#    everything else (name, hooks, MCP servers, resources, ...) stays the base.
#    Kiro's allowedPaths does not restrict absolute paths, so everything
#    sensitive is denied explicitly: /proc (holds the API key), system config,
#    home dotfiles, runner internals, this work dir and .git.
denied=(
  "/proc/**" "/sys/**" "/dev/**" "/etc/**" "/root/**" "/run/**" "/var/**" "/tmp/**" "/mnt/**" "/opt/**"
  "$HOME/.*" "$HOME/.*/**" "$HOME/actions-runner/**" "$HOME/runners/**"
  "$AI_CODE_REVIEW_WORK_DIR/**" "$repo/.git" "$repo/.git/**"
  # Local .env files can hold real secrets on a workstation; list the repo
  # root explicitly as well, whether or not "**/" also matches it.
  "$repo/.env" "$repo/.env.*" "$repo/**/.env" "$repo/**/.env.*"
)
[[ -n "${RUNNER_TEMP:-}" ]] && denied+=("$RUNNER_TEMP/**")
[[ -n "${RUNNER_WORKSPACE:-}" ]] && denied+=("$(dirname "$RUNNER_WORKSPACE")/_*/**")

overlay="${AI_CODE_REVIEW_AGENT_OVERLAY:-}"
if [[ -n "$overlay" ]]; then
  jq -e 'type == "object"' "$overlay" >/dev/null 2>&1 ||
    { echo "::error title=AI review::The agent file is not a JSON object." >&2; exit 1; }
  ignored="$(jq -r '[keys[] | select(IN("prompt", "description", "model", "tools", "allowedTools", "toolsSettings") | not)] | join(", ")' "$overlay")"
  [[ -z "$ignored" ]] || echo "::warning title=AI review::Agent file keys ignored (fixed by the shared agent): ${ignored}" >&2
  dropped="$(jq -r --slurpfile base "$here/code-reviewer.json" \
    '[(.tools, .allowedTools) | arrays | .[]] - $base[0].tools | unique | map(tostring) | join(", ")' "$overlay")"
  [[ -z "$dropped" ]] || echo "::warning title=AI review::Agent file tools not allowed (read-only sandbox): ${dropped}" >&2
else
  overlay="$work/no-overlay.json"
  echo '{}' >"$overlay"
fi

agent="$work/code-reviewer.json"
printf '%s\n' "${denied[@]}" | jq -R . | jq -s \
  --slurpfile base "$here/code-reviewer.json" --slurpfile overlay "$overlay" '
  . as $denied | $overlay[0] as $o
  | def str_list: if type == "array" then map(select(type == "string")) else [] end;
    # A project can only narrow the base tools, never add one.
    def narrow($key):
      if $o | has($key) then ($o[$key] | str_list) as $keep | .[$key] |= map(select(. as $t | $keep | any(. == $t)))
      else . end;
  $base[0]
  | if ($o.prompt | type) == "string" and $o.prompt != "" then .prompt += "\n\n" + $o.prompt else . end
  | if ($o.description | type) == "string" then .description = $o.description else . end
  | if ($o.model | type) == "string" and $o.model != "" then .model = $o.model else . end
  | narrow("tools") | narrow("allowedTools")
  # Denied paths are additive only.
  | reduce ("read", "glob", "grep") as $t (.;
      .toolsSettings[$t].deniedPaths += ((try $o.toolsSettings[$t].deniedPaths catch null) | str_list) + $denied)
' >"$agent" || { echo "::error title=AI review::Could not build the Kiro agent." >&2; exit 1; }

# 2. Install the pinned build.
arch="$(uname -m)"
curl -fsSL --retry 3 -o "$work/kiro.tar.gz" \
  "https://prod.download.cli.kiro.dev/stable/${kiro_version}/kirocli-${arch}-linux.tar.gz"
tar -xzf "$work/kiro.tar.gz" -C "$work" && rm "$work/kiro.tar.gz"
export PATH="$work/kirocli/bin:$PATH"

# 3. Isolate Kiro: a private KIRO_HOME holding only our agent, run from an empty
#    directory so the PR's own .kiro/ (agents, hooks, MCP servers) never loads.
export KIRO_HOME="$work/home"
kiro-cli settings telemetry.enabled false >/dev/null
kiro-cli settings app.disableAutoupdates true >/dev/null
mkdir -p "$KIRO_HOME/agents"
cp "$agent" "$KIRO_HOME/agents/code-reviewer.json"

# 4. Run headless, streaming JSON Lines events.
args=(chat --no-interactive --agent-engine v2 --output-format stream-json --agent code-reviewer)
[[ -n "${AI_CODE_REVIEW_MODEL:-}" ]] && args+=(--model "$AI_CODE_REVIEW_MODEL")
echo "kiro-cli ${kiro_version}, model ${AI_CODE_REVIEW_MODEL:-default}" >&2
(cd "$work/cwd" && KIRO_API_KEY="${AI_CODE_REVIEW_API_KEY:-}" kiro-cli "${args[@]}") \
  <"$AI_CODE_REVIEW_WORK_DIR/prompt.md" >"$work/events.jsonl" 2>"$work/stderr.log" ||
  { tail -n 20 "$work/stderr.log" >&2; exit 1; }

# 5. Read the final response, falling back to ACP chunks. Extract from the
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

echo "credits=$(jq -rs '[.[] | .data.meteringUsage? // empty] | last // [] | map(.value) | add // empty | . * 100 | round / 100' "$events")"
