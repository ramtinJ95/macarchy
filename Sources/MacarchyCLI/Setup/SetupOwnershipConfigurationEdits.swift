import Darwin
import Foundation
import TOMLDecoder
import ThemeCore

extension SetupOwnershipManager {
  func setupTOMLSelector(
    id: String,
    target: URL,
    backupURL: URL,
    replacementName: String,
    label: String,
    table: String,
    key: String,
    value: String,
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupRegularFile(
      id: id,
      target: target,
      backupURL: backupURL,
      replacementName: replacementName,
      label: label,
      read: { try readConfiguration($0, id: id) },
      isExternal: {
        try tomlSelectionIsExternal(
          $0,
          table: table,
          key: key,
          value: value,
          id: id,
          target: target
        )
      },
      installedData: {
        try addingTOMLSelection(
          to: $0,
          table: table,
          key: key,
          value: value,
          id: id,
          target: target
        )
      },
      externalOwnershipError: .configurationIsExternallyOwned(id, target),
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func readConfiguration(_ url: URL, id: String) throws -> Data {
    var metadata = stat()
    guard stat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
      throw SetupOwnershipError.missingConfiguration(id, url)
    }
    let data: Data
    do {
      data = try BoundedRegularFile.read(
        at: url.resolvingSymlinksInPath(),
        maximumSize: Self.maximumConfigurationSize
      ).data
    } catch BoundedRegularFileError.tooLarge {
      throw SetupOwnershipError.configurationTooLarge(id, url)
    } catch {
      throw SetupOwnershipError.system("read", url, String(describing: error))
    }
    guard String(data: data, encoding: .utf8) != nil else {
      throw SetupOwnershipError.unreadableConfiguration(id, url)
    }
    return data
  }

  func configurationLines(_ data: Data) -> [String] {
    String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
  }

  func exactLineIsExternal(
    _ data: Data,
    exactLine: String,
    id: String,
    target: URL,
    isRelevantLine: (String) -> Bool
  ) throws -> Bool {
    let relevant = configurationLines(data).filter(isRelevantLine)
    if relevant == [exactLine] { return true }
    guard relevant.isEmpty else {
      throw SetupOwnershipError.conflictingDirective(id, target)
    }
    return false
  }

  func tomlSelectionIsExternal(
    _ data: Data,
    table: String,
    key: String,
    value: String,
    id: String,
    target: URL
  ) throws -> Bool {
    let configuration = String(decoding: data, as: UTF8.self)
    let document: TOMLTable
    do {
      document = try TOMLTable(source: configuration)
    } catch {
      throw SetupOwnershipError.invalidConfiguration(id, target, String(describing: error))
    }
    let selection = CanonicalTOMLSelector(
      configuration: configuration,
      table: table,
      key: key
    )
    let tableHeaders = selection.tableHeaderCount
    let selections = selection.values

    guard document.contains(key: table) else {
      guard tableHeaders == 0, selections.isEmpty else {
        throw SetupOwnershipError.conflictingDirective(id, target)
      }
      return false
    }
    let selectionTable: TOMLTable
    do {
      selectionTable = try document.table(forKey: table)
    } catch {
      throw SetupOwnershipError.conflictingDirective(id, target)
    }
    guard tableHeaders == 1 else {
      throw SetupOwnershipError.conflictingDirective(id, target)
    }
    guard selectionTable.contains(key: key) else {
      guard selections.isEmpty else {
        throw SetupOwnershipError.conflictingDirective(id, target)
      }
      return false
    }
    do {
      guard try selectionTable.string(forKey: key) == value else {
        throw SetupOwnershipError.conflictingDirective(id, target)
      }
    } catch let error as SetupOwnershipError {
      throw error
    } catch {
      throw SetupOwnershipError.conflictingDirective(id, target)
    }
    guard selections == ["\"\(value)\""] else {
      throw SetupOwnershipError.conflictingDirective(id, target)
    }
    return true
  }

  func addingTOMLSelection(
    to original: Data,
    table: String,
    key: String,
    value: String,
    id: String,
    target: URL
  ) throws -> Data {
    if try tomlSelectionIsExternal(
      original,
      table: table,
      key: key,
      value: value,
      id: id,
      target: target
    ) {
      return original
    }

    let configuration = String(decoding: original, as: UTF8.self)
    let document: TOMLTable
    do {
      document = try TOMLTable(source: configuration)
    } catch {
      throw SetupOwnershipError.invalidConfiguration(id, target, String(describing: error))
    }
    var candidate: String
    let newline = tomlNewline(in: original)
    if document.contains(key: table) {
      var lines = configuration.components(separatedBy: "\n")
      let expectedHeader = "[\(table)]"
      let headerIndices = lines.indices.filter { index in
        let content = lines[index].split(separator: "#", maxSplits: 1).first ?? ""
        return content.trimmingCharacters(in: .whitespacesAndNewlines) == expectedHeader
      }
      guard headerIndices.count == 1, let headerIndex = headerIndices.first else {
        throw SetupOwnershipError.conflictingDirective(id, target)
      }
      if headerIndex == lines.index(before: lines.endIndex) {
        candidate = configuration + newline + "\(key) = \"\(value)\"" + newline
      } else {
        let carriageReturn = newline == "\r\n" ? "\r" : ""
        lines.insert("\(key) = \"\(value)\"\(carriageReturn)", at: headerIndex + 1)
        candidate = lines.joined(separator: "\n")
      }
    } else {
      candidate = configuration
      if !candidate.isEmpty, original.last != UInt8(ascii: "\n") { candidate.append(newline) }
      candidate.append("[\(table)]\(newline)\(key) = \"\(value)\"\(newline)")
    }

    let installed = Data(candidate.utf8)
    guard
      try tomlSelectionIsExternal(
        installed,
        table: table,
        key: key,
        value: value,
        id: id,
        target: target
      )
    else {
      throw SetupOwnershipError.conflictingDirective(id, target)
    }
    return installed
  }

  func tomlNewline(in data: Data) -> String {
    let bytes = Array(data)
    guard let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) else { return "\n" }
    return newline > 0 && bytes[newline - 1] == UInt8(ascii: "\r") ? "\r\n" : "\n"
  }

  func addingLine(_ original: Data, _ line: String) -> Data {
    var configuration = String(decoding: original, as: UTF8.self)
    if !configuration.isEmpty, !configuration.hasSuffix("\n") {
      configuration.append("\n")
    }
    configuration.append("\(line)\n")
    return Data(configuration.utf8)
  }
}
