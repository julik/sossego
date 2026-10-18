# frozen_string_literal: true

pin "@sossego/client", to: "@sossego/client/index.js"
pin "@sossego/stimulus", to: "@sossego/stimulus/index.js"
pin "@sossego/highlight", to: "@sossego/highlight/index.js"
# Needs "react" pinned by the host, so it is not preloaded: a preload would try
# to resolve "react" on every page.
pin "@sossego/react", to: "@sossego/react/index.js", preload: false
