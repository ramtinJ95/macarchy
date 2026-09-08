import Foundation

enum SketchyBarWiFiScript {
  static func render(palettePath: String, macarchyExecutablePath: String) -> String {
    """
    #!/bin/sh
    set -eu
    : "${NAME:?SketchyBar did not provide an item name}"
    PALETTE=\(SketchyBarConfigurationComposer.shellLiteral(palettePath))
    . "$PALETTE"
    exec \(SketchyBarConfigurationComposer.shellLiteral(macarchyExecutablePath)) desktop _wifi \\
      --name "$NAME" --sender "${SENDER:-routine}" \\
      --text-color "$MACARCHY_TEXT_COLOR" --accent-color "$MACARCHY_ACCENT_COLOR" \\
      --muted-color "$MACARCHY_MUTED_COLOR" --error-color "$MACARCHY_BATTERY_RED"

    """
  }
}
