# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The engine hands the packages to assiette as "@julik", and assiette serves
# them from the gem with the imports between them fingerprinted. The same
# holds for a copy under the app's own root, which assiette prefers.
class Sossego::AssietteTest < ActiveSupport::TestCase
  setup do
    @dir = Pathname(Dir.mktmpdir)
    @dir.join("js").mkpath
    @dir.join("js/application.js").write(%(import SossegoController from "@julik/sossego-stimulus/index.js"\n))
  end

  teardown { FileUtils.rm_rf(@dir) }

  def served(handler, url_path) = handler.dependency_graph.rewrite_content(url_path, File.read(handler.resolve_file(url_path)))

  # What the host's initializer does: build a handler and hand it to a Server,
  # which runs the :assiette load hooks on it
  def handler_with_exposures(handler)
    Assiette::Server.new(->(_env) { [404, {}, []] }, handler)
    handler
  end

  test "the engine exposes the gem's @julik directory on every handler a Server is built with, next to another gem's" do
    handler = handler_with_exposures(Assiette::AssetHandler.new(root: @dir).expose("@julik", @dir.join("js")))
    assert_equal [@dir.join("js"), Sossego.javascript.root.join("@julik")], handler.exposed.fetch("@julik")
  end

  test "an app module imports a package by file, and the package imports the client by file, both fingerprinted" do
    handler = handler_with_exposures(Assiette::AssetHandler.new(root: @dir))

    assert_equal Sossego.javascript.root.join("@julik/sossego-stimulus/index.js"), handler.resolve_file("/@julik/sossego-stimulus/index.js")
    assert_match %r{from "\.\./@julik/sossego-stimulus/index\.js\?s=\h{8}"}, served(handler, "js/application.js")
    assert_match %r{from "\.\./sossego-client/index\.js\?s=\h{8}"}, served(handler, "@julik/sossego-stimulus/index.js")
    assert_match %r{from "\.\./sossego-client/index\.js\?s=\h{8}"}, served(handler, "@julik/sossego-react/index.js")
    # Third-party peers stay bare, for the page's import map
    assert_includes served(handler, "@julik/sossego-stimulus/index.js"), %(from "@hotwired/stimulus")
    assert_includes served(handler, "@julik/sossego-react/index.js"), %(from "react")
  end

  test "a vendored copy under the app's root is served the same way, with nothing exposed" do
    Sossego.javascript.copy_to(@dir, %w[@julik/sossego-client @julik/sossego-stimulus])
    handler = Assiette::AssetHandler.new(root: @dir)

    assert_equal @dir.join("@julik/sossego-stimulus/index.js"), handler.resolve_file("/@julik/sossego-stimulus/index.js")
    assert_match %r{from "\.\./@julik/sossego-stimulus/index\.js\?s=\h{8}"}, served(handler, "js/application.js")
    assert_match %r{from "\.\./sossego-client/index\.js\?s=\h{8}"}, served(handler, "@julik/sossego-stimulus/index.js")
    assert_equal %w[/@julik/sossego-client/index.js /@julik/sossego-stimulus/index.js /js/application.js], handler.js_modules.map { |m| m[:path] }
  end
end
