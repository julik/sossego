# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"

module Sossego
  # The JS client as the package.json at the root of the gem describes it. The
  # `exports` map gives the bare specifiers and their files, `files` what a copy
  # of the package holds.
  #
  # It does three things with that: serves the files at digested URLs for apps
  # that write their own importmap ({#call}, {ImportmapHelper}), copies the
  # package into a host app for a package.json `link:` dependency ({#copy_to}),
  # and tells whether such a copy still matches the gem ({#stale_files}).
  class Package
    CONTENT_TYPES = {".js" => "text/javascript", ".css" => "text/css"}.freeze

    attr_reader :root

    def initialize(root = File.expand_path("../..", __dir__))
      @root = Pathname(root)
      @digests = {}
    end

    def manifest
      @manifest ||= JSON.parse(root.join("package.json").read)
    end

    def name = manifest.fetch("name")

    def version = manifest.fetch("version")

    # @return [Hash{String => String}] bare specifier => path relative to {#root},
    #   e.g. "sossego/stimulus" => "app/javascript/sossego/stimulus.js"
    def modules
      @modules ||= manifest.fetch("exports").to_h do |subpath, target|
        target = target.fetch("default") if target.is_a?(Hash)
        [subpath.sub(/\A\./, name), target.delete_prefix("./")]
      end
    end

    # @return [Array<String>] paths relative to {#root} that a copy of the package holds
    def files
      ["package.json", *manifest.fetch("files")]
    end

    # Short content digest for the URL. Keyed on mtime, so a path gem being
    # edited gets new URLs without a restart.
    def digest(relpath)
      fingerprint(relpath).first
    end

    # SRI hash, for the importmap's `integrity` section
    def integrity(relpath)
      fingerprint(relpath).last
    end

    # Rack endpoint behind the engine's `js/:digest/*path` route. Serves only
    # files named in `exports`, and only under their current digest, so the
    # response can be cached forever.
    def call(env)
      params = env.fetch("action_dispatch.request.path_parameters")
      relpath = params[:path]
      unless modules.value?(relpath) && digest(relpath) == params[:digest]
        return [404, {"content-type" => "text/plain"}, ["Not found"]]
      end

      headers = {
        "content-type" => CONTENT_TYPES.fetch(File.extname(relpath)),
        "cache-control" => "public, max-age=31536000, immutable"
      }
      [200, headers, [root.join(relpath).binread]]
    end

    # Replaces `dir` with a copy of the package: package.json and its `files`.
    # The directory is ours, anything else in it is removed.
    def copy_to(dir)
      dir = Pathname(dir)
      FileUtils.rm_rf(dir)
      files.each do |relpath|
        FileUtils.mkdir_p(dir.join(relpath).dirname)
        FileUtils.cp(root.join(relpath), dir.join(relpath))
      end
    end

    # Files of the package that are missing from `dir` or differ from the gem's.
    # Extra files in `dir` don't count: an install from npm or Git brings its own.
    #
    # @return [Array<String>] empty when `dir` holds the same client as the gem
    def stale_files(dir)
      dir = Pathname(dir)
      files.reject { |f| dir.join(f).file? && dir.join(f).binread == root.join(f).binread }
    end

    private

    def fingerprint(relpath)
      path = root.join(relpath)
      mtime = path.mtime
      cached = @digests[relpath]
      return cached.last if cached&.first == mtime

      bytes = path.binread
      pair = [Digest::SHA256.hexdigest(bytes)[0, 16], "sha384-#{Digest::SHA384.base64digest(bytes)}"]
      @digests[relpath] = [mtime, pair]
      pair
    end
  end

  # The package this gem ships
  def self.package
    @package ||= Package.new
  end
end
