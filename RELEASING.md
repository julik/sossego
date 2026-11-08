# Releasing

The gem carries the five JS packages (`@julik/sossego-client`, `-stimulus`, `-react`, `-highlight`, `-testing`) under `app/javascript/@julik`, all at the gem's version. Nothing goes to npm: a host app takes the packages from the gem (see [Getting the JavaScript into your app](MANUAL.md#getting-the-javascript-into-your-app)).

## A release

```sh
bundle exec rake version[0.2.0]   # sets version.rb and every package.json, dates the CHANGELOG's Unreleased section
# read CHANGELOG.md, then commit on main and push
bundle exec rake release
```

`rake release` is Bundler's: it builds the gem, checks that the tree is clean, tags `v0.2.0`, pushes the commit and the tag, and pushes the gem to RubyGems. Before the tag it also checks that every version agrees and the CHANGELOG has the version's section. Pushing the gem asks for your RubyGems OTP, since the gem requires MFA.

The tag starts [the release workflow](.github/workflows/release.yml), which checks the tag against the versions, runs CI on it, and creates the GitHub release with the CHANGELOG section as its notes.
