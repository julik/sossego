# frozen_string_literal: true

Sossego::Engine.routes.draw do
  get "streams/:stream_id", to: "signed_streams#show", as: :signed_stream, constraints: {stream_id: /[^\/]+/}
  get "js/:digest/*path", to: ->(env) { Sossego.javascript.call(env) }, as: :javascript_file, format: false
end
