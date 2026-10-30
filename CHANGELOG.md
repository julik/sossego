# Changelog

## 0.1.0

- First release. Sossego as extracted from Moneymaker and Cora: the events table, the streaming body, signed streams, the job helpers, and the JavaScript client with its Stimulus, React and highlight add-ons.
- The JavaScript ships inside the gem as five npm-shaped packages under `app/javascript/@julik/`, not on npm. importmap-rails gets pins for them, assiette gets them exposed as `@julik` (the engine does it from `ActiveSupport.on_load(:assiette)`), an app with a bundler or one that wants the files in its own tree copies them with `bin/rails sossego:js:vendor` (`DIR=`, `ONLY=client,stimulus`) and keeps the copy honest with `sossego:js:check`. Every package exports its module as `@julik/sossego-<part>` and as `@julik/sossego-<part>/index.js`; the add-ons import the client by file, which is what assiette rewrites.
