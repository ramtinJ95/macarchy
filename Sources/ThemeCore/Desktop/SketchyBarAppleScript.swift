import Foundation

/// The separate Apple-menu helper executable the bar's Apple item runs.
package enum AppleMenuHelper {
  package static let executableName = "macarchy-menu"
}

enum SketchyBarAppleScript {
  static func render(palettePath: String, helperPath: String) -> String {
    """
    #!/bin/sh
    set -eu
    [ "${NAME-}" = macarchy.apple ] || exit 1
    . \(DesktopShellSyntax.literal(palettePath))
    if [ "${SENDER-}" = macarchy_permission_check ]; then
      case "${MACARCHY_PERMISSION_TOKEN-}" in
        ''|*[!a-f0-9-]*) exit 1 ;;
      esac
    fi
    ACTION=--check
    if [ "${SENDER-}" = mouse.clicked ]; then ACTION=--open-apple-menu; fi
    if [ "${SENDER-}" = macarchy_permission_check ] && [ "${MACARCHY_PERMISSION_REQUEST_AX-0}" = 1 ]; then
      ACTION=--request-accessibility
    fi
    STATUS=0
    if \(DesktopShellSyntax.literal(helperPath)) "$ACTION"; then
      /opt/homebrew/bin/sketchybar --set macarchy.apple label= label.drawing=off icon.color="$MACARCHY_TEXT_COLOR"
    else
      echo 'Macarchy: Apple-menu helper failed; check desktop doctor and manual Accessibility setup' >&2
      /opt/homebrew/bin/sketchybar --set macarchy.apple label='Menu ERR' label.drawing=on label.color="$MACARCHY_BATTERY_RED" icon.color="$MACARCHY_BATTERY_RED" || echo 'Macarchy: Apple-menu error presentation also failed' >&2
      STATUS=1
      # Still run the nonprompting Automation probe below when AX access is missing.
    fi
    if [ "${SENDER-}" = macarchy_permission_check ]; then
      MACARCHY=\(DesktopShellSyntax.literal(URL(filePath: helperPath).deletingLastPathComponent().appending(path: "macarchy").path))
      if "$MACARCHY" setup check-appearance; then RESULT=granted; else RESULT=missing; fi
      /opt/homebrew/bin/sketchybar --set macarchy.theme.ready label="permission:$RESULT:$MACARCHY_PERMISSION_TOKEN"
    fi
    exit "$STATUS"

    """
  }
}
