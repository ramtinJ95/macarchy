import Foundation

/// A desktop provider's personal configuration and the legacy hook it replaces. Each
/// composer keeps its own hook reader, trusted root and rendering.
package protocol DesktopPersonalSourceOptions {
  var configurationURL: URL? { get }
  var hookURL: URL? { get }
}

extension DesktopPersonalSourceOptions {
  /// A native configuration replaces the legacy hook, so only one may be selected.
  package var sourceConflict: String? {
    configurationURL != nil && hookURL != nil
      ? "select configuration or legacy hook, not both" : nil
  }

  /// The selected source. Excluding the personal configuration falls back to the legacy hook.
  package func personalSource(includingPersonalConfiguration: Bool) -> DesktopPersonalSource {
    let configurationURL = includingPersonalConfiguration ? configurationURL : nil
    return DesktopPersonalSource(
      url: configurationURL ?? hookURL, native: configurationURL != nil)
  }
}

package struct DesktopPersonalSource: Equatable, Sendable {
  /// The personal configuration or legacy hook to read, if either is selected.
  package let url: URL?
  /// Whether `url` is a native personal configuration rather than a legacy hook.
  package let native: Bool

  /// The source digest as recorded in the input identity; a native configuration is marked.
  package func identityDigest(_ digest: String?) -> String? {
    native ? digest.map { "native:" + $0 } : digest
  }
}

extension YabaiProfileOptions: DesktopPersonalSourceOptions {}
extension SketchyBarProfileOptions: DesktopPersonalSourceOptions {}
