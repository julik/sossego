# frozen_string_literal: true

namespace :sossego do
  namespace :js do
    vendor_dir = -> { Rails.root.join(ENV.fetch("DIR", "vendor/javascript")) }

    desc "Copy the @julik/sossego-* packages from the installed gem into vendor/javascript/@julik (DIR= to change), for package.json `link:` dependencies"
    task :vendor do
      dir = vendor_dir.call
      Sossego.javascript.copy_to(dir)
      relative = dir.relative_path_from(Rails.root)
      puts "Copied #{Sossego.javascript.package_names.join(", ")} #{Sossego.javascript.version} to #{relative}/#{Sossego::JavaScript::SCOPE}"

      # A symlink, so node_modules can't keep an old copy. npm has no `link:`, but its `file:` is a symlink
      protocol = Rails.root.join("package-lock.json").file? ? "file" : "link"
      host_manifest = Rails.root.join("package.json")
      manifest = host_manifest.file? ? JSON.parse(host_manifest.read) : {}
      declared = manifest.fetch("dependencies", {}).merge(manifest.fetch("devDependencies", {}))
      missing = Sossego.javascript.package_names.reject { |name| declared.key?(name) }
      if missing.any?
        puts "Add the ones you use to package.json, then install (@julik/sossego-testing under devDependencies):"
        missing.each { |name| puts %(  "#{name}": "#{protocol}:./#{relative}/#{name}") }
      end
    end

    desc "Fail if the vendored @julik/sossego-* packages, or those in node_modules, differ from the installed gem"
    task :check do
      dirs = [vendor_dir.call, Rails.root.join("node_modules")]
      stale = dirs.filter_map do |dir|
        names = Sossego.javascript.present_in(dir)
        next if names.empty?
        files = Sossego.javascript.stale_files(dir, names)
        [dir.relative_path_from(Rails.root), files] if files.any?
      end
      stale.each { |dir, files| warn "#{dir} differs from sossego #{Sossego.javascript.version}: #{files.join(", ")}" }
      abort "Run bin/rails sossego:js:vendor, then your package manager's install" if stale.any?
    end
  end
end
