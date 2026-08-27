import Darwin
import Dispatch
import Foundation

package enum OmarchyThemePackageInstallationError: Error, CustomStringConvertible, Equatable,
  Sendable
{
  case unsafeThemesRoot(String)
  case unsafeExistingPackage(String)
  case filesystem(String)
  case interruptedTransaction(String)
  case lockDirectory(String)
  case lock(operation: String, code: Int32)
  case publication(operation: String, code: Int32)

  package var description: String {
    switch self {
    case .unsafeThemesRoot(let path):
      "The user theme root is not a real directory: \(path)"
    case .unsafeExistingPackage(let path):
      "The installed theme destination is not a real directory: \(path)"
    case .filesystem(let detail):
      "Cannot install the converted Omarchy theme package: \(detail)"
    case .interruptedTransaction(let path):
      "An interrupted theme-install transaction remains at \(path); refusing to discard recovery evidence"
    case .lockDirectory(let detail):
      "Cannot prepare the theme-package lock: \(detail)"
    case .lock(let operation, let code):
      "Cannot \(operation) the theme-package lock (errno \(code)): "
        + String(cString: strerror(code))
    case .publication(let operation, let code):
      "Cannot \(operation) the converted Omarchy theme package (errno \(code)): "
        + String(cString: strerror(code))
    }
  }
}

package struct ThemePackageLock: Sendable {
  private static let processSemaphore = DispatchSemaphore(value: 1)
  private let root: URL

  package init(root: URL) {
    self.root = root.standardizedFileURL
  }

  package func withLock<Output: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Output
  ) async throws -> Output {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        Self.processSemaphore.wait()
        continuation.resume()
      }
    }
    defer { Self.processSemaphore.signal() }
    try Task.checkCancellation()
    let descriptor = try acquire()
    defer { Darwin.close(descriptor) }
    return try await operation()
  }

  private func acquire() throws -> Int32 {
    let runDirectory = root.appending(path: "run", directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(
        at: runDirectory,
        withIntermediateDirectories: true
      )
    } catch {
      throw OmarchyThemePackageInstallationError.lockDirectory(
        "cannot create \(runDirectory.path): \(error)"
      )
    }
    let lockURL = runDirectory.appending(path: "theme-package.lock")

    let descriptor = lockURL.path.withCString {
      Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    guard descriptor >= 0 else {
      throw OmarchyThemePackageInstallationError.lock(operation: "open", code: errno)
    }
    while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
      if errno == EINTR { continue }
      let code = errno
      Darwin.close(descriptor)
      throw OmarchyThemePackageInstallationError.lock(
        operation: "acquire",
        code: code
      )
    }
    return descriptor
  }
}

package struct OmarchyThemePackageInstallation: Sendable {
  package let package: ThemePackage
  package let replacedExistingPackage: Bool

  private let destination: URL
  private let displacedPackage: URL

  fileprivate init(
    package: ThemePackage,
    replacedExistingPackage: Bool,
    destination: URL,
    displacedPackage: URL
  ) {
    self.package = package
    self.replacedExistingPackage = replacedExistingPackage
    self.destination = destination
    self.displacedPackage = displacedPackage
  }

  package func finish() throws {
    guard replacedExistingPackage else { return }
    do {
      try FileManager.default.removeItem(at: displacedPackage)
    } catch {
      throw OmarchyThemePackageInstallationError.filesystem(
        "cannot remove the replaced package at \(displacedPackage.path): \(error)"
      )
    }
  }

  package func rollback() throws {
    if replacedExistingPackage {
      try Self.swap(destination, displacedPackage, operation: "restore the previous")
    } else {
      try Self.renameExclusive(
        destination,
        displacedPackage,
        operation: "withdraw the new"
      )
    }

    do {
      try FileManager.default.removeItem(at: displacedPackage)
    } catch {
      let completed =
        replacedExistingPackage
        ? "the previous package was restored"
        : "the uncommitted package was withdrawn"
      throw OmarchyThemePackageInstallationError.filesystem(
        "\(completed), but the rejected package remains at "
          + "\(displacedPackage.path): \(error)"
      )
    }
  }

  fileprivate static func swap(_ first: URL, _ second: URL, operation: String) throws {
    let result = first.path.withCString { firstPath in
      second.path.withCString { secondPath in
        Darwin.renamex_np(firstPath, secondPath, UInt32(RENAME_SWAP))
      }
    }
    guard result == 0 else {
      throw OmarchyThemePackageInstallationError.publication(operation: operation, code: errno)
    }
  }

  fileprivate static func renameExclusive(
    _ source: URL,
    _ destination: URL,
    operation: String
  ) throws {
    let result = source.path.withCString { sourcePath in
      destination.path.withCString { destinationPath in
        Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
      }
    }
    guard result == 0 else {
      throw OmarchyThemePackageInstallationError.publication(operation: operation, code: errno)
    }
  }
}

package struct OmarchyThemePackageInstaller: Sendable {
  package init() {}

  package func wouldReplace(themeID: String, userThemesRoot: URL) throws -> Bool {
    let root = userThemesRoot.standardizedFileURL
    guard try validateRoot(root) else { return false }
    return try destinationExists(themeID: themeID, root: root)
  }

  package func install(
    package sourcePackage: ThemePackage,
    userThemesRoot: URL
  ) throws -> OmarchyThemePackageInstallation {
    let root = userThemesRoot.standardizedFileURL
    try prepareRoot(root)

    let destination = root.appending(path: sourcePackage.id, directoryHint: .isDirectory)
    let incoming = root.appending(
      path: ".macarchy-install-\(sourcePackage.id)-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    var shouldRemoveIncoming = true

    do {
      do {
        try FileManager.default.copyItem(at: sourcePackage.packageURL, to: incoming)
      } catch {
        throw OmarchyThemePackageInstallationError.filesystem(
          "cannot copy the validated package into \(root.path): \(error)"
        )
      }

      let copied: ThemePackage
      do {
        copied = try ThemePackageLoader().load(packageURL: incoming)
      } catch {
        throw OmarchyThemePackageInstallationError.filesystem(
          "the copied package did not pass validation: \(error)"
        )
      }
      guard copied.id == sourcePackage.id else {
        throw OmarchyThemePackageInstallationError.filesystem(
          "the copied package identifier changed from \(sourcePackage.id) to \(copied.id)"
        )
      }

      let replaced = try destinationExists(themeID: sourcePackage.id, root: root)
      if replaced {
        _ = try ThemePackageLoader().load(packageURL: destination)
        try OmarchyThemePackageInstallation.swap(
          incoming,
          destination,
          operation: "atomically replace"
        )
      } else {
        try OmarchyThemePackageInstallation.renameExclusive(
          incoming,
          destination,
          operation: "publish"
        )
      }
      shouldRemoveIncoming = false
      let installed = ThemePackage(
        packageURL: destination,
        schemaVersion: copied.schemaVersion,
        id: copied.id,
        displayName: copied.displayName,
        appearance: copied.appearance,
        semantic: copied.semantic,
        terminal: copied.terminal,
        wallpaper: copied.wallpaper,
        wallpaperData: copied.wallpaperData,
        mappings: copied.mappings
      )
      return OmarchyThemePackageInstallation(
        package: installed,
        replacedExistingPackage: replaced,
        destination: destination,
        displacedPackage: incoming
      )
    } catch {
      guard shouldRemoveIncoming, Self.entryExists(incoming) else { throw error }
      do {
        try FileManager.default.removeItem(at: incoming)
      } catch let cleanupError {
        throw OmarchyThemePackageInstallationError.filesystem(
          "installation failed (\(error)); temporary-package cleanup also failed "
            + "(\(cleanupError)); recovery evidence remains at \(incoming.path)"
        )
      }
      throw error
    }
  }

  private func destinationExists(themeID: String, root: URL) throws -> Bool {
    let destination = root.appending(path: themeID, directoryHint: .isDirectory)
    var metadata = stat()
    if lstat(destination.path, &metadata) == 0 {
      guard metadata.st_mode & S_IFMT == S_IFDIR else {
        throw OmarchyThemePackageInstallationError.unsafeExistingPackage(destination.path)
      }
      return true
    }
    guard errno == ENOENT else {
      throw OmarchyThemePackageInstallationError.filesystem(
        "cannot inspect \(destination.path): \(String(cString: strerror(errno)))"
      )
    }
    return false
  }

  private func prepareRoot(_ root: URL) throws {
    guard try !validateRoot(root) else { return }
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
      throw OmarchyThemePackageInstallationError.filesystem(
        "cannot create \(root.path): \(error)"
      )
    }
  }

  private func validateRoot(_ root: URL) throws -> Bool {
    var metadata = stat()
    guard lstat(root.path, &metadata) == 0 else {
      guard errno == ENOENT else {
        throw OmarchyThemePackageInstallationError.filesystem(
          "cannot inspect \(root.path): \(String(cString: strerror(errno)))"
        )
      }
      return false
    }
    guard metadata.st_mode & S_IFMT == S_IFDIR else {
      throw OmarchyThemePackageInstallationError.unsafeThemesRoot(root.path)
    }
    let children: [URL]
    do {
      children = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
      )
    } catch {
      throw OmarchyThemePackageInstallationError.filesystem(
        "cannot inspect \(root.path) for interrupted transactions: \(error)"
      )
    }
    if let residue = children.first(where: {
      $0.lastPathComponent.hasPrefix(".macarchy-install-")
    }) {
      throw OmarchyThemePackageInstallationError.interruptedTransaction(residue.path)
    }
    return true
  }

  private static func entryExists(_ url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0 || errno != ENOENT
  }
}
