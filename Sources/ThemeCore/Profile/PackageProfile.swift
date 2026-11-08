import Foundation

package enum PackageBaseline: String, Codable, Sendable {
  case core
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

  package var baseline: PackageBaseline
  package var layers: [Layer]

  package static let defaults = Self(baseline: .core, layers: [])
}

extension PackageProfile: PortableProfileSection {
  package static let table = "packages"
  package static var fields: [PortableProfileField<Self>] {
    [
      .init("baseline", \.baseline),
      .contributed("brewfile"),
      .contributed("exclude_formulae"),
      .contributed("exclude_casks"),
    ]
  }
}
