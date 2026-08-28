import Darwin
import Foundation
import TOMLDecoder

package struct SkhdCatalogEntry: Equatable, Sendable {
  package let identity: String
  package let label: String
  package let category: String
  package let order: Int
  package let aliases: [String]
}

package struct SkhdKeybindingCatalog: Equatable, Sendable {
  package let entries: [SkhdCatalogEntry]
  package let isPresent: Bool

  private init(entries: [SkhdCatalogEntry], isPresent: Bool) {
    self.entries = entries
    self.isPresent = isPresent
  }

  package static let missing = SkhdKeybindingCatalog(entries: [], isPresent: false)

  fileprivate static func present(entries: [SkhdCatalogEntry]) -> Self {
    SkhdKeybindingCatalog(entries: entries, isPresent: true)
  }
}

package struct SkhdPresentedBinding: Equatable, Sendable {
  package let binding: SkhdBinding
  package let metadata: SkhdCatalogEntry?
}

package struct SkhdCatalogCorrelation: Equatable, Sendable {
  package let bindings: [SkhdPresentedBinding]
  package let missingMetadataIdentities: [String]
  package let staleMetadataIdentities: [String]
}

package enum SkhdCatalogError: Error, CustomStringConvertible, Sendable {
  case cannotRead(URL, String)
  case invalid(URL, String)

  package var description: String {
    switch self {
    case .cannotRead(let file, _), .invalid(let file, _):
      "\(file.path): \(diagnosticMessage)"
    }
  }

  package var diagnosticMessage: String {
    switch self {
    case .cannotRead(_, let reason):
      "cannot read keybinding catalog: \(reason)"
    case .invalid(_, let reason):
      "invalid keybinding catalog: \(reason)"
    }
  }
}

package struct SkhdKeybindingCatalogLoader: Sendable {
  package init() {}

  package func load(at file: URL) throws -> SkhdKeybindingCatalog {
    var metadata = stat()
    guard lstat(file.path, &metadata) == 0 else {
      if errno == ENOENT { return .missing }
      throw SkhdCatalogError.cannotRead(file, Self.systemError(errno))
    }

    let resolved = file.resolvingSymlinksInPath().standardizedFileURL
    let data: Data
    do {
      data = try BoundedRegularFile.read(at: resolved).data
    } catch {
      throw SkhdCatalogError.cannotRead(file, String(describing: error))
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw SkhdCatalogError.invalid(file, "catalog is not valid UTF-8")
    }
    return try decode(text, source: file)
  }

  package func decode(_ text: String, source: URL) throws -> SkhdKeybindingCatalog {
    let index: TOMLSourceIndex
    do {
      index = try TOMLSourceIndex(
        text: text,
        file: source,
        syntaxRole: "Keybinding catalog"
      )
    } catch let diagnostic as ThemeDiagnostic {
      var reason = diagnostic.location.line.map { "line \($0)" } ?? ""
      if let column = diagnostic.location.column {
        reason += ", column \(column)"
      }
      if !reason.isEmpty { reason += ": " }
      reason += diagnostic.message
      if let field = diagnostic.field {
        reason += " [\(field)]"
      }
      throw SkhdCatalogError.invalid(source, reason)
    } catch {
      throw SkhdCatalogError.invalid(source, String(describing: error))
    }

    if let table = index.tables.first(where: { $0.path != "bindings" }) {
      throw SkhdCatalogError.invalid(
        source,
        "line \(table.line), column \(table.column): unknown table '\(table.path)'"
      )
    }
    let allowedFields = Set([
      "schema_version",
      "bindings.identity",
      "bindings.label",
      "bindings.category",
      "bindings.order",
      "bindings.aliases",
    ])
    if let field = index.fields.first(where: { !allowedFields.contains($0.path) }) {
      throw SkhdCatalogError.invalid(
        source,
        "line \(field.line), column \(field.column): unknown key '\(field.path)'"
      )
    }

    let document: CatalogDocument
    do {
      document = try TOMLDecoder().decode(CatalogDocument.self, from: text)
    } catch {
      throw SkhdCatalogError.invalid(source, String(describing: error))
    }
    guard document.schemaVersion == 1 else {
      throw SkhdCatalogError.invalid(
        source,
        "unsupported schema_version \(document.schemaVersion); expected 1"
      )
    }
    guard document.bindings.count <= 1_024 else {
      throw SkhdCatalogError.invalid(source, "contains more than 1024 bindings")
    }

    var identities = Set<String>()
    var entries: [SkhdCatalogEntry] = []
    for entry in document.bindings {
      guard Self.isCanonicalIdentity(entry.identity) else {
        throw SkhdCatalogError.invalid(
          source,
          "identity '\(entry.identity)' is not a normalized skhd chord"
        )
      }
      guard identities.insert(entry.identity).inserted else {
        throw SkhdCatalogError.invalid(
          source,
          "identity '\(entry.identity)' appears more than once"
        )
      }
      try Self.validate(
        entry.label,
        field: "label",
        identity: entry.identity,
        maximumLength: 120,
        source: source
      )
      try Self.validate(
        entry.category,
        field: "category",
        identity: entry.identity,
        maximumLength: 80,
        source: source
      )
      guard (0...1_000_000).contains(entry.order) else {
        throw SkhdCatalogError.invalid(
          source,
          "identity '\(entry.identity)' order must be between 0 and 1000000"
        )
      }
      guard entry.aliases.count <= 16 else {
        throw SkhdCatalogError.invalid(
          source,
          "identity '\(entry.identity)' aliases may contain at most 16 values"
        )
      }
      for alias in entry.aliases {
        try Self.validate(
          alias,
          field: "alias",
          identity: entry.identity,
          maximumLength: 80,
          source: source
        )
      }
      guard Set(entry.aliases).count == entry.aliases.count else {
        throw SkhdCatalogError.invalid(
          source,
          "identity '\(entry.identity)' contains duplicate aliases"
        )
      }
      entries.append(
        SkhdCatalogEntry(
          identity: entry.identity,
          label: entry.label,
          category: entry.category,
          order: entry.order,
          aliases: entry.aliases
        )
      )
    }
    return .present(entries: entries)
  }

  package func correlate(
    bindings: [SkhdBinding],
    catalog: SkhdKeybindingCatalog
  ) -> SkhdCatalogCorrelation {
    let entries = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.identity, $0) })
    let bindingIdentities = Set(bindings.map(\.identity))
    let presented = bindings.map {
      SkhdPresentedBinding(binding: $0, metadata: entries[$0.identity])
    }.sorted { lhs, rhs in
      let leftOrder = lhs.metadata?.order ?? Int.max
      let rightOrder = rhs.metadata?.order ?? Int.max
      if leftOrder != rightOrder { return leftOrder < rightOrder }
      return lhs.binding.line < rhs.binding.line
    }
    var seenMissing = Set<String>()
    let missing = bindings.reduce(into: [String]()) { result, binding in
      if entries[binding.identity] == nil, seenMissing.insert(binding.identity).inserted {
        result.append(binding.identity)
      }
    }
    return SkhdCatalogCorrelation(
      bindings: presented,
      missingMetadataIdentities: missing,
      staleMetadataIdentities: catalog.entries.compactMap {
        bindingIdentities.contains($0.identity) ? nil : $0.identity
      }
    )
  }

  private static func isCanonicalIdentity(_ identity: String) -> Bool {
    let result = SkhdConfigurationParser().parse("\(identity) : catalog")
    return result.diagnostics.isEmpty
      && result.bindings.count == 1
      && result.bindings[0].identity == identity
  }

  private static func validate(
    _ value: String,
    field: String,
    identity: String,
    maximumLength: Int,
    source: URL
  ) throws {
    guard value == value.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      throw SkhdCatalogError.invalid(
        source,
        "identity '\(identity)' \(field) must be nonempty without outer whitespace"
      )
    }
    guard value.count <= maximumLength else {
      throw SkhdCatalogError.invalid(
        source,
        "identity '\(identity)' \(field) exceeds the \(maximumLength)-character limit"
      )
    }
    guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw SkhdCatalogError.invalid(
        source,
        "identity '\(identity)' \(field) contains a control character"
      )
    }
  }

  private static func systemError(_ code: Int32) -> String {
    "\(String(cString: strerror(code))) (errno \(code))"
  }
}

private struct CatalogDocument: Decodable {
  let schemaVersion: Int
  let bindings: [CatalogEntryDocument]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case bindings
  }
}

private struct CatalogEntryDocument: Decodable {
  let identity: String
  let label: String
  let category: String
  let order: Int
  let aliases: [String]

  enum CodingKeys: CodingKey {
    case identity, label, category, order, aliases
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    identity = try container.decode(String.self, forKey: .identity)
    label = try container.decode(String.self, forKey: .label)
    category = try container.decode(String.self, forKey: .category)
    order = try container.decode(Int.self, forKey: .order)
    aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
  }
}
