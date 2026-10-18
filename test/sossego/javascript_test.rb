# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Sossego::JavaScriptTest < ActiveSupport::TestCase
  setup { @js = Sossego::JavaScript.new }

  test "finds the five @sossego packages, all versioned in lockstep with the gem" do
    assert_equal %w[@sossego/client @sossego/highlight @sossego/react @sossego/stimulus @sossego/testing], @js.package_names
    @js.package_names.each { |name| assert_equal Sossego::VERSION, @js.version(name), name }
  end

  test "add-ons ask for exactly this version of @sossego/client" do
    @js.manifests.each do |name, manifest|
      pinned = manifest.fetch("peerDependencies", {})["@sossego/client"]
      assert_equal Sossego::VERSION, pinned, name if pinned
    end
  end

  test "maps the exports to bare specifiers and the files behind them" do
    assert_equal "@sossego/client/index.js", @js.modules.fetch("@sossego/client")
    assert_equal "@sossego/stimulus/index.js", @js.modules.fetch("@sossego/stimulus")
    assert_equal "@sossego/react/index.js", @js.modules.fetch("@sossego/react")
    assert_equal "@sossego/highlight/highlight.css", @js.modules.fetch("@sossego/highlight/highlight.css")
  end

  test "lists in files every file the exports point to, and the gemspec ships them all" do
    gem_root = Pathname(File.expand_path("../..", __dir__))
    gem_files = Gem::Specification.load(gem_root.join("sossego.gemspec").to_s).files
    @js.modules.each_value { |relpath| assert_includes @js.files, relpath }
    @js.files.each { |relpath| assert_includes gem_files, "app/javascript/#{relpath}" }
  end

  test "the add-ons import the client by its package name, never by a relative path" do
    @js.modules.each_value do |relpath|
      next unless relpath.end_with?(".js")
      source = @js.root.join(relpath).read
      refute_match(/from\s+["']\.\.?\//, source, "#{relpath} imports by relative path, which 404s under digested asset URLs")
    end
  end

  test "digests a file by its content" do
    Dir.mktmpdir do |dir|
      @js.copy_to(dir)
      copy = Sossego::JavaScript.new(dir)
      relpath = "@sossego/client/index.js"
      assert_equal @js.digest(relpath), copy.digest(relpath)
      assert_match(/\Asha384-/, copy.integrity(relpath))

      File.write(File.join(dir, relpath), "export {}\n")
      File.utime(Time.now + 5, Time.now + 5, File.join(dir, relpath)) # same second otherwise
      refute_equal @js.digest(relpath), copy.digest(relpath)
    end
  end

  test "a fresh copy is not stale, an edited or missing file is" do
    Dir.mktmpdir do |dir|
      @js.copy_to(dir)
      assert_empty @js.stale_files(dir)

      File.write(File.join(dir, "@sossego/client/index.js"), "export {}\n")
      File.delete(File.join(dir, "@sossego/react/index.js"))
      File.write(File.join(dir, "@sossego/client/extra.js"), "export {}\n") # an npm or Git install has more files
      assert_equal ["@sossego/client/index.js", "@sossego/react/index.js"], @js.stale_files(dir)
    end
  end

  test "compares only the packages asked about, so node_modules may hold a subset" do
    Dir.mktmpdir do |dir|
      @js.copy_to(dir)
      FileUtils.rm_rf(File.join(dir, "@sossego/react"))

      assert_equal %w[@sossego/client @sossego/highlight @sossego/stimulus @sossego/testing], @js.present_in(dir)
      assert_empty @js.stale_files(dir, @js.present_in(dir))
    end
  end

  test "copying replaces @sossego and leaves the rest of the directory alone" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "@sossego/old"))
      File.write(File.join(dir, "@sossego/old/leftover.js"), "")
      File.write(File.join(dir, "other-vendored-lib.js"), "")

      @js.copy_to(dir)

      refute File.exist?(File.join(dir, "@sossego/old"))
      assert File.exist?(File.join(dir, "other-vendored-lib.js"))
      assert_equal @js.manifests.fetch("@sossego/client"), JSON.parse(File.read(File.join(dir, "@sossego/client/package.json")))
    end
  end
end
