# do-agent-issue-to-pr

Turn a GitHub issue into a pull request with an [OpenCode](https://opencode.ai) agent running on [DigitalOcean Managed Agents](https://docs.digitalocean.com/products/managed-agents/), using an open model (DeepSeek V4 Pro) on DigitalOcean serverless inference. The agent never holds a GitHub token.

```bash
scripts/issue-to-pr.sh 3
```

That one command creates a fresh microVM session, clones this repository into it, lets the agent fix issue #3, checks the result, opens a pull request, and removes the session.

## Requirements

- [doctl](https://docs.digitalocean.com/reference/doctl/) 1.175.0 or later, and the [GitHub CLI](https://cli.github.com/) logged in with a token that can push branches.
- `DIGITALOCEAN_ACCESS_TOKEN`: a DigitalOcean API token that can use Managed Agents.
- `DO_INFERENCE_KEY`: a DigitalOcean model access key for serverless inference.
- Python 3.12 only if you want to run the tests locally.

## How it works

1. **Create** a session from [`agent.yaml`](agent.yaml): the `opencode` adapter on a `mars-2vcpu-4gb` sandbox, with `deepseek-v4-pro` through `HARNESS_INFERENCE_MODEL`. The only secret in the sandbox is the model access key.
2. **Clone** the repository with `doctl harness-runtime exec`. It runs as root, so the script hands the checkout to the `agent` user.
3. **Count** the tests that run before the change.
4. **Prompt** the agent once, headless, with `--on-hitl reject`: anything the policy would ask a person about is refused.
5. **Check** the result from outside the agent: read the diff out of the sandbox, run the tests there again, and refuse the change if the agent touched `tests/` but no extra test runs.
6. **Open** the pull request with your own GitHub credentials, never the agent's, and comment on the issue.
7. **Remove** the session, after saving its event log under `runs/`.

A person reviews and merges. The script's checks only decide whether a pull request is opened at all.

## Recorded runs

Every run is in [`runs/`](runs/): the terminal output, the agent's answer with token counts, the diff, the test output and the session event log.

| Issue | Result | Input / output tokens | Model cost at list price |
|---|---|---|---|
| [#1](https://github.com/The-DevOps-Daily/do-agent-issue-to-pr/issues/1) combined durations lose all but the last part | [#4](https://github.com/The-DevOps-Daily/do-agent-issue-to-pr/pull/4), merged | 8,481 / 1,024 | $0.018 |
| [#2](https://github.com/The-DevOps-Daily/do-agent-issue-to-pr/issues/2) support days, first try | [#5](https://github.com/The-DevOps-Daily/do-agent-issue-to-pr/pull/5), closed in review: the new tests never ran | 14,372 / 1,848 | $0.031 |
| #2, second try | 4 new tests ran; the push failed because #5's branch still existed | 14,676 / 2,268 | $0.033 |
| #2, third try | [#6](https://github.com/The-DevOps-Daily/do-agent-issue-to-pr/pull/6), merged | 9,868 / 1,605 | $0.023 |
| [#3](https://github.com/The-DevOps-Daily/do-agent-issue-to-pr/issues/3) reject unknown units | [#7](https://github.com/The-DevOps-Daily/do-agent-issue-to-pr/pull/7), merged | 8,750 / 2,109 | $0.023 |

Model cost uses DigitalOcean's list price for DeepSeek V4 Pro: $1.74 per million input tokens and $3.48 per million output tokens. Each session also starts with a short readiness run (235 to 4,587 input tokens in these runs), and the sandbox is billed for the minutes it exists.

## Security notes

- **No GitHub credentials in the sandbox.** The agent cannot push, merge or open anything. Only the script, outside, can.
- **Egress is an allowlist.** Naming one host in `egress` makes everything else deny by default. Inside a session, `https://example.com` and `https://pypi.org` were both refused; GitHub and the model endpoint still worked.
- **Tool rules match literally.** With `default: deny`, OpenCode's own `edit` and `write` tools were refused in these runs, even with a `file.write` rule for `/workspace/**`. Because `bash` is allowed, the agent wrote the files with `cat >` instead. If you allow `bash`, assume the agent can do anything `bash` can inside the sandbox; the sandbox, the missing credentials and the egress allowlist are the real limits.

## Gotchas we hit

- `doctl harness-runtime create` for the `claude-code` adapter insists on a real Anthropic API key and checks it against Anthropic, even when the spec uses DigitalOcean inference (see `prepareClaudeCodeStart` in doctl's `commands/agents_run.go`). OpenCode has no such check.
- Our model access key could not use Anthropic or OpenAI models ("this model is not available for your subscription tier"). Open models such as DeepSeek V4 Pro worked.
- `--gh-repo` did not clone anything for us without a GitHub connection, so the script clones with `exec`.
- `exec` runs as root: `chown` the checkout for the agent, and read it with `git -c safe.directory=...`.
- A closed pull request leaves its branch behind, so each run pushes to its own branch.

## GitHub Actions

[`.github/workflows/issue-to-pr.yml`](.github/workflows/issue-to-pr.yml) runs the same script when an issue gets the `agent` label. It needs two repository secrets, `DIGITALOCEAN_ACCESS_TOKEN` and `DO_INFERENCE_KEY`. Use a token that can do as little as possible, ideally in a separate DigitalOcean team: a repository secret that can manage your whole cloud account is a large blast radius. Pull requests opened with the workflow's `GITHUB_TOKEN` do not trigger other workflows, so the tests workflow will not run on them by itself.

The recorded runs above were made with the script from a terminal, not through Actions.

## License

MIT
