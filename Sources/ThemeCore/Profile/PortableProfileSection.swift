import Foundation

/// One TOML table of the portable profile: its name, its default and the keys it accepts.
///
/// The keys drive the unknown-field check, layer merging and guided profile output.
/// Decoding stays typed per section so each field keeps its own validation.
package protocol PortableProfileSection {
  static var table: String { get }
  static var defaults: Self { get }
  static var fields: [PortableProfileField<Self>] { get }
}

extension PortableProfileSection {
  /// The key that sets `path` within this section's table.
  // Writable like the declared paths: key path equality also compares the key path class.
  package static func key<Value>(_ path: WritableKeyPath<Self, Value>) -> String {
    guard let field = fields.first(where: { $0.paths.contains(path) }) else {
      preconditionFailure("\(Self.self) declares no profile key for \(path)")
    }
    return field.key
  }
}

/// A role table whose only key is `provider`.
package protocol PortableProfileProvider: PortableProfileSection, RawRepresentable
where RawValue == String {
  static var disabled: Self { get }
}

extension PortableProfileProvider {
  package static var fields: [PortableProfileField<Self>] {
    [PortableProfileField<Self>("provider", \.self)]
  }
}

/// A key in one profile table and the decoded values it sets.
///
/// Layers replace whole fields: a later layer that declares the key wins every value it sets.
/// Package inputs instead contribute from each layer by identity, so no layer replaces them.
package struct PortableProfileField<Section> {
  package let key: String
  let paths: [PartialKeyPath<Section>]
  let replace: ((inout Section, Section) -> Void)?

  init<Value>(_ key: String, _ paths: WritableKeyPath<Section, Value>...) {
    self.key = key
    self.paths = paths.map { $0 as PartialKeyPath<Section> }
    replace = { section, layer in
      for path in paths { section[keyPath: path] = layer[keyPath: path] }
    }
  }

  private init(key: String) {
    self.key = key
    paths = []
    replace = nil
  }

  static func contributed(_ key: String) -> Self { Self(key: key) }
}

/// A profile table placed at its location in the decoded profile.
struct PortableProfileTable {
  let name: String
  /// Dotted `table.key` names, as the source index reports declared fields.
  let fields: [String]
  let contributedFields: [String]
  private let replace: (Set<String>, inout PortableProfile, PortableProfile) -> Void

  init<Section: PortableProfileSection>(_ path: WritableKeyPath<PortableProfile, Section>) {
    let table = Section.table
    let fields = Section.fields.map { (name: table + "." + $0.key, replace: $0.replace) }
    name = table
    self.fields = fields.map { $0.name }
    contributedFields = fields.filter { $0.replace == nil }.map { $0.name }
    replace = { declared, profile, layer in
      for field in fields where declared.contains(field.name) {
        field.replace?(&profile[keyPath: path], layer[keyPath: path])
      }
    }
  }

  /// Replaces every value whose key `declaredFields` names with the value from `layer`.
  func replaceDeclared(
    _ declaredFields: Set<String>, in profile: inout PortableProfile, from layer: PortableProfile
  ) {
    replace(declaredFields, &profile, layer)
  }
}

extension PortableProfile {
  /// Every profile table, in the order the profile document lists them.
  static var tables: [PortableProfileTable] {
    [
      .init(\.keybindings),
      .init(\.desktop.provider),
      .init(\.desktop.yabai),
      .init(\.topBar),
      .init(\.sketchyBar),
      .init(\.environment.scripts),
      .init(\.environment.focusRing),
      .init(\.environment.terminal),
      .init(\.environment.kitty),
      .init(\.environment.shell),
      .init(\.environment.zsh),
      .init(\.environment.prompt),
      .init(\.environment.starship),
      .init(\.environment.history),
      .init(\.environment.atuin),
      .init(\.environment.editor),
      .init(\.environment.neovim),
      .init(\.environment.tools),
      .init(\.environment.presets),
      .init(\.environment.btop),
      .init(\.environment.yazi),
      .init(\.packages),
      .init(\.macOSPreferences),
    ]
  }
}
