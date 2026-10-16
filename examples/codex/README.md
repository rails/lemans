# Codex agent

A Lemans extension that runs the Codex CLI using your ChatGPT subscription. It saves an ATIF trajectory for lemans-viewer and a native session checkpoint for recovery.

## Run

Use the installed `lemans` command, start Docker Desktop, and authenticate as described below. From your benchmark project's root, create `benches/codex/bench.yml` to reuse your root `bench.yml` and existing tasks:

```yaml
inherit_from: ../../bench.yml
tasks: ../../tasks

environment:
  backend: docker

agent:
  name: codex
  model: gpt-6.1-sol#medium
  timeout: 90m
  cost_limit: null
  environment:
    network:
      mode: allowlist
      hosts: [chatgpt.com, auth.openai.com]
```

The inherited config supplies the Docker image, setup, and verifier. Preinstalling a pinned Codex CLI version in that image is recommended for faster setup and reliable recovery. If `codex` is absent, the adapter installs it automatically using the Codex installer; setup needs network access to download it.

Run from the same project root, assuming the Lemans checkout is at `tmp/lemans` (adjust `CODEX_AGENT` otherwise):

```sh
export CODEX_AGENT="$PWD/tmp/lemans/examples/codex/agent.rb"

lemans -r "$CODEX_AGENT" run \
  --bench benches/codex \
  --task TASK_NAME \
  -c 1 \
  --runs-dir tmp/codex-runs
```

Replace `TASK_NAME` with a task from your benchmark. The extension files must be available locally; they are not bundled with the gem.

## Recover

```sh
lemans -r "$CODEX_AGENT" restart TASK_NAME__TRIAL_ID \
  --bench benches/codex \
  --recover --allow-scored \
  -c 1 \
  --runs-dir tmp/codex-runs
```

Use the original trial ID. Recovery creates a new container, restores `agent.patch` and the native Codex session saved in `agent.result.json`, and continues the task. `--allow-scored` permits recovery of a timed-out run that Lemans already graded. Time, token usage, and estimated cost carry forward; increase `agent.timeout` before recovering if the original run exhausted it.

## Authentication

Log in on the host with file-backed credentials:

```sh
codex -c 'cli_auth_credentials_store="file"' login
```

The adapter reads `$CODEX_HOME/auth.json`, defaulting to `~/.codex/auth.json`. To use a separate copy, set:

```sh
export LEMANS_CODEX_AUTH_FILE="$PWD/.codex/auth.json"
```

Each trial receives an access-token snapshot in an isolated Codex home. The refresh token is removed from the snapshot; containers never refresh credentials or write them back to the host. The access token must have at least **10 hours** remaining when the adapter starts. Otherwise, refresh the host login and update any separate copy. Authentication is supplied again on recovery and is excluded from the saved session archive. API-key authentication is unsupported.

## Estimated price

`cost_usd` estimates the equivalent standard API token cost using the OpenAI model's prices in RubyLLM's model registry. Uncached input, cache reads/writes, and output are priced separately; cache rates fall back to the regular input rate when absent. Reasoning tokens are already included in output. This is a comparison metric, not your subscription charge. If the model's prices are unknown, cost is omitted.

## Known limitations

- Dollar budgets cannot be enforced: cost is calculated after Codex exits. Set `agent.cost_limit: null` and use `agent.timeout`. Lemans's `step_limit`, `exec_timeout`, and `max_output_tokens` are not forwarded to Codex.
- Subscription usage limits and access-token expiry still apply; long runs cannot refresh their credentials.
- Recovery needs a saved native checkpoint and the same model and Codex CLI version. Workspace files are restored through Git patches; ignored files and files outside the worktree are not recovered.
- The ATIF conversion uses the CLI event stream. System prompts, timestamps, and per-call usage are absent; `total_steps` counts completed shell commands rather than model calls.
