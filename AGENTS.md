# Lemans development guidelines

This file holds only lasting guidelines. Temporary or local instructions (work-in-progress notes, current refactoring state) go to `TODO.local.md` (gitignored, imported via CLAUDE.md); prune entries there as the work lands.

## Code style

- Ruby 3.4: use modern syntax — `it` block parameter, shorthand hash/kwarg notation (`config_path:`), endless methods for one-liners.
- No explanatory comments. A comment is only warranted for a non-obvious constraint the code cannot express. Never modify or delete comments written by a human.
- Adapter pattern: the abstract base class lives at the root as `Lemans::<Role>` (`store.rb`, `agent.rb`, `environment.rb`); implementations live in the plural directory and inherit the root class (`Stores::FS < Store`, `Agents::Miniswen < Agent`); name-to-class registries live on the plural module (`Agents.build`, `Environments.build`).
- Avoid the `#call` interface — use meaningful verb methods: `Agent#run`, `Setup#execute!`, `Verifier#verify!`.
- `#initialize` organization (see `Result`): required instance vars — blank line — containers (required initial empty values) — blank line — inferred state. Only attributes required at construction go into the signature; the rest is set through writers or lifecycle methods.
- A long-lived process reads better as one procedural method (`Trial#run`) than as extracted steps that make no sense on their own; peripheral extractions (`save_trajectory`, `check_cost_limit!`) are fine.
- Don't extract constants used once in a constructor — inline them as keyword defaults (`timeout: 300`), not `TIMEOUT`.
- Keep legacy files until the very end of a refactoring, even unused ones; don't touch functionality outside the current focus.
- Not defensive: assume user-provided values have sane types (strings where strings are expected). Validate semantics (unknown modes, relative vs absolute paths), never types.
- No single-purpose helper modules (a module wrapping one validation is an anti-pattern) — make such helpers private methods of the class that uses them. Same for shared conversion modules: only generic value parsing belongs in `Config::Conversion`; feature-specific validation (restore paths, setup files) lives on the section that owns the feature.
- Prefer mutable value containers: `Struct.new(..., keyword_init: true)` updated via writers, not `Data` with `#with`.
- No unit suffixes in names: `duration`, not `duration_sec` — the unit is implied by convention (seconds, megabytes).
- Persisted formats are wire contracts, not code. The schema may evolve deliberately — every result.json carries a `lemans_version` stamp — but readers (`Result.from_json`) must keep backward-compat hooks so new lemans always reads old runs (`duration_sec`, `bench:`, hash-shaped phases). Use `#as_json` for the JSON protocol, never `#to_h`.

## Tests

- Classic Minitest (`Minitest::Test`), `require "test_helper"` first.
- Files: `test/lemans/<path>/<unit>_test.rb`, mirroring `lib/`. Class names flatten the namespace: `Lemans::Config::Agent` → `ConfigAgentTest`.
- Concise test method names: `test_full_section`, `test_missing_model`. Behavior-oriented, a few words, not sentences.
- Few, dense tests: one method per behavior area with several assertions, not one assertion per method. For helper modules, one test method per helper covering valid and invalid inputs together.
- Unit-test at the contract level with plain Ruby data (`from_config` takes a hash) — no YAML files or fixtures unless the unit itself reads files.
- To test a helper module, `include` it into the test class and call the methods directly.
- Test adapters are named `Test*` (`TestStore`, `TestEnvironment` in `test/support/adapters.rb`); use `Scripted*` for fakes that replay prerecorded answers (shells, git). Support filenames must not match the `test_*.rb`/`*_test.rb` globs.
- Assertions: `assert_equal` on the exact error message when the message is the contract, `assert_includes` when only a fragment matters; `assert_in_delta` for floats; `assert_nil` for nils.
- Group each test as setup → act → blank line-separated asserts.
- Run: `bundle exec ruby -Ilib -Itest test/path/to/x_test.rb`; lint with `bundle exec rubocop` before finishing.
