#!/usr/bin/env bash
# Entry point: picks the mode from the event, checks the token, installs
# Anysola Code and hands over to review.sh or issue.sh.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$here/lib.sh"

: "${GITHUB_EVENT_PATH:?not running in GitHub Actions}"
: "${GITHUB_REPOSITORY:?not running in GitHub Actions}"
INPUT_MODE=${INPUT_MODE:-auto}
INPUT_MODEL=${INPUT_MODEL:-claude-sonnet-5-5}
INPUT_BUDGET=${INPUT_BUDGET:-100}
INPUT_TRIGGER=${INPUT_TRIGGER:-/anysola}
INPUT_LABEL=${INPUT_LABEL-anysola}
INPUT_VERSION=${INPUT_VERSION:-latest}
INPUT_MAX_DIFF_BYTES=${INPUT_MAX_DIFF_BYTES:-120000}
WORKSPACE=${GITHUB_WORKSPACE:-$PWD}
AGENT_DIR=${RUNNER_TEMP:-/tmp}/anysola-code-$$
export INPUT_MODEL INPUT_BUDGET AGENT_DIR

[[ $INPUT_BUDGET =~ ^[1-9][0-9]*$ ]] || fail "budget must be a whole number of credits, got \"$INPUT_BUDGET\"."
[[ $INPUT_MAX_DIFF_BYTES =~ ^[1-9][0-9]*$ ]] || fail "max-diff-bytes must be a whole number, got \"$INPUT_MAX_DIFF_BYTES\"."

# review or issue; skip or fail with the reason on the second line.
detect_mode() {
  case "$INPUT_MODE" in
    review | issue)
      printf '%s\n' "$INPUT_MODE"
      return
      ;;
    auto) ;;
    *)
      printf 'fail\nmode must be auto, review or issue, got "%s".\n' "$INPUT_MODE"
      return
      ;;
  esac
  local action
  action=$(event .action)
  case "${GITHUB_EVENT_NAME:-}" in
    pull_request | pull_request_target)
      case "$action" in
        opened | synchronize | reopened | ready_for_review) ;;
        *)
          printf 'skip\nNothing to review on a pull request "%s" event.\n' "$action"
          return
          ;;
      esac
      if [ "$(event .pull_request.draft)" = true ]; then
        printf 'skip\nDraft pull request: it is reviewed once marked ready.\n'
        return
      fi
      printf 'review\n'
      ;;
    issue_comment)
      local body
      body=$(event .comment.body)
      # Leading blanks are allowed; the trigger must be its own word.
      body=${body#"${body%%[![:space:]]*}"}
      if [ "$action" != created ] || [[ $body != "$INPUT_TRIGGER" && $body != "$INPUT_TRIGGER"[[:space:]]* ]]; then
        printf 'skip\nThe comment does not start with %s.\n' "$INPUT_TRIGGER"
      elif [ -n "$(event .issue.pull_request.url)" ]; then
        printf 'skip\n%s works on issues; on pull requests the review runs by itself.\n' "$INPUT_TRIGGER"
      else
        printf 'issue\n'
      fi
      ;;
    issues)
      if [ -n "$INPUT_LABEL" ] && [ "$action" = labeled ] && [ "$(event .label.name)" = "$INPUT_LABEL" ]; then
        printf 'issue\n'
      else
        printf 'skip\nNot the "%s" label being added.\n' "$INPUT_LABEL"
      fi
      ;;
    *)
      printf 'fail\n%s\n' "Can't tell what to do on a \"${GITHUB_EVENT_NAME:-unknown}\" event. Run it on pull_request, issue_comment or issues, or set mode."
      ;;
  esac
}

detected=$(detect_mode)
mode=$(head -n 1 <<<"$detected")
reason=$(sed -n 2p <<<"$detected")
[ "$mode" != fail ] || fail "$reason"
set_output mode "$mode"
if [ "$mode" = skip ]; then
  notice "$reason"
  exit 0
fi

# The token: present, and shaped like one, before anything is installed.
ANYSOLA_SECRET=${INPUT_TOKEN:-}
if [ -z "$ANYSOLA_SECRET" ]; then
  fail "The token input is empty. Make a CI token in account.anysola.com/apps (Code > New CI token) and store it as the repository secret ANYSOLA_TOKEN. Pull requests from forks get no secrets."
fi
if ! [[ $ANYSOLA_SECRET =~ ^asc_[0-9A-Za-z]{40}$ ]]; then
  fail "The token input isn't an Anysola Code token (asc_ and 40 letters and digits). Check the ANYSOLA_TOKEN secret."
fi
export ANYSOLA_SECRET
check_access

# shellcheck source=scripts/install.sh
. "$here/install.sh"
export ANYSOLA_BIN

cd "$WORKSPACE"
case "$mode" in
  review)
    # shellcheck source=scripts/review.sh
    . "$here/review.sh"
    ;;
  issue)
    # shellcheck source=scripts/issue.sh
    . "$here/issue.sh"
    ;;
esac
