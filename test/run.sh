#!/usr/bin/env bash
# The action end to end with stand-ins for gh, git's network calls and
# anysola (test/bin): every mode, the skips and the failures. No network,
# no token, no credits.
#
#   bash test/run.sh
#
# ANYSOLA_CODE_BIN and ANYSOLA_TOKEN set to a real binary and token run the
# two live cases instead (one review, one issue to pull request), still with
# gh and git push stubbed.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/code-action-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fake_token=asc_$(printf 'a%.0s' $(seq 40))
passed=0
failed=0

# A fresh state directory and a workspace repository with one commit.
setup() {
  case_dir=$tmp/$1
  STUB_STATE=$case_dir/state
  WS=$case_dir/ws
  mkdir -p "$STUB_STATE" "$WS" "$case_dir/runner" "$case_dir/home"
  git -C "$WS" init -q -b main
  printf 'export const answer = 42\n' >"$WS/util.js"
  printf '{ "name": "widgets", "version": "1.0.0" }\n' >"$WS/package.json"
  git -C "$WS" add -A
  git -C "$WS" -c user.name=test -c user.email=test@example.com commit -qm init
  # shellcheck disable=SC2016 # the diff's own backticks
  printf 'diff --git a/util.js b/util.js\n--- a/util.js\n+++ b/util.js\n@@ -1 +1,2 @@\n export const answer = 42\n+export const greet = (name) => `Hello, ${name}!`\n' >"$case_dir/pr.diff"
}

# run_action <event name> <event file> [VAR=value...]: the action's main
# script as the runner calls it. Its status is in $status.
run_action() {
  local name=$1 file=$2
  shift 2
  status=0
  # A home of its own, as on a fresh runner: no stored sign-in, no config.
  env PATH="$root/test/bin:$PATH" STUB_STATE="$STUB_STATE" STUB_DIFF="$case_dir/pr.diff" \
    HOME="$case_dir/home" XDG_CONFIG_HOME="$case_dir/home/.config" XDG_DATA_HOME="$case_dir/home/.local/share" \
    XDG_CACHE_HOME="$case_dir/home/.cache" XDG_STATE_HOME="$case_dir/home/.local/state" \
    GITHUB_EVENT_NAME="$name" GITHUB_EVENT_PATH="$root/test/events/$file" \
    GITHUB_REPOSITORY=acme/widgets GITHUB_WORKSPACE="$WS" GITHUB_OUTPUT="$STUB_STATE/output" \
    GITHUB_RUN_ID=42 GITHUB_SERVER_URL=https://github.com RUNNER_TEMP="$case_dir/runner" \
    ANYSOLA_CODE_BIN="${LIVE_BIN:-$root/test/bin/anysola}" GH_TOKEN=ghs_test GITHUB_TOKEN=ghs_test \
    INPUT_TOKEN="${LIVE_TOKEN:-$fake_token}" INPUT_MODEL="${LIVE_MODEL:-claude-sonnet-5-5}" "$@" \
    bash "$root/scripts/main.sh" >"$STUB_STATE/stdout" 2>"$STUB_STATE/stderr" || status=$?
}

expect() {
  local what=$1
  shift
  if "$@"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL %s: %s\n' "$current" "$what"
    printf '  stdout: %s\n' "$(tr '\n' ' ' <"$STUB_STATE/stdout" | head -c 600)"
    printf '  stderr: %s\n' "$(tail -n 5 "$STUB_STATE/stderr" | tr '\n' ' ' | head -c 600)"
  fi
}
has() { grep -q -- "$2" "$1"; }
lacks() { ! grep -q -- "$2" "$1" 2>/dev/null; }
# The last value a step output was set to, as the runner keeps it.
output() { sed -n "s/^$1=//p" "$STUB_STATE/output" 2>/dev/null | tail -n 1; }
comment_body() { jq -r .body "$STUB_STATE/comment-$1.json"; }

if [ -n "${ANYSOLA_CODE_BIN:-}" ]; then
  : "${ANYSOLA_TOKEN:?the live cases need ANYSOLA_TOKEN}"
  LIVE_BIN=$ANYSOLA_CODE_BIN LIVE_TOKEN=$ANYSOLA_TOKEN LIVE_MODEL=${LIVE_MODEL:-claude-haiku-5-5}
  unset ANYSOLA_TOKEN
  export STUB_CURL=real

  current=live-review
  setup "$current"
  run_action pull_request pull_request.json INPUT_BUDGET=20
  expect "the review run succeeds" test "$status" -eq 0
  expect "a review comment is posted" test -s "$STUB_STATE/comment-1.json"
  [ -s "$STUB_STATE/comment-1.json" ] && printf '\n--- review comment ---\n%s\n' "$(comment_body 1)"
  expect "the checkout is untouched" test -z "$(git -C "$WS" status --porcelain)"

  current=live-issue
  setup "$current"
  run_action issue_comment issue_comment.json INPUT_BUDGET=40
  expect "the issue run succeeds" test "$status" -eq 0
  expect "a branch is pushed" has "$STUB_STATE/git.log" "HEAD:refs/heads/anysola/issue-7"
  expect "a pull request is opened" test "$(output pr-url)" = "https://github.com/acme/widgets/pull/99"
  git -C "$WS" log --stat -1 anysola/issue-7 2>/dev/null | sed 's/^/  /' || true
  [ -s "$STUB_STATE/pr-body.md" ] && printf '\n--- pull request body ---\n%s\n' "$(cat "$STUB_STATE/pr-body.md")"
  printf '\n%s passed, %s failed\n' "$passed" "$failed"
  [ "$failed" -eq 0 ]
  exit
fi

current=no-token
setup "$current"
run_action pull_request pull_request.json INPUT_TOKEN=
expect "fails" test "$status" -eq 1
expect "says how to get a token" has "$STUB_STATE/stdout" "::error title=Anysola Code::The token input is empty"
expect "never runs the agent" test ! -e "$STUB_STATE/anysola.args"

current=bad-token
setup "$current"
run_action pull_request pull_request.json INPUT_TOKEN=sk-ant-wrong
expect "fails on a token that isn't one" has "$STUB_STATE/stdout" "isn't an Anysola Code token"

current=bad-mode
setup "$current"
run_action pull_request pull_request.json INPUT_MODE=everything
expect "fails on an unknown mode" has "$STUB_STATE/stdout" "mode must be auto, review or issue"

current=bad-budget
setup "$current"
run_action pull_request pull_request.json INPUT_BUDGET=lots
expect "fails on a budget that isn't a number" has "$STUB_STATE/stdout" "budget must be a whole number"

current=token-refused
setup "$current"
run_action pull_request pull_request.json STUB_CONFIG=401
expect "fails" test "$status" -eq 1
expect "says the token was refused" has "$STUB_STATE/stdout" "ANYSOLA_TOKEN was refused: it expired or was revoked"
expect "never runs the agent" test ! -e "$STUB_STATE/anysola.args"
expect "sends the token on stdin, not in argv" test "$(cat "$STUB_STATE/curl.token")" = stdin

current=no-access
setup "$current"
run_action pull_request pull_request.json STUB_CONFIG=403
expect "passes Anysola's reason on" has "$STUB_STATE/stdout" "refused the token: Anysola Code needs a Pro or Team plan"

current=model-not-in-plan
setup "$current"
run_action pull_request pull_request.json INPUT_MODEL=claude-opus-5-5
expect "names the models the account has" has "$STUB_STATE/stdout" "claude-opus-5-5 isn't available to this account. Its models: claude-haiku-5-5, claude-sonnet-5-5."

current=gateway-down
setup "$current"
run_action pull_request pull_request.json STUB_CONFIG=down
expect "goes on when the check can't be made" test "$status" -eq 0
expect "says so in the log" has "$STUB_STATE/stderr" "Could not check the token with Anysola"

current=review-no-comment-permission
setup "$current"
run_action pull_request pull_request.json STUB_GH_DENY=1
expect "fails" test "$status" -eq 1
expect "names the permission" has "$STUB_STATE/stdout" "The job needs pull-requests: write."

current=review
setup "$current"
run_action pull_request pull_request.json INPUT_BUDGET=50 INPUT_PROMPT="Mind the error handling."
expect "succeeds" test "$status" -eq 0
expect "reports review mode" test "$(output mode)" = review
expect "runs the read-only agent without --auto" has "$STUB_STATE/anysola.args" "--agent anysola-review"
expect "no --auto in review" lacks "$STUB_STATE/anysola.args" "--auto"
expect "passes the budget and the model" has "$STUB_STATE/anysola.args" "--budget 50 .*"
expect "uses the anysola provider" has "$STUB_STATE/anysola.args" "-m anysola/claude-sonnet-5-5"
expect "runs standalone with JSON" has "$STUB_STATE/anysola.args" "run --standalone --format json"
expect "gives the agent the Anysola token" has "$STUB_STATE/anysola.env" "^ANYSOLA_TOKEN=set$"
expect "keeps GitHub's tokens from the agent" has "$STUB_STATE/anysola.env" "^GH_TOKEN=$"
expect "keeps GITHUB_TOKEN from the agent" has "$STUB_STATE/anysola.env" "^GITHUB_TOKEN=$"
expect "keeps the input token var from the agent" has "$STUB_STATE/anysola.env" "^INPUT_TOKEN=$"
expect "sets the review agent's config" has "$STUB_STATE/anysola.env" "^OPENCODE_CONFIG_CONTENT=set$"
expect "ignores the pull request's own config" has "$STUB_STATE/anysola.env" "^OPENCODE_DISABLE_PROJECT_CONFIG=1$"
expect "puts the diff in the prompt" has "$STUB_STATE/prompt.md" "+export const greet"
expect "puts the title in the prompt" has "$STUB_STATE/prompt.md" "Add a greet helper"
expect "puts the extra prompt in" has "$STUB_STATE/prompt.md" "Mind the error handling."
expect "posts a new comment" has "$STUB_STATE/comment-1.req" "POST repos/acme/widgets/issues/12/comments"
expect "the comment carries the marker" sh -c "jq -r .body '$STUB_STATE/comment-1.json' | grep -q '<!-- anysola-code-review -->'"
expect "the comment is the last message only" sh -c "jq -r .body '$STUB_STATE/comment-1.json' | grep -q 'ready to merge' && ! jq -r .body '$STUB_STATE/comment-1.json' | grep -q 'Let me read'"
expect "sets comment-url" test -n "$(output comment-url)"

current=review-update
setup "$current"
printf '[{"id": 321, "body": "<!-- anysola-code-review -->\\nold review"}, {"id": 5, "body": "unrelated"}]' >"$case_dir/comments.json"
run_action pull_request pull_request.json STUB_COMMENTS="$case_dir/comments.json"
expect "succeeds" test "$status" -eq 0
expect "updates the earlier comment in place" has "$STUB_STATE/comment-1.req" "PATCH repos/acme/widgets/issues/comments/321"

current=review-cut
setup "$current"
run_action pull_request pull_request.json INPUT_MAX_DIFF_BYTES=40
expect "cuts a long diff" has "$STUB_STATE/prompt.md" "It is cut at 40 of its"

current=review-draft
setup "$current"
run_action pull_request pull_request_draft.json
expect "skips a draft" test "$status" -eq 0 -a "$(output mode)" = skip
expect "skips without running" test ! -e "$STUB_STATE/anysola.args"

current=review-budget
setup "$current"
run_action pull_request pull_request.json STUB_AGENT=budget INPUT_BUDGET=100
expect "fails at the budget" test "$status" -eq 1
expect "says it hit the budget" has "$STUB_STATE/stdout" "Stopped at the budget of 100 credits"
expect "posts no review" test ! -e "$STUB_STATE/comment-1.json"

current=review-credits
setup "$current"
run_action pull_request pull_request.json STUB_AGENT=credits
expect "says the credits ran out" has "$STUB_STATE/stdout" "Out of Anysola credits: You've used this cycle"

current=review-revoked
setup "$current"
run_action pull_request pull_request.json STUB_AGENT=revoked
expect "says the token was refused" has "$STUB_STATE/stdout" "ANYSOLA_TOKEN was refused"

current=issue-edit
setup "$current"
run_action issue_comment issue_comment.json STUB_AGENT=edit INPUT_BUDGET=200
expect "succeeds" test "$status" -eq 0
expect "reports issue mode" test "$(output mode)" = issue
expect "runs with --auto" has "$STUB_STATE/anysola.args" "--auto"
expect "uses the default agent" lacks "$STUB_STATE/anysola.args" "--agent"
expect "keeps GitHub's tokens from the agent" has "$STUB_STATE/anysola.env" "^GH_TOKEN=$"
expect "reacts to the comment" has "$STUB_STATE/gh.log" "issues/comments/555/reactions"
expect "puts the issue and the request in the prompt" sh -c "grep -q 'util.js should export' '$STUB_STATE/prompt.md' && grep -q 'please add it, with a test' '$STUB_STATE/prompt.md'"
expect "drops the trigger from the request" lacks "$STUB_STATE/prompt.md" "/anysola please"
expect "commits to anysola/issue-7" test "$(git -C "$WS" rev-parse --abbrev-ref HEAD)" = anysola/issue-7
expect "the commit has the file" sh -c "git -C '$WS' show --stat HEAD | grep -q greet.js"
expect "the commit credits the requester" sh -c "git -C '$WS' log -1 --format=%B | grep -q 'Co-authored-by: mert <1001+mert@users.noreply.github.com>'"
expect "the commit is the bot's" test "$(git -C "$WS" log -1 --format=%an)" = "github-actions[bot]"
expect "pushes the branch with the token, not the checkout's header" has "$STUB_STATE/git.log" "http.https://github.com/.extraheader= push -q https://x-access-token:\*\*\*@github.com/acme/widgets.git HEAD:refs/heads/anysola/issue-7"
expect "opens the pull request against main" test "$(cat "$STUB_STATE/pr-base.txt")" = main
expect "the pull request closes the issue" has "$STUB_STATE/pr-body.md" "Closes #7. Requested by @mert."
expect "the pull request says what changed" has "$STUB_STATE/pr-body.md" "Added greet.js"
expect "sets pr-url" test "$(output pr-url)" = "https://github.com/acme/widgets/pull/99"
expect "links the pull request on the issue" sh -c "jq -r .body '$STUB_STATE/comment-1.json' | grep -q 'Opened https://github.com/acme/widgets/pull/99'"

current=issue-branch-taken
setup "$current"
run_action issue_comment issue_comment.json STUB_AGENT=edit STUB_BRANCH_EXISTS=1
expect "picks another branch when anysola/issue-7 exists" test "$(git -C "$WS" rev-parse --abbrev-ref HEAD)" = anysola/issue-7-42

current=issue-answer
setup "$current"
run_action issues issues_labeled.json STUB_AGENT=answer
expect "succeeds" test "$status" -eq 0
expect "starts from the label" test "$(output mode)" = issue
expect "answers on the issue" sh -c "jq -r .body '$STUB_STATE/comment-1.json' | grep -q 'runs tsc, then bundles'"
expect "pushes nothing" test ! -e "$STUB_STATE/git.log"
expect "opens no pull request" test ! -e "$STUB_STATE/pr-body.md"

current=issue-reader
setup "$current"
run_action issue_comment issue_comment_reader.json
expect "ignores someone who can't write" test "$status" -eq 0 -a "$(output mode)" = skip
expect "never runs the agent" test ! -e "$STUB_STATE/anysola.args"

current=issue-plain-comment
setup "$current"
run_action issue_comment issue_comment_plain.json
expect "skips a comment without the trigger" test "$(output mode)" = skip
expect "checks no permission" test ! -e "$STUB_STATE/gh.log"

current=issue-prefix
setup "$current"
run_action issue_comment issue_comment_prefix.json
expect "skips /anysolar" test "$(output mode)" = skip

current=issue-on-pr
setup "$current"
run_action issue_comment issue_comment_on_pr.json
expect "skips a comment on a pull request" test "$(output mode)" = skip

current=issue-other-label
setup "$current"
run_action issues issues_labeled.json INPUT_LABEL=bug
expect "skips another label" test "$(output mode)" = skip

current=issue-budget
setup "$current"
run_action issue_comment issue_comment.json STUB_AGENT=budget INPUT_BUDGET=100
expect "fails at the budget" test "$status" -eq 1
expect "says so on the issue" sh -c "jq -r .body '$STUB_STATE/comment-1.json' | grep -q 'Stopped at the budget of 100 credits'"
expect "links the run" sh -c "jq -r .body '$STUB_STATE/comment-1.json' | grep -q 'actions/runs/42'"

current=issue-dirty
setup "$current"
printf 'stray\n' >"$WS/stray.txt"
run_action issue_comment issue_comment.json
expect "refuses a dirty checkout" test "$status" -eq 1
expect "never runs the agent" test ! -e "$STUB_STATE/anysola.args"

current=unknown-event
setup "$current"
run_action push pull_request.json
expect "fails on an event it can't use" has "$STUB_STATE/stdout" "Can't tell what to do on a \"push\" event"

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
