import Darwin
import Foundation

public enum OmarchyIgnoredFileReason: String, Codable, Equatable, Sendable {
  case applicationOverride = "application_override"
  case executableFile = "executable_file"
  case hookFile = "hook_file"
  case luaConfiguration = "lua_configuration"
  case nestedBackgroundFile = "nested_background_file"
  case scriptFile = "script_file"
  case unknownActiveConfiguration = "unknown_active_configuration"
  case unsupportedImageType = "unsupported_image_type"
  case unrecognizedInertFile = "unrecognized_inert_file"
}

public struct OmarchyIgnoredFile: Codable, Equatable, Sendable {
  public let path: String
  public let reason: OmarchyIgnoredFileReason
}

public struct OmarchyImportedAsset: Codable, Equatable, Sendable {
  public let sourcePath: String
  public let packagePath: String

  enum CodingKeys: String, CodingKey {
    case sourcePath = "source_path"
    case packagePath = "package_path"
  }
}

public enum OmarchyConversionWarning: String, Codable, Equatable, Sendable {
  case missingAssetProvenance = "missing_asset_provenance"
}

public struct OmarchyThemeConversionReport: Codable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let themeID: String
  public let sourceURL: String
  public let resolvedCommit: String
  public let defaultBackground: String
  public let paletteFile: String
  public let appearanceMarker: String?
  public let ignoredFiles: [OmarchyIgnoredFile]
  public let backgrounds: [OmarchyImportedAsset]
  public let previews: [OmarchyImportedAsset]
  public let compatibility: OmarchyPaletteCompatibility
  public let warnings: [OmarchyConversionWarning]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case themeID = "theme_id"
    case sourceURL = "source_url"
    case resolvedCommit = "resolved_commit"
    case defaultBackground = "default_background"
    case paletteFile = "palette_file"
    case appearanceMarker = "appearance_marker"
    case ignoredFiles = "ignored_files"
    case backgrounds, previews, compatibility, warnings
  }
}

public struct ConvertedOmarchyTheme: Sendable {
  public let package: ThemePackage
  public let report: OmarchyThemeConversionReport
}

public enum OmarchyThemeConversionError: Error, CustomStringConvertible, Equatable, Sendable {
  case destinationExists(String)
  case unsafeEntry(path: String, reason: String)
  case missingBackgrounds([OmarchyIgnoredFile])
  case invalidAsset(path: String, reason: String)
  case packageFilesystem(String)

  public var description: String {
    switch self {
    case .destinationExists(let path):
      "The converted package destination already exists: \(path)"
    case .unsafeEntry(let path, let reason):
      "Unsafe Omarchy theme entry \(String(reflecting: path)): \(reason)"
    case .missingBackgrounds(let ignored):
      if ignored.isEmpty {
        "The Omarchy theme contains no supported image directly under backgrounds/"
      } else {
        "The Omarchy theme contains no supported background; rejected: "
          + ignored.prefix(3).map { String(reflecting: $0.path) }.joined(separator: ", ")
      }
    case .invalidAsset(let path, let reason):
      "Invalid Omarchy theme image \(String(reflecting: path)): \(reason)"
    case .packageFilesystem(let detail):
      "Cannot build the converted Macarchy theme package: \(detail)"
    }
  }
}

public struct OmarchyThemeConverter: Sendable {
  private let stager: OmarchyThemeStager

  public init() {
    stager = OmarchyThemeStager()
  }

  package init(stager: OmarchyThemeStager) {
    self.stager = stager
  }

  public func withConvertedPackage<Output>(
    from source: String,
    _ operation: (ConvertedOmarchyTheme) throws -> Output
  ) throws -> Output {
    try stager.withStagedCheckout(from: source) { staged in
      let destination = staged.checkoutURL.deletingLastPathComponent().appending(
        path: "converted-package",
        directoryHint: .isDirectory
      )
      let converted = try convert(staged: staged, to: destination)
      return try operation(converted)
    }
  }

  package func convert(
    from source: String,
    to destination: URL
  ) throws -> ConvertedOmarchyTheme {
    try stager.withStagedCheckout(from: source) { staged in
      try convert(staged: staged, to: destination)
    }
  }

  package func convert(
    staged: StagedOmarchyTheme,
    to destination: URL
  ) throws -> ConvertedOmarchyTheme {
    guard !Self.entryExists(destination) else {
      throw OmarchyThemeConversionError.destinationExists(destination.path)
    }

    let transaction = destination.deletingLastPathComponent().appending(
      path: ".macarchy-conversion-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: transaction) }

    do {
      try FileManager.default.createDirectory(
        at: transaction,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      let inventory = try Self.inventory(checkout: staged.checkoutURL)
      guard let colors = inventory.first(where: { $0.path == "colors.toml" }) else {
        throw ThemeDiagnostic(
          location: .init(file: staged.checkoutURL.appending(path: "colors.toml")),
          message: "Cannot read required Omarchy colors: colors.toml is missing"
        )
      }
      guard colors.permissions & 0o111 == 0 else {
        throw OmarchyThemeConversionError.unsafeEntry(
          path: colors.path,
          reason: "the active palette input is marked executable"
        )
      }

      let palette = try OmarchyPaletteLoader().load(
        colorsFile: staged.checkoutURL.appending(path: colors.path))
      let classified = try Self.classify(
        inventory: inventory,
        checkout: staged.checkoutURL
      )
      guard let firstBackground = classified.backgrounds.first else {
        throw OmarchyThemeConversionError.missingBackgrounds(
          classified.ignored.filter { $0.path.hasPrefix("backgrounds/") })
      }

      try Self.writePackage(
        at: transaction,
        staged: staged,
        palette: palette,
        classified: classified
      )
      let report = Self.report(
        staged: staged,
        palette: palette,
        classified: classified,
        defaultBackground: firstBackground
      )
      try Self.writeReport(report, to: transaction.appending(path: "import.json"))

      _ = try ThemePackageLoader().load(packageURL: transaction)
      try FileManager.default.moveItem(at: transaction, to: destination)
      let package = try ThemePackageLoader().load(packageURL: destination)
      return ConvertedOmarchyTheme(package: package, report: report)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as OmarchyThemeConversionError {
      throw error
    } catch let error as ThemeDiagnostic {
      throw error
    } catch {
      throw OmarchyThemeConversionError.packageFilesystem(String(describing: error))
    }
  }

  private struct InventoryFile {
    let path: String
    let permissions: Int
  }

  private struct LoadedImage {
    let sourcePath: String
    let packagePath: String
    let data: Data
  }

  private struct Classified {
    let backgrounds: [LoadedImage]
    let previews: [LoadedImage]
    let ignored: [OmarchyIgnoredFile]
    let hasLightModeMarker: Bool
  }

  private struct ImportTarget {
    let packagePath: String
    let isBackground: Bool
    let format: ThemeBackgroundFormat
  }

  private static func inventory(checkout: URL) throws -> [InventoryFile] {
    var files: [InventoryFile] = []
    try walk(directory: checkout, relativeDirectory: "", files: &files)
    return files.sorted { $0.path < $1.path }
  }

  private static func walk(
    directory: URL,
    relativeDirectory: String,
    files: inout [InventoryFile]
  ) throws {
    let children: [URL]
    do {
      children = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )
    } catch {
      throw OmarchyThemeConversionError.packageFilesystem(
        "Cannot inspect staged directory '\(relativeDirectory)': \(error)"
      )
    }

    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      try Task.checkCancellation()
      let relative =
        relativeDirectory.isEmpty
        ? child.lastPathComponent : "\(relativeDirectory)/\(child.lastPathComponent)"
      if relative == ".git" { continue }

      var metadata = stat()
      guard lstat(child.path, &metadata) == 0 else {
        throw OmarchyThemeConversionError.packageFilesystem(
          "Cannot inspect staged entry '\(relative)': \(String(cString: strerror(errno)))"
        )
      }
      switch metadata.st_mode & S_IFMT {
      case S_IFLNK:
        throw OmarchyThemeConversionError.unsafeEntry(
          path: relative,
          reason: "symbolic links are not accepted"
        )
      case S_IFDIR:
        try walk(directory: child, relativeDirectory: relative, files: &files)
      case S_IFREG:
        files.append(
          InventoryFile(path: relative, permissions: Int(metadata.st_mode & 0o777)))
      default:
        throw OmarchyThemeConversionError.unsafeEntry(
          path: relative,
          reason: "only regular files and directories are accepted"
        )
      }
    }
  }

  private static func classify(
    inventory: [InventoryFile],
    checkout: URL
  ) throws -> Classified {
    var backgrounds: [LoadedImage] = []
    var previews: [LoadedImage] = []
    var ignored: [OmarchyIgnoredFile] = []
    var outputKeys: Set<String> = []
    var hasLightModeMarker = false

    for file in inventory {
      if file.path == "colors.toml" { continue }
      if file.path == "light.mode" {
        guard file.permissions & 0o111 == 0 else {
          throw OmarchyThemeConversionError.unsafeEntry(
            path: file.path,
            reason: "the active appearance marker is marked executable"
          )
        }
        _ = try BoundedRegularFile.read(at: checkout.appending(path: file.path))
        hasLightModeMarker = true
        continue
      }
      if file.permissions & 0o111 != 0 {
        ignored.append(.init(path: file.path, reason: .executableFile))
        continue
      }

      let parts = file.path.split(separator: "/")
      let ext = URL(filePath: file.path).pathExtension.lowercased()
      let supportedFormat = ThemeBackgroundFormat(pathExtension: ext)
      let target: ImportTarget?
      if parts.count == 2, parts[0] == "backgrounds", let supportedFormat {
        target = ImportTarget(
          packagePath: "backgrounds/\(parts[1])",
          isBackground: true,
          format: supportedFormat
        )
      } else if parts.count == 1, parts[0].lowercased() == "preview.\(ext)",
        let supportedFormat
      {
        target = ImportTarget(
          packagePath: "previews/\(parts[0])",
          isBackground: false,
          format: supportedFormat
        )
      } else if parts.count == 2, parts[0] == "preview", let supportedFormat {
        target = ImportTarget(
          packagePath: "previews/\(parts[1])",
          isBackground: false,
          format: supportedFormat
        )
      } else {
        target = nil
      }

      guard let target else {
        let reason: OmarchyIgnoredFileReason
        if parts.first == "backgrounds", parts.count > 2 {
          reason = .nestedBackgroundFile
        } else if parts.first == "backgrounds" || parts.first == "preview"
          || (parts.count == 1 && parts[0].lowercased().hasPrefix("preview."))
        {
          reason = .unsupportedImageType
        } else if parts.contains("hooks") {
          reason = .hookFile
        } else if ext == "lua" {
          reason = .luaConfiguration
        } else if ["bash", "fish", "sh", "zsh"].contains(ext) {
          reason = .scriptFile
        } else if ["conf", "css", "theme"].contains(ext) {
          reason = .applicationOverride
        } else if ["ini", "json", "toml", "yaml", "yml"].contains(ext) {
          reason = .unknownActiveConfiguration
        } else {
          reason = .unrecognizedInertFile
        }
        ignored.append(.init(path: file.path, reason: reason))
        continue
      }

      let collisionKey = target.packagePath.precomposedStringWithCanonicalMapping.lowercased()
      guard outputKeys.insert(collisionKey).inserted else {
        throw OmarchyThemeConversionError.unsafeEntry(
          path: file.path,
          reason: "its imported package path collides with another file"
        )
      }
      let image = try loadImage(
        sourcePath: file.path,
        packagePath: target.packagePath,
        expectedFormat: target.format,
        checkout: checkout
      )
      if target.isBackground {
        backgrounds.append(image)
      } else {
        previews.append(image)
      }
    }

    return Classified(
      backgrounds: backgrounds.sorted { $0.sourcePath < $1.sourcePath },
      previews: previews.sorted { $0.sourcePath < $1.sourcePath },
      ignored: ignored.sorted { $0.path < $1.path },
      hasLightModeMarker: hasLightModeMarker
    )
  }

  private static func loadImage(
    sourcePath: String,
    packagePath: String,
    expectedFormat: ThemeBackgroundFormat,
    checkout: URL
  ) throws -> LoadedImage {
    let data: Data
    do {
      data = try ThemeImageAsset.load(
        at: checkout.appending(path: sourcePath),
        format: expectedFormat
      )
    } catch {
      throw OmarchyThemeConversionError.invalidAsset(
        path: sourcePath,
        reason: String(describing: error)
      )
    }

    return LoadedImage(
      sourcePath: sourcePath,
      packagePath: packagePath,
      data: data
    )
  }

  private static func writePackage(
    at package: URL,
    staged: StagedOmarchyTheme,
    palette: OmarchyPaletteConversion,
    classified: Classified
  ) throws {
    for directory in ["sources", "backgrounds", "previews", "LICENSES"] {
      try FileManager.default.createDirectory(
        at: package.appending(path: directory, directoryHint: .isDirectory),
        withIntermediateDirectories: false
      )
    }

    let colorsData = try BoundedRegularFile.read(
      at: staged.checkoutURL.appending(path: "colors.toml")
    ).data
    try colorsData.write(to: package.appending(path: "sources/colors.toml"))
    for image in classified.backgrounds + classified.previews {
      try image.data.write(to: package.appending(path: image.packagePath))
    }

    try themeManifest(staged: staged, palette: palette, backgrounds: classified.backgrounds).write(
      to: package.appending(path: "theme.toml"),
      atomically: false,
      encoding: .utf8
    )
    try "schema_version = 1\n\n[mappings]\n".write(
      to: package.appending(path: "mappings.toml"),
      atomically: false,
      encoding: .utf8
    )
    let provenance = """
      # Imported Omarchy wallpaper provenance

      - Repository: \(staged.sourceURL.absoluteString)
      - Commit: \(staged.resolvedCommit)
      - Selected source: see `import.json` `default_background`
      - Upstream author: not verified by the safe importer
      - Upstream asset license: not verified by the safe importer
      - Distribution: personal use only; not release-eligible without provenance
      """ + "\n"
    try provenance.write(
      to: package.appending(path: "LICENSES/wallpaper.md"),
      atomically: false,
      encoding: .utf8
    )
  }

  private static func themeManifest(
    staged: StagedOmarchyTheme,
    palette: OmarchyPaletteConversion,
    backgrounds: [LoadedImage]
  ) -> String {
    let semantic = palette.semantic
    let terminal = palette.terminal
    let ansi = terminal.ansi.map { "  \"\($0.rawValue)\"" }.joined(separator: ",\n")
    let displayName = staged.themeID.split(separator: "-").map { part in
      part.prefix(1).uppercased() + part.dropFirst()
    }.joined(separator: " ")
    let backgroundEntries = backgrounds.map { background in
      """
      [[backgrounds]]
      id = "\(backgroundID(for: background.packagePath))"
      path = "\(background.packagePath)"
      source = "\(staged.sourceURL.absoluteString) at \(staged.resolvedCommit)"
      author = "Not verified by the safe importer"
      license = "Not verified; personal use only"
      """
    }.joined(separator: "\n\n")
    return """
      schema_version = 1
      id = "\(staged.themeID)"
      display_name = "\(displayName)"
      appearance = "\(palette.appearance.rawValue)"

      [semantic]
      background = "\(semantic.background.rawValue)"
      surface = "\(semantic.surface.rawValue)"
      overlay = "\(semantic.overlay.rawValue)"
      border = "\(semantic.border.rawValue)"
      text = "\(semantic.text.rawValue)"
      muted_text = "\(semantic.mutedText.rawValue)"
      accent = "\(semantic.accent.rawValue)"
      selection = "\(semantic.selection.rawValue)"
      info = "\(semantic.info.rawValue)"
      success = "\(semantic.success.rawValue)"
      warning = "\(semantic.warning.rawValue)"
      error = "\(semantic.error.rawValue)"

      [terminal]
      foreground = "\(terminal.foreground.rawValue)"
      background = "\(terminal.background.rawValue)"
      cursor = "\(terminal.cursor.rawValue)"
      selection_foreground = "\(terminal.selectionForeground.rawValue)"
      selection_background = "\(terminal.selectionBackground.rawValue)"
      ansi = [
      \(ansi),
      ]

      \(backgroundEntries)
      """ + "\n"
  }

  private static func backgroundID(for packagePath: String) -> String {
    var slug = ""
    var previousWasSeparator = false
    for character in URL(filePath: packagePath).lastPathComponent.lowercased() {
      if character.isASCII, character.isLetter || character.isNumber {
        slug.append(character)
        previousWasSeparator = false
      } else if !previousWasSeparator, !slug.isEmpty {
        slug.append("-")
        previousWasSeparator = true
      }
    }
    if slug.last == "-" { slug.removeLast() }
    if slug.first?.isLetter != true { slug = "background-\(slug)" }
    let digest = sha256Digest(Data(packagePath.utf8)).dropFirst("sha256:".count).prefix(8)
    return "\(slug)-\(digest)"
  }

  private static func report(
    staged: StagedOmarchyTheme,
    palette: OmarchyPaletteConversion,
    classified: Classified,
    defaultBackground: LoadedImage
  ) -> OmarchyThemeConversionReport {
    return OmarchyThemeConversionReport(
      schemaVersion: OmarchyThemeConversionReport.currentSchemaVersion,
      themeID: staged.themeID,
      sourceURL: staged.sourceURL.absoluteString,
      resolvedCommit: staged.resolvedCommit,
      defaultBackground: defaultBackground.sourcePath,
      paletteFile: "colors.toml",
      appearanceMarker: classified.hasLightModeMarker ? "light.mode" : nil,
      ignoredFiles: classified.ignored,
      backgrounds: classified.backgrounds.map {
        OmarchyImportedAsset(sourcePath: $0.sourcePath, packagePath: $0.packagePath)
      },
      previews: classified.previews.map {
        OmarchyImportedAsset(sourcePath: $0.sourcePath, packagePath: $0.packagePath)
      },
      compatibility: palette.compatibility,
      warnings: [.missingAssetProvenance]
    )
  }

  private static func writeReport(_ report: OmarchyThemeConversionReport, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(report)
    data.append(0x0a)
    try data.write(to: url)
  }

  private static func entryExists(_ url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0 || errno != ENOENT
  }
}
