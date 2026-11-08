import Foundation

package struct KeybindingProfile: Equatable, Sendable {
  package let sourceURL: URL?
  package let overrideURL: URL?
  package let metadataURL: URL?
  package let disabledIdentities: [String]

  package static let empty = KeybindingProfile(
    sourceURL: nil,
    overrideURL: nil,
    metadataURL: nil,
    disabledIdentities: []
  )
}
