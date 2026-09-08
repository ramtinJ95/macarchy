import Foundation

enum SketchyBarBatteryScript {
  static func render(palettePath: String) -> String {
    """
    #!/bin/sh
    set -eu
    : "${NAME:?SketchyBar did not provide an item name}"
    SKETCHYBAR=/opt/homebrew/bin/sketchybar
    case "${SENDER-}" in
      mouse.clicked) "$SKETCHYBAR" --set "$NAME" popup.drawing=toggle; exit ;;
      mouse.exited.global) "$SKETCHYBAR" --set "$NAME" popup.drawing=off; exit ;;
    esac
    PALETTE=\(SketchyBarConfigurationComposer.shellLiteral(palettePath))
    . "$PALETTE"
    fail() {
      "$SKETCHYBAR" --set "$NAME" label=ERR icon='!' icon.color="$MACARCHY_BATTERY_RED" \\
        --set macarchy.battery.remaining label='Battery query failed'
      echo 'cannot read system battery state' >&2
      exit 1
    }
    RAW=$(/usr/bin/pmset -g batt) || fail
    STATE=$(printf '%s\\n' "$RAW" | /usr/bin/awk '
      NR == 1 {
        q = sprintf("%c", 39)
        if ($0 != "Now drawing from " q "AC Power" q && $0 != "Now drawing from " q "Battery Power" q) exit 1
        ac = ($0 ~ /AC Power/); next
      }
      /^[[:space:]]*$/ { next }
      {
        if ($0 !~ /^[[:space:]]*-InternalBattery-/ || ++batteries != 1) exit 1
        if (!match($0, /[[:space:]][0-9]+%;/)) exit 1
        level = substr($0, RSTART + 1, RLENGTH - 3) + 0
        if (level > 100) exit 1
        estimate = "No estimate"
        if (match($0, /[0-9]+:[0-5][0-9]/)) estimate = substr($0, RSTART, RLENGTH) "h"
      }
      END {
        if (NR == 1 && ac) print "-1|1|No battery"
        else if (batteries == 1 && level <= 100) printf "%d|%d|%s\\n", level, ac, estimate
        else exit 1
      }
    ') || fail
    IFS='|' read -r LEVEL AC ESTIMATE <<EOF
    $STATE
    EOF
    COLOR=$MACARCHY_BATTERY_GREEN
    if [ "$LEVEL" -eq -1 ]; then
      LABEL='No battery'; ICON='􀟛'; COLOR=$MACARCHY_MUTED_COLOR
    else
      LABEL=$(printf '%02d%%' "$LEVEL")
      if [ "$LEVEL" -gt 80 ]; then ICON='􀛨'
      elif [ "$LEVEL" -gt 60 ]; then ICON='􀺸'
      elif [ "$LEVEL" -gt 40 ]; then ICON='􀺶'
      elif [ "$LEVEL" -gt 20 ]; then ICON='􀛩'; COLOR=$MACARCHY_BATTERY_ORANGE
      else ICON='􀛪'; COLOR=$MACARCHY_BATTERY_RED
      fi
      if [ "$AC" -eq 1 ]; then ICON='􀢋'; fi
    fi
    "$SKETCHYBAR" --set "$NAME" label="$LABEL" icon="$ICON" icon.color="$COLOR" \\
      --set macarchy.battery.remaining label="$ESTIMATE"

    """
  }
}
