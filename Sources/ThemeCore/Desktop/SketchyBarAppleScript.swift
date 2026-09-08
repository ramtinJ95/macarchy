import Foundation

enum SketchyBarAppleScript {
  static func render(palettePath: String, helperPath: String) -> String {
    """
    #!/bin/sh
    set -eu
    [ "${NAME-}" = macarchy.apple ] || exit 1
    . \(SketchyBarConfigurationComposer.shellLiteral(palettePath))
    if [ "${SENDER-}" = mouse.clicked ]; then ACTION=--open-apple-menu; else ACTION=--check; fi
    if \(SketchyBarConfigurationComposer.shellLiteral(helperPath)) "$ACTION"; then
      /opt/homebrew/bin/sketchybar --set macarchy.apple label= label.drawing=off icon.color="$MACARCHY_TEXT_COLOR"
    else
      echo 'Macarchy: Apple-menu helper failed; check desktop doctor and manual Accessibility setup' >&2
      /opt/homebrew/bin/sketchybar --set macarchy.apple label='Menu ERR' label.drawing=on label.color="$MACARCHY_BATTERY_RED" icon.color="$MACARCHY_BATTERY_RED" || echo 'Macarchy: Apple-menu error presentation also failed' >&2
      exit 1
    fi

    """
  }
}
