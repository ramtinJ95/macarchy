import Foundation
import ThemeCore

struct EnvironmentVSCodeOwnership: Codable, Equatable, Sendable {
  let editor: VSCodeEditor
  let installation: VSCodeEditor.Installation
  let path: String
  let originalFileExisted: Bool
  let autoDetect: Bool
  let originalMembers: [String: Data]
  let initialVersion: String

  var keys: [String] {
    autoDetect
      ? ["workbench.preferredDarkColorTheme", "workbench.preferredLightColorTheme"]
      : ["workbench.colorTheme"]
  }

  var hasValidShape: Bool {
    guard editor.installations.contains(installation), path.hasPrefix("/"),
      originalFileExisted || originalMembers.isEmpty,
      Set(originalMembers.keys).isSubset(of: Set(keys)),
      initialVersion.hasPrefix("1.0."), UInt32(initialVersion.dropFirst(4)) != nil
    else { return false }
    return originalMembers.allSatisfy { key, bytes in
      guard
        bytes.count <= BoundedRegularFile.maximumSize,
        let parsed = try? Self.document(
          Data("{".utf8) + bytes + Data("}".utf8), at: URL(filePath: path))
      else { return false }
      return parsed.members.count == 1 && parsed.memberBytes(key) == Array(bytes)
    }
  }

  static func document(_ data: Data, at url: URL) throws -> JSONCObjectDocument {
    try JSONCObjectDocument(data: data, id: "vscode_configuration", target: url)
  }

  static func automatic(_ document: JSONCObjectDocument) -> Bool {
    guard let member = document.member("window.autoDetectColorScheme") else { return false }
    return String(decoding: document.bytes[member.valueRange], as: UTF8.self) == "true"
  }

  static func adopting(
    _ data: Data?, editor: VSCodeEditor, installation: VSCodeEditor.Installation,
    home: URL, initialVersion: String
  ) throws -> Self {
    let url = installation.settings(home: home)
    let parsed = try document(data ?? Data("{}".utf8), at: url)
    let automatic = automatic(parsed)
    let keys =
      automatic
      ? ["workbench.preferredDarkColorTheme", "workbench.preferredLightColorTheme"]
      : ["workbench.colorTheme"]
    return Self(
      editor: editor, installation: installation, path: url.path,
      originalFileExisted: data != nil, autoDetect: automatic,
      originalMembers: Dictionary(
        uniqueKeysWithValues: keys.compactMap { key in
          parsed.memberBytes(key).map { (key, Data($0)) }
        }), initialVersion: initialVersion)
  }
}

extension EnvironmentVSCodeOwnership: EnvironmentPresetFileOwnership {
  static let filesystem = EnvironmentPresetFilesystem(
    configurationLabel: "VS Code-family settings",
    residueLabel: "VS Code-family settings transaction residue",
    nonRegularMessage: "VS Code-family settings are not an ordinary file")
  static let driftLabel = "VS Code family"
  static let ownershipChangedMessage = "VS Code-family settings ownership changed unexpectedly"
  static let replacementLabel = "VS Code-family color-theme members"
  static let replacementFailureLabel: String? = nil

  private func managedMember(_ key: String) -> [UInt8] { Array("\"\(key)\": \"Macarchy\"".utf8) }

  func managed(from current: Data?, at url: URL) throws -> Data {
    var result = current ?? Data("{}\n".utf8)
    guard try Self.automatic(Self.document(result, at: url)) == autoDetect else {
      throw VSCodeAdapter.Failure.drift
    }
    for key in keys.reversed() {
      let parsed = try Self.document(result, at: url)
      result =
        parsed.replacingMember(key, with: managedMember(key))
        ?? parsed.insertingFirstMember(managedMember(key))
    }
    return try bounded(result)
  }

  func matchesManaged(_ data: Data, at url: URL) throws -> Bool {
    let parsed = try Self.document(data, at: url)
    return Self.automatic(parsed) == autoDetect
      && keys.allSatisfy { parsed.memberBytes($0) == managedMember($0) }
  }

  func restored(in current: Data, at url: URL) throws -> Data? {
    guard try matchesManaged(current, at: url) else { throw VSCodeAdapter.Failure.drift }
    var result = current
    for key in keys {
      let parsed = try Self.document(result, at: url)
      result =
        originalMembers[key].flatMap { parsed.replacingMember(key, with: Array($0)) }
        ?? parsed.removingMember(key)!
    }
    if !originalFileExisted, try Self.document(result, at: url).members.isEmpty { return nil }
    return try bounded(result)
  }

  func matchesOriginal(_ data: Data?, at url: URL) throws -> Bool {
    guard let data else { return !originalFileExisted }
    let parsed = try Self.document(data, at: url)
    return Self.automatic(parsed) == autoDetect
      && keys.allSatisfy { parsed.memberBytes($0) == originalMembers[$0].map { Array($0) } }
  }

  private func bounded(_ data: Data) throws -> Data {
    guard data.count <= BoundedRegularFile.maximumSize else {
      throw EnvironmentLifecycleError.blocked(
        "VS Code-family settings edit exceeds the bounded size")
    }
    return data
  }

  func adapter(root: URL, home: URL, runner: ProcessRunner = .live) -> VSCodeAdapter {
    VSCodeAdapter(
      editor: editor, root: root, home: home, runner: runner, validateOwnership: { _, _ in })
  }
}

extension EnvironmentProviderInspector {
  func inspectVSCode(
    editor: VSCodeEditor, enabled: Bool, ownership: EnvironmentVSCodeOwnership?, home: URL,
    root: URL
  )
    throws -> KeyOwnedInspection<EnvironmentVSCodeOwnership>
  {
    guard enabled || ownership != nil else { return (nil, nil, nil) }
    let installation = try enabled ? vscodeDiscover(editor) : ownership!.installation
    if let ownership, ownership.installation != installation { throw VSCodeAdapter.Failure.drift }
    let url = installation.settings(home: home)
    guard try !hasSymlinkAncestor(url, stoppingAt: home) else {
      throw EnvironmentLifecycleError.blocked("\(editor.label) requires an ordinary settings path")
    }
    let evidence = try capture(url, directoryLink: nil)
    let current = try EnvironmentVSCodeOwnership.filesystem.read(url)
    let installed = try VSCodeAdapter.installedVersion(cli: installation.cli, runner: vscodeRunner)
    if ownership == nil, installed != nil {
      throw EnvironmentLifecycleError.blocked(
        "\(editor.label) already has macarchy.macarchy-theme without Macarchy ownership; refusing adoption"
      )
    }
    let proposed: EnvironmentVSCodeOwnership
    let status: EnvironmentInspectionStatus
    if let ownership {
      proposed = ownership
      try ownership.adapter(root: root, home: home, runner: vscodeRunner).authenticate(
        version: installed, installation: installation, initialVersion: ownership.initialVersion)
      let matches = try current.map { try ownership.matchesManaged($0, at: url) } ?? false
      status = matches ? (enabled ? .managed : .restorationRequired) : .drifted
    } else {
      let theme =
        try bootstrapTheme.map { try VSCodeTheme.render(package: $0) }
        ?? VSCodeTheme.active(root: root)
      proposed = try .adopting(
        current, editor: editor, installation: installation, home: home,
        initialVersion: theme.version)
      status = current == nil ? .installRequired : .adoptionRequired
    }
    let profiles = try VSCodeAdapter.profiles(installation: installation, home: home)
    return (
      EnvironmentEntryInspection(
        id: "\(editor.rawValue)_configuration", path: url.path,
        status: status, ownership: ownership == nil ? "external" : "macarchy",
        message:
          "\(editor.label): selected \(installation.application).app; own only \(proposed.keys.joined(separator: ", ")). Workspace settings can override."
          + (profiles.isEmpty
            ? "" : " Non-default profiles with settings: \(profiles.joined(separator: ", "))."),
        evidence: evidence),
      enabled ? proposed : nil, ownership == nil ? evidence : nil
    )
  }
}
