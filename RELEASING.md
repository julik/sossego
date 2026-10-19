# Releasing

The gem and the five npm packages (`@julik/sossego-client`, `-stimulus`, `-react`, `-highlight`, `-testing`) are released together, at one version. The add-ons pin `@julik/sossego-client` to exactly that version.

## A release

```sh
bundle exec rake version[0.2.0]   # sets version.rb and every package.json, dates the CHANGELOG's Unreleased section
# read CHANGELOG.md, then commit on main and push
bundle exec rake release
```

`rake release` checks that the tree is clean, `main` matches `origin/main`, every version agrees and the CHANGELOG has the version's section. It runs the Ruby tests, standardrb, the JS tests and an npm dry run. Then it tags `v0.2.0` and pushes the tag.

The tag starts [the release workflow](.github/workflows/release.yml):

1. It checks that the tag matches the versions, and runs CI on the tag.
2. It pushes the gem to RubyGems and publishes the npm packages, the client first. Both use trusted publishing: GitHub's OIDC token instead of a stored API key. The npm packages get provenance.
3. It creates the GitHub release, with the CHANGELOG section as its notes.

A job that fails can be re-run. A version that is already on RubyGems or npm is skipped, not published again.

From a laptop, when CI can't: `rake release:gem` and `rake release:npm` (`DRY_RUN=1` to see what would go out). They skip what is up already too.

## One-time setup

**RubyGems.** On rubygems.org: your profile → Trusted publishers → Create a pending trusted publisher. Gem `sossego`, repository `julik/sossego`, workflow `release.yml`, environment `release`. A pending publisher works for a gem that has never been pushed.

**npm.** npm only lets you add a trusted publisher to a package that exists, so the first version goes out from a laptop:

```sh
npm login                              # as julik, who owns the @julik scope
bundle exec rake version[0.1.0]        # and commit
bundle exec rake release:npm
```

Then on npmjs.com, for each of the five packages: Settings → Trusted publishing → GitHub Actions. Repository `julik/sossego`, workflow `release.yml`, environment `release`. While there, set "Require two-factor authentication and disallow tokens". After that `rake release` finishes the first release: the workflow skips the npm packages that are up already and pushes the gem.

**GitHub.** The workflow's publishing jobs run in the `release` environment, which GitHub creates on first use. Add a required reviewer to it (Settings → Environments → release) if a pushed tag should wait for a click before publishing.
