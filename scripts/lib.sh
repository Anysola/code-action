# shellcheck shell=bash
# Helpers shared by the action's scripts. Sourced, never run.

# A failure the workflow shows as an error annotation, then the step fails.
fail() {
  printf '::error title=Anysola Code::%s\n' "$*"
  exit 1
}

notice() {
  printf '::notice title=Anysola Code::%s\n' "$*"
}

log() {
  printf '%s\n' "$*" >&2
}

# `name=value` for the step's outputs; values here never span lines.
set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
}

# One field of the triggering event, empty when absent or null.
event() {
  jq -r "$1 // empty" "$GITHUB_EVENT_PATH"
}

# The run's page, for comments that say where to look.
run_url() {
  printf '%s/%s/actions/runs/%s' "${GITHUB_SERVER_URL:-https://github.com}" "$GITHUB_REPOSITORY" "${GITHUB_RUN_ID:-0}"
}

# `anysola/<id>` for the CLI; a bare id gets the provider in front.
model_ref() {
  case "$1" in
    */*) printf '%s' "$1" ;;
    *) printf 'anysola/%s' "$1" ;;
  esac
}

# The line under every comment: the model and the run.
footer() {
  printf '\n\n<sub>Anysola Code · %s · [run](%s)</sub>\n' "${INPUT_MODEL#anysola/}" "$(run_url)"
}

# POSTs or PATCHes a comment from a body file and prints its URL.
#   comment_write POST repos/o/r/issues/1/comments body.md
#   comment_write PATCH repos/o/r/issues/comments/123 body.md
comment_write() {
  local method=$1 path=$2 file=$3
  jq -n --rawfile body "$file" '{body: $body}' |
    gh api -X "$method" "$path" --input - | jq -r '.html_url // empty'
}

# The repository's role for a user: admin, maintain, write, triage, read or none.
repo_permission() {
  gh api "repos/$GITHUB_REPOSITORY/collaborators/$1/permission" 2>/dev/null |
    jq -r '.role_name // .permission // empty'
}

# The review agent: reads, searches and globs the checkout, nothing else.
# Rules are matched last to first, so the denies for env files come after
# the read allow.
REVIEW_AGENT=anysola-review
REVIEW_CONFIG='{
  "agents": {
    "anysola-review": {
      "mode": "primary",
      "description": "Reviews a pull request without changing anything.",
      "permissions": [
        { "action": "*", "resource": "*", "effect": "deny" },
        { "action": "read", "resource": "*", "effect": "allow" },
        { "action": "grep", "resource": "*", "effect": "allow" },
        { "action": "glob", "resource": "*", "effect": "allow" },
        { "action": "read", "resource": "*.env", "effect": "deny" },
        { "action": "read", "resource": "*.env.*", "effect": "deny" },
        { "action": "read", "resource": "*.env.example", "effect": "allow" }
      ]
    }
  }
}'

# Runs the agent on a prompt file and leaves in $AGENT_DIR:
#   events.jsonl  the CLI's JSON events
#   stderr.log    its logs
#   answer.md     the text of its last message
#   error.txt     the last error it reported, if any
# `review` runs the read-only agent without the project's config (a pull
# request can't widen it); `edit` runs the default agent with every prompt
# approved. Returns the CLI's exit status. GitHub's tokens stay out of the
# agent's environment: only the Anysola token goes in.
run_agent() {
  local kind=$1 prompt=$2
  local args=(run --standalone --format json -m "$(model_ref "$INPUT_MODEL")" --budget "$INPUT_BUDGET")
  local extra=()
  if [ "$kind" = review ]; then
    args+=(--agent "$REVIEW_AGENT")
    extra+=(OPENCODE_CONFIG_CONTENT="$REVIEW_CONFIG" OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_DISABLE_CLAUDE_CODE=1)
  else
    args+=(--auto)
  fi
  mkdir -p "$AGENT_DIR"
  local status=0
  # No message argument: the prompt comes on stdin, which has no length limit.
  env -u GH_TOKEN -u GITHUB_TOKEN -u INPUT_TOKEN -u INPUT_GITHUB_TOKEN \
    -u ACTIONS_RUNTIME_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL \
    ANYSOLA_TOKEN="$ANYSOLA_SECRET" OPENCODE_DISABLE_AUTOUPDATE=1 "${extra[@]}" \
    "$ANYSOLA_BIN" "${args[@]}" <"$prompt" >"$AGENT_DIR/events.jsonl" 2>"$AGENT_DIR/stderr.log" || status=$?

  # Lines that aren't JSON (a stray log line) are skipped.
  jq -nrR '
    [inputs | fromjson? | select(type == "object" and .type == "text")
      | {m: .part.messageID, t: (.part.text // "")}] as $parts
    | if ($parts | length) == 0 then ""
      else ($parts[-1].m) as $last | [$parts[] | select(.m == $last) | .t] | join("\n\n")
      end' "$AGENT_DIR/events.jsonl" >"$AGENT_DIR/answer.md"
  jq -nrR '
    [inputs | fromjson? | select(type == "object" and .type == "error")
      | (.error.message // .error.data.message // (.error | tostring))] | last // ""' \
    "$AGENT_DIR/events.jsonl" >"$AGENT_DIR/error.txt"
  return "$status"
}

# Why a run failed, in words a workflow author can act on.
explain_failure() {
  local status=$1 message
  message=$(cat "$AGENT_DIR/error.txt" 2>/dev/null)
  [ -n "$message" ] || message=$(tail -n 5 "$AGENT_DIR/stderr.log" 2>/dev/null | tr '\n' ' ')
  case "$message" in
    *"Budget reached"*)
      printf 'Stopped at the budget of %s credits. Raise the budget input to let it finish.' "$INPUT_BUDGET" ;;
    *"used this cycle"*|*"Anysola credits"*|*"Daily free limit"*|*"may cost up to"*)
      printf 'Out of Anysola credits: %s' "$message" ;;
    *"expired or revoked"*|*"authentication_error"*)
      printf 'ANYSOLA_TOKEN was refused: it expired or was revoked. Make a new CI token in account.anysola.com/apps and update the secret.' ;;
    *"needs a Pro or Team"*|*"isn't open to this account"*|*"isn’t open to this account"*|*"is paused"*)
      printf 'Anysola Code refused the request: %s' "$message" ;;
    *)
      printf 'Anysola Code exited with status %s: %s' "$status" "${message:-no error message}" ;;
  esac
}
