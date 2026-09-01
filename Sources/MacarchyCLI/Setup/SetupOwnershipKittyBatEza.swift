import Foundation
import ThemeCore

extension SetupOwnershipManager {
  func setupKitty(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupRegularFile(
      id: Self.integrationID,
      target: context.kittyConfiguration,
      backupURL: context.backupURL,
      replacementName: context.replacementName,
      label: "Kitty include",
      read: { try readConfiguration($0) },
      isExternal: { try hasValidExternalInclude($0, context: context) },
      installedData: { addingLine($0, context.includeDirective) },
      externalOwnershipError: .kittyConfigurationIsExternallyOwned(context.kittyConfiguration),
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupBatSelector(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    let exactLine = BatAdapter.themeDirective
    return try setupRegularFile(
      id: Self.batSelectorID,
      target: context.batConfiguration,
      backupURL: context.batSelectorBackup,
      replacementName: context.batSelectorReplacementName,
      label: "bat selector",
      read: { try readConfiguration($0, id: Self.batSelectorID) },
      isExternal: { data in
        try exactLineIsExternal(
          data,
          exactLine: exactLine,
          id: Self.batSelectorID,
          target: context.batConfiguration,
          isRelevantLine: { $0.hasPrefix("--theme=") || $0.hasPrefix("--theme ") }
        )
      },
      installedData: { addingLine($0, exactLine) },
      externalOwnershipError: .configurationIsExternallyOwned(
        Self.batSelectorID,
        context.batConfiguration
      ),
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupBatThemeLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupThemeLink(
      id: Self.batThemeLinkID,
      target: context.batThemeLink,
      destination: context.batThemeDestination,
      label: "bat theme",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupEzaEnvironment(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    let exactLine = EzaAdapter.environmentDirective(
      configurationDirectoryURL: context.ezaThemeLink.deletingLastPathComponent()
    )
    return try setupRegularFile(
      id: Self.ezaEnvironmentID,
      target: context.shellConfiguration,
      backupURL: context.ezaEnvironmentBackup,
      replacementName: context.ezaEnvironmentReplacementName,
      label: "eza environment",
      read: { try readConfiguration($0, id: Self.ezaEnvironmentID) },
      isExternal: { data in
        try exactLineIsExternal(
          data,
          exactLine: exactLine,
          id: Self.ezaEnvironmentID,
          target: context.shellConfiguration,
          isRelevantLine: Self.isEzaEnvironmentDirective
        )
      },
      installedData: { addingLine($0, exactLine) },
      externalOwnershipError: .configurationIsExternallyOwned(
        Self.ezaEnvironmentID,
        context.shellConfiguration
      ),
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupEzaThemeLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupThemeLink(
      id: Self.ezaThemeLinkID,
      target: context.ezaThemeLink,
      destination: context.ezaThemeDestination,
      label: "eza theme",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  static func isEzaEnvironmentDirective(_ line: String) -> Bool {
    var assignment = line[...]
    let fields = assignment.split(
      maxSplits: 1,
      omittingEmptySubsequences: true,
      whereSeparator: { $0.isWhitespace }
    )
    if fields.first == "export" {
      guard fields.count == 2 else { return false }
      assignment = fields[1]
    }
    guard assignment.hasPrefix("EZA_CONFIG_DIR") else { return false }
    let suffix = assignment.dropFirst("EZA_CONFIG_DIR".count)
    guard let first = suffix.first else { return false }
    return first == "=" || first.isWhitespace
  }

  func hasValidExternalInclude(_ data: Data, context: Context) throws -> Bool {
    let configuration = String(decoding: data, as: UTF8.self)
    let targets = configuration.components(separatedBy: .newlines).compactMap { line in
      includeTarget(line, context: context)
    }
    let macarchyTargets = targets.filter { target in
      target.path == context.stateRoot.path
        || target.path.hasPrefix(context.stateRoot.path + "/")
    }
    let expectedCount = macarchyTargets.count { $0.path == context.bridgeURL.path }
    if expectedCount > 1 || macarchyTargets.count != expectedCount {
      throw SetupOwnershipError.conflictingKittyInclude(context.kittyConfiguration)
    }
    return expectedCount == 1
  }

  func includeTarget(_ line: String, context: Context) -> URL? {
    let fields = line.split(
      maxSplits: 1,
      omittingEmptySubsequences: true,
      whereSeparator: { $0.isWhitespace }
    )
    guard fields.count == 2, fields[0] == "include" else { return nil }
    var path = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    if (path.hasPrefix("\"") && path.hasSuffix("\""))
      || (path.hasPrefix("'") && path.hasSuffix("'"))
    {
      path.removeFirst()
      path.removeLast()
    }
    if path.hasPrefix("~/") {
      return context.homeDirectory.appending(path: String(path.dropFirst(2))).standardizedFileURL
    }
    if path.hasPrefix("/") {
      return URL(filePath: path).standardizedFileURL
    }
    return context.kittyConfiguration.deletingLastPathComponent()
      .appending(path: path).standardizedFileURL
  }
}
