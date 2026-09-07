import Foundation

package enum BordersConfiguration {
  package static let artifactPath = "borders/bordersrc"

  /// Native Borders invokes this at startup. It reads the authoritative pointer;
  /// the environment generation intentionally contains no copied palette.
  package static func contents(stateRoot: URL) -> String {
    let themePath = stateRoot.appending(path: "current/theme.json").path
      .replacingOccurrences(of: "'", with: "'\"'\"'")
    return """
      #!/bin/sh
      # Macarchy-owned; generated from the applied focus-ring role.
      set -eu
      accent=$(/usr/bin/plutil -extract semantic.accent raw -o - '\(themePath)')
      case "$accent" in
        \\#??????) ;;
        *) echo 'Borders: canonical accent is not a six-digit color' >&2; exit 1 ;;
      esac
      color=${accent#\\#}
      case "$color" in
        *[!0-9a-fA-F]*) echo 'Borders: canonical accent is not hexadecimal' >&2; exit 1 ;;
      esac
      exec \(BordersService.executableURL.path) "active_color=0xff$color" \(BordersPalette.appearanceArguments.joined(separator: " "))

      """
  }
}
