# Changelog

## Unreleased

- A payload format is registered with `Sossego.register_fmt(fmt, encoder:, decoder:)`, both halves at once, and removed with `unregister_fmt`. `Sossego.encoders` and `Sossego.decoders` are frozen now. They are built when the gem loads and made shareable, so the wire layer - `envelope`, `format_event_frame`, `decode_frame`, the registries - runs in any Ractor; a format whose lambdas have an unshareable self (one written at the top level of an initializer) keeps the registries on the main Ractor. The streaming body stays there regardless: it reads through Active Record.
- The manual says how to serve streams from Falcon (fiber isolation, no reloading) and what one process can hold, measured: 1,000 streams at two thirds of a core, saturation around 3,500 on the default poll interval.
- `require "sossego"` works outside a Rails application: the engine, which needs Action Dispatch, loads only when Rails is there. What loads without it is the wire layer, the streaming body and its source.

## 0.1.0

- First release. Sossego as extracted from Moneymaker and Cora: the events table, the streaming body, signed streams, the job helpers, and the JavaScript client with its Stimulus, React and highlight add-ons.
- The JavaScript ships inside the gem as five npm-shaped packages under `app/javascript/@julik/`, not on npm. importmap-rails gets pins for them, assiette gets them exposed as `@julik` (the engine does it from `ActiveSupport.on_load(:assiette)`), an app with a bundler or one that wants the files in its own tree copies them with `bin/rails sossego:js:vendor` (`DIR=`, `ONLY=client,stimulus`) and keeps the copy honest with `sossego:js:check`. Every package exports its module as `@julik/sossego-<part>` and as `@julik/sossego-<part>/index.js`; the add-ons import the client by file, which is what assiette rewrites.
- Payloads can be encrypted at rest: `Sossego::Event.encrypts :payload, support_unencrypted_data: true` in a `to_prepare` block, which the generated initializer and the manual show. Every row is written and read through the model, so the wire is unaffected. The dummy app does it, so the suite runs on encrypted rows.
