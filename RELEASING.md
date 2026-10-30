# Releasing

The gem carries the five JS packages (`@julik/sossego-client`, `-stimulus`, `-react`, `-highlight`, `-testing`) under `app/javascript/@julik`, all at the gem's version. Nothing goes to npm: a host app takes the packages from the gem (see [Getting the JavaScript into your app](MANUAL.md#getting-the-javascript-into-your-app)).

## A release

```sh
bundle exec rake version[0.2.0]   # sets version.rb and every package.json, dates the CHANGELOG's Unreleased section
# read CHANGELOG.md, then commit on main and push
bundle exec rake release
```

`rake release` checks that the tree is clean, `main` matches `origin/main`, every version agrees and the CHANGELOG has the version's section. It runs the Ruby tests, standardrb and the JS tests. Then it tags `v0.2.0` and pushes the tag.

The tag starts [the release workflow](.github/workflows/release.yml):

1. It checks that the tag matches the versions, and runs CI on the tag.
2. It pushes the gem to RubyGems with trusted publishing: GitHub's OIDC token instead of a stored API key.
3. It creates the GitHub release, with the CHANGELOG section as its notes.

A job that fails can be re-run. A version that is already on RubyGems is skipped, not pushed again.

From a laptop, when CI can't: `rake release:gem`. It skips a version that is up already too.

## One-time setup

**RubyGems.** On rubygems.org: your profile → Trusted publishers → Create a pending trusted publisher. Gem `sossego`, repository `julik/sossego`, workflow `release.yml`, environment `release`. A pending publisher works for a gem that has never been pushed.

**GitHub.** The workflow's publishing job runs in the `release` environment, which GitHub creates on first use. Add a required reviewer to it (Settings → Environments → release) if a pushed tag should wait for a click before publishing.
