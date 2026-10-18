# frozen_string_literal: true

module Sossego
  # For apps that write their own `<script type="importmap">` instead of using
  # importmap-rails. The engine serves the client itself, under the path it is
  # mounted at, so neither Propshaft nor Sprockets is needed.
  #
  # @example Merging into an importmap the app already renders
  #   map = {imports: {"@hotwired/stimulus" => "https://..."}, integrity: {...}}
  #   map.merge!(sossego_importmap) { |_key, ours, theirs| ours.merge(theirs) }
  #   tag.script(map.to_json.html_safe, type: "importmap")
  module ImportmapHelper
    DEFAULT_IMPORTMAP_SPECIFIERS = %w[sossego sossego/stimulus sossego/highlight].freeze

    # Digested path to one of the package's files, by bare specifier.
    #
    # @param specifier [String] "sossego", "sossego/stimulus", "sossego/highlight.css"...
    # @return [String] e.g. "/sossego/js/3f9a.../app/javascript/sossego/stimulus.js"
    def sossego_asset_path(specifier)
      relpath = Sossego.package.modules.fetch(specifier)
      sossego.package_file_path(digest: Sossego.package.digest(relpath), path: relpath)
    end

    # Importmap entries for the client's JS modules: `sossego`,
    # `sossego/stimulus` and `sossego/highlight`. `sossego/react` needs React
    # in the same importmap, so it is only added when asked for, and
    # `sossego/testing` is for test runners, never a page.
    #
    # @example With the React hook
    #   sossego_importmap(also: %w[sossego/react])
    #
    # @param also [Array<String>] more bare specifiers to map
    # @return [Hash{Symbol => Hash{String => String}}] `{imports: {...}, integrity: {...}}`
    def sossego_importmap(also: [])
      specifiers = DEFAULT_IMPORTMAP_SPECIFIERS + Array(also)
      paths = specifiers.to_h { |specifier| [specifier, sossego_asset_path(specifier)] }
      integrity = specifiers.to_h { |specifier| [paths.fetch(specifier), Sossego.package.integrity(Sossego.package.modules.fetch(specifier))] }
      {imports: paths, integrity: integrity}
    end
  end
end
