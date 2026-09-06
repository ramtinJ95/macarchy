import Foundation

/// Pinned native effect adapter. It never executes formula installation while preparing.
enum HomebrewFormulaInstallationAdapter {
  static let script = #"""
    require "json"
    require "formula_installer"
    require "upgrade"
    require "digest"
    require "zlib"
    require "rubygems/package"
    require "fileutils"

    raise "Unqualified Homebrew runtime" unless HOMEBREW_VERSION == "6.0.21-81-g571381a"
    raise "Unqualified platform" unless Homebrew::SimulateSystem.current_tag.to_s == "arm64_tahoe"
    phase, input, output = ARGV
    request = JSON.parse(File.read(input))
    names = request.fetch("names")
    raise "Invalid formula set" unless names.is_a?(Array) && names.size.between?(1, 64) &&
      names.uniq == names && names.all? { |n| n.match?(/\A[a-z0-9][a-z0-9+_.@-]*\z/) }
    formulae = names.map do |name|
      f = Formulary.factory("homebrew/core/#{name}")
      raise "Identity changed: #{name}" unless f.core_formula? && f.name == name
      raise "Already installed or disabled: #{name}" if f.any_version_installed? || f.disabled?
      raise "Unqualified aliases or migration: #{name}" unless f.aliases.empty? && f.oldnames.empty?
      raise "Unqualified post-install/service effects: #{name}" if f.post_install_defined? ||
        f.post_install_steps_defined? || f.service?
      raise "Unqualified overwrite effects: #{name}" unless f.class.link_overwrite_paths.empty? &&
        f.link_overwrite_formulae_names.empty?
      raise "Same-name cask exists: #{name}" if Cask::Caskroom.cask_installed?(name)
      f
    end
    installers = formulae.map { |f| FormulaInstaller.new(f) }
    components = installers.map do |fi|
      f = fi.formula
      bottle = fi.selected_bottle
      raise "No compatible bottle: #{f.name}" unless bottle && fi.pour_bottle?
      attrs = bottle.tab_attributes
      raise "Missing bottle evidence: #{f.name}" unless attrs["runtime_dependencies"].is_a?(Array)
      fi.determine_bottle_tab_attributes
      fi.check_requirements(fi.expand_requirements)
      fi.check_conflicts
      deps = fi.expand_dependencies.map(&:to_formula)
      raise "Existing dependency would change: #{f.name}" if deps.any?(&:any_version_installed?)
      raise "Non-core dependency: #{f.name}" unless deps.all?(&:core_formula?)
      {
        name: f.name, version: f.pkg_version.to_s, sha256: bottle.resource.checksum.hexdigest,
        dependencies: deps.map(&:name).sort, link_keg: fi.link_keg,
        url: bottle.url, path: bottle.cached_download.to_s, tab: attrs
      }
    end
    if phase == "inspect"
      File.write(output, JSON.generate(components))
      exit
    end
    raise "Unknown installation phase" unless phase == "effects"
    raise "Incomplete new dependency closure" unless components.all? { |c|
      (c[:dependencies] - names).empty?
    }
    dependent_issue = begin
      dependants = Homebrew::Upgrade.dependants(formulae, flags: [], dry_run: true)
      if [dependants.upgradeable, dependants.pinned, dependants.skipped].all?(&:empty?)
        nil
      else
        "Native dependent work is not empty"
      end
    rescue StandardError => e
      "Native dependent inspection unavailable: #{e.class}: #{e.message}"[0, 1000]
    end
    # Keep native checks enabled. An empty plan here is evidence, not a suppression flag.
    host = HOMEBREW_PREFIX
    scratch = Pathname.new(input).parent
    shadow = scratch/"effect-prefix"
    cellar = shadow/"Cellar"
    cellar.mkpath
    total = 0
    components.each do |component|
      path = Pathname.new(component.fetch(:path))
      raise "Archive escaped staging" unless path.parent == HOMEBREW_CACHE/"downloads"
      raise "Archive exceeded bound" unless path.size <= 32 * 1024 * 1024
      raise "Archive checksum changed" unless Digest::SHA256.file(path).hexdigest == component[:sha256]
      count = 0
      Zlib::GzipReader.open(path) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each do |entry|
            count += 1
            raise "Archive entry bound exceeded" if count > 2000
            size = entry.header.size
            total += size
            raise "Expanded archive bound exceeded" unless size >= 0 && total <= 128 * 1024 * 1024
            # Extended metadata is not interpreted as a filesystem path.
            if ["x", "g"].include?(entry.header.typeflag)
              pax = entry.read
              raise "Unqualified extended archive paths" if pax.match?(/ (?:path|linkpath|size)=/)
              next
            end
            parts = entry.full_name.split("/")
            raise "Unsafe archive path" if parts.include?("..") || entry.full_name.start_with?("/")
            raise "Unexpected archive root" unless parts.take(2) == [component[:name], component[:version]]
            target = cellar.join(*parts)
            ancestor = target.parent
            while ancestor != cellar
              raise "Archive symlink ancestor" if ancestor.symlink?
              ancestor = ancestor.parent
            end
            raise "Duplicate archive path" if target.exist? || target.symlink?
            target.parent.mkpath
            case entry.header.typeflag
            when "5" then target.mkpath
            when "0", "\0"
              File.open(target, "wb", entry.header.mode & 0777) { |file| IO.copy_stream(entry, file) }
            when "2"
              link = entry.header.linkname
              destination = Pathname.new(File.expand_path(link, target.parent))
              raise "Unsafe archive symlink" if link.start_with?("/") ||
                !destination.to_s.start_with?("#{cellar/component[:name]/component[:version]}/")
              File.symlink(link, target)
            else
              raise "Unsupported archive member"
            end
          end
        end
      end
      keg_path = cellar/component[:name]/component[:version]
      raise "Unqualified etc/var payload" if [".bottle/etc", ".bottle/var", "etc", "var"].any? {
        |p| (keg_path/p).exist? || (keg_path/p).symlink?
      }
      # Modern bottles carry their tab in the matching registry manifest, not
      # necessarily in the archive. Use native Tab decoding, then apply the
      # alias/tap fields which real pour sets before native Keg linking.
      tab = Tab.from_file_content(component[:tab].to_json, keg_path/AbstractTab::FILENAME)
      raise "Wrong bottle tab platform" unless tab.built_on&.[]("os") == HOMEBREW_SYSTEM
      tab.aliases = [] # Current formula aliases were required to be empty above.
      tab.tap = "homebrew/core"
      tab.write
    end

    footprint = {}
    inspect_path = lambda do |path, allow_directory|
      raise "Effect escaped qualified prefix" unless path == host || path.to_s.start_with?("#{host}/")
      stat = begin
        path.lstat
      rescue Errno::ENOENT
        nil
      end
      if stat
        raise "Existing path would change: #{path}" unless allow_directory && stat.directory? && !stat.symlink?
        footprint[path.to_s] = { path: path.to_s, device: stat.dev, inode: stat.ino, mode: stat.mode }
      else
        footprint[path.to_s] = { path: path.to_s }
      end
      stat
    end
    inspect_parents = lambda do |path|
      path.ascend do |parent|
        break if parent == host.parent
        inspect_path.call(parent, true)
      end
    end
    inspect_parents.call(host)
    common = Keg.must_exist_directories
    common.each { |p| inspect_parents.call(p) }
    # No deprecated opt cleanup, version alias removal or old-rack migration.
    inspect_path.call(host/"opt/homebrew", false)
    components.each do |component|
      name = component[:name]
      inspect_path.call(host/"Cellar"/name, false)
      raise "Existing version aliases: #{name}" unless
        Pathname.glob("#{host}/opt/#{name}@*").empty? &&
        Pathname.glob("#{HOMEBREW_LINKED_KEGS}/#{name}@*").empty?
      %W[opt/#{name} var/homebrew/linked/#{name}].each { |p|
        inspect_parents.call((host/p).parent)
        inspect_path.call(host/p, false)
      }
      next unless component[:link_keg]
      payload = cellar/name/component[:version]
      Keg.keg_link_directories.each do |dir|
        source = payload/dir
        next unless source.directory?
        source.find do |item|
          relative = item.relative_path_from(payload)
          target = host/relative
          inspect_parents.call(target.parent)
          existing = inspect_path.call(target, item.directory? && !item.symlink?)
          # Mirror only proved plain directory shapes. No existing file or
          # symlink is approximated. Unsupported overlaps block before mutation.
          (shadow/relative).mkpath if existing&.directory?
        end
      end
    end
    common.each { |p| (shadow/p.relative_path_from(host)).mkpath }
    { HOMEBREW_PREFIX: shadow, HOMEBREW_CELLAR: cellar,
      HOMEBREW_LINKED_KEGS: shadow/"var/homebrew/linked" }.each do |name, value|
      Object.send(:remove_const, name)
      Object.const_set(name, value)
    end
    components.each do |component|
      keg = Keg.new(cellar/component[:name]/component[:version])
      component[:link_keg] ? keg.link : keg.optlink
    end
    links = []
    directories = []
    shadow.find do |path|
      Find.prune if path == cellar
      next if path == shadow
      target = host/path.relative_path_from(shadow)
      if path.symlink?
        inspect_path.call(target, false)
        destination = File.expand_path(File.readlink(path), path.parent)
        raise "Native link escaped staged Cellar" unless destination.start_with?("#{cellar}/")
        links << { path: target.to_s, target: destination.sub(shadow.to_s, host.to_s) }
      elsif path.directory?
        stat = inspect_path.call(target, true)
        directories << target.to_s unless stat
      else
        raise "Unqualified native prefix file: #{path}"
      end
    end
    result = {
      components: components.map { |c| c.reject { |key, _| [:url, :path, :link_keg, :tab].include?(key) } },
      links: links.sort_by { |l| l[:path] }, directories: directories.sort,
      footprint: footprint.values.sort_by { |p| p[:path] }, dependent_issue: dependent_issue
    }
    File.write(output, JSON.generate(result))
    """#
}
