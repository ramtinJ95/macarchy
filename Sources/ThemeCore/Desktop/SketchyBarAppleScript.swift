import Foundation

/// The separate Apple-menu helper executable the bar's Apple item runs.
package enum AppleMenuHelper {
  package static let executableName = "macarchy-menu"
}

enum SketchyBarAppleScript {
  static func render(palettePath: String, helperPath: String) -> String {
    """
    #!/bin/zsh -f
    set -eu
    [ "${NAME-}" = macarchy.apple ] || exit 1
    . \(DesktopShellSyntax.literal(palettePath))
    if [ "${SENDER-}" = macarchy_permission_check ]; then
      case "${MACARCHY_PERMISSION_TOKEN-}" in
        ''|*[!a-f0-9-]*) exit 1 ;;
      esac
      # Built-in high-resolution timestamps; no extra executable or user startup files.
      zmodload zsh/datetime
      MACARCHY=\(DesktopShellSyntax.literal(URL(filePath: helperPath).deletingLastPathComponent().appending(path: "macarchy").path))
      # Separate properties on the existing hidden item prevent either stage from
      # gating or overwriting the other's result. Never infer AX from a visual label.
      (
        START=$EPOCHREALTIME
        /opt/homebrew/bin/sketchybar --set macarchy.theme.ready icon="permission:v2:${MACARCHY_PERMISSION_TOKEN}:running:${START}:0:-1"
        RESULT=0
        "$MACARCHY" setup check-appearance --json || RESULT=$?
        FINISH=$EPOCHREALTIME
        echo "Macarchy permission stage=automation token=$MACARCHY_PERMISSION_TOKEN start=$START end=$FINISH exit=$RESULT" >&2
        /opt/homebrew/bin/sketchybar --set macarchy.theme.ready icon="permission:v2:${MACARCHY_PERMISSION_TOKEN}:complete:${START}:${FINISH}:${RESULT}"
      ) &
      AX_START=$EPOCHREALTIME
      /opt/homebrew/bin/sketchybar --set macarchy.theme.ready label="permission:v2:${MACARCHY_PERMISSION_TOKEN}:running:${AX_START}:0:-1"
    fi
    ACTION=--check
    if [ "${SENDER-}" = mouse.clicked ]; then ACTION=--open-apple-menu; fi
    if [ "${SENDER-}" = macarchy_permission_check ] && [ "${MACARCHY_PERMISSION_REQUEST_AX-0}" = 1 ]; then
      ACTION=--request-accessibility
    fi
    STATUS=0
    \(DesktopShellSyntax.literal(helperPath)) "$ACTION" || STATUS=$?
    if [ "${SENDER-}" = macarchy_permission_check ]; then
      AX_FINISH=$EPOCHREALTIME
      echo "Macarchy permission stage=ax token=$MACARCHY_PERMISSION_TOKEN start=$AX_START end=$AX_FINISH exit=$STATUS" >&2
      /opt/homebrew/bin/sketchybar --set macarchy.theme.ready label="permission:v2:${MACARCHY_PERMISSION_TOKEN}:complete:${AX_START}:${AX_FINISH}:${STATUS}"
    fi
    if [ "$STATUS" = 0 ]; then
      /opt/homebrew/bin/sketchybar --set macarchy.apple label= label.drawing=off icon.color="$MACARCHY_TEXT_COLOR" || echo 'Macarchy: Apple-menu success presentation failed' >&2
    else
      echo 'Macarchy: Apple-menu helper failed; check desktop doctor and manual Accessibility setup' >&2
      /opt/homebrew/bin/sketchybar --set macarchy.apple label='Menu ERR' label.drawing=on label.color="$MACARCHY_BATTERY_RED" icon.color="$MACARCHY_BATTERY_RED" || echo 'Macarchy: Apple-menu error presentation also failed' >&2
    fi
    if [ "${SENDER-}" = macarchy_permission_check ]; then
      wait
    fi
    exit "$STATUS"

    """
  }
}
