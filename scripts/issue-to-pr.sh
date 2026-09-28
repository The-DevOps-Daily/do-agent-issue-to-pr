#!/usr/bin/env bash
# Turn one GitHub issue into a pull request with an OpenCode session on
# DigitalOcean Managed Agents.
#
#   scripts/issue-to-pr.sh <issue-number>
#
# Needs doctl and gh on PATH, DIGITALOCEAN_ACCESS_TOKEN, DO_INFERENCE_KEY
# (a DigitalOcean model access key), and a gh login or GH_TOKEN that can push
# branches and open pull requests. The sandbox never sees the GitHub token.
set -euo pipefail

issue="${1:?usage: $0 <issue-number>}"
repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
session="issue-${issue}-$(date +%s)"
workdir=/workspace/repo
branch="agent/${session}"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/runs/issue-${issue}"
mkdir -p "$out"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$out/timeline.log" >&2; }

cleanup() {
  doctl harness-runtime logs "$session" >"$out/session.log" 2>&1 || true
  log "removing session $session"
  echo y | doctl harness-runtime remove "$session" >/dev/null 2>&1 || true
}
trap cleanup EXIT

title=$(gh issue view "$issue" -R "$repo" --json title -q .title)
body=$(gh issue view "$issue" -R "$repo" --json body -q .body)
log "issue #$issue: $title"

# 1. A fresh microVM for this issue. The only secret inside is the model key.
log "creating session $session"
doctl harness-runtime create --spec "$root/agent.yaml" --name "$session" \
  --wait-timeout 300 >/dev/null

# 2. Clone the repo from outside the agent loop: it is public, and the
#    sandbox has no GitHub credentials to clone a private one anyway.
#    exec runs as root, so hand the checkout to the agent's own user.
doctl harness-runtime exec "$session" -- sh -c \
  "git clone -q https://github.com/$repo $workdir && chown -R agent:agent $workdir"

# unittest prints "Ran N tests"; count before and after so a test the
# agent wrote but that never runs cannot pass unnoticed.
count_tests() {
  doctl harness-runtime exec "$session" -- sh -c \
    "cd $workdir && python3 -m unittest -q 2>&1" | sed -n 's/^Ran \([0-9]*\) tests\{0,1\}.*/\1/p'
}
before=$(count_tests)
log "tests before: $before"

# 3. One headless run. Any action the policy would ask about is rejected,
#    because nobody is there to approve it.
prompt=$(cat <<EOF
The repository is cloned at $workdir. Fix GitHub issue #$issue.

Title: $title

$body

Rules:
- Change only what the issue needs, and add or update tests in tests/.
- Run "cd $workdir && python3 -m unittest -q" and make sure it passes.
- Do not commit, push or open a pull request. That happens outside the sandbox.
- Finish with a summary of the change in two or three sentences.
EOF
)
log "running the agent"
if ! doctl harness-runtime prompt "$session" --on-hitl reject --timeout 1200 \
  -o json - <<<"$prompt" >"$out/answer.json" 2>"$out/progress.log"; then
  log "agent run did not complete; see $out/progress.log"
  exit 1
fi

# 4. Check the result ourselves instead of trusting the summary: read the
#    diff out of the sandbox and run the tests there again.
doctl harness-runtime exec "$session" -- sh -c \
  "git -c safe.directory=$workdir -C $workdir add -A && git -c safe.directory=$workdir -C $workdir diff --cached" \
  >"$out/change.patch"
if [ ! -s "$out/change.patch" ]; then
  log "agent made no change"
  gh issue comment "$issue" -R "$repo" --body "The agent finished without changing any file."
  exit 1
fi
if ! doctl harness-runtime exec "$session" -- \
  sh -c "cd $workdir && python3 -m unittest -q" >"$out/tests.log" 2>&1; then
  log "tests fail in the sandbox; not opening a pull request"
  gh issue comment "$issue" -R "$repo" --body "The agent's change fails the test suite, so no pull request was opened."
  exit 1
fi
after=$(count_tests)
log "tests pass in the sandbox: $before before, $after after"
if grep -q '^+++ b/tests/' "$out/change.patch" && [ "$after" -le "$before" ]; then
  log "the agent changed tests/ but no new test ran; not opening a pull request"
  gh issue comment "$issue" -R "$repo" --body "The agent changed tests/, but the number of tests that run did not go up ($before before, $after after), so no pull request was opened."
  exit 1
fi

# 5. Open the pull request from outside the sandbox, with our own credentials.
# The answer narrates the whole run; keep the closing summary for the PR body.
summary=$(python3 - "$out/answer.json" <<'PY'
import json, re, sys
text = json.load(open(sys.argv[1])).get("text", "")
text = re.sub(r"\n{3,}", "\n\n", text).strip()
parts = re.split(r"\*\*Summary:?\*\*:?", text)
print(parts[-1].strip() if len(parts) > 1 else text.split("\n\n")[-1].strip())
PY
)
tmp=$(mktemp -d)
git clone -q "https://github.com/$repo" "$tmp/repo"
git -C "$tmp/repo" checkout -q -b "$branch"
git -C "$tmp/repo" apply --index "$out/change.patch"
git -C "$tmp/repo" commit -q -m "Fix #$issue: $title"
git -C "$tmp/repo" push -q -u origin "$branch"
pr=$(gh pr create -R "$repo" --head "$branch" --title "Fix #$issue: $title" \
  --body "$summary

Closes #$issue. Written by an OpenCode agent in DigitalOcean Managed Agents session \`$session\`; the tests passed in the sandbox ($before before, $after after). Review before merging.")
rm -rf "$tmp"
log "opened $pr"
gh issue comment "$issue" -R "$repo" --body "Opened $pr for review."
