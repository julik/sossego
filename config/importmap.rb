# frozen_string_literal: true

pin "sossego", to: "sossego.js"
pin "sossego/stimulus", to: "sossego/stimulus.js"
pin "sossego/highlight", to: "sossego/highlight.js"
# Needs "react" pinned by the host, so it is not preloaded: a preload would try
# to resolve "react" on every page.
pin "sossego/react", to: "sossego/react.js", preload: false
