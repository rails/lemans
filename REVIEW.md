# Lemans — a skeptical, DHH-flavored review

*2026-08-12 · reviewed at `767f947` (main, with uncommitted convention-over-configuration work) · all ~2,900 lines of `lib/` read*

**Verdict: this is a genuinely good gem with one bug-shaped hole (resume ignores its own digests), one god object (Miniswen), and a vocabulary problem it inherited from its own cleverness.**

## The Good

This is what a gem should feel like. 2,900 lines, no service-object soup, no dependency-injection framework, `Data.define` values frozen on construction, a Thor CLI that's genuinely thin. Somebody said no to a lot of things here.

**The error taxonomy is the domain model, and that's the best design decision in the codebase.** `ConfigError` aborts the wave, `InfrastructureError` becomes an invalid outcome, `VerifierError` is terminal because retrying verifies the same patch, `AccountingError` refuses to report unpriced spend as $0.00. "An infrastructure failure never scores" isn't a README slogan — it's `lib/lemans/trial.rb:59-70`, enforced by exception class. That's conviction expressed as code.

The verifier's paranoia is earned, not performative: seal the network, wipe the pre-written reward, upload tests fresh, NUL-delimited `find`, path-escape checks on downloaded evidence. Every line answers a specific attack, and the comment tells you which one.

Convention-over-configuration is real, not decorative: flat `solution.patch` tasks, frontmatter-as-config, `reward_path` derived so a reward can't outlive its logs, and — the boldest move — *refusing* per-task overrides with an error message that tells you where the knob belongs. Oracle and nop as corpus self-tests is the kind of idea that seems obvious only after someone does it.

## The Bad

### 1. `--resume` betrays the gem's own religion

Every result carries `profile_digest`, `task_digest`, and the corpus revision, because "nothing changed is not evidence." Then `Run#same_wave?` (`lib/lemans/run.rb:68`) counts any result with matching task/agent/model as a completed attempt — edit `bench.yml`, resume, and old-profile trials silently satisfy the new wave. The one place provenance would change behavior instead of decorating a JSON file, it isn't consulted. Compare `profile_digest` and `task_digest` in `same_wave?`. This is the finding to fix before shipping anything else.

### 2. There are two classes named Miniswen

`Lemans::Miniswen` and `Lemans::Agents::Miniswen`. You cannot talk about this code out loud. And the 545-line one is three objects wearing a trenchcoat: the agent loop, a ruby_llm client (resolve/complete/payload/price/registry-refresh/configure_from_env — ~200 lines), and trajectory bookkeeping. The file even has a section divider: *"-- The model side --"*. A section divider inside a class is the class telling you where to cut it. Extract `Miniswen::Model` (or `Lemans::ModelClient`), and the loop drops to ~300 honest lines.

### 3. Vocabulary drift

The module is `Corpus`, the class is `Bench`, the CLI variable is `corpus = Corpus::Bench.load`, the README says "a corpus has one bench.yml." Meanwhile every comment says "wave" but the class is `Run`. Call things what you call them when you speak: either `Corpus.load` returns a Corpus that `bench.yml` configures, or it's a Bench everywhere. And if the prose says wave, name the class `Wave`.

### 4. Speculative generality — delete it

- `Outcome#retryable?` / `RETRYABLE` — nothing in the codebase retries a trial.
- `Usage#+` — never summed anywhere; it even carries a two-line philosophical comment about the provenance of sums that never happen.
- `CostSource.agent` — used only by a test double.

Three features for a future that hasn't asked for them.

### 5. `Bench` has an altitude problem

Environment's fields get flattened onto Bench (`bench.workdir`, `bench.resources`, `bench.setup`) while agent and verifier stay nested (`bench.agent.timeout_sec`). Pick one altitude. And `Section#validate!` invoking every public method via reflection (`lib/lemans/corpus/bench.rb:67`) is clever-clever — an explicit list of readers is dumber and reads in one pass.

### 6. Global mutation, repeatedly

`RubyLLM.configure` runs at require, and `configure_from_env` rewrites the *global* RubyLLM config on every `Miniswen#initialize` — concurrent trials each re-mutating process-wide state for a process-wide effect that needs doing once. Benign today (same ENV), but it's per-instance work with global consequences. `SdkTweaks` monkey-patching is allowed — it's documented, quarantined, and carries its upstream ask.

## The Ugly (mostly charming)

- **gemspec residue:** homepage is `github.com/rails/lemans` (really?), the files glob includes `app/**/*` which doesn't exist — Rails-engine-template copy-pasta. The `rexml` and `csv` pins have no comment saying whose transitive breakage they're fixing.
- The macOS sed note: Daytona sandboxes are Linux; the Darwin branch is mini.yaml fidelity, i.e., dead in practice. Fine, but the comment should admit it.
- `finish_reason_from` reaches around ruby_llm into `response.raw.body`. Pragmatic, fragile, at least documented.
- `@config_error ||= e` written from multiple worker threads without a mutex (`lib/lemans/run.rb:89`) — benign race, but sloppy next to the care everywhere else.
- The literal `timeout_sec: 60` appears ~8 times across Verifier and Shell.
- `Run#summarize` duplicates `Report#summary` — two implementations of scored/invalid/solved. One should die.
- The house comment voice is mostly superb and occasionally a riddle — *"mini-swe-agent joins this list with the accounting layer"* needed decoding, and a comment that needs decoding is failing at its one job.

## If I could only make you do three things

1. Make `same_wave?` check `profile_digest` + `task_digest` — resume should honor the provenance the gem preaches.
2. Split `Lemans::Miniswen` at its own section divider and fix the double name.
3. Settle Corpus/Bench and Run/wave — one word per concept, everywhere.

Everything else is polish on a codebase that's already better than most gems ten times its size.
