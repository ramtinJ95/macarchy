import Foundation

enum SketchyBarVolumeScript {
  static func render(
    palettePath: String, macarchyExecutablePath: String = "/opt/homebrew/bin/macarchy"
  ) -> String {
    """
    #!/bin/sh
    set -eu
    PALETTE=\(SketchyBarConfigurationComposer.shellLiteral(palettePath))
    . "$PALETTE"
    BAR=/opt/homebrew/bin/sketchybar
    case "${NAME-}" in macarchy.volume|macarchy.volume.icon|macarchy.volume.slider|macarchy.volume.device.*) ;; *) exit 1 ;; esac
    picker() {
      \(SketchyBarConfigurationComposer.shellLiteral(macarchyExecutablePath)) desktop _audio-picker --action "$1" --name "$NAME" --plugin-path "$0" --text-color "$MACARCHY_TEXT_COLOR" --muted-color "$MACARCHY_MUTED_COLOR"
    }
    finish() {
      rc=$?
      if [ "$rc" -ne 0 ]; then
        echo 'Macarchy: volume query or control failed' >&2
        "$BAR" --set macarchy.volume label=ERR label.color="$MACARCHY_BATTERY_RED" || echo 'Macarchy: volume error presentation also failed' >&2
      fi
      exit "$rc"
    }
    trap finish EXIT
    level() {
      /usr/bin/awk 'BEGIN { good=0 } /^[0-9]+$/ && length($0)<=3 && $0+0<=100 { print $0+0; good=1 } END { if (NR!=1 || !good) exit 1 }'
    }
    case "${SENDER-}" in
      mouse.exited.global)
        picker close
        exit 0 ;;
      mouse.clicked)
        if [ "${BUTTON-}" = right ]; then
          /usr/bin/open /System/Library/PreferencePanes/Sound.prefpane
        else
          picker toggle
        fi
        exit 0 ;;
      macarchy.output)
        picker select
        ;;
      macarchy.slider)
        VOLUME=$(printf '%s\\n' "${PERCENTAGE-}" | level)
        /usr/bin/osascript -e "set volume output volume $VOLUME"
        ;;
      mouse.scrolled)
        DELTA=$(printf '%s\\n' "${SCROLL_DELTA-}" | /usr/bin/awk 'BEGIN { good=0 } /^-?[0-9]+$/ && length($0)<=5 && $0+0>=-1000 && $0+0<=1000 { print $0+0; good=1 } END { if (NR!=1 || !good) exit 1 }')
        RAW=$(/usr/bin/osascript -e 'output volume of (get volume settings)')
        CURRENT=$(printf '%s\\n' "$RAW" | level)
        if [ "${MODIFIER-}" != ctrl ]; then DELTA=$((DELTA * 10)); fi
        VOLUME=$((CURRENT + DELTA))
        if [ "$VOLUME" -lt 0 ]; then VOLUME=0; fi
        if [ "$VOLUME" -gt 100 ]; then VOLUME=100; fi
        /usr/bin/osascript -e "set volume output volume $VOLUME"
        ;;
    esac
    if [ "${SENDER-}" = volume_change ]; then
      VOLUME=$(printf '%s\\n' "${INFO-}" | level)
    else
      RAW=$(/usr/bin/osascript -e 'output volume of (get volume settings)')
      VOLUME=$(printf '%s\\n' "$RAW" | level)
    fi
    ICON='􀊣'
    if [ "$VOLUME" -gt 60 ]; then ICON='􀊩'
    elif [ "$VOLUME" -gt 30 ]; then ICON='􀊧'
    elif [ "$VOLUME" -gt 10 ]; then ICON='􀊥'
    elif [ "$VOLUME" -gt 0 ]; then ICON='􀊡'; fi
    LABEL=$(printf '%02d%%' "$VOLUME")
    "$BAR" --set macarchy.volume label="$LABEL" label.color="$MACARCHY_TEXT_COLOR" \\
      --set macarchy.volume.icon label="$ICON" label.color="$MACARCHY_TEXT_COLOR" \\
      --set macarchy.volume.slider slider.percentage="$VOLUME"

    """
  }
}
