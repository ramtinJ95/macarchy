import Foundation
import Testing

@testable import ThemeCore

struct BuiltInOmarchyParityTests {
  @Test(
    arguments: [
      (themeID: "tokyo-night", omarchyThemeID: "tokyo-night"),
      (themeID: "kanagawa-wave", omarchyThemeID: "kanagawa"),
    ])
  func canonicalPaletteMatchesOmarchyConversion(
    themeID: String,
    omarchyThemeID: String
  ) throws {
    let package = try repository.package(id: themeID)
    let conversion = try OmarchyPaletteLoader().load(
      colorsFile: repositoryRoot.appending(
        path: "Tests/Fixtures/Omarchy/\(omarchyThemeID)/colors.toml"
      )
    )

    #expect(package.appearance == conversion.appearance)
    #expect(semanticValues(package.semantic) == semanticValues(conversion.semantic))
    #expect(terminalValues(package.terminal) == terminalValues(conversion.terminal))
  }

  @Test
  func builtInBackgroundsAreExactOmarchyAssetsInOmarchyOrder() throws {
    let tokyoNight = try repository.package(id: "tokyo-night")
    #expect(
      tokyoNight.backgrounds.map(\.path) == [
        "wallpapers/0-winding-road.webp",
        "wallpapers/1-quattro.webp",
        "wallpapers/2-swirl-buck.webp",
        "wallpapers/3-sunset-lake.webp",
        "wallpapers/4-omakub.webp",
        "wallpapers/5-oma-cityscape.jpg",
        "wallpapers/6-oma.webp",
        "wallpapers/omarchy.webp",
      ])
    #expect(
      tokyoNight.backgrounds.map { sha256Digest(tokyoNight.data(for: $0)) } == [
        "sha256:b149c3e1c8ce383812e7bc3170c2cf8b160ca583d72d59173cd42efdb79ced2b",
        "sha256:c9b96c106d2758113986a8ddb621f3867edf65e09a89dad51abb9fc5f3447146",
        "sha256:d068aa0ce70685b336fa15dfb8b8df96c03a75e045cb32fe101319c8d284105a",
        "sha256:eabc95e4d5e2396b967970458f51a1a2ead80d5cad88a4d303af58989f5f8c49",
        "sha256:1de02e50e19b1884c9195f1553cbb686ae0642963789b34d0a9f4f0478f80aa7",
        "sha256:22e1d639722b33fa6f0d3ac2733450b4bae961b481f5665cb16397bc5f714e5c",
        "sha256:1dae1555422c3713381f09dd20b8ed91eaaf42cf73e73bfe255dfefe89b1d004",
        "sha256:ef9c6d4c7763a1d56e97e4e5300ffd45d10995e35273e8b16d3a1e4b36a45566",
      ])

    let kanagawa = try repository.package(id: "kanagawa-wave")
    #expect(
      kanagawa.backgrounds.map(\.path) == [
        "wallpapers/1-kanagawa.jpg", "wallpapers/omarchy.webp",
      ])
    #expect(
      kanagawa.backgrounds.map { sha256Digest(kanagawa.data(for: $0)) } == [
        "sha256:9b817d717688539f0db87603b661992839c3cbb5d4918a02a4efc05c9f88b27d",
        "sha256:e27fe79776337f0e80c2051d6d981c2ee4cca170584f455e27395de4bc3ff6c5",
      ])

    let catppuccin = try repository.package(id: "catppuccin-mocha")
    #expect(
      catppuccin.backgrounds.map(\.path) == [
        "wallpapers/1-totoro.webp",
        "wallpapers/2-waves.webp",
        "wallpapers/3-blue-eye.webp",
        "wallpapers/omarchy.webp",
      ])
    #expect(
      catppuccin.backgrounds.map { sha256Digest(catppuccin.data(for: $0)) } == [
        "sha256:4896da620ed3016b7e52eede8db8169591a9fa4856064db4039521be96f724b6",
        "sha256:5fe347ef9814dbf1d5bc73a96381b8fe4908ed0f7e4293d2c3c8d860b46041ce",
        "sha256:70743c244575253b72f17978060f87239e0125575195f64e288479666129954a",
        "sha256:24cb9211e2191edefadd093976526d3606167343a636eb9ff123b40d4e594329",
      ]
    )
  }

  private var repository: ThemeRepository {
    ThemeRepository(
      builtInRoot: repositoryRoot.appending(path: "Themes", directoryHint: .isDirectory)
    )
  }

  private func semanticValues(_ colors: SemanticColors) -> [String] {
    [
      colors.background, colors.surface, colors.overlay, colors.border,
      colors.text, colors.mutedText, colors.accent, colors.selection,
      colors.info, colors.success, colors.warning, colors.error,
    ].map(\.rawValue)
  }

  private func terminalValues(_ colors: TerminalColors) -> [String] {
    [
      colors.foreground, colors.background, colors.cursor,
      colors.selectionForeground, colors.selectionBackground,
    ].map(\.rawValue) + colors.ansi.map(\.rawValue)
  }
}
