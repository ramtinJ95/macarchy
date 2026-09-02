import Darwin
import Foundation
import ThemeCore

extension SetupOwnershipManager {
  func setupBtopSelector(context: Context) throws -> SetupIntegrationResult {
    if try environmentOwns([.btopConfiguration], context: context) {
      return integrationResult(
        id: Self.btopSelectorID,
        target: context.btopConfiguration,
        status: .external,
        message: "btop keys are owned by the aggregate environment lifecycle"
      )
    }
    let exactLine = BtopAdapter.themeDirective
    let configuration = try readConfiguration(
      context.btopConfiguration,
      id: Self.btopSelectorID
    )
    guard
      try exactLineIsExternal(
        configuration,
        exactLine: exactLine,
        id: Self.btopSelectorID,
        target: context.btopConfiguration,
        isRelevantLine: Self.isBtopThemeDirective
      )
    else {
      throw SetupOwnershipError.missingExternalDirective(
        Self.btopSelectorID,
        context.btopConfiguration
      )
    }
    return integrationResult(
      id: Self.btopSelectorID,
      target: context.btopConfiguration,
      status: .external,
      message: "The exact btop selector is externally owned"
    )
  }

  func setupBtopThemeLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    if try environmentOwns([.btopTheme], context: context) {
      return integrationResult(
        id: Self.btopThemeLinkID,
        target: context.btopThemeLink,
        status: .external,
        message: "The btop theme seam is owned by the aggregate environment lifecycle"
      )
    }
    return try setupThemeLink(
      id: Self.btopThemeLinkID,
      target: context.btopThemeLink,
      destination: context.btopThemeDestination,
      label: "btop theme",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupYaziSelector(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    if try environmentOwns([.yaziThemeSelection], context: context) {
      return integrationResult(
        id: Self.yaziSelectorID,
        target: context.yaziConfiguration,
        status: .external,
        message: "Yazi theme selection is owned by the aggregate environment lifecycle"
      )
    }
    return try setupTOMLSelector(
      id: Self.yaziSelectorID,
      target: context.yaziConfiguration,
      backupURL: context.yaziSelectorBackup,
      replacementName: context.yaziSelectorReplacementName,
      label: "Yazi flavor selector",
      table: YaziAdapter.selectionTable,
      key: YaziAdapter.selectionKey,
      value: YaziAdapter.flavorName,
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupYaziFlavorLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    if try environmentOwns([.yaziFlavor], context: context) {
      return integrationResult(
        id: Self.yaziFlavorLinkID,
        target: context.yaziFlavorLink,
        status: .external,
        message: "The Yazi flavor seam is owned by the aggregate environment lifecycle"
      )
    }
    if !records.contains(where: { $0.id == Self.yaziFlavorLinkID }) {
      var metadata = stat()
      let result = stat(context.yaziFlavorDirectory.path, &metadata)
      if result != 0 {
        let errorNumber = errno
        guard errorNumber == ENOENT || errorNumber == ENOTDIR else {
          throw SetupOwnershipError.system(
            "inspect Yazi flavor directory",
            context.yaziFlavorDirectory,
            String(cString: strerror(errorNumber))
          )
        }
        throw SetupOwnershipError.missingIntegrationParent(
          Self.yaziFlavorLinkID,
          context.yaziFlavorDirectory
        )
      }
      guard metadata.st_mode & S_IFMT == S_IFDIR else {
        throw SetupOwnershipError.missingIntegrationParent(
          Self.yaziFlavorLinkID,
          context.yaziFlavorDirectory
        )
      }
    }
    return try setupThemeLink(
      id: Self.yaziFlavorLinkID,
      target: context.yaziFlavorLink,
      destination: context.yaziFlavorDestination,
      label: "Yazi flavor",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupYaziSyntaxLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    if try environmentOwns([.yaziSyntax], context: context) {
      return integrationResult(
        id: Self.yaziSyntaxLinkID,
        target: context.yaziSyntaxLink,
        status: .external,
        message: "The Yazi syntax seam is owned by the aggregate environment lifecycle"
      )
    }
    return try setupThemeLink(
      id: Self.yaziSyntaxLinkID,
      target: context.yaziSyntaxLink,
      destination: context.yaziSyntaxDestination,
      label: "Yazi syntax theme",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupAtuinSelector(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    if try environmentOwns([.atuinConfiguration], context: context) {
      return integrationResult(
        id: Self.atuinSelectorID,
        target: context.atuinConfiguration,
        status: .external,
        message: "Atuin configuration is owned by the aggregate environment lifecycle"
      )
    }
    return try setupTOMLSelector(
      id: Self.atuinSelectorID,
      target: context.atuinConfiguration,
      backupURL: context.atuinSelectorBackup,
      replacementName: context.atuinSelectorReplacementName,
      label: "Atuin theme selector",
      table: AtuinAdapter.selectionTable,
      key: AtuinAdapter.selectionKey,
      value: AtuinAdapter.themeName,
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupAtuinThemeLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    if try environmentOwns([.atuinConfiguration, .atuinTheme], context: context) {
      return integrationResult(
        id: Self.atuinThemeLinkID,
        target: context.atuinThemeLink,
        status: .external,
        message: "The Atuin theme seam is managed by the aggregate environment lifecycle"
      )
    }
    return try setupThemeLink(
      id: Self.atuinThemeLinkID,
      target: context.atuinThemeLink,
      destination: context.atuinThemeDestination,
      label: "Atuin theme",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  static func isBtopThemeDirective(_ line: String) -> Bool {
    let parts = line.split(separator: "=", maxSplits: 1).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    return parts.first == "color_theme"
  }
}
