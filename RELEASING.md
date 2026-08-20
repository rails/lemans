# How to release gems

This document describes a process of releasing new versions of the gems living in this repo: `lemans` and `miniswen`.

We're (kinda) using semantic versioning:

- Bugfixes should be released as fast as possible as patch versions.
- New features could be combined and released as minor or patch version upgrades (depending on the _size of the feature_—it's up to maintainers to decide).
- Breaking API changes should be avoided in minor and patch releases.
- Breaking dependencies changes (e.g., dropping older Ruby support) could be released in minor versions.

**Release order matters:** if the miniswen version has changed since its last release, release miniswen first. The `miniswen-installed` agent installs miniswen from RubyGems at the exact version packaged with lemans (`gem install miniswen -v <Miniswen::VERSION>`), so that version must be published before a lemans release ships it.

## Releasing lemans

1. Bump version.

- Change the version number in the `lib/lemans/version.rb` file.
- Update the changelog (add new heading with the version name and date).
- Update the installation documentation if necessary (e.g., during minor and major updates).

```sh
git commit -m "Bump 1.<x>.<y>"
```

2. Push code to GitHub and make sure CI passes.

```sh
git push
```

3. Tag the release and push the tag.

```sh
git tag v1.<x>.<y>
git push --tags
```

Pushing a `v*` tag triggers the [release workflow](.github/workflows/release.yml), which runs tests and publishes the gem to RubyGems via [trusted publishing](https://guides.rubygems.org/trusted-publishing/).

Don't forget to write release notes on GitHub (if necessary).

## Releasing miniswen

1. Bump the version in the `lib/miniswen/version.rb` file, commit, push, and make sure CI passes.

2. Run the [release-miniswen workflow](.github/workflows/release-miniswen.yml) manually (via the Actions tab or `gh workflow run release-miniswen.yml`).

The miniswen release is not tagged. Remember to release miniswen before lemans whenever its version has been bumped.
