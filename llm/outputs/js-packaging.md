# Shipping sossego's JavaScript to host apps

## The problem

The gem carries a small JS client: plain ES modules with hand-written `.d.ts`, no build step, and no runtime npm dependencies (only optional peers: `@hotwired/stimulus`, `react`). Three kinds of host need it:

1. **importmap-rails + Propshaft** (the dummy app). Works today: the engine adds `app/javascript` to the asset paths and registers `config/importmap.rb`.
2. **Plain importmap, no importmap-rails** (Moneymaker: assiette serves the app's files, `ExternalAssetsHelper#external_importmap_tag` writes the map by hand). The engine's pins don't apply. The plan in `moneymaker/llm/todos/sossego-migration.md` §6 adds two assiette directory mappings into the gem's install path and hand-written pins.
3. **A bundler with node_modules** (Cora: esbuild via jsbundling-rails, yarn 1.22, vitest, `tsc --noEmit`). Needs `import ... from "sossego"` to resolve in esbuild, vitest and tsc. The plan in Cora's `docs/plans/2026-10-18-chore-sossego-gem-migration-plan.md` §5 says `"sossego": "github:julik/sossego"` or a `file:` path.

What makes 3 awkward: the gem's files live wherever Bundler put them, and that path is versioned (`.../gems/sossego-0.1.0`, or `.../bundler/gems/sossego-<sha>` for a Git source), differs between a laptop, CI and the Docker image, and changes on every `bundle update`. Anything that writes that path into a committed file (package.json, yarn.lock, tsconfig) breaks on the next machine or the next upgrade. And whatever route the JS takes, the npm side and the gem side are two pins of the same code that can drift apart.

## Findings

### Proscenium

Source: [docs/guides/rubygem_npm_dependencies.md](https://github.com/joelmoss/proscenium/blob/main/docs/guides/rubygem_npm_dependencies.md) and [docs/guides/gem_author.md](https://github.com/joelmoss/proscenium/blob/main/docs/guides/gem_author.md).

- A gem opts in with `spec.metadata['proscenium.dependencies'] = 'true'` and a package.json at its root (or `proscenium.frontend_root`).
- `bundle exec proscenium install` writes one small package.json per gem under `.proscenium/packages/<gem>/`, holding only that gem's `dependencies`/`peerDependencies` (no paths, no version). It registers `.proscenium/packages/*` as a pnpm/Bun workspace, edits `.gitignore`, and runs `pnpm install`/`bun install`. You commit the contexts and the lockfile.
- **The gem's own JS is not installed into node_modules at all.** Proscenium's own bundler (esbuild in Go, inside the gem) resolves a gem's files from where Bundler put them, under the `@rubygems/<gem>` name. Only the gem's third-party npm deps go through the package manager. That is how it sidesteps the "gem path in package.json" problem: the path never leaves Ruby.
- It refuses yarn and npm, refuses `file:`/`link:`/`workspace:` specs inside gems, has `install --frozen` for CI, a `doctor`, and refuses to build when a context is stale.
- Its guide names the drift problem directly: depending on a gem as an npm package "pins the gem twice, once in Gemfile.lock and once in your lockfile, and the two drift".

For sossego this mechanism mostly doesn't apply. Sossego has no npm dependencies to install, and the part Proscenium solves with its own resolver (finding the gem's files) is exactly what esbuild/vitest/tsc in Cora can't do without help. Cora uses yarn 1, which Proscenium doesn't support.

### How other gems do it

- **turbo-rails, stimulus-rails** ([turbo-rails](https://github.com/hotwired/turbo-rails), [stimulus-rails](https://github.com/hotwired/stimulus-rails)): the gem ships a built `turbo.min.js` / `stimulus.min.js` under `app/assets/javascripts` for importmap/Propshaft, and the same code is published to npm separately (`@hotwired/turbo-rails`, `@hotwired/stimulus`). Gem and npm versions are not even numbered alike (turbo-rails gem 2.0.x carries npm `@hotwired/turbo` 8.0.x). Bundler users simply `yarn add` the npm package.
- **Rails' own JS** (`@rails/actioncable`, `@rails/activestorage`, `@rails/actiontext`): the gem ships the compiled ESM file for importmap, and the release script publishes an npm package with the same version as the gem. No runtime check that they match.
- **importmap-rails** ([README](https://github.com/rails/importmap-rails)): `bin/importmap pin x` downloads the file into `vendor/javascript/` and you commit it. `bin/importmap outdated`/`update` handles upgrades. Vendoring is the default since 2.0.
- **jsbundling-rails**: only runs `yarn build`; a gem that wants to reach bundler apps publishes to npm.
- **Shakapacker** ([README](https://github.com/shakacode/shakapacker)): gem `shakapacker` and npm `shakapacker` must have the same version. The gem checks the installed npm package's version at boot (`ensure_consistent_versioning`) and raises if they differ or the package.json spec isn't exact. The closest prior art for "a check that warns when gem and npm versions differ".

### Package managers and local directories

Verified here with yarn 1.22.22 and npm 11.4.2 (scratch projects, fake versioned gem dirs, a symlink re-pointed to simulate `bundle update`):

| | `file:<dir>` | `link:<dir>` |
|---|---|---|
| yarn 1 | **copies** the whole directory (ignores `files`, takes nested `node_modules` and tests). yarn.lock records the version. A plain `yarn install` does **not** refresh the copy when the source changes, even when the version changes; `--frozen-lockfile` still passes and yarn.lock keeps the old version. Needs `--check-files`/`--force`. `file:` to a path that is itself a symlink fails outright (ENOENT making a relative symlink). | symlink. yarn.lock records only the path and `version "0.0.0"`, so it is identical on every machine and across upgrades. Frozen install passes when the target changes or doesn't exist yet. Pointed at a gem dir, yarn wrote `.yarn-metadata.json` into it once. Dependencies of the linked package are not installed (sossego has none). |
| npm | symlink (npm ≥ 5). package-lock records the target's version, `npm ci` doesn't recheck it. | not supported |
| pnpm | per [its docs](https://pnpm.io/package-sources) a local directory becomes a symlink, like `pnpm link`; `file:` with `dependenciesMeta.injected` hard-links a copy. Not tested here. | symlink |
| yarn berry | `file:` copies (content hash in the lockfile), `link:` symlinks without resolving its deps, `portal:` symlinks and resolves deps ([protocols](https://yarnpkg.com/protocols)). Not tested here. | |
| Bun | `link:` symlinks (`bun link --save`); I couldn't confirm what `file:` does for a directory. | |

A symlink into the gem's install directory has one more problem, verified with esbuild: Node-style resolvers follow the symlink to its real path and look for peers (`react`, `@hotwired/stimulus`) in `node_modules` folders above *that* path, i.e. inside the Ruby gems dir, where there are none. esbuild fails with "Could not resolve react" unless `nodePaths` (Cora happens to set it) or `--preserve-symlinks`; vitest/Vite needs `resolve.preserveSymlinks` or `dedupe`; tsc needs `preserveSymlinks`. For a path gem under development the opposite happens: the gem's own dev `node_modules/react` is found, and the page gets two Reacts.

A symlink to a directory **inside the host app** has neither problem: its real path is under the app root, so peers resolve from the app's `node_modules`. Verified with esbuild, Node, vitest and tsc (types from the `.d.ts` resolve, `moduleResolution: Bundler`).

## Options

### (a) Publish to npm, version-locked to the gem

Release both from one tag: `gem push` and `npm publish` (or a `github:julik/sossego#v0.1.0` tag instead of the registry while the repo is private). package.json's version already equals `Sossego::VERSION`; the prototype adds a test that keeps it so.

- Upgrades: two steps, `bundle update sossego` and `yarn upgrade sossego@<same>`. Forgetting the second is the drift case. Needs a check (below).
- `bundle update`: nothing breaks, nothing follows either.
- CI/Docker: standard. With `github:` on a private repo, `yarn install` in Docker needs Git credentials (Cora's Dockerfile currently has none for yarn).
- Types, vitest: work out of the box, it's a normal package.
- Host effort: one line in package.json.
- Cost: a release step per version, and the decision to put the code on npm while the repo is private. The name is free.

### (b) Gem-side installer, Proscenium-style

A task that resolves `Sossego.package.root` (= `Gem.loaded_specs["sossego"].full_gem_path`) and wires it in.

- **Writing that path into package.json** (`file:` or `link:` to the gem dir): machine-specific and version-specific, so the committed package.json and yarn.lock are wrong on the next machine and after `bundle update`; with yarn 1 `file:` it can't even go through a stable symlink. Peers don't resolve through a symlink into the gem dir (above). Rejected.
- **A stable symlink in the app** (`vendor/gems/sossego -> <gem path>`, gitignored, recreated by a task after every `bundle install` on every machine and in Docker), plus `link:./vendor/gems/sossego`. Keeps the lockfile stable, but every build environment must run Ruby before the JS install, and peers still resolve from the gem dir. Too many moving parts.
- **Vendoring a copy** (`bin/rails sossego:js:vendor` copies the package into `vendor/javascript/sossego`, committed; package.json has `"sossego": "link:./vendor/javascript/sossego"`). This is importmap-rails' `vendor/javascript` idea applied to node_modules. The path in package.json is relative and stable; CI and Docker need no Ruby for the JS install; peers, types and vitest work because the real path is inside the app; the copy is reviewable in diffs. Drift between the copy and the gem is caught by `bin/rails sossego:js:check`. **Prototyped.**
  - Upgrades: `bundle update sossego && bin/rails sossego:js:vendor`, commit. yarn.lock doesn't change.
  - `bundle update` alone: the app keeps running the old JS until `vendor` runs; `check` (in CI) fails until it does.
  - Types: the `.d.ts` files come along. vitest: works.

### (c) A generic "any gem with a package.json" mechanism

The same as (b)'s vendoring, but scanning `Bundler.load.specs` for gems that opt in (a gemspec metadata key, like Proscenium's) and vendoring each into `vendor/javascript/<name>`, adding `link:` entries, plus a `check` across all of them. `Sossego::Package` is already written against "a directory with a package.json" (it takes any root) and would move into such a gem almost unchanged; the gem-specific part is only the list of gems. Worth extracting once a second gem of yours needs it, not before. Proscenium is the full version of this idea for pnpm/Bun apps that let it own the bundling.

### (d) Engine-served files plus an importmap fragment

The engine serves its own package files at `/<mount>/js/<content digest>/<path>`, `Cache-Control: immutable`, 404 for any other digest or any file not in package.json's `exports`. Two view helpers:

- `sossego_importmap` → `{imports: {"sossego" => "/sossego/js/…/app/javascript/sossego.js", "sossego/stimulus" => …}, integrity: {url => "sha384-…"}}`, to merge into an importmap the app already renders;
- `sossego_asset_path("sossego/highlight.css")` → the digested path of any exported file.

- Upgrades: nothing to do; URLs change with content.
- `bundle update`: nothing breaks; the gem path is read at runtime on the machine that serves.
- CI/Docker: nothing; no precompile involved (the files aren't in `public/assets`).
- Types/vitest: not applicable; this is for apps without a JS toolchain.
- Host effort: merge one hash into the importmap, one `<link>` for the CSS.
- Limits: paths, not URLs, so `config.asset_host`/a CDN isn't used. During a rolling deploy an old page asking for an old digest gets a 404 (Propshaft behaves the same). Not useful to bundler apps.
- **Prototyped.**

### Version/drift check

`bin/rails sossego:js:check` compares the vendored copy and `node_modules/sossego` (if present) file by file against the installed gem and exits non-zero naming the stale files. Because it compares content, not version numbers, it also works for an install from npm or GitHub under (a), and catches a path gem edited without a version bump. Extra files in the installed package are ignored. A Shakapacker-style boot-time warning in development would be a few more lines; not done.

## Recommendation

One mechanism per host style, all reading the same package.json:

| Host | Use | Host does |
|---|---|---|
| importmap-rails + Propshaft/Sprockets | what exists: asset path + `config/importmap.rb` | nothing |
| plain importmap / assiette (Moneymaker) | (d) engine-served files + `sossego_importmap` | merge one hash; one `<link>` for the CSS |
| bundler + node_modules (Cora) | (b) vendored copy + `link:`, checked in CI | `sossego:js:vendor` once per upgrade; add `sossego:js:check` to CI |

Reasons:

- For Moneymaker, (d) replaces two assiette mappings into the gem's install path plus hand-kept pins with a hash merge, and gets SRI for free. It doesn't depend on assiette, Propshaft or importmap-rails, so it works for any app that writes its own map.
- For Cora, the vendored copy is the only option that needs neither a release pipeline nor Ruby in the JS install step, and keeps every committed path relative. It also keeps the gem the single source of truth: the copy is derived from the installed gem, and the check says when it isn't. `link:` rather than `file:`, because yarn 1 silently keeps an old `file:` copy (and Cora's CI caches `node_modules` keyed on yarn.lock alone, which a `file:` change doesn't touch).
- When the repo goes public, (a) becomes the better choice for bundler apps: `"sossego": "0.2.0"` in package.json, drop the vendored copy, keep `sossego:js:check` in CI to catch a forgotten `yarn upgrade`. Nothing in the gem has to change for that switch.
- (c) is (b) generalised; wait for a second gem.

## What was prototyped

Changed in the gem (not committed):

- `lib/sossego/package.rb` (new): `Sossego::Package`, reading the root package.json. `#modules` (exports → `{"sossego/stimulus" => "app/javascript/sossego/stimulus.js", …}`), `#files`, `#digest`/`#integrity` (cached per mtime, so a path gem being edited gets new URLs without a restart), `#call` (the Rack endpoint), `#copy_to(dir)`, `#stale_files(dir)`. `Sossego.package` is the gem's instance.
- `lib/sossego.rb`: requires it.
- `config/routes.rb`: `get "js/:digest/*path"` → `Sossego.package`, named `package_file`.
- `app/helpers/sossego/importmap_helper.rb` (new): `sossego_asset_path`, `sossego_importmap`.
- `lib/sossego/engine.rb`: registers `Sossego::ImportmapHelper` next to `StreamsHelper`.
- `lib/tasks/sossego.rake` (new): `sossego:js:vendor` (`DIR=` to change the destination, prints the package.json line to add: `link:` or, when there's a package-lock.json, `file:`), `sossego:js:check`.
- `test/sossego/package_test.rb`, `test/controllers/package_files_test.rb` (new): exports mapping, package.json version = `Sossego::VERSION`, every exported file is in `files` and in the gemspec, digests, copy/stale detection, serving (content type, immutable caching), 404 for a wrong digest, a `.d.ts`, a Ruby file and `../`, and that every importmap integrity matches the bytes served.

`bundle exec rake`: 205 runs, 0 failures, 3 skips (the existing database-specific ones), standardrb clean. `npx vitest run`: 89 passed.

### Trying it in Moneymaker (not done; Moneymaker untouched)

```ruby
# app/helpers/external_assets_helper.rb
def external_importmap_tag
  sossego = sossego_importmap
  map = {
    imports: EXTERNAL_JS_PINS.transform_values { |pin| pin[:url] }.merge(sossego[:imports]),
    integrity: EXTERNAL_JS_PINS.values.to_h { |pin| [pin[:url], pin[:integrity]] }.merge(sossego[:integrity])
  }
  tag.script(JSON.pretty_generate(map).html_safe, type: "importmap")
end
```

```erb
<link rel="stylesheet" href="<%= sossego_asset_path("sossego/highlight.css") %>">
```

That replaces the two `additional_directory_mappings` and the manual pins in §6 of the migration plan. The engine must be mounted (the installer mounts it at `/sossego`). `assiette_modulepreload_tags` won't list these modules; a `sossego_modulepreload_tags` would be a few lines if wanted.

### Trying it in Cora (not done; Cora untouched)

```sh
bin/rails sossego:js:vendor          # writes vendor/javascript/sossego
```

```json
"sossego": "link:./vendor/javascript/sossego"
```

Then `yarn install`, commit `vendor/javascript/sossego`, package.json and yarn.lock (the yarn.lock entry is `version "0.0.0"`, path only, and won't change on upgrades). Add `bin/rails sossego:js:check` to CI. The Dockerfile needs nothing: yarn creates the symlink before `COPY . .` brings the target in (verified: a dangling `link:` target passes `--frozen-lockfile`). esbuild, vitest and `tsc` resolve the package and its peers from the app's `node_modules`; verified with copies of the real files in a scratch app.

To see it locally without Cora: in `test/dummy`, `DIR=/some/tmp/app/vendor/javascript/sossego bin/rails sossego:js:vendor`, then in that app add the `link:` line and `yarn install`.

## Changed after review (18 Oct 2026)

- `sossego_importmap` maps only `sossego`, `sossego/stimulus` and `sossego/highlight`. `sossego/react` is opt-in (`sossego_importmap(also: %w[sossego/react])`), and `sossego/testing` is never mapped by default. An unknown specifier raises `KeyError`.
- The engine's importmap-rails pin for `sossego/react` is `preload: false`, so pages that don't pin React don't try to preload it.
- `sossego/stimulus` and `sossego/highlight` now have `.d.ts` files, listed in `exports` and `files`. A strict `tsc` consumer of all five entry points type-checks.
- The README has a "Getting the JS into your app" section with the three host styles.

## Open questions

- Engine-served URLs are paths, not `asset_host` URLs. If Moneymaker puts a CDN in front of assets later, the helper would need `sossego.package_file_url` with a host.
- Should a stale vendored copy also warn at boot in development (Shakapacker-style), or is the CI check enough?
- Cora runs `knip`; whether it flags `vendor/javascript/sossego` or the `link:` dependency is unknown.
- pnpm, yarn berry and Bun behaviour is from their docs, not tested here. Vendoring inside the app should make the copy-vs-symlink difference irrelevant for all of them.
- For (a): whether to publish to npm while the GitHub repo is private, and whether a `github:` tag is acceptable for Cora's Docker build (it would need Git credentials for yarn).
