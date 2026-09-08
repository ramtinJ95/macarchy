import Foundation

enum SketchyBarMediaScript {
  static func render(palettePath: String, macarchyExecutablePath: String) -> String {
    """
    #!/bin/sh
    set -eu
    . \(SketchyBarConfigurationComposer.shellLiteral(palettePath))
    if \(SketchyBarConfigurationComposer.shellLiteral(macarchyExecutablePath)) desktop _media --name "${NAME-}" --sender "${SENDER-forced}"; then
      /opt/homebrew/bin/sketchybar --set macarchy.media icon.color="$MACARCHY_TEXT_COLOR"
    else
      echo 'Macarchy: nowplaying-cli metadata or playback control failed' >&2
      /opt/homebrew/bin/sketchybar --set macarchy.media drawing=on label.drawing=on label=ERR label.color="$MACARCHY_BATTERY_RED" popup.drawing=off --set macarchy.media.artist drawing=off --set macarchy.media.title drawing=off || echo 'Macarchy: media error presentation also failed' >&2
      exit 1
    fi

    """
  }
}
