import Darwin
import Foundation

public struct ImportedThemePreviewLoader: Sendable {
  private let maximumPreviewCount: Int
  private let maximumTotalBytes: Int64

  public init() {
    maximumPreviewCount = OmarchyThemeStager.maximumStagingEntries
    maximumTotalBytes = OmarchyThemeStager.maximumStagingBytes
  }

  package init(maximumPreviewCount: Int, maximumTotalBytes: Int64) {
    precondition(maximumPreviewCount >= 0 && maximumTotalBytes >= 0)
    self.maximumPreviewCount = maximumPreviewCount
    self.maximumTotalBytes = maximumTotalBytes
  }

  public func load(package: ThemePackage) throws -> [ThemePreviewAsset] {
    let reportURL = package.packageURL.appending(path: "import.json")
    let packageDescriptor = package.packageURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard packageDescriptor >= 0 else {
      throw ThemeDiagnostic(
        location: .init(file: reportURL),
        message: "Cannot open imported theme package: \(String(cString: strerror(errno)))"
      )
    }
    defer { Darwin.close(packageDescriptor) }

    let reportDescriptor = "import.json".withCString {
      openat(packageDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard reportDescriptor >= 0 else {
      if errno == ENOENT { return [] }
      throw ThemeDiagnostic(
        location: .init(file: reportURL),
        message: "Cannot open Omarchy import report: \(String(cString: strerror(errno)))"
      )
    }
    defer { Darwin.close(reportDescriptor) }

    let report: OmarchyThemeConversionReport
    do {
      report = try JSONDecoder().decode(
        OmarchyThemeConversionReport.self,
        from: BoundedRegularFile.read(
          descriptor: reportDescriptor,
          maximumSize: OmarchyThemeConversionReport.maximumEncodedSize
        ).data
      )
    } catch {
      throw ThemeDiagnostic(
        location: .init(file: reportURL),
        message: "Cannot read Omarchy import report: \(error)"
      )
    }
    guard report.schemaVersion == OmarchyThemeConversionReport.currentSchemaVersion else {
      throw ThemeDiagnostic(
        location: .init(file: reportURL),
        field: "schema_version",
        message:
          "Unsupported Omarchy import report schema version \(report.schemaVersion); expected "
          + "\(OmarchyThemeConversionReport.currentSchemaVersion)"
      )
    }
    guard report.themeID == package.id else {
      throw ThemeDiagnostic(
        location: .init(file: reportURL),
        field: "theme_id",
        message: "Omarchy import report theme '\(report.themeID)' does not match '\(package.id)'"
      )
    }
    guard report.previews.count <= maximumPreviewCount else {
      throw ThemeDiagnostic(
        location: .init(file: reportURL),
        field: "previews",
        message: "Imported preview inventory exceeds the \(maximumPreviewCount)-entry limit"
      )
    }
    guard !report.previews.isEmpty else { return [] }

    let previewsDescriptor = "previews".withCString {
      openat(
        packageDescriptor,
        $0,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
      )
    }
    guard previewsDescriptor >= 0 else {
      throw ThemeDiagnostic(
        location: .init(file: reportURL),
        field: "previews.package_path",
        message: "Cannot open imported previews directory: \(String(cString: strerror(errno)))"
      )
    }
    defer { Darwin.close(previewsDescriptor) }

    var filenames: Set<String> = []
    var totalBytes: Int64 = 0
    return try report.previews.map { preview in
      let sourceComponents = preview.sourcePath.split(
        separator: "/",
        omittingEmptySubsequences: false
      )
      guard
        !preview.sourcePath.hasPrefix("/"),
        !preview.sourcePath.contains("\0"),
        sourceComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
      else {
        throw ThemeDiagnostic(
          location: .init(file: reportURL),
          field: "previews.source_path",
          message: "Imported preview source path must be a safe relative path"
        )
      }

      let packageComponents = preview.packagePath.split(
        separator: "/",
        omittingEmptySubsequences: false
      )
      guard
        packageComponents.count == 2,
        packageComponents[0] == "previews",
        !preview.packagePath.contains("\0"),
        packageComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
      else {
        throw ThemeDiagnostic(
          location: .init(file: reportURL),
          field: "previews.package_path",
          message: "Imported preview must name one file directly under previews/"
        )
      }
      guard
        let format = ThemeBackgroundFormat(
          pathExtension: URL(filePath: preview.packagePath).pathExtension)
      else {
        throw ThemeDiagnostic(
          location: .init(file: reportURL),
          field: "previews.package_path",
          message: "Imported preview has an unsupported image extension"
        )
      }
      guard sourceComponents.last == packageComponents[1] else {
        throw ThemeDiagnostic(
          location: .init(file: reportURL),
          field: "previews.source_path",
          message: "Imported preview source and package filenames must match"
        )
      }

      let filename = String(packageComponents[1])
      let collisionKey = filename.precomposedStringWithCanonicalMapping.lowercased()
      guard filenames.insert(collisionKey).inserted else {
        throw ThemeDiagnostic(
          location: .init(file: reportURL),
          field: "previews.package_path",
          message: "Imported preview path '\(preview.packagePath)' is listed more than once"
        )
      }

      let descriptor = filename.withCString {
        openat(previewsDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      }
      guard descriptor >= 0 else {
        throw ThemeDiagnostic(
          location: .init(file: reportURL),
          field: "previews.package_path",
          message:
            "Cannot open imported preview '\(preview.packagePath)': "
            + String(cString: strerror(errno))
        )
      }
      defer { Darwin.close(descriptor) }

      do {
        let data = try BoundedRegularFile.read(
          descriptor: descriptor,
          maximumSize: ThemeImageAsset.maximumSize
        ).data
        let (updatedTotal, overflow) = totalBytes.addingReportingOverflow(Int64(data.count))
        guard !overflow, updatedTotal <= maximumTotalBytes else {
          let unit = 1_048_576
          let limit =
            maximumTotalBytes.isMultiple(of: Int64(unit))
            ? "\(maximumTotalBytes / Int64(unit)) MiB"
            : "\(maximumTotalBytes) bytes"
          throw ThemeDiagnostic(
            location: .init(file: reportURL),
            field: "previews",
            message: "Imported previews exceed the \(limit) aggregate limit"
          )
        }
        try ThemeImageAsset.validate(data: data, format: format)
        totalBytes = updatedTotal
        return ThemePreviewAsset(
          sourcePath: preview.sourcePath,
          packagePath: preview.packagePath,
          format: format,
          data: data
        )
      } catch let diagnostic as ThemeDiagnostic {
        throw diagnostic
      } catch {
        throw ThemeDiagnostic(
          location: .init(file: reportURL),
          field: "previews.package_path",
          message: "Cannot load imported preview '\(preview.packagePath)': \(error)"
        )
      }
    }
  }
}
