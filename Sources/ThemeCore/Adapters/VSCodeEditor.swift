import Foundation

package enum VSCodeEditor: String, CaseIterable, Codable, Sendable {
  case vscode, cursor, vscodium, windsurf

  package var label: String {
    switch self {
    case .vscode: "VS Code"
    case .cursor: "Cursor"
    case .vscodium: "VSCodium"
    case .windsurf: "Windsurf (Devin Desktop)"
    }
  }

  package struct Installation: Codable, Equatable, Sendable {
    package let application: String
    package let cliName: String
    package let supportDirectory: String

    package var applicationURL: URL { URL(filePath: "/Applications/\(application).app") }
    package var cli: URL { applicationURL.appending(path: "Contents/Resources/app/bin/\(cliName)") }
    package func settings(home: URL) -> URL {
      home.appending(path: "Library/Application Support/\(supportDirectory)/User/settings.json")
    }
  }

  package var installations: [Installation] {
    switch self {
    case .vscode:
      [.init(application: "Visual Studio Code", cliName: "code", supportDirectory: "Code")]
    case .cursor: [.init(application: "Cursor", cliName: "code", supportDirectory: "Cursor")]
    case .vscodium:
      [.init(application: "VSCodium", cliName: "codium", supportDirectory: "VSCodium")]
    case .windsurf:
      [
        .init(application: "Devin", cliName: "devin-desktop", supportDirectory: "Devin"),
        .init(application: "Windsurf", cliName: "windsurf", supportDirectory: "Windsurf"),
      ]
    }
  }

  package func discover(
    exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
    executable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
  ) throws -> Installation {
    let present = installations.filter { exists($0.applicationURL) }
    guard present.count <= 1 else {
      throw VSCodeAdapter.Failure.blocked(
        "Both Devin.app and Windsurf.app are installed; select one installation before adopting the windsurf preset."
      )
    }
    guard let selected = present.first else {
      throw AdapterConfigurationError.controlUnavailable(label, installations[0].applicationURL)
    }
    guard executable(selected.cli) else {
      throw AdapterConfigurationError.controlUnavailable("\(label) bundled CLI", selected.cli)
    }
    return selected
  }

  package var runtimeKind: RuntimeAdapterKind {
    switch self {
    case .vscode: .vscode
    case .cursor: .cursor
    case .vscodium: .vscodium
    case .windsurf: .windsurf
    }
  }
}
