import Darwin
import Foundation
import TOMLDecoder
import ThemeCore

extension SetupOwnershipManager {
  static let starshipStowConfigurationRelativePath =
    "dotfiles/mac-config/mac-dotfiles/starship/.config/starship.toml"
  static let starshipStowFirstDestination =
    "../\(starshipStowConfigurationRelativePath)"
  static let starshipStowSecondDestination =
    "../../../../../.config/macarchy/\(StarshipAdapter.bridgePath)"

  func setupNeovimWatcher(context: Context) throws -> SetupIntegrationResult {
    let configuration = try readExternalPrerequisite(
      at: context.neovimWatcherConfiguration,
      id: Self.neovimWatcherID
    )
    guard NeovimAdapter.containsIntegrationDirective(in: configuration) else {
      throw SetupOwnershipError.missingExternalDirective(
        Self.neovimWatcherID,
        context.neovimWatcherConfiguration
      )
    }
    return integrationResult(
      id: Self.neovimWatcherID,
      target: context.neovimWatcherConfiguration,
      status: .external,
      message: "The executable Neovim canonical-pointer watcher is externally owned"
    )
  }

  func setupNeovimThemeLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    try setupThemeLink(
      id: Self.neovimThemeLinkID,
      target: context.neovimThemeLink,
      destination: context.neovimThemeDestination,
      label: "Neovim theme",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func setupStarshipBehavior(context: Context) throws -> SetupIntegrationResult {
    if try environmentOwns([.starship], context: context) {
      return integrationResult(
        id: Self.starshipBehaviorID,
        target: context.starshipBehavior,
        status: .external,
        message: "Starship behavior is owned by the aggregate environment lifecycle"
      )
    }
    let configuration = try readExternalPrerequisite(
      at: context.starshipBehavior,
      id: Self.starshipBehaviorID
    )
    let document: TOMLTable
    do {
      document = try TOMLTable(source: configuration)
    } catch {
      throw SetupOwnershipError.invalidConfiguration(
        Self.starshipBehaviorID,
        context.starshipBehavior,
        String(describing: error)
      )
    }
    guard !document.contains(key: "palette"), !document.contains(key: "palettes") else {
      throw SetupOwnershipError.invalidConfiguration(
        Self.starshipBehaviorID,
        context.starshipBehavior,
        "the externally owned behavior source must define neither palette nor palettes"
      )
    }
    return integrationResult(
      id: Self.starshipBehaviorID,
      target: context.starshipBehavior,
      status: .external,
      message: "The palette-free Starship behavior source is externally owned"
    )
  }

  func setupStarshipConfigurationLink(
    context: Context,
    dryRun: Bool,
    records: inout [SetupOwnershipRecord]
  ) throws -> SetupIntegrationResult {
    if try environmentOwns([.starship], context: context) {
      return integrationResult(
        id: Self.starshipConfigurationLinkID,
        target: context.starshipConfigurationLink,
        status: .external,
        message: "Starship configuration is owned by the aggregate environment lifecycle"
      )
    }
    if !records.contains(where: { $0.id == Self.starshipConfigurationLinkID }) {
      guard
        try themeLinkRemovalState(
          id: Self.starshipConfigurationLinkID,
          target: context.starshipConfigurationLink
        ) == .missing
      else {
        throw SetupOwnershipError.ownershipDrift(context.starshipConfigurationLink)
      }
      if try exactTwoHopStarshipConfigurationLinkIsExternal(context: context) {
        return integrationResult(
          id: Self.starshipConfigurationLinkID,
          target: context.starshipConfigurationLink,
          status: .external,
          message: "The exact two-hop Starship bridge link is already externally owned"
        )
      }
    }
    return try setupThemeLink(
      id: Self.starshipConfigurationLinkID,
      target: context.starshipConfigurationLink,
      destination: context.starshipBridgeDestination,
      label: "Starship configuration",
      context: context,
      dryRun: dryRun,
      records: &records
    )
  }

  func teardownNeovimWatcher(context: Context) -> SetupIntegrationResult {
    integrationResult(
      id: Self.neovimWatcherID,
      target: context.neovimWatcherConfiguration,
      status: .none,
      message: "The externally owned Neovim watcher is not a teardown target"
    )
  }

  func teardownStarshipBehavior(context: Context) -> SetupIntegrationResult {
    integrationResult(
      id: Self.starshipBehaviorID,
      target: context.starshipBehavior,
      status: .none,
      message: "The externally owned Starship behavior source is not a teardown target"
    )
  }

  private func exactTwoHopStarshipConfigurationLinkIsExternal(
    context: Context
  ) throws -> Bool {
    let firstDestination: String
    switch try themeLinkState(
      id: Self.starshipConfigurationLinkID,
      url: context.starshipConfigurationLink,
      target: context.starshipConfigurationLink
    ) {
    case .matching(let destination):
      firstDestination = destination
    case .missing, .other:
      return false
    }

    guard firstDestination == Self.starshipStowFirstDestination else { return false }
    let secondDestination: String
    switch try themeLinkState(
      id: Self.starshipConfigurationLinkID,
      url: context.starshipStowConfigurationLink,
      target: context.starshipConfigurationLink
    ) {
    case .matching(let destination):
      secondDestination = destination
    case .missing, .other:
      return false
    }
    return secondDestination == Self.starshipStowSecondDestination
  }

  private func readExternalPrerequisite(at url: URL, id: String) throws -> String {
    let data: Data
    do {
      data = try BoundedRegularFile.read(
        at: url,
        maximumSize: Self.maximumConfigurationSize
      ).data
    } catch BoundedRegularFileError.tooLarge {
      throw SetupOwnershipError.configurationTooLarge(id, url)
    } catch BoundedRegularFileError.system(operation: "open", code: ENOENT) {
      throw SetupOwnershipError.missingConfiguration(id, url)
    } catch BoundedRegularFileError.notRegular,
      BoundedRegularFileError.system(operation: "open", code: ELOOP)
    {
      throw SetupOwnershipError.invalidConfiguration(
        id,
        url,
        "the final path must be an ordinary regular file"
      )
    } catch {
      throw SetupOwnershipError.system(
        "read externally owned prerequisite for \(id)",
        url,
        String(describing: error)
      )
    }
    guard let configuration = String(data: data, encoding: .utf8) else {
      throw SetupOwnershipError.unreadableConfiguration(id, url)
    }
    return configuration
  }
}
