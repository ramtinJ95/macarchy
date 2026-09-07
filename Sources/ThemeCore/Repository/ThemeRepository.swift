import Darwin
import Foundation

package struct ThemePackageDeletionTarget: Equatable, Sendable {
  package let themeID: String
  package let packageURL: URL
  fileprivate let device: dev_t
  fileprivate let inode: ino_t
  fileprivate let birthSeconds: Int
  fileprivate let birthNanoseconds: Int
}

public struct ThemeRepository: Sendable {
  private let builtInRoot: URL
  private let userRoot: URL?

  public init(builtInRoot: URL, userRoot: URL? = nil) {
    self.builtInRoot = builtInRoot
    self.userRoot = userRoot
  }

  public func packages() throws -> [ThemePackage] {
    try loadPackages(in: [builtInRoot, userRoot].compactMap { $0 })
  }

  /// A deletion selection binds a user-library directory, not just a reusable theme ID.
  /// Callers must revalidate it under ThemePackageLock immediately before mutation.
  package func deletionTarget(for package: ThemePackage) throws -> ThemePackageDeletionTarget? {
    let directory = package.packageURL.standardizedFileURL
    guard let userRoot = userRoot?.standardizedFileURL,
      directory.deletingLastPathComponent().path == userRoot.path,
      !directory.lastPathComponent.hasPrefix(".")
    else { return nil }

    let builtInPath = builtInRoot.resolvingSymlinksInPath().standardizedFileURL.path
    let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
    guard directoryPath != builtInPath,
      !directoryPath.hasPrefix(builtInPath + "/"),
      !builtInPath.hasPrefix(directoryPath + "/")
    else { return nil }

    // Reuse the no-symlink ancestor walk. A linked user root/package is not owned
    // merely because discovery can read a valid manifest through it.
    let descriptor = try PinnedFilesystem.openDirectory(at: directory)
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw PinnedFilesystemError(operation: "inspect theme directory", url: directory, code: errno)
    }
    return ThemePackageDeletionTarget(
      themeID: package.id,
      packageURL: directory,
      device: metadata.st_dev,
      inode: metadata.st_ino,
      birthSeconds: metadata.st_birthtimespec.tv_sec,
      birthNanoseconds: metadata.st_birthtimespec.tv_nsec
    )
  }

  package func validateDeletionTarget(_ target: ThemePackageDeletionTarget) throws {
    let current = try package(id: target.themeID)
    guard try deletionTarget(for: current) == target else {
      throw ThemeDiagnostic(
        location: .init(file: target.packageURL),
        message:
          "The selected user theme changed or is protected. Reopen the picker and confirm again."
      )
    }
  }

  package func builtInPackage(id: String) throws -> ThemePackage? {
    try loadPackages(in: [builtInRoot]).first { $0.id == id }
  }

  private func loadPackages(in roots: [URL]) throws -> [ThemePackage] {
    var packages: [ThemePackage] = []
    for root in roots {
      let children: [URL]
      do {
        children = try FileManager.default.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        )
      } catch {
        let cocoaError = error as NSError
        if root == userRoot,
          cocoaError.domain == NSCocoaErrorDomain,
          [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoaError.code)
        {
          continue
        }
        throw ThemeDiagnostic(
          location: .init(file: root),
          message: "Cannot discover theme packages: \(error.localizedDescription)")
      }

      for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let values = try child.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { continue }
        packages.append(try ThemePackageLoader().load(packageURL: child))
      }
    }

    var seen: [String: URL] = [:]
    for package in packages {
      if let first = seen[package.id] {
        throw ThemeDiagnostic(
          location: .init(file: package.packageURL.appending(path: "theme.toml")),
          field: "id",
          message: "Duplicate theme identifier '\(package.id)'; first declared by \(first.path)"
        )
      }
      seen[package.id] = package.packageURL
    }

    return packages.sorted(by: { $0.id < $1.id })
  }

  public func package(id: String) throws -> ThemePackage {
    let available = try packages()
    guard let package = available.first(where: { $0.id == id }) else {
      throw ThemeDiagnostic(
        location: .init(file: builtInRoot),
        field: "id",
        message: "Unknown theme '\(id)'; available: \(available.map(\.id).joined(separator: ", "))"
      )
    }
    return package
  }
}
