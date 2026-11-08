import Foundation

package struct KeybindingProfile: Equatable, Sendable {
  package var sourceURL: URL?
  package var overrideURL: URL?
  package var metadataURL: URL?
  package var disabledIdentities: [String]

  package static let empty = KeybindingProfile(
    sourceURL: nil,
    overrideURL: nil,
    metadataURL: nil,
    disabledIdentities: []
  )
}

extension KeybindingProfile: PortableProfileSection {
  package static let table = "keybindings"
  package static var defaults: Self { .empty }
  /// The source follows the layer that declares any keybinding field, so it has no key.
  package static var fields: [PortableProfileField<Self>] {
    [
      .init("override", \.overrideURL),
      .init("metadata", \.metadataURL),
      .init("disabled", \.disabledIdentities),
    ]
  }
}
