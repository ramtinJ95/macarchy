import Foundation
import TestSupport
import Testing

@testable import ThemeCore

struct KittyColorOverridesTests {
  /// Every color option set by a theme in Kitty's theme collection (kovidgoyal/kitty-themes at
  /// 2c03004345b5ef42d5b78fb6273c8622223922e4, which `kitten themes` in Kitty 0.48.2 downloads).
  static let bundledThemeColorOptions: [String] =
    [
      "foreground", "background", "cursor", "cursor_text_color", "cursor_trail_color",
      "selection_foreground", "selection_background", "active_border_color",
      "inactive_border_color", "bell_border_color", "active_tab_foreground",
      "active_tab_background", "inactive_tab_foreground", "inactive_tab_background",
      "tab_bar_background", "tab_bar_margin_color", "macos_titlebar_color",
      "wayland_titlebar_color", "mark1_foreground", "mark1_background", "mark2_foreground",
      "mark2_background", "mark3_foreground", "mark3_background", "url_color",
      "visual_bell_color",
    ] + (0...23).map { "color\($0)" }

  @Test func theRenderedThemeSetsEveryColorOptionOfKittysBundledThemesOnce() throws {
    let package = try ThemeRepository(builtInRoot: repositoryRoot.appending(path: "Themes"))
      .package(id: "tokyo-night")
    let keys = KittyAdapter.render(package: package).split(separator: "\n")
      .filter { !$0.hasPrefix("#") }.map { String($0.split(separator: " ")[0]) }

    #expect(Set(Self.bundledThemeColorOptions).isSubset(of: Set(keys)))
    #expect(Set(keys).isSubset(of: KittyColorOverrides.colorOptions))
    #expect(keys.count == Set(keys).count)
    #expect(keys.contains("color255"))
  }

  @Test(arguments: [
    (16, "#000000"), (21, "#0000ff"), (196, "#ff0000"), (231, "#ffffff"), (232, "#080808"),
    (255, "#eeeeee"),
  ])
  func paletteEntriesAboveFifteenAreTheXtermDefaults(index: Int, color: String) {
    #expect(KittyAdapter.xtermColor(index) == color)
  }

  @Test func nothingOverridesAConfigurationThatEndsWithTheInclude() throws {
    try withTemporaryRoot(named: "macarchy-kitty-overrides") { directory in
      let overrides = KittyColorOverrides.inspect(
        configuration: "font_size 13\nforeground #ffffff\n\(include)\n# background #000000\n",
        directory: directory, includeDirective: include)

      #expect(overrides.sources.isEmpty)
      #expect(overrides.message == nil)
    }
  }

  @Test func autoThemeFilesAreReportedWithTheirAppearanceAndKeys() throws {
    try withTemporaryRoot(named: "macarchy-kitty-overrides") { directory in
      try write(
        "background #101010\nforeground #eeeeee\nfont_size 12\n", "dark-theme.auto.conf",
        in: directory)
      try write("", "no-preference-theme.auto.conf", in: directory)

      let overrides = KittyColorOverrides.inspect(
        configuration: "\(include)\n", directory: directory, includeDirective: include)

      #expect(
        overrides.message
          == "Theme colors are overridden by dark-theme.auto.conf, which replaces every color "
          + "when macOS is in Dark mode (background, foreground); "
          + "no-preference-theme.auto.conf, which replaces every color when macOS has no "
          + "appearance preference (sets no colors, so Kitty's defaults show)")
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
      #expect(names == ["dark-theme.auto.conf", "no-preference-theme.auto.conf"])
    }
  }

  @Test func colorsSetAfterTheIncludeDirectlyOrThroughALaterIncludeAreReported() throws {
    try withTemporaryRoot(named: "macarchy-kitty-overrides") { directory in
      try write(
        (0...7).map { "color\($0) #111111" }.joined(separator: "\n"), "current-theme.conf",
        in: directory)
      try write("font_family Menlo\n", "fonts.conf", in: directory)
      try FileManager.default.createDirectory(
        at: directory.appending(path: "extra"), withIntermediateDirectories: true)
      try write("url_color #00ff00\n", "extra/b.conf", in: directory)
      try write("cursor #ff0000\n", "extra/a.conf", in: directory)
      let configuration = """
        foreground #000000
        \(include)
        include current-theme.conf
        include fonts.conf
        include missing.conf
        globinclude extra/*.conf
          background   #222222
        background #333333
        font_size 14
        """

      let overrides = KittyColorOverrides.inspect(
        configuration: configuration, directory: directory, includeDirective: include)

      let path = directory.path
      #expect(
        overrides.sources == [
          .init(
            description: "\(path)/current-theme.conf, included after Macarchy's theme",
            keys: (0...7).map { "color\($0)" }),
          .init(
            description: "\(path)/extra/a.conf, included after Macarchy's theme", keys: ["cursor"]),
          .init(
            description: "\(path)/extra/b.conf, included after Macarchy's theme",
            keys: ["url_color"]),
          .init(
            description: "kitty.conf lines after Macarchy's theme include", keys: ["background"]),
        ])
      #expect(
        overrides.message?.hasPrefix(
          "Theme colors are overridden by \(path)/current-theme.conf, included after Macarchy's "
            + "theme (color0, color1, color2, color3, color4, color5 and 2 more); ") == true)
    }
  }
}

extension AdapterContractTests {
  @Test
  func kittyReportsAnAutoThemeOverrideWithItsAppliedResult() async throws {
    try await withTemporaryRoot(named: "macarchy-kitty-override-tests") { root in
      _ = try testActivator(root: root).activate(package: catppuccinPackage())
      let includeDirective = KittyAdapter.includeDirective(stateRoot: root)
      let directory = root.appending(path: "kitty", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let configurationURL = directory.appending(path: "kitty.conf")
      try "\(includeDirective)\n".write(to: configurationURL, atomically: true, encoding: .utf8)
      try "background #000000\n".write(
        to: directory.appending(path: "light-theme.auto.conf"), atomically: true,
        encoding: .utf8)
      let adapter = KittyAdapter(
        root: root, configurationURL: configurationURL, includeDirective: includeDirective,
        processRunner: ProcessRunner { _ in ProcessResult(terminationStatus: 0, output: "") })
      let expected =
        "Theme colors are overridden by light-theme.auto.conf, which replaces every color "
        + "when macOS is in Light mode (background)"

      let outcome = try await adapter.reconciliation().run()

      #expect(outcome.status == .applied)
      #expect(outcome.message == expected)
      #expect(adapter.inspection().status == .ready)
      #expect(adapter.inspection().message == expected)
      #expect(
        try String(contentsOf: directory.appending(path: "light-theme.auto.conf"), encoding: .utf8)
          == "background #000000\n")
    }
  }
}

private let include = "include /state/state/adapters/kitty.conf"

private func write(_ contents: String, _ name: String, in directory: URL) throws {
  try contents.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
}
