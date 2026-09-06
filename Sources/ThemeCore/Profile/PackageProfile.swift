import Foundation

package enum PackageBaseline: String, Codable, Sendable {
  case standard
  case personal
}

/// Preserve contributions: a machine fragment supplements the portable fragment.
/// Package identity composition belongs to the package consumer, not a generic
/// change to the profile's existing whole-field overlay.
package struct PackageProfile: Equatable, Sendable {
  package struct Layer: Equatable, Sendable {
    package let kind: PortableProfileLayerKind
    package let sourceURL: URL
    package let brewfileURL: URL?
    package let excludedFormulae: [String]
    package let excludedCasks: [String]
  }

  package let baseline: PackageBaseline
  package let layers: [Layer]

  package static let defaults = Self(baseline: .standard, layers: [])
}
