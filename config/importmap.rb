# frozen_string_literal: true

pin "@julik/sossego-client", to: "@julik/sossego-client/index.js"
pin "@julik/sossego-stimulus", to: "@julik/sossego-stimulus/index.js"
pin "@julik/sossego-highlight", to: "@julik/sossego-highlight/index.js"
# Needs "react" pinned by the host, so it is not preloaded: a preload would try
# to resolve "react" on every page.
pin "@julik/sossego-react", to: "@julik/sossego-react/index.js", preload: false
