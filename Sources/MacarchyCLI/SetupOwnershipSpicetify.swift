import Foundation
import ThemeCore

extension SetupOwnershipManager {
  func withSpicetifySetupGroup(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord],
    execute: ConsumerSetupPlan.Execution
  ) throws -> [SetupIntegrationResult] {
    if try spicetifyProviderStateIsAbsent(context: context, records: records) {
      return disabledSpicetifyIntegrationResults(context: context)
    }
    if dryRun {
      return try execute(&records)
    }
    // Central setup already holds activation.lock. Reconciliation never takes that lock,
    // so the global order is activation.lock followed by spicetify.lock.
    return try SpicetifyLock(root: context.stateRoot).withLock {
      try execute(&records)
    }
  }

  private func disabledSpicetifyIntegrationResults(
    context: Context
  ) -> [SetupIntegrationResult] {
    [
      integrationResult(
        id: Self.spicetifySelectorsID,
        target: context.spicetifyConfiguration,
        status: .disabled,
        message: "Spicetify configuration is absent; "
          + "the optional selector integration is disabled"
      ),
      integrationResult(
        id: Self.spicetifyColorLinkID,
        target: context.spicetifyColorLink,
        status: .disabled,
        message: "Spicetify configuration is absent; "
          + "the optional color integration is disabled"
      ),
    ]
  }

  private func spicetifyProviderStateIsAbsent(
    context: Context,
    records: [SetupOwnershipRecord]
  ) throws -> Bool {
    let integrationIDs = [Self.spicetifySelectorsID, Self.spicetifyColorLinkID]
    guard !records.contains(where: { integrationIDs.contains($0.id) }) else { return false }
    let replacement = context.spicetifyConfiguration.deletingLastPathComponent()
      .appending(path: context.spicetifySelectorsReplacementName)
    let linkRemoval = themeLinkRemovalURL(
      id: Self.spicetifyColorLinkID,
      target: context.spicetifyColorLink
    )
    for path in [
      context.spicetifyConfiguration,
      context.spicetifyColorLink,
      context.spicetifySelectorsBackup,
      replacement,
      linkRemoval,
    ] where try itemExists(path) {
      return false
    }
    return true
  }

  func withSpicetifyTeardownGroup(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord],
    execute: ConsumerSetupPlan.Execution
  ) throws -> [SetupIntegrationResult] {
    let integrationIDs = [Self.spicetifySelectorsID, Self.spicetifyColorLinkID]
    if !records.contains(where: { integrationIDs.contains($0.id) }) {
      return unownedSpicetifyTeardownResults(context: context)
    }
    if dryRun {
      return try execute(&records)
    }
    return try SpicetifyLock(root: context.stateRoot).withLock {
      try execute(&records)
    }
  }

  private func unownedSpicetifyTeardownResults(
    context: Context
  ) -> [SetupIntegrationResult] {
    [
      integrationResult(
        id: Self.spicetifySelectorsID,
        target: context.spicetifyConfiguration,
        status: .none,
        message: "No Macarchy-owned Spicetify theme selection exists"
      ),
      integrationResult(
        id: Self.spicetifyColorLinkID,
        target: context.spicetifyColorLink,
        status: .none,
        message: "No Macarchy-owned Spicetify color scheme link exists"
      ),
    ]
  }

  func setupSpicetifySelectors(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupSpicetifySelectorOwnership(
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupSpicetifyColorLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupThemeLink(
      id: Self.spicetifyColorLinkID,
      target: context.spicetifyColorLink,
      destination: context.spicetifyColorDestination,
      label: "Spicetify color scheme",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func spicetifySelectorsAreExternal(
    _ data: Data,
    target: URL
  ) throws -> Bool {
    let selection = try spicetifySelection(data, target: target)
    return selection.theme == SpicetifyAdapter.themeName
      && selection.colorScheme == SpicetifyAdapter.colorSchemeName
  }

  func addingSpicetifySelectors(
    to original: Data,
    target: URL
  ) throws -> Data {
    if try spicetifySelectorsAreExternal(original, target: target) {
      return original
    }
    let selection = try spicetifySelection(original, target: target)
    return try editingSpicetifySelectors(
      in: original,
      themeRawValue: SpicetifyAdapter.themeName,
      colorSchemeRawValue: SpicetifyAdapter.colorSchemeName,
      expectedTheme: SpicetifyAdapter.themeName,
      expectedColorScheme: SpicetifyAdapter.colorSchemeName,
      existingSelection: selection,
      target: target
    )
  }

  func restoringSpicetifySelectors(
    in current: Data,
    from original: SpicetifyAdapter.ConfigurationSelection,
    target: URL
  ) throws -> Data {
    let currentSelection = try spicetifySelection(current, target: target)
    return try editingSpicetifySelectors(
      in: current,
      themeRawValue: original.rawTheme,
      colorSchemeRawValue: original.rawColorScheme,
      expectedTheme: original.theme,
      expectedColorScheme: original.colorScheme,
      existingSelection: currentSelection,
      target: target
    )
  }

  private func editingSpicetifySelectors(
    in original: Data,
    themeRawValue: String?,
    colorSchemeRawValue: String?,
    expectedTheme: String?,
    expectedColorScheme: String?,
    existingSelection: SpicetifyAdapter.ConfigurationSelection,
    target: URL
  ) throws -> Data {
    let configuration = String(decoding: original, as: UTF8.self)
    let lines = configuration.components(separatedBy: "\n")
    let headerIndices = lines.indices.filter { index in
      spicetifySectionName(lines[index], firstLine: index == 0) == "Setting"
    }
    guard headerIndices.count == 1 else {
      throw SetupOwnershipError.invalidConfiguration(
        Self.spicetifySelectorsID,
        target,
        "expected one [Setting] table"
      )
    }

    var editedLines = [String]()
    var sectionName = "DEFAULT"
    for index in lines.indices {
      let line = lines[index]
      if let parsedSection = spicetifySectionName(line, firstLine: index == 0) {
        sectionName = parsedSection
        editedLines.append(line)
        continue
      }
      guard sectionName == "Setting", let key = spicetifyAssignmentKey(line) else {
        editedLines.append(line)
        continue
      }
      switch key {
      case "current_theme":
        if let themeRawValue {
          editedLines.append(replacingSpicetifyValue(in: line, with: themeRawValue))
        }
      case "color_scheme":
        if let colorSchemeRawValue {
          editedLines.append(replacingSpicetifyValue(in: line, with: colorSchemeRawValue))
        }
      default:
        editedLines.append(line)
      }
    }

    let editedHeaderIndices = editedLines.indices.filter { index in
      spicetifySectionName(editedLines[index], firstLine: index == 0) == "Setting"
    }
    guard editedHeaderIndices.count == 1, let editedHeaderIndex = editedHeaderIndices.first else {
      throw SetupOwnershipError.invalidConfiguration(
        Self.spicetifySelectorsID,
        target,
        "expected one [Setting] table"
      )
    }
    let carriageReturn = editedLines[editedHeaderIndex].hasSuffix("\r") ? "\r" : ""
    var additions = [String]()
    if existingSelection.theme == nil, let themeRawValue {
      additions.append("current_theme = \(themeRawValue)\(carriageReturn)")
    }
    if existingSelection.colorScheme == nil, let colorSchemeRawValue {
      additions.append("color_scheme = \(colorSchemeRawValue)\(carriageReturn)")
    }
    editedLines.insert(contentsOf: additions, at: editedHeaderIndex + 1)
    let installed = Data(editedLines.joined(separator: "\n").utf8)
    let installedSelection = try spicetifySelection(installed, target: target)
    guard installedSelection.theme == expectedTheme,
      installedSelection.colorScheme == expectedColorScheme
    else {
      throw SetupOwnershipError.invalidConfiguration(
        Self.spicetifySelectorsID,
        target,
        "installed selectors are not recognized"
      )
    }
    return installed
  }

  private func replacingSpicetifyValue(
    in line: String,
    with value: String
  ) -> String {
    guard let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return line }
    let valueStart = line.index(after: separator)
    let rawValue = line[valueStart...]
    let contentStart = rawValue.firstIndex { $0 != " " && $0 != "\t" } ?? rawValue.endIndex
    let contentAndTrailingWhitespace = rawValue[contentStart...]
    let contentEnd =
      contentAndTrailingWhitespace.lastIndex {
        $0 != " " && $0 != "\t" && $0 != "\r"
      }.map { contentAndTrailingWhitespace.index(after: $0) }
      ?? contentAndTrailingWhitespace.startIndex
    return String(line[..<contentStart]) + value + String(line[contentEnd...])
  }

  func spicetifySelection(
    _ data: Data,
    target: URL
  ) throws -> SpicetifyAdapter.ConfigurationSelection {
    do {
      return try SpicetifyAdapter.configurationSelection(
        in: String(decoding: data, as: UTF8.self),
        at: target
      )
    } catch {
      throw SetupOwnershipError.invalidConfiguration(
        Self.spicetifySelectorsID,
        target,
        String(describing: error)
      )
    }
  }

  func spicetifySelectionIsDesired(
    _ selection: SpicetifyAdapter.ConfigurationSelection
  ) -> Bool {
    selection.theme == SpicetifyAdapter.themeName
      && selection.colorScheme == SpicetifyAdapter.colorSchemeName
  }

  func spicetifySelectionsEqual(
    _ lhs: SpicetifyAdapter.ConfigurationSelection,
    _ rhs: SpicetifyAdapter.ConfigurationSelection
  ) -> Bool {
    lhs.theme == rhs.theme && lhs.colorScheme == rhs.colorScheme
  }

  private func spicetifySectionName(_ line: String, firstLine: Bool) -> String? {
    var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if firstLine, trimmed.hasPrefix("\u{FEFF}") { trimmed.removeFirst() }
    guard trimmed.hasPrefix("["), let closingBracket = trimmed.lastIndex(of: "]") else {
      return nil
    }
    return String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket])
  }

  private func spicetifyAssignmentKey(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#"),
      let separator = trimmed.firstIndex(where: { $0 == "=" || $0 == ":" })
    else { return nil }
    return trimmed[..<separator].trimmingCharacters(in: .whitespaces)
  }
}
