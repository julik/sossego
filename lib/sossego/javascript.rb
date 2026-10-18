# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"

module Sossego
  # The JS client: the npm packages under `app/javascript/@sossego/`, one
  # directory and package.json each (`@sossego/client`, `@sossego/stimulus`,
  # ...). Paths are relative to `app/javascript`, so a file's path is also its
  # place in an importmap, a copy, or node_modules.
  #
  # It serves the files at digested URLs for apps that write their own
  # importmap ({#call}, {ImportmapHelper}), copies the packages into a host app
  # for `link:` dependencies ({#copy_to}), and tells whether such a copy still
  # matches the gem ({#stale_files}).
  class JavaScript
    SCOPE = "@sossego"
    CONTENT_TYPES = {".js" => "text/javascript", ".css" => "text/css"}.freeze

    attr_reader :root

    # @param root [String, Pathname] the directory that holds `@sossego/`
    def initialize(root = File.expand_path("../../app/javascript", __dir__))
      @root = Pathname(root)
      @digests = {}
    end

    # @return [Hash{String => Hash}] package name => its package.json
    def manifests
      @manifests ||= root.join(SCOPE).children.select { |dir| dir.join("package.json").file? }.sort.to_h do |dir|
        manifest = JSON.parse(dir.join("package.json").read)
        [manifest.fetch("name"), manifest]
      end
    end

    # @return [Array<String>] e.g. ["@sossego/client", "@sossego/highlight", ...]
    def package_names = manifests.keys

    def version(package_name = "#{SCOPE}/client") = manifests.fetch(package_name).fetch("version")

    # @return [Hash{String => String}] bare specifier => file, e.g.
    #   "@sossego/stimulus" => "@sossego/stimulus/index.js",
    #   "@sossego/highlight/highlight.css" => "@sossego/highlight/highlight.css"
    def modules
      @modules ||= manifests.each_with_object({}) do |(name, manifest), modules|
        manifest.fetch("exports").each do |subpath, target|
          target = target.fetch("default") if target.is_a?(Hash)
          modules[subpath.sub(/\A\./, name)] = File.join(name, target.delete_prefix("./"))
        end
      end
    end

    # @param package_names [Array<String>] only these packages
    # @return [Array<String>] what a copy of the packages holds
    def files(package_names = self.package_names)
      package_names.flat_map do |name|
        [File.join(name, "package.json"), *manifests.fetch(name).fetch("files").map { |f| File.join(name, f) }]
      end
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
    # files named in the packages' `exports`, and only under their current
    # digest, so the response can be cached forever.
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

    # Replaces `dir/@sossego` with a copy of the packages. Anything else in
    # `dir` is left alone.
    def copy_to(dir)
      dir = Pathname(dir)
      FileUtils.rm_rf(dir.join(SCOPE))
      files.each do |relpath|
        FileUtils.mkdir_p(dir.join(relpath).dirname)
        FileUtils.cp(root.join(relpath), dir.join(relpath))
      end
    end

    # Files of the packages that are missing from `dir` or differ from the
    # gem's. Extra files in `dir` don't count: an install from npm or Git
    # brings its own.
    #
    # @param dir [String, Pathname] holds `@sossego/` (a vendor dir, node_modules)
    # @param package_names [Array<String>] the packages to compare
    # @return [Array<String>] empty when `dir` holds the same client as the gem
    def stale_files(dir, package_names = self.package_names)
      dir = Pathname(dir)
      files(package_names).reject { |f| dir.join(f).file? && dir.join(f).binread == root.join(f).binread }
    end

    # The packages `dir` has a directory for.
    #
    # @return [Array<String>]
    def present_in(dir)
      package_names.select { |name| Pathname(dir).join(name).directory? }
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

  # The packages this gem ships
  def self.javascript
    @javascript ||= JavaScript.new
  end
end
