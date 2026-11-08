import Foundation

/// Closed, observable public scripting properties. Never accept arbitrary defaults keys.
package enum MacOSPreference: String, CaseIterable, Codable, Hashable, Sendable {
  case dockAutohide = "dock_autohide"
  case finderShowExtensions = "finder_show_extensions"

  package var title: String {
    switch self {
    case .dockAutohide: "Automatically hide and show the Dock"
    case .finderShowExtensions: "Show all filename extensions in Finder"
    }
  }
}

package struct MacOSPreferencesProfile: Equatable, Decodable, Sendable {
  package var enabled: Bool
  package var dockAutohide: Bool?
  package var finderShowExtensions: Bool?

  package init(
    enabled: Bool = false, dockAutohide: Bool? = nil, finderShowExtensions: Bool? = nil
  ) {
    self.enabled = enabled
    self.dockAutohide = dockAutohide
    self.finderShowExtensions = finderShowExtensions
  }

  package var selected: [MacOSPreference: Bool] {
    guard enabled else { return [:] }
    var result: [MacOSPreference: Bool] = [:]
    result[.dockAutohide] = dockAutohide
    result[.finderShowExtensions] = finderShowExtensions
    return result
  }

  package init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    dockAutohide = try values.decodeIfPresent(Bool.self, forKey: .dockAutohide)
    finderShowExtensions = try values.decodeIfPresent(Bool.self, forKey: .finderShowExtensions)
  }

  private enum CodingKeys: String, CodingKey {
    case enabled
    case dockAutohide = "dock_autohide"
    case finderShowExtensions = "finder_show_extensions"
  }
}

extension MacOSPreferencesProfile: PortableProfileSection {
  package static let table = "macos_preferences"
  package static let defaults = Self()
  package static var fields: [PortableProfileField<Self>] {
    [
      .init("enabled", \.enabled),
      .init("dock_autohide", \.dockAutohide),
      .init("finder_show_extensions", \.finderShowExtensions),
    ]
  }
}
