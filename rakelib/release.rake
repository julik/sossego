# frozen_string_literal: true

# Releasing: the gem, with its JS packages inside it, all at one version.
# Bundler's `rake release` builds, tags, pushes the tag and pushes the gem;
# the version check below runs in front of it. See RELEASING.md.

require "json"
require_relative "../lib/sossego/version"
require_relative "../lib/sossego/javascript"

module Release
  ROOT = File.expand_path("..", __dir__)
  VERSION_FILE = File.join(ROOT, "lib/sossego/version.rb")
  CHANGELOG = File.join(ROOT, "CHANGELOG.md")
  CLIENT = "#{Sossego::JavaScript::SCOPE}/#{Sossego::JavaScript::PREFIX}client"

  module_function

  def javascript = Sossego::JavaScript.new(File.join(ROOT, "app/javascript"))

  # The version the gem says, re-read so a bump in this process counts
  def version = File.read(VERSION_FILE)[/VERSION = "([^"]+)"/, 1]

  # Every place a version is written down, and what it says
  def versions
    js = javascript
    found = {"lib/sossego/version.rb" => version}
    js.manifests.each do |name, manifest|
      found["#{name} version"] = manifest.fetch("version")
      pinned = manifest.fetch("peerDependencies", {})[CLIENT]
      found["#{name} peer #{CLIENT}"] = pinned if pinned
    end
    found
  end

  # The CHANGELOG section for a version: what follows its `## x.y.z` heading
  def notes(for_version)
    File.read(CHANGELOG)[/^## #{Regexp.escape(for_version)}\b[^\n]*\n(.*?)(?=^## |\z)/m, 1]&.strip
  end

  def package_dirs = javascript.manifests.keys.map { |name| File.join(ROOT, "app/javascript", name) }
end

desc "Set the version of the gem and its JS packages, and date its CHANGELOG section, e.g. rake version[0.2.0]"
task :version, [:to] do |_, args|
  to = args.fetch(:to) { abort "Give the version: rake version[0.2.0]" }
  abort "#{to} is not a version" unless to.match?(/\A\d+\.\d+\.\d+(\.[a-z0-9.]+)?\z/)

  version_rb = File.read(Release::VERSION_FILE)
  File.write(Release::VERSION_FILE, version_rb.sub(/VERSION = "[^"]+"/, %(VERSION = "#{to}")))

  Release.package_dirs.each do |dir|
    path = File.join(dir, "package.json")
    manifest = JSON.parse(File.read(path))
    manifest["version"] = to
    manifest["peerDependencies"][Release::CLIENT] = to if manifest.dig("peerDependencies", Release::CLIENT)
    File.write(path, JSON.pretty_generate(manifest) + "\n")
  end

  changelog = File.read(Release::CHANGELOG)
  if changelog.match?(/^## Unreleased\s*$/)
    File.write(Release::CHANGELOG, changelog.sub(/^## Unreleased\s*$/, "## Unreleased\n\n## #{to} (#{Time.now.utc.strftime("%Y-%m-%d")})"))
  else
    puts "CHANGELOG.md has no `## Unreleased` section: write the one for #{to} yourself"
  end

  puts "Now #{to}. Check CHANGELOG.md, commit, then `rake release`."
end

namespace :release do
  desc "Fail unless every version is the same (and matches TAG=vX.Y.Z, when given) and CHANGELOG.md has its section"
  task :versions do
    versions = Release.versions
    unless versions.values.uniq.one?
      abort "The versions differ:\n" + versions.map { |where, v| "  #{v}  #{where}" }.join("\n")
    end
    version = versions.values.first
    if (tag = ENV["TAG"]) && tag != "v#{version}"
      abort "The tag #{tag} is not v#{version}"
    end
    abort "CHANGELOG.md has no `## #{version}` section, or it is empty" if Release.notes(version).to_s.empty?
    puts "Everything is at #{version}"
  end

  desc "Print the CHANGELOG section of the current version"
  task :notes do
    puts Release.notes(Release.version)
  end

  # Bundler's release checks the tree is clean, then tags and pushes. Check
  # the versions agree before the tag goes anywhere.
  task guard_clean: :versions
end
