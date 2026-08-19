# Lemans development guidelines

This file holds only lasting guidelines. Temporary or local instructions (work-in-progress notes, current refactoring state) go to `TODO.local.md` (gitignored, imported via CLAUDE.md); prune entries there as the work lands.

## Code style

- Ruby 3.4: use modern syntax — `it` block parameter, shorthand hash/kwarg notation (`config_path:`), endless methods for one-liners.
- No explanatory comments. A comment is only warranted for a non-obvious constraint the code cannot express.
- Not defensive: assume user-provided values have sane types (strings where strings are expected). Validate semantics (unknown modes, relative vs absolute paths), never types.
- No single-purpose helper modules (a module wrapping one validation is an anti-pattern) — make such helpers private methods of the class that uses them.
- Prefer mutable value containers: `Struct.new(..., keyword_init: true)` updated via writers, not `Data` with `#with`.

## Tests

- Classic Minitest (`Minitest::Test`), `require "test_helper"` first.
- Files: `test/lemans/<path>/<unit>_test.rb`, mirroring `lib/`. Class names flatten the namespace: `Lemans::Config::Agent` → `ConfigAgentTest`.
- Concise test method names: `test_full_section`, `test_missing_model`. Behavior-oriented, a few words, not sentences.
- Few, dense tests: one method per behavior area with several assertions, not one assertion per method. For helper modules, one test method per helper covering valid and invalid inputs together.
- Unit-test at the contract level with plain Ruby data (`from_config` takes a hash) — no YAML files or fixtures unless the unit itself reads files.
- To test a helper module, `include` it into the test class and call the methods directly.
- Assertions: `assert_equal` on the exact error message when the message is the contract, `assert_includes` when only a fragment matters; `assert_in_delta` for floats; `assert_nil` for nils.
- Group each test as setup → act → blank line-separated asserts.
- Run: `bundle exec ruby -Ilib -Itest test/path/to/x_test.rb`; lint with `bundle exec rubocop` before finishing.
