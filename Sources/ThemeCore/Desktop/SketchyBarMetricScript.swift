import Foundation

enum SketchyBarMetricScript {
  static func render(module: SketchyBarModule, palettePath: String, macarchyExecutablePath: String)
    -> String
  {
    precondition(module == .cpu || module == .memory)
    let cpu = module == .cpu
    let query =
      cpu
      ? "\(SketchyBarConfigurationComposer.shellLiteral(macarchyExecutablePath)) desktop _cpu-load"
      : "/usr/bin/memory_pressure"
    let parser =
      cpu
      ? #"{ if ($0 !~ /^[0-9]+$/ || $0 + 0 > 100 || ++count != 1) exit 1; value = $0 + 0 } END { if (count != 1) exit 1; printf "%d\n", value }"#
      : #"/^System-wide memory free percentage:/ { if (NF != 5 || $5 !~ /^[0-9]+%$/ || $5 + 0 > 100 || ++count != 1) exit 1; value = 100 - $5 } END { if (count != 1) exit 1; printf "%d\n", value }"#
    return """
      #!/bin/sh
      set -eu
      export LC_ALL=C
      : "${NAME:?SketchyBar did not provide an item name}"
      SKETCHYBAR=/opt/homebrew/bin/sketchybar
      PALETTE=\(SketchyBarConfigurationComposer.shellLiteral(palettePath))
      . "$PALETTE"
      fail() {
        "$SKETCHYBAR" --set "$NAME" label='\(cpu ? "cpu" : "mem") ERR' label.color="$MACARCHY_BATTERY_RED"
        echo 'cannot read system \(module.rawValue) utilization' >&2
        exit 1
      }
      RAW=$(\(query)) || fail
      LEVEL=$(printf '%s\\n' "$RAW" | /usr/bin/awk '\(parser)') || fail
      COLOR=$MACARCHY_ACCENT_COLOR
      if [ "$LEVEL" -ge \(cpu ? 80 : 85) ]; then COLOR=$MACARCHY_BATTERY_RED
      elif [ "$LEVEL" -ge \(cpu ? 60 : 70) ]; then COLOR=$MACARCHY_BATTERY_ORANGE
      elif [ "$LEVEL" -ge \(cpu ? 30 : 50) ]; then COLOR=$MACARCHY_WARNING_COLOR
      fi
      LABEL=$(printf '\(cpu ? "cpu" : "mem") %02d%%' "$LEVEL")
      "$SKETCHYBAR" --set "$NAME" label="$LABEL" label.color="$COLOR"

      """
  }
}
