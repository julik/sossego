# frozen_string_literal: true

namespace :sossego do
  namespace :js do
    vendored_dir = -> { Rails.root.join(ENV.fetch("DIR", "vendor/javascript/sossego")) }

    desc "Copy the JS client from the installed gem into vendor/javascript/sossego (or DIR=), for a package.json `link:` dependency"
    task :vendor do
      dir = vendored_dir.call
      Sossego.package.copy_to(dir)
      puts "Copied sossego #{Sossego.package.version} to #{dir.relative_path_from(Rails.root)}"

      # A symlink, so node_modules can't keep an old copy. npm has no `link:`, but its `file:` is a symlink
      relative = dir.relative_path_from(Rails.root)
      spec = Rails.root.join("package-lock.json").file? ? "file:./#{relative}" : "link:./#{relative}"
      host_manifest = Rails.root.join("package.json")
      deps = host_manifest.file? ? JSON.parse(host_manifest.read).fetch("dependencies", {}) : {}
      unless deps["sossego"].to_s.end_with?(":./#{relative}")
        puts %(Add "sossego": "#{spec}" to "dependencies" in package.json, then install.)
      end
    end

    desc "Fail if the vendored JS client, or the copy in node_modules, differs from the installed gem"
    task :check do
      stale = [vendored_dir.call, Rails.root.join("node_modules/sossego")].filter_map do |dir|
        next unless dir.exist?
        files = Sossego.package.stale_files(dir)
        [dir.relative_path_from(Rails.root), files] if files.any?
      end
      stale.each { |dir, files| warn "#{dir} differs from sossego #{Sossego.package.version}: #{files.join(", ")}" }
      abort "Run bin/rails sossego:js:vendor, then your package manager's install" if stale.any?
    end
  end
end
