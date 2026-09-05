import Foundation

/// A deliberately version-coupled adapter, not a second dependency solver.
/// Embedded so source checkouts and installed binaries execute identical code.
enum HomebrewFormulaResolver {
  static let revision = "571381a8a7b42bf38f94c65b6be340466945d217"
  static let version = "6.0.21-81-g571381a"
  static let script = #"""
    require "json"
    require "formula_installer"

    raise "Unqualified Homebrew runtime" unless HOMEBREW_VERSION == "6.0.21-81-g571381a"
    raise "Unqualified bottle platform" unless Homebrew::SimulateSystem.current_tag.to_s == "arm64_tahoe"
    phase, input, output = ARGV
    names = JSON.parse(File.read(input))
    raise "Invalid request" unless names.is_a?(Array) && names.size <= 64 && names.uniq == names

    results = names.map do |name|
      begin
        raise "Unsupported formula identity" unless name.match?(/\A[a-z0-9][a-z0-9+_.@-]*\z/)
        formula = Formulary.factory("homebrew/core/#{name}")
        raise "Formula identity changed" unless formula.core_formula? && formula.name == name
        raise "Disabled formula" if formula.disabled?
        installer = FormulaInstaller.new(formula)
        bottle = installer.selected_bottle
        raise "No supported bottle" unless bottle
        manifest = bottle.github_packages_manifest_resource
        raise "No official manifest" unless manifest
        result = { name: name, version: formula.pkg_version.to_s }
        if phase == "metadata"
          raise "No supported bottle" unless installer.pour_bottle?
          result.merge(status: "metadata_required", url: manifest.url, path: manifest.cached_download.to_s)
        elsif phase == "resolve"
          # Native BottleManifest selects BOTH checksum and version/rebuild/tag.
          # Do not use compute_dependencies: its fetch wrapper writes prefix locks
          # even for cached manifests. Validate before its permissive rescue path.
          attrs = bottle.tab_attributes
          raise "Missing matching bottle dependency evidence" unless attrs.is_a?(Hash) &&
            attrs["runtime_dependencies"].is_a?(Array)
          # Check compatibility after validation: pour_bottle? can otherwise
          # turn a stale manifest into a generic source-build fallback.
          raise "No supported bottle" unless installer.pour_bottle?
          installer.determine_bottle_tab_attributes
          installer.check_requirements(installer.expand_requirements)
          dependencies = installer.expand_dependencies.map do |dep|
            target = dep.to_formula
            raise "Non-core dependency" unless target.core_formula?
            { name: target.name, version: target.pkg_version.to_s,
              installed: target.any_version_installed?, linked: target.optlinked? }
          end
          result.merge(status: "resolved_dependencies",
                       installed: formula.any_version_installed?,
                       current: formula.latest_version_installed?, linked: formula.optlinked?,
                       dependencies: dependencies)
        else
          raise "Unknown adapter phase"
        end
      rescue StandardError => e
        { name: name, status: "incomplete", issue: "#{e.class}: #{e.message}"[0, 1000] }
      end
    end
    File.write(output, JSON.generate(results))
    """#

  static let sandbox = #"""
    (version 1)
    (allow default)
    (deny file-write*)
    (deny network*)
    (allow file-write* (subpath (param "SCRATCH")) (literal "/dev/null"))
    """#
}
