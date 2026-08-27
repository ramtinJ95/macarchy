import Darwin
import Foundation
import ImageIO

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
  private static let maximumImageDimension = 16_384
  private static let maximumImagePixels = 64_000_000
  private static let supportedExtensions = [
    "jpeg": "public.jpeg",
    "jpg": "public.jpeg",
    "png": "public.png",
  ]

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
        classified: classified,
        defaultBackground: firstBackground
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
    let mediaType: String
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
    let mediaType: String
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
      let supportedType = supportedExtensions[ext]
      let target: ImportTarget?
      if parts.count == 2, parts[0] == "backgrounds", let supportedType {
        target = ImportTarget(
          packagePath: "backgrounds/\(parts[1])",
          isBackground: true,
          mediaType: supportedType
        )
      } else if parts.count == 1, parts[0].lowercased() == "preview.\(ext)",
        let supportedType
      {
        target = ImportTarget(
          packagePath: "previews/\(parts[0])",
          isBackground: false,
          mediaType: supportedType
        )
      } else if parts.count == 2, parts[0] == "preview", let supportedType {
        target = ImportTarget(
          packagePath: "previews/\(parts[1])",
          isBackground: false,
          mediaType: supportedType
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
        expectedType: target.mediaType,
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
    expectedType: String,
    checkout: URL
  ) throws -> LoadedImage {
    let data: Data
    do {
      data = try BoundedRegularFile.read(
        at: checkout.appending(path: sourcePath),
        maximumSize: WallpaperAsset.maximumSize
      ).data
    } catch {
      throw OmarchyThemeConversionError.invalidAsset(
        path: sourcePath,
        reason: String(describing: error)
      )
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0,
      (CGImageSourceGetType(source) as String?) == expectedType
    else {
      throw OmarchyThemeConversionError.invalidAsset(
        path: sourcePath,
        reason: "the bytes do not decode as the filename's PNG or JPEG type"
      )
    }
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0, height > 0,
      width <= maximumImageDimension, height <= maximumImageDimension,
      width.multipliedReportingOverflow(by: height).overflow == false,
      width * height <= maximumImagePixels
    else {
      throw OmarchyThemeConversionError.invalidAsset(
        path: sourcePath,
        reason:
          "image dimensions must be positive, at most 16384 per side, and at most 64 megapixels"
      )
    }
    let decodeOptions =
      [
        kCGImageSourceShouldCache: true,
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions),
      CGImageSourceGetStatus(source) == .statusComplete,
      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
      let provider = image.dataProvider,
      provider.data != nil
    else {
      throw OmarchyThemeConversionError.invalidAsset(
        path: sourcePath,
        reason: "ImageIO cannot fully decode the image"
      )
    }

    return LoadedImage(
      sourcePath: sourcePath,
      packagePath: packagePath,
      mediaType: expectedType,
      data: data
    )
  }

  private static func writePackage(
    at package: URL,
    staged: StagedOmarchyTheme,
    palette: OmarchyPaletteConversion,
    classified: Classified,
    defaultBackground: LoadedImage
  ) throws {
    for directory in ["sources", "backgrounds", "previews", "wallpapers", "LICENSES"] {
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

    let defaultPNG = try pngData(from: defaultBackground)
    guard defaultPNG.count <= WallpaperAsset.maximumSize else {
      throw OmarchyThemeConversionError.invalidAsset(
        path: defaultBackground.sourcePath,
        reason: "the converted PNG exceeds the 32 MiB wallpaper limit"
      )
    }
    try defaultPNG.write(to: package.appending(path: "wallpapers/default.png"))
    try themeManifest(staged: staged, palette: palette).write(
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

  private static func pngData(from image: LoadedImage) throws -> Data {
    if image.mediaType == "public.png" { return image.data }
    guard let source = CGImageSourceCreateWithData(image.data as CFData, nil) else {
      throw OmarchyThemeConversionError.invalidAsset(
        path: image.sourcePath,
        reason: "cannot reopen the selected JPEG"
      )
    }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output as CFMutableData,
        "public.png" as CFString,
        1,
        nil
      )
    else {
      throw OmarchyThemeConversionError.invalidAsset(
        path: image.sourcePath,
        reason: "cannot prepare the default PNG conversion"
      )
    }
    CGImageDestinationAddImageFromSource(destination, source, 0, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw OmarchyThemeConversionError.invalidAsset(
        path: image.sourcePath,
        reason: "cannot convert the selected default image to PNG"
      )
    }
    return output as Data
  }

  private static func themeManifest(
    staged: StagedOmarchyTheme,
    palette: OmarchyPaletteConversion
  ) -> String {
    let semantic = palette.semantic
    let terminal = palette.terminal
    let ansi = terminal.ansi.map { "  \"\($0.rawValue)\"" }.joined(separator: ",\n")
    let displayName = staged.themeID.split(separator: "-").map { part in
      part.prefix(1).uppercased() + part.dropFirst()
    }.joined(separator: " ")
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

      [wallpaper]
      path = "wallpapers/default.png"
      source = "\(staged.sourceURL.absoluteString) at \(staged.resolvedCommit)"
      author = "Not verified by the safe importer"
      license = "Not verified; personal use only"
      """ + "\n"
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
