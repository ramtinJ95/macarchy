import Foundation

/// One `sketchybar --query <item>` reply laid out exactly as SketchyBar 2.24.0's
/// bar_item_serialize prints it: icon, label and image values verbatim, and scripts with only
/// quotes and newlines escaped. Tests use it where an escaping encoder would hide that output.
enum SketchyBarNativeQuery {
  static func item(
    name: String, type: String = "item", drawing: String = "on", position: String = "right",
    icon: String = "", label: String = "", labelDrawing: String = "on",
    script: String = "", clickScript: String = "", updateFrequency: Int = 0,
    updateMask: UInt64 = 0, updates: String = "when_shown", popupItems: [String]? = nil
  ) -> String {
    var reply = """
      {
      \t"name": "\(name)",
      \t"type": "\(type)",
      \t"geometry": {
      \t\t"drawing": "\(drawing)",
      \t\t"position": "\(position)",
      \t\t"associated_space_mask": 0,
      \t\t"associated_display_mask": 0,
      \t\t"ignore_association": "off",
      \t\t"y_offset": 0,
      \t\t"padding_left": 0,
      \t\t"padding_right": 0,
      \t\t"scroll_texts": "off",
      \t\t"width": -1,
      \t\t"background": {
      \(background(indent: "\t\t\t"))
      \t\t}
      \t},
      \t"icon": {
      \(text(icon, drawing: "on"))
      \t},
      \t"label": {
      \(text(label, drawing: labelDrawing))
      \t},
      \t"scripting": {
      \t\t"script": "\(escaped(script))",
      \t\t"click_script": "\(escaped(clickScript))",
      \t\t"update_freq": \(updateFrequency),
      \t\t"update_mask": \(updateMask),
      \t\t"updates": "\(updates)"
      \t},
      \t"bounding_rects": {
      \t\t"display-1": {
      \t\t\t"origin": [ 10.000000, 0.000000 ],
      \t\t\t"size": [ 40.000000, 30.000000 ]
      \t\t}
      \t}
      """
    if let popupItems {
      reply += """
        ,
        \t"popup": {
        \t\t"drawing": "off",
        \t\t"horizontal": "off",
        \t\t"height": -1,
        \t\t"blur_radius": 0,
        \t\t"y_offset": 0,
        \t\t"align": "left",
        \t\t"background": {
        \(background(indent: "\t\t\t"))
        \t\t},
        \t\t"items": [
        \(popupItems.map { "\t\t\t \"\($0)\"" }.joined(separator: ",\n"))
        \t\t]
        \t}
        """
    }
    return reply + "\n}\n"
  }

  private static func text(_ value: String, drawing: String) -> String {
    """
    \t\t"value": "\(value)",
    \t\t"drawing": "\(drawing)",
    \t\t"highlight": "off",
    \t\t"color": "0xffcdd6f4",
    \t\t"highlight_color": "0xff000000",
    \t\t"padding_left": 0,
    \t\t"padding_right": 0,
    \t\t"y_offset": 0,
    \t\t"font": "SF Pro:Semibold:14.00",
    \t\t"width": -1,
    \t\t"scroll_duration": 100,
    \t\t"align": "left",
    \t\t"background": {
    \(background(indent: "\t\t\t"))
    \t\t},
    \t\t"shadow": {
    \t\t\t"drawing": "off",
    \t\t\t"color": "0xff000000",
    \t\t\t"angle": 30,
    \t\t\t"distance": 5
    \t\t}
    """
  }

  private static func background(indent: String) -> String {
    let deeper = indent + "\t"
    return [
      "\(indent)\"drawing\": \"off\",", "\(indent)\"color\": \"0x0\",",
      "\(indent)\"border_color\": \"0x0\",", "\(indent)\"border_width\": 0,",
      "\(indent)\"height\": 0,", "\(indent)\"corner_radius\": 0,",
      "\(indent)\"padding_left\": 0,", "\(indent)\"padding_right\": 0,",
      "\(indent)\"x_offset\": 0,", "\(indent)\"y_offset\": 0,", "\(indent)\"clip\": 0.000000,",
      "\(indent)\"image\": {", "\(deeper)\"value\": \"(null)\",", "\(deeper)\"drawing\": \"off\",",
      "\(deeper)\"scale\": 1.000000", "\(indent)},", "\(indent)\"shadow\": {",
      "\(deeper)\"drawing\": \"off\",", "\(deeper)\"color\": \"0xff000000\",",
      "\(deeper)\"angle\": 30,", "\(deeper)\"distance\": 5", "\(indent)}",
    ].joined(separator: "\n")
  }

  /// SketchyBar's escape_string, applied to scripts only.
  private static func escaped(_ script: String) -> String {
    script.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(
      of: "\n", with: "\\n")
  }
}
