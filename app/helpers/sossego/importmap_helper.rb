# frozen_string_literal: true

module Sossego
  # For apps that write their own `<script type="importmap">` instead of using
  # importmap-rails. The engine serves the client itself, under the path it is
  # mounted at, at digested URLs that can be cached forever, so neither
  # Propshaft nor Sprockets is needed.
  #
  # An app that serves its assets with assiette does not need this: the engine
  # exposes the packages to it, see {Sossego::JavaScript}.
  #
  # @example Merging into an importmap the app already renders
  #   map = {imports: {"@hotwired/stimulus" => "https://..."}, integrity: {...}}
  #   map.merge!(sossego_importmap) { |_key, yours, ours| yours.merge(ours) }
  #   tag.script(map.to_json.html_safe, type: "importmap")
  module ImportmapHelper
    DEFAULT_IMPORTMAP_PACKAGES = %w[@julik/sossego-client @julik/sossego-stimulus @julik/sossego-highlight].freeze

    # Digested path to one of the client's files, by bare specifier.
    #
    # @param specifier [String] "@julik/sossego-client", "@julik/sossego-highlight/highlight.css"...
    # @return [String] e.g. "/sossego/js/3f9a.../@julik/sossego-stimulus/index.js"
    def sossego_asset_path(specifier)
      relpath = Sossego.javascript.modules.fetch(specifier)
      sossego.javascript_file_path(digest: Sossego.javascript.digest(relpath), path: relpath)
    end

    # Importmap entries for the modules of `@julik/sossego-client`,
    # `@julik/sossego-stimulus` and `@julik/sossego-highlight`, under both
    # names each has: `@julik/sossego-stimulus` and `@julik/sossego-stimulus/index.js`.
    # `@julik/sossego-react` needs React in the same importmap, so it is only
    # added when asked for, and `@julik/sossego-testing` is for test runners,
    # never a page.
    #
    # @example With the React hook
    #   sossego_importmap(also: %w[@julik/sossego-react])
    #
    # @param also [Array<String>] more packages to map
    # @return [Hash{Symbol => Hash{String => String}}] `{imports: {...}, integrity: {...}}`
    def sossego_importmap(also: [])
      js = Sossego.javascript
      packages = DEFAULT_IMPORTMAP_PACKAGES + Array(also)
      packages.each { |name| js.manifests.fetch(name) }
      specifiers = js.modules.select { |specifier, file| file.end_with?(".js") && packages.any? { |name| specifier == name || specifier.start_with?("#{name}/") } }.keys
      paths = specifiers.to_h { |specifier| [specifier, sossego_asset_path(specifier)] }
      integrity = specifiers.to_h { |specifier| [paths.fetch(specifier), js.integrity(js.modules.fetch(specifier))] }
      {imports: paths, integrity: integrity}
    end
  end
end
