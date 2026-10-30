# frozen_string_literal: true

# One pin per export of every page package, so both `@julik/sossego-stimulus`
# and `@julik/sossego-stimulus/index.js` resolve: the add-ons import the client
# by file (see Sossego::JavaScript), and a page may too. `@julik/sossego-testing`
# is for test runners, never a page.
Sossego.javascript.modules.each do |specifier, file|
  next unless file.end_with?(".js")
  next if specifier.start_with?("@julik/sossego-testing")
  # @julik/sossego-react needs "react" pinned by the host, so it is not
  # preloaded: a preload would try to resolve "react" on every page.
  pin specifier, to: file, preload: !specifier.start_with?("@julik/sossego-react")
end
