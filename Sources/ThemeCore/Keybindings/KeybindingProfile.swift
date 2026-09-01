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

package enum KeybindingProfileError: Error, CustomStringConvertible, Sendable {
  case cannotRead(URL, String)
  case invalid(URL, String)

  package var description: String {
    switch self {
    case .cannotRead(let source, let reason):
      "\(source.path): cannot read Macarchy profile: \(reason)"
    case .invalid(let source, let reason):
      "\(source.path): invalid Macarchy profile: \(reason)"
    }
  }
}

package struct KeybindingProfileLoader: Sendable {
  package init() {}

  package func load(at source: URL, required: Bool) throws -> KeybindingProfile {
    try PortableProfileLoader().load(at: source, required: required).keybindings
  }

  package func decode(
    _ text: String,
    source: URL,
    resolvedSource: URL? = nil
  ) throws -> KeybindingProfile {
    try PortableProfileLoader()
      .decode(text, source: source, resolvedSource: resolvedSource)
      .keybindings
  }
}
