# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Sossego::PackageTest < ActiveSupport::TestCase
  setup { @package = Sossego::Package.new }

  test "is versioned in lockstep with the gem" do
    assert_equal Sossego::VERSION, @package.version
  end

  test "maps the exports to bare specifiers and the files behind them" do
    assert_equal "app/javascript/sossego.js", @package.modules.fetch("sossego")
    assert_equal "app/javascript/sossego/stimulus.js", @package.modules.fetch("sossego/stimulus")
    assert_equal "app/javascript/sossego/react.js", @package.modules.fetch("sossego/react")
    assert_equal "app/assets/stylesheets/sossego/highlight.css", @package.modules.fetch("sossego/highlight.css")
  end

  test "lists in files every file the exports point to, and the gemspec ships them all" do
    gem_files = Gem::Specification.load(@package.root.join("sossego.gemspec").to_s).files
    @package.modules.each_value { |relpath| assert_includes @package.files, relpath }
    @package.files.each { |relpath| assert_includes gem_files, relpath }
  end

  test "digests a file by its content" do
    Dir.mktmpdir do |dir|
      @package.copy_to(dir)
      copy = Sossego::Package.new(dir)
      relpath = "app/javascript/sossego.js"
      assert_equal @package.digest(relpath), copy.digest(relpath)
      assert_match(/\Asha384-/, copy.integrity(relpath))

      File.write(File.join(dir, relpath), "export {}\n")
      File.utime(Time.now + 5, Time.now + 5, File.join(dir, relpath)) # same second otherwise
      refute_equal @package.digest(relpath), copy.digest(relpath)
    end
  end

  test "a fresh copy is not stale, an edited or missing file is" do
    Dir.mktmpdir do |dir|
      @package.copy_to(dir)
      assert_empty @package.stale_files(dir)

      File.write(File.join(dir, "app/javascript/sossego.js"), "export {}\n")
      File.delete(File.join(dir, "app/javascript/sossego/react.js"))
      File.write(File.join(dir, "extra.js"), "export {}\n") # an npm or Git install has more files
      assert_equal ["app/javascript/sossego.js", "app/javascript/sossego/react.js"], @package.stale_files(dir)
    end
  end

  test "copying replaces whatever the directory held" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "leftover.js"), "")
      @package.copy_to(dir)
      refute File.exist?(File.join(dir, "leftover.js"))
      assert_equal @package.manifest, JSON.parse(File.read(File.join(dir, "package.json")))
    end
  end
end
