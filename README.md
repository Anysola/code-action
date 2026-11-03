# Anysola Code for GitHub Actions

Runs [Anysola Code](https://www.anysola.com/code) in a workflow:

- **Review**: on a pull request, a read-only agent reads the diff and the code around it and leaves one review comment, updated on every push.
- **Issue to pull request**: a `/anysola …` comment on an issue (or the `anysola` label) from someone with write access runs the agent with edits allowed. If it changes files, they go to a branch `anysola/issue-<n>` and a pull request that closes the issue; if not, its answer is the reply.

## Setup

1. In [account.anysola.com/apps](https://account.anysola.com/apps), under Code, choose **New CI token**. It needs a plan with Anysola Code and is shown once.
2. Store it as the repository secret `ANYSOLA_TOKEN`:

   ```sh
   gh secret set ANYSOLA_TOKEN
   ```

3. Add one or both workflows below.

## Review pull requests

`.github/workflows/anysola-review.yml`:

```yaml
name: Anysola Code review

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

permissions:
  contents: read
  pull-requests: write

# A new push replaces the review in progress instead of paying for both.
concurrency:
  group: anysola-review-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  review:
    # Pull requests from forks get no secrets.
    if: github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          persist-credentials: false
      - uses: Anysola/code-action@v1
        with:
          token: ${{ secrets.ANYSOLA_TOKEN }}
          budget: 100
```

Drafts are skipped until they are marked ready. Use `pull_request`, not `pull_request_target`: the second runs with secrets on code from forks.

## Issues to pull requests

`.github/workflows/anysola.yml`:

```yaml
name: Anysola Code

on:
  issue_comment:
    types: [created]
  issues:
    types: [labeled]

permissions:
  contents: write
  pull-requests: write
  issues: write

jobs:
  anysola:
    if: >-
      (github.event_name == 'issue_comment' && !github.event.issue.pull_request &&
       startsWith(github.event.comment.body, '/anysola') &&
       contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.comment.author_association)) ||
      (github.event_name == 'issues' && github.event.label.name == 'anysola')
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          persist-credentials: false
      - uses: Anysola/code-action@v1
        with:
          token: ${{ secrets.ANYSOLA_TOKEN }}
          budget: 300
```

Then comment on an issue:

```
/anysola add a --json flag to the export command, with a test
```

- The commenter (or whoever adds the label) must have write access; the action checks it with the repository's own record, the `if:` only saves a runner for everyone else.
- For `GITHUB_TOKEN` to open the pull request, turn on **Allow GitHub Actions to create and approve pull requests** (Settings > Actions > General > Workflow permissions).
- A pull request opened with `GITHUB_TOKEN` doesn't start other workflows, so its checks won't run. Pass a personal or GitHub App token as `github-token` if they should.
- The pull request goes into the branch the workflow checked out (the default branch for these events).

## Inputs

| Input            | Default               | What it does                                                                         |
| ---------------- | --------------------- | ------------------------------------------------------------------------------------ |
| `token`          | (required)            | The CI token, `secrets.ANYSOLA_TOKEN`.                                               |
| `mode`           | `auto`                | `review`, `issue`, or `auto` to pick from the event.                                 |
| `model`          | `claude-sonnet-5-5`   | `claude-haiku-5-5` is cheaper, `claude-opus-5-5` stronger; your plan decides which.  |
| `budget`         | `100`                 | Credits one run may spend before it is stopped (1 credit is $0.01).                  |
| `prompt`         |                       | Extra instructions for the agent, such as the repository's review priorities.        |
| `version`        | `latest`              | The Anysola Code version to install.                                                 |
| `trigger`        | `/anysola`            | The comment prefix for issue mode.                                                   |
| `label`          | `anysola`             | The label for issue mode; empty turns labels off.                                    |
| `max-diff-bytes` | `120000`              | How much of the diff goes into the review prompt; the agent reads files for the rest. |
| `github-token`   | `${{ github.token }}` | For comments, the push and the pull request.                                         |

## Outputs

| Output        | What it is                                       |
| ------------- | ------------------------------------------------ |
| `mode`        | `review`, `issue`, or `skip` when the event asked for nothing. |
| `comment-url` | The review comment, or the reply on the issue.   |
| `pr-url`      | The pull request issue mode opened.              |

## Cost

Every run spends credits from the Anysola account the token belongs to, at the same rates as `anysola` in a terminal. `budget` caps one run: Anysola Code stops once the session has spent that many credits and the step fails with "Stopped at the budget". An account out of credits fails the step with Anysola's message, and nothing is posted. For reviews, `concurrency` with `cancel-in-progress` (above) keeps a burst of pushes from paying for reviews nobody reads.

## What the agent can do

- **Review** runs a read-only agent: it can read, search and list files in the checkout, nothing else. No commands, no edits, no web; `.env` files are off limits. The repository's own Anysola Code config is ignored, so a pull request can't widen that.
- **Issue mode** runs the default agent with every permission prompt approved, so it can run commands on the runner. The issue's text comes from anyone who can open an issue; only someone with write access can start a run, but treat the run like handing the issue to a contributor with a shell.
- GitHub's tokens are kept out of the agent's environment, and `persist-credentials: false` keeps them out of the checkout's git config; the push happens after the agent is done. `ANYSOLA_TOKEN` is in it, since the agent needs it. CI tokens expire (30, 90 or 365 days) and can be revoked in Account at any time.

## Errors

The token is checked with Anysola before anything is installed, so most of these fail in a second and spend nothing.

| Message                     | What to do                                                                                   |
| --------------------------- | -------------------------------------------------------------------------------------------- |
| The token input is empty    | Add the `ANYSOLA_TOKEN` secret. Fork pull requests get no secrets.                            |
| ANYSOLA_TOKEN was refused   | The token expired or was revoked. Make a new one and update the secret.                      |
| isn't available to this account | The plan doesn't include that model; the message lists the ones it has.                  |
| Stopped at the budget       | Raise `budget`, or narrow the request.                                                       |
| Out of Anysola credits      | Credits renew with the plan's cycle; packs are in [Billing](https://account.anysola.com/billing). |

## Development

```sh
bash test/run.sh   # both modes, the skips and the failures, with test/bin's stand-ins for gh, git push and anysola
shellcheck -x -P scripts scripts/*.sh test/run.sh test/bin/*
```

`ANYSOLA_CODE_BIN=/path/to/anysola ANYSOLA_TOKEN=asc_… bash test/run.sh` runs one real review and one real issue run against a scratch repository instead (GitHub and the push still stubbed; it spends credits).

## License

MIT
