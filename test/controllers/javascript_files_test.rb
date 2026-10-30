# frozen_string_literal: true

require "test_helper"

class Sossego::JavaScriptFilesTest < ActionDispatch::IntegrationTest
  def helpers
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    controller.view_context
  end

  test "serves a module at its digested path, cacheable forever" do
    path = helpers.sossego_asset_path("@julik/sossego-stimulus")
    assert_match %r{\A/sossego/js/\h{16}/@julik/sossego-stimulus/index\.js\z}, path

    get path

    assert_response :ok
    assert_equal "text/javascript", response.media_type
    assert_equal "public, max-age=31536000, immutable", response.headers["cache-control"]
    assert_equal Sossego::Engine.root.join("app/javascript/@julik/sossego-stimulus/index.js").read, response.body
  end

  test "serves the stylesheet" do
    get helpers.sossego_asset_path("@julik/sossego-highlight/highlight.css")

    assert_response :ok
    assert_equal "text/css", response.media_type
  end

  test "refuses a stale digest and files outside the exports" do
    digest = Sossego.javascript.digest("@julik/sossego-client/index.js")

    get "/sossego/js/0000000000000000/@julik/sossego-client/index.js"
    assert_response :not_found

    get "/sossego/js/#{digest}/@julik/sossego-testing/index.d.ts"
    assert_response :not_found

    get "/sossego/js/#{digest}/@julik/sossego-client/package.json"
    assert_response :not_found

    get "/sossego/js/#{digest}/../../lib/sossego.rb"
    assert_response :not_found

    get "/sossego/js/#{digest}/../../Gemfile"
    assert_response :not_found
  end

  test "gives an importmap fragment with the page modules and their integrity" do
    map = helpers.sossego_importmap

    assert_equal %w[@julik/sossego-client @julik/sossego-client/index.js @julik/sossego-highlight @julik/sossego-highlight/index.js @julik/sossego-stimulus @julik/sossego-stimulus/index.js], map[:imports].keys.sort
    map[:imports].each_value do |url|
      assert_match(/\Asha384-/, map[:integrity].fetch(url))
      get url
      assert_response :ok
      assert_equal "sha384-#{Digest::SHA384.base64digest(response.body)}", map[:integrity].fetch(url)
    end
  end

  test "adds @julik/sossego-react only when asked for, and never maps @julik/sossego-testing by default" do
    map = helpers.sossego_importmap(also: %w[@julik/sossego-react])

    assert_includes map[:imports].keys, "@julik/sossego-react"
    assert_includes map[:imports].keys, "@julik/sossego-react/index.js"
    assert map[:integrity].key?(map[:imports]["@julik/sossego-react"])
    refute_includes helpers.sossego_importmap[:imports].keys, "@julik/sossego-testing"
  end

  test "names an unknown specifier instead of mapping it" do
    assert_raises(KeyError) { helpers.sossego_importmap(also: %w[@julik/sossego-nope]) }
  end
end

class Sossego::ImportmapPinsTest < ActiveSupport::TestCase
  test "importmap-rails pins both names of every page package, preloads all but react, and never maps the testing package" do
    resolver = ActionController::Base.helpers
    imports = JSON.parse(Rails.application.importmap.to_json(resolver: resolver)).fetch("imports")
    preloaded = Rails.application.importmap.preloaded_module_paths(resolver: resolver)

    %w[client stimulus highlight react].each do |part|
      assert_equal imports.fetch("@julik/sossego-#{part}"), imports.fetch("@julik/sossego-#{part}/index.js")
    end
    refute imports.keys.any? { |specifier| specifier.start_with?("@julik/sossego-testing") }
    assert_includes preloaded, imports.fetch("@julik/sossego-stimulus")
    refute_includes preloaded, imports.fetch("@julik/sossego-react")
  end
end
