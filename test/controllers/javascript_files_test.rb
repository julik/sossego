# frozen_string_literal: true

require "test_helper"

class Sossego::JavaScriptFilesTest < ActionDispatch::IntegrationTest
  def helpers
    controller = ApplicationController.new
    controller.request = ActionDispatch::TestRequest.create
    controller.view_context
  end

  test "serves a module at its digested path, cacheable forever" do
    path = helpers.sossego_asset_path("@sossego/stimulus")
    assert_match %r{\A/sossego/js/\h{16}/@sossego/stimulus/index\.js\z}, path

    get path

    assert_response :ok
    assert_equal "text/javascript", response.media_type
    assert_equal "public, max-age=31536000, immutable", response.headers["cache-control"]
    assert_equal Sossego::Engine.root.join("app/javascript/@sossego/stimulus/index.js").read, response.body
  end

  test "serves the stylesheet" do
    get helpers.sossego_asset_path("@sossego/highlight/highlight.css")

    assert_response :ok
    assert_equal "text/css", response.media_type
  end

  test "refuses a stale digest and files outside the exports" do
    digest = Sossego.javascript.digest("@sossego/client/index.js")

    get "/sossego/js/0000000000000000/@sossego/client/index.js"
    assert_response :not_found

    get "/sossego/js/#{digest}/@sossego/testing/index.d.ts"
    assert_response :not_found

    get "/sossego/js/#{digest}/@sossego/client/package.json"
    assert_response :not_found

    get "/sossego/js/#{digest}/../../lib/sossego.rb"
    assert_response :not_found

    get "/sossego/js/#{digest}/../../Gemfile"
    assert_response :not_found
  end

  test "gives an importmap fragment with the page modules and their integrity" do
    map = helpers.sossego_importmap

    assert_equal %w[@sossego/client @sossego/highlight @sossego/stimulus], map[:imports].keys.sort
    map[:imports].each_value do |url|
      assert_match(/\Asha384-/, map[:integrity].fetch(url))
      get url
      assert_response :ok
      assert_equal "sha384-#{Digest::SHA384.base64digest(response.body)}", map[:integrity].fetch(url)
    end
  end

  test "adds @sossego/react only when asked for, and never maps @sossego/testing by default" do
    map = helpers.sossego_importmap(also: %w[@sossego/react])

    assert_includes map[:imports].keys, "@sossego/react"
    assert map[:integrity].key?(map[:imports]["@sossego/react"])
    refute_includes helpers.sossego_importmap[:imports].keys, "@sossego/testing"
  end

  test "names an unknown specifier instead of mapping it" do
    assert_raises(KeyError) { helpers.sossego_importmap(also: %w[@sossego/nope]) }
  end
end
