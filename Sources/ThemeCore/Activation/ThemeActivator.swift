import CoreFoundation
import Darwin
import Foundation
import Synchronization

package enum ThemeActivationError: Error, CustomStringConvertible, Equatable, Sendable {
  case activeGenerationChanged(expected: String, active: String)
  case activationLock(operation: String, code: Int32)
  case cannotReplaceCurrent(Int32)
  case corruptGeneration(id: String, reason: String)
  case generatedFileTooLarge(path: String, size: Int, maximumSize: Int)

  package var description: String {
    switch self {
    case .activeGenerationChanged(let expected, let active):
      "Expected active generation '\(expected)', but '\(active)' is now active"
    case .activationLock(let operation, let code):
      "Cannot \(operation) activation lock (errno \(code)): \(String(cString: strerror(code)))"
    case .cannotReplaceCurrent(let code):
      "Cannot atomically replace current theme pointer (errno \(code)): \(String(cString: strerror(code)))"
    case .corruptGeneration(let id, let reason):
      "Generation '\(id)' matches the requested theme inputs but is corrupt: \(reason)"
    case .generatedFileTooLarge(let path, let size, let maximumSize):
      "Generated file '\(path)' is \(size) bytes; limit is \(maximumSize / 1_048_576) MiB"
    }
  }
}

package struct ThemeCommittedActivationError: Error, CustomStringConvertible, Sendable {
  package let manifest: GenerationManifest
  package let cause: String

  package var description: String {
    "Theme '\(manifest.themeID)' committed as generation '\(manifest.generationID)', but postcommit activation work failed: \(cause)"
  }
}

package enum ThemeDeactivationError: Error, CustomStringConvertible, Sendable {
  case activeGenerationChanged(expected: String, active: String)
  case invalidReconciliation(String)
  case system(operation: String, url: URL, code: Int32)

  package var description: String {
    switch self {
    case .activeGenerationChanged(let expected, let active):
      "Cannot remove setup theme generation '\(expected)' while '\(active)' is active"
    case .invalidReconciliation(let reason):
      "Cannot remove setup theme with invalid reconciliation state: \(reason)"
    case .system(let operation, let url, let code):
      "Cannot \(operation) \(url.path) (errno \(code)): \(String(cString: strerror(code)))"
    }
  }
}

package struct ActivationLock: Sendable {
  // lockf is process-scoped, so sibling threads also need a mutex.
  private static let processMutex = Mutex<Void>(())

  private let root: URL

  package init(root: URL) {
    self.root = root.standardizedFileURL
  }

  package func withLock<Value>(_ operation: () throws -> Value) throws -> Value {
    try Self.processMutex.withLock { _ in
      let runDirectory = root.appending(path: "run", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: runDirectory,
        withIntermediateDirectories: true
      )

      let lockURL = runDirectory.appending(path: "activation.lock")
      let descriptor = lockURL.path.withCString {
        Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
      }
      guard descriptor >= 0 else {
        throw ThemeActivationError.activationLock(operation: "open", code: errno)
      }
      defer { Darwin.close(descriptor) }

      while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
        if errno == EINTR { continue }
        throw ThemeActivationError.activationLock(operation: "acquire", code: errno)
      }
      return try operation()
    }
  }
}

package enum ActivationCheckpoint: Sendable {
  case inputDigested
  case outputsRendered
  case generationWritten
  case generationPublished
  case generationSealed
  case generationCommitted
  case currentPointerReady
  case currentReplaced
  case generationsCleaned
  case changePublished
}

public struct ThemeActivator: Sendable {
  private static let rendererVersions: [String: Int] = {
    let internalVersions = ["capabilities": 1, "normalized_theme": 1]
    let consumerVersions = ConsumerCatalog.shared.rendererVersions
    precondition(
      Set(internalVersions.keys).isDisjoint(with: consumerVersions.keys),
      "Internal renderer IDs collide with the consumer catalog"
    )
    return consumerVersions.merging(internalVersions) { _, _ in
      preconditionFailure("Duplicate renderer ID")
    }
  }()

  private let root: URL
  private let activationLock: ActivationLock
  private let faultInjector: @Sendable (ActivationCheckpoint) throws -> Void
  private let onThemeChanged: @Sendable (ThemeChanged) -> Void
  private let postDarwinNotification: @Sendable (String) -> Void

  public init(
    root: URL,
    onThemeChanged: @escaping @Sendable (ThemeChanged) -> Void = { _ in }
  ) {
    self.init(
      root: root,
      faultInjector: { _ in },
      onThemeChanged: onThemeChanged,
      postDarwinNotification: Self.postDarwinNotification
    )
  }

  package init(
    root: URL,
    faultInjector: @escaping @Sendable (ActivationCheckpoint) throws -> Void,
    onThemeChanged: @escaping @Sendable (ThemeChanged) -> Void = { _ in },
    postDarwinNotification: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.root = root.standardizedFileURL
    activationLock = ActivationLock(root: root)
    self.faultInjector = faultInjector
    self.onThemeChanged = onThemeChanged
    self.postDarwinNotification = postDarwinNotification
  }

  public func activate(package: ThemePackage) throws -> GenerationManifest {
    try activate(package: package, onCommittedLocked: { _ in })
  }

  package func activate(
    package: ThemePackage,
    onCommittedLocked: (GenerationManifest) throws -> Void
  ) throws -> GenerationManifest {
    let background =
      package.backgrounds.first.map {
        PreparedThemeBackground(
          selection: GenerationBackground(id: $0.id, format: $0.format),
          data: package.data(for: $0)
        )
      } ?? PreparedThemeBackground(selection: nil, data: nil)
    return try activate(
      package: package,
      expectedActiveGenerationID: nil,
      preparedBackground: { background },
      onCommittedLocked: onCommittedLocked
    )
  }

  package func deactivate(
    expectedGenerationID: String,
    dryRun: Bool
  ) throws -> String? {
    let cleanupError: String? = try activationLock.withLock {
      let statusStore = ReconciliationStatusStore(root: root)
      let manifest = try statusStore.activeManifest()
      guard manifest.generationID == expectedGenerationID else {
        throw ThemeDeactivationError.activeGenerationChanged(
          expected: expectedGenerationID,
          active: manifest.generationID
        )
      }
      do {
        switch try statusStore.read() {
        case .missing:
          break
        case .current(let record) where record.generationID == expectedGenerationID:
          break
        case .current, .stale:
          throw ThemeDeactivationError.invalidReconciliation(
            "status does not describe the setup-owned active generation"
          )
        }
      } catch let error as ThemeDeactivationError {
        throw error
      } catch {
        throw ThemeDeactivationError.invalidReconciliation(String(describing: error))
      }
      if dryRun { return nil }

      let currentURL = root.appending(path: "current")
      let generationURL = root.appending(
        path: "generations/\(expectedGenerationID)",
        directoryHint: .isDirectory
      )
      let statusURL = root.appending(path: "state/reconciliation.json")
      let nonce = UUID().uuidString.lowercased()
      let currentClaim = root.appending(path: ".setup-teardown-current-\(nonce)")
      let generationClaim = generationURL.deletingLastPathComponent().appending(
        path: ".setup-teardown-\(expectedGenerationID)-\(nonce)",
        directoryHint: .isDirectory
      )
      let statusClaim = statusURL.deletingLastPathComponent().appending(
        path: ".setup-teardown-reconciliation-\(nonce).json"
      )

      try rename(currentURL, to: currentClaim, operation: "claim current theme pointer")
      do {
        try rename(generationURL, to: generationClaim, operation: "claim theme generation")
      } catch let claimError {
        do {
          try rename(currentClaim, to: currentURL, operation: "restore current theme pointer")
        } catch {
          throw error
        }
        throw claimError
      }
      var statusClaimed = false
      if FileManager.default.fileExists(atPath: statusURL.path) {
        do {
          try rename(statusURL, to: statusClaim, operation: "claim reconciliation status")
          statusClaimed = true
        } catch let claimError {
          do {
            try rename(generationClaim, to: generationURL, operation: "restore theme generation")
            try rename(currentClaim, to: currentURL, operation: "restore current theme pointer")
          } catch {
            throw error
          }
          throw claimError
        }
      }

      var cleanupError: String?
      do {
        try FileManager.default.removeItem(at: currentClaim)
        if statusClaimed { try FileManager.default.removeItem(at: statusClaim) }
        makeWritableForRemoval(generationClaim)
        try FileManager.default.removeItem(at: generationClaim)
      } catch {
        cleanupError = String(describing: error)
      }
      return cleanupError
    }

    if !dryRun { postDarwinNotification(ThemeChanged.darwinNotificationName) }
    return cleanupError
  }

  private func rename(_ source: URL, to destination: URL, operation: String) throws {
    let result = source.path.withCString { sourcePath in
      destination.path.withCString { destinationPath in
        Darwin.rename(sourcePath, destinationPath)
      }
    }
    guard result == 0 else {
      throw ThemeDeactivationError.system(operation: operation, url: source, code: errno)
    }
  }

  package func activate(
    package: ThemePackage,
    expectedActiveGenerationID: String?,
    preparedBackground: () throws -> PreparedThemeBackground,
    onCommittedLocked: (GenerationManifest) throws -> Void = { _ in }
  ) throws -> GenerationManifest {
    let result = try activationLock.withLock {
      let background = try preparedBackground()
      if let expectedActiveGenerationID {
        let active = try ReconciliationStatusStore(root: root).activeManifest().generationID
        guard active == expectedActiveGenerationID else {
          throw ThemeActivationError.activeGenerationChanged(
            expected: expectedActiveGenerationID,
            active: active
          )
        }
      }

      let interruptedTrash = try recoverInterruptedActivation()
      let result = try activateLocked(
        package: package,
        background: background,
        interruptedTrash: interruptedTrash
      )
      do {
        try onCommittedLocked(result.manifest)
      } catch {
        throw committedError(result.manifest, String(describing: error))
      }
      return result
    }

    onThemeChanged(ThemeChanged(manifest: result.manifest))
    postDarwinNotification(ThemeChanged.darwinNotificationName)
    do {
      try faultInjector(.changePublished)
    } catch {
      throw committedError(result.manifest, String(describing: error))
    }

    var cleanupError = result.cleanupError
    for trashURL in result.trashURLs where cleanupError == nil {
      do {
        makeWritableForRemoval(trashURL)
        try FileManager.default.removeItem(at: trashURL)
      } catch {
        cleanupError = String(describing: error)
      }
    }
    do {
      try faultInjector(.generationsCleaned)
    } catch {
      throw committedError(result.manifest, String(describing: error))
    }
    if let cleanupError {
      throw committedError(result.manifest, cleanupError)
    }
    return result.manifest
  }

  private static func postDarwinNotification(named name: String) {
    // The filesystem remains authoritative; the Darwin notification carries no payload.
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(name as CFString),
      nil,
      nil,
      true
    )
  }

  private func activateLocked(
    package: ThemePackage,
    background: PreparedThemeBackground,
    interruptedTrash: [URL]
  ) throws -> LockedActivationResult {
    let previousGenerationID = currentGenerationID()
    try validate(background: background)
    let themeDigest = try generationThemeDigest(package: package)
    let inputDigest = try generationInputDigest(
      themeDigest: themeDigest,
      background: background
    )
    try faultInjector(.inputDigested)

    if let reusable = try reusableGeneration(inputDigest: inputDigest, package: package) {
      try replaceCurrent(with: reusable.generationID)
      return try finishCommit(
        reusable,
        previousGenerationID: previousGenerationID,
        interruptedTrash: interruptedTrash
      )
    }

    let generationID = "g-\(UUID().uuidString.lowercased())"
    let rendered: RenderedTheme
    do {
      rendered = try ThemeRenderer().render(
        package: package,
        generationID: generationID,
        wallpaperData: background.data
      )
    } catch RenderedArtifactCollectionError.dataTooLarge(
      let path,
      let size,
      let maximumSize
    ) {
      // Preserve activation's established checkpoint and typed size-error contract
      // while package-level artifact collections reject oversized data themselves.
      try faultInjector(.outputsRendered)
      throw ThemeActivationError.generatedFileTooLarge(
        path: path,
        size: size,
        maximumSize: maximumSize
      )
    }
    try faultInjector(.outputsRendered)
    for artifact in rendered.artifacts {
      try requireGeneratedFileSize(artifact)
    }

    let manifest = GenerationManifest(
      generationID: generationID,
      themeID: package.id,
      themeSchemaVersion: package.schemaVersion,
      inputDigest: inputDigest,
      themeDigest: themeDigest,
      background: background.selection,
      rendererVersions: Self.rendererVersions,
      artifacts: rendered.manifestArtifacts
    )
    let manifestData = try encode(manifest)
    try requireGeneratedFileSize(
      manifestData,
      path: "manifest.json",
      maximumSize: BoundedRegularFile.maximumSize
    )

    let generationsRoot = root.appending(path: "generations", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: generationsRoot, withIntermediateDirectories: true)

    let stagingURL = generationsRoot.appending(
      path: ".staging-\(generationID)", directoryHint: .isDirectory)
    let generationURL = generationsRoot.appending(path: generationID, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: false)

    let generationsDescriptor = try PinnedFilesystem.openDirectory(at: generationsRoot)
    defer { Darwin.close(generationsDescriptor) }
    let stagingDescriptor = try PinnedFilesystem.openDirectory(
      parentDescriptor: generationsDescriptor,
      name: stagingURL.lastPathComponent,
      url: stagingURL
    )
    defer { Darwin.close(stagingDescriptor) }

    var shouldRemoveUncommittedGeneration = true
    var cleanupURL = stagingURL
    defer {
      if shouldRemoveUncommittedGeneration {
        makeWritableForRemoval(cleanupURL)
        try? FileManager.default.removeItem(at: cleanupURL)
      }
    }

    try ThemeRenderer().write(rendered, to: stagingURL)
    try manifestData.write(to: stagingURL.appending(path: "manifest.json"), options: [.atomic])
    try faultInjector(.generationWritten)

    try makeContentsReadOnly(stagingURL, artifactPaths: rendered.artifacts.map(\.path))
    try PinnedFilesystem.publishDirectoryAtomicallyAndSeal(
      parentDescriptor: generationsDescriptor,
      directoryDescriptor: stagingDescriptor,
      sourceName: stagingURL.lastPathComponent,
      destinationName: generationID,
      sourceURL: stagingURL,
      destinationURL: generationURL,
      didPublish: {
        cleanupURL = generationURL
        try faultInjector(.generationPublished)
      }
    )
    try faultInjector(.generationSealed)
    shouldRemoveUncommittedGeneration = false
    try faultInjector(.generationCommitted)

    try replaceCurrent(with: generationID)
    return try finishCommit(
      manifest,
      previousGenerationID: previousGenerationID,
      interruptedTrash: interruptedTrash
    )
  }

  private func finishCommit(
    _ manifest: GenerationManifest,
    previousGenerationID: String?,
    interruptedTrash: [URL]
  ) throws -> LockedActivationResult {
    do {
      try faultInjector(.currentReplaced)
    } catch {
      throw committedError(manifest, String(describing: error))
    }

    let collection = collectGenerations(
      currentGenerationID: manifest.generationID,
      previousGenerationID: previousGenerationID
    )
    return LockedActivationResult(
      manifest: manifest,
      trashURLs: interruptedTrash + collection.trashURLs,
      cleanupError: collection.error
    )
  }

  private func recoverInterruptedActivation() throws -> [URL] {
    let generationsRoot = root.appending(path: "generations", directoryHint: .isDirectory)
    let activeGenerationID = currentGenerationID()
    var trashURLs = [URL]()
    if FileManager.default.fileExists(atPath: generationsRoot.path) {
      for item in try FileManager.default.contentsOfDirectory(
        at: generationsRoot,
        includingPropertiesForKeys: nil
      ) {
        if isStagingName(item.lastPathComponent), isRealDirectory(item) {
          makeWritableForRemoval(item)
          try FileManager.default.removeItem(at: item)
        } else if item.lastPathComponent != activeGenerationID,
          isRecoverablePublishedGeneration(item)
        {
          makeWritableForRemoval(item)
          try FileManager.default.removeItem(at: item)
        } else if isTrashName(item.lastPathComponent), isRealDirectory(item) {
          trashURLs.append(item)
        }
      }
    }

    for item in try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    ) where isTemporaryPointerName(item.lastPathComponent) && isSymbolicLink(item) {
      try FileManager.default.removeItem(at: item)
    }
    return trashURLs
  }

  private func collectGenerations(
    currentGenerationID: String,
    previousGenerationID: String?
  ) -> (trashURLs: [URL], error: String?) {
    let generationsRoot = root.appending(path: "generations", directoryHint: .isDirectory)
    let generations: [(url: URL, modified: Date)]
    do {
      generations = try FileManager.default.contentsOfDirectory(
        at: generationsRoot,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      ).compactMap(validGenerationForCleanup)
    } catch {
      return ([], String(describing: error))
    }

    var retained = Set([currentGenerationID])
    // The old pointer is diagnostic and reuse evidence; a no-op activation keeps its newest peer.
    if let previousGenerationID, previousGenerationID != currentGenerationID,
      generations.contains(where: { $0.url.lastPathComponent == previousGenerationID })
    {
      retained.insert(previousGenerationID)
    } else if let prior =
      generations
      .filter({ $0.url.lastPathComponent != currentGenerationID })
      .sorted(by: {
        $0.modified == $1.modified
          ? $0.url.lastPathComponent < $1.url.lastPathComponent
          : $0.modified > $1.modified
      }).first
    {
      retained.insert(prior.url.lastPathComponent)
    }

    var trashURLs = [URL]()
    for generation in generations where !retained.contains(generation.url.lastPathComponent) {
      let trashURL = generationsRoot.appending(
        path: ".trash-\(generation.url.lastPathComponent)-\(UUID().uuidString.lowercased())",
        directoryHint: .isDirectory
      )
      do {
        try moveGenerationToTrash(generation.url, trashURL: trashURL)
        trashURLs.append(trashURL)
      } catch {
        return (trashURLs, String(describing: error))
      }
    }
    return (trashURLs, nil)
  }

  private func validGenerationForCleanup(_ url: URL) -> (url: URL, modified: Date)? {
    guard isGenerationID(url.lastPathComponent) else { return nil }
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
      return nil
    }
    guard
      let manifestFile = safelyReadManifest(at: url.appending(path: "manifest.json")),
      manifestFile.permissions & 0o222 == 0,
      let object = manifestObject(in: manifestFile.data),
      let schemaVersion = object["manifest_schema_version"] as? Int,
      let encodedKeys = GenerationManifest.encodedKeys(schemaVersion: schemaVersion),
      Set(object.keys) == encodedKeys,
      let manifest = try? JSONDecoder().decode(GenerationManifest.self, from: manifestFile.data),
      manifest.manifestSchemaVersion == schemaVersion,
      manifest.generationID == url.lastPathComponent,
      (try? manifest.validateArtifacts(at: url)) != nil
    else { return nil }
    let modified = Date(
      timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
        + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
    )
    return (url, modified)
  }

  private func moveGenerationToTrash(_ generationURL: URL, trashURL: URL) throws {
    let generationsRoot = generationURL.deletingLastPathComponent()
    let generationsDescriptor = try PinnedFilesystem.openDirectory(at: generationsRoot)
    defer { Darwin.close(generationsDescriptor) }
    let generationDescriptor = try PinnedFilesystem.openDirectory(
      parentDescriptor: generationsDescriptor,
      name: generationURL.lastPathComponent,
      url: generationURL
    )
    defer { Darwin.close(generationDescriptor) }
    var pinned = stat()
    guard fstat(generationDescriptor, &pinned) == 0 else {
      throw PinnedFilesystemError(
        operation: "inspect collectible generation",
        url: generationURL,
        code: errno
      )
    }
    let path = try PinnedFilesystem.metadata(
      parentDescriptor: generationsDescriptor,
      name: generationURL.lastPathComponent,
      url: generationURL
    )
    guard
      pinned.st_dev == path.st_dev,
      pinned.st_ino == path.st_ino,
      pinned.st_mode & 0o222 == 0
    else {
      throw PinnedFilesystemError(
        operation: "bind collectible generation",
        url: generationURL,
        code: ESTALE
      )
    }
    guard fchmod(generationDescriptor, 0o755) == 0 else {
      throw PinnedFilesystemError(
        operation: "prepare collectible generation",
        url: generationURL,
        code: errno
      )
    }
    var restoreReadOnly = true
    defer {
      if restoreReadOnly {
        _ = fchmod(generationDescriptor, 0o555)
        _ = fsync(generationDescriptor)
      }
    }
    guard fsync(generationDescriptor) == 0 else {
      throw PinnedFilesystemError(
        operation: "sync collectible generation",
        url: generationURL,
        code: errno
      )
    }
    let preparedPath = try PinnedFilesystem.metadata(
      parentDescriptor: generationsDescriptor,
      name: generationURL.lastPathComponent,
      url: generationURL
    )
    guard pinned.st_dev == preparedPath.st_dev, pinned.st_ino == preparedPath.st_ino else {
      throw PinnedFilesystemError(
        operation: "rebind collectible generation",
        url: generationURL,
        code: ESTALE
      )
    }
    let moved = generationURL.lastPathComponent.withCString { source in
      trashURL.lastPathComponent.withCString { destination in
        Darwin.renameatx_np(
          generationsDescriptor,
          source,
          generationsDescriptor,
          destination,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard moved == 0 else {
      throw PinnedFilesystemError(
        operation: "publish collectible generation trash",
        url: trashURL,
        code: errno
      )
    }
    let trash = try PinnedFilesystem.metadata(
      parentDescriptor: generationsDescriptor,
      name: trashURL.lastPathComponent,
      url: trashURL
    )
    guard pinned.st_dev == trash.st_dev, pinned.st_ino == trash.st_ino else {
      throw PinnedFilesystemError(
        operation: "bind collectible generation trash",
        url: trashURL,
        code: ESTALE
      )
    }
    restoreReadOnly = false
    guard fsync(generationsDescriptor) == 0 else {
      throw PinnedFilesystemError(
        operation: "sync collectible generation trash",
        url: trashURL,
        code: errno
      )
    }
  }

  private func isStagingName(_ name: String) -> Bool {
    name.hasPrefix(".staging-") && isGenerationID(String(name.dropFirst(9)))
  }

  private func isTrashName(_ name: String) -> Bool {
    isTemporaryName(name, prefix: ".trash-")
  }

  private func isTemporaryPointerName(_ name: String) -> Bool {
    isTemporaryName(name, prefix: ".current-")
  }

  private func isTemporaryName(_ name: String, prefix: String) -> Bool {
    guard name.hasPrefix(prefix) else { return false }
    let value = name.dropFirst(prefix.count)
    guard value.count == 75 else { return false }
    let separator = value.index(value.startIndex, offsetBy: 38)
    guard value[separator] == "-" else { return false }
    let generationID = String(value[..<separator])
    let nonce = String(value[value.index(after: separator)...])
    return isGenerationID(generationID)
      && nonce == nonce.lowercased()
      && UUID(uuidString: nonce) != nil
  }

  private func isRealDirectory(_ url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFDIR
  }

  private func isRecoverablePublishedGeneration(_ url: URL) -> Bool {
    guard isGenerationID(url.lastPathComponent) else { return false }
    var metadata = stat()
    guard
      lstat(url.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_mode & 0o222 != 0,
      let manifestFile = safelyReadManifest(at: url.appending(path: "manifest.json")),
      manifestFile.permissions & 0o222 == 0,
      let object = manifestObject(in: manifestFile.data),
      Set(object.keys) == GenerationManifest.encodedKeys,
      let manifest = try? JSONDecoder().decode(GenerationManifest.self, from: manifestFile.data),
      manifest.generationID == url.lastPathComponent,
      (try? manifest.validateArtifacts(
        at: url,
        requireReadOnlyGenerationDirectory: false
      )) != nil,
      hasExactGenerationInventory(manifest, at: url)
    else { return false }
    return true
  }

  private func hasExactGenerationInventory(
    _ manifest: GenerationManifest,
    at url: URL
  ) -> Bool {
    var rootEntries = Set(["manifest.json"])
    rootEntries.formUnion(
      manifest.artifacts.keys.map {
        String($0.split(separator: "/", maxSplits: 1)[0])
      })
    let generatedEntries = Set(
      manifest.artifacts.keys.compactMap { path -> String? in
        let components = path.split(separator: "/", maxSplits: 1)
        return components.count == 2 && components[0] == "generated"
          ? String(components[1])
          : nil
      }
    )
    do {
      let generationDescriptor = try PinnedFilesystem.openDirectory(at: url)
      defer { Darwin.close(generationDescriptor) }
      let rootInventory = try PinnedFilesystem.directoryEntries(
        descriptor: generationDescriptor,
        url: url,
        limit: rootEntries.count
      )
      guard !rootInventory.truncated, Set(rootInventory.entries) == rootEntries else {
        return false
      }
      let generatedURL = url.appending(path: "generated", directoryHint: .isDirectory)
      let generatedDescriptor = try PinnedFilesystem.openDirectory(
        parentDescriptor: generationDescriptor,
        name: "generated",
        url: generatedURL
      )
      defer { Darwin.close(generatedDescriptor) }
      let generatedInventory = try PinnedFilesystem.directoryEntries(
        descriptor: generatedDescriptor,
        url: generatedURL,
        limit: generatedEntries.count
      )
      return !generatedInventory.truncated
        && Set(generatedInventory.entries) == generatedEntries
    } catch {
      return false
    }
  }

  private func isSymbolicLink(_ url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFLNK
  }

  private func currentGenerationID() -> String? {
    let currentURL = root.appending(path: "current")
    guard
      let destination = try? FileManager.default.destinationOfSymbolicLink(
        atPath: currentURL.path
      )
    else { return nil }
    let components = destination.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2, components[0] == "generations" else { return nil }
    let generationID = String(components[1])
    return isGenerationID(generationID) ? generationID : nil
  }

  private func committedError(
    _ manifest: GenerationManifest,
    _ cause: String
  ) -> ThemeCommittedActivationError {
    ThemeCommittedActivationError(manifest: manifest, cause: cause)
  }

  private func reusableGeneration(
    inputDigest: String,
    package: ThemePackage
  ) throws -> GenerationManifest? {
    let generationsRoot = root.appending(path: "generations", directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: generationsRoot.path) else { return nil }

    let generationURLs = try FileManager.default.contentsOfDirectory(
      at: generationsRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

    var reusable: GenerationManifest?
    for generationURL in generationURLs {
      guard
        (try? generationURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      else { continue }

      let manifestURL = generationURL.appending(path: "manifest.json")
      guard
        let manifestFile = safelyReadManifest(at: manifestURL),
        let object = manifestObject(in: manifestFile.data),
        object["input_digest"] as? String == inputDigest
      else { continue }

      try requireReusable(
        Set(object.keys) == GenerationManifest.encodedKeys,
        generationURL,
        "manifest.json contains unknown or missing fields"
      )
      try requireReusable(
        manifestFile.permissions & 0o222 == 0,
        generationURL,
        "manifest.json is writable"
      )

      let manifest: GenerationManifest
      do {
        manifest = try JSONDecoder().decode(GenerationManifest.self, from: manifestFile.data)
      } catch {
        throw corruptGeneration(
          generationURL,
          reason: "manifest.json cannot be decoded: \(String(describing: error))"
        )
      }
      try validateReusableGeneration(
        manifest, at: generationURL, inputDigest: inputDigest, package: package)
      reusable = reusable ?? manifest
    }
    return reusable
  }

  private func safelyReadManifest(at url: URL) -> BoundedRegularFile? {
    try? BoundedRegularFile.read(at: url)
  }

  private func manifestObject(in data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func validateReusableGeneration(
    _ manifest: GenerationManifest,
    at generationURL: URL,
    inputDigest: String,
    package: ThemePackage
  ) throws {
    let generationID = generationURL.lastPathComponent
    try requireReusable(
      manifest.manifestSchemaVersion == GenerationManifest.currentSchemaVersion,
      generationURL,
      "unsupported manifest schema version \(manifest.manifestSchemaVersion)"
    )
    try requireReusable(
      manifest.generationID == generationID,
      generationURL,
      "manifest generation_id '\(manifest.generationID)' does not match its directory"
    )
    try requireReusable(
      generationID.hasPrefix("g-")
        && generationID == generationID.lowercased()
        && UUID(uuidString: String(generationID.dropFirst(2))) != nil,
      generationURL,
      "generation identifier is not in g-<uuid> form"
    )
    try requireReusable(
      manifest.themeID == package.id,
      generationURL,
      "manifest theme_id '\(manifest.themeID)' does not match '\(package.id)'"
    )
    try requireReusable(
      manifest.inputDigest == inputDigest,
      generationURL,
      "decoded input digest does not match the requested inputs"
    )
    try requireReusable(
      manifest.themeSchemaVersion == package.schemaVersion,
      generationURL,
      "manifest theme schema version does not match the package"
    )
    try requireReusable(
      manifest.rendererVersions == Self.rendererVersions,
      generationURL,
      "renderer versions do not match the current renderers"
    )

    do {
      try manifest.validateArtifacts(at: generationURL)
    } catch let error as GenerationIntegrityError {
      throw corruptGeneration(generationURL, reason: error.reason)
    }
  }

  private func requireReusable(
    _ condition: @autoclosure () -> Bool,
    _ generationURL: URL,
    _ reason: String
  ) throws {
    guard condition() else { throw corruptGeneration(generationURL, reason: reason) }
  }

  private func corruptGeneration(_ generationURL: URL, reason: String) -> ThemeActivationError {
    .corruptGeneration(id: generationURL.lastPathComponent, reason: reason)
  }

  private func replaceCurrent(with generationID: String) throws {
    let temporaryPointer = root.appending(
      path: ".current-\(generationID)-\(UUID().uuidString.lowercased())")
    defer { try? FileManager.default.removeItem(at: temporaryPointer) }
    try FileManager.default.createSymbolicLink(
      atPath: temporaryPointer.path,
      withDestinationPath: "generations/\(generationID)"
    )
    try faultInjector(.currentPointerReady)
    try atomicallyReplaceCurrent(with: temporaryPointer)
  }

  private func generationInputDigest(
    themeDigest: String,
    background: PreparedThemeBackground
  ) throws -> String {
    let input = GenerationInput(
      manifestSchemaVersion: GenerationManifest.currentSchemaVersion,
      themeDigest: themeDigest,
      background: background.selection,
      wallpaperDigest: background.data.map(sha256Digest)
    )
    return sha256Digest(try encode(input))
  }

  private func validate(background: PreparedThemeBackground) throws {
    switch (background.selection, background.data) {
    case (nil, nil):
      return
    case (nil, _), (_, nil):
      throw GenerationIntegrityError(
        reason:
          "background identity and selected bytes must either both be present or both be absent"
      )
    case (let selection?, let data?):
      if data.count <= ThemeImageAsset.maximumSize {
        try ThemeImageAsset.validate(data: data, format: selection.format)
      }
    }
  }

  private func generationThemeDigest(package: ThemePackage) throws -> String {
    sha256Digest(
      try encode(
        GenerationThemeInput(
          manifestSchemaVersion: GenerationManifest.currentSchemaVersion,
          themeSchemaVersion: package.schemaVersion,
          themeID: package.id,
          appearance: package.appearance,
          semantic: package.semantic,
          terminal: package.terminal,
          mappings: package.mappings,
          rendererVersions: Self.rendererVersions
        )
      )
    )
  }

  private func encode<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0a)
    return data
  }

  private func requireGeneratedFileSize(_ artifact: RenderedArtifact) throws {
    try requireGeneratedFileSize(
      artifact.data,
      path: artifact.path,
      maximumSize: artifact.maximumSize
    )
  }

  private func requireGeneratedFileSize(
    _ data: Data,
    path: String,
    maximumSize: Int
  ) throws {
    guard data.count <= maximumSize else {
      throw ThemeActivationError.generatedFileTooLarge(
        path: path,
        size: data.count,
        maximumSize: maximumSize
      )
    }
  }

  private func makeContentsReadOnly(
    _ generationURL: URL,
    artifactPaths: [String]
  ) throws {
    let generated = generationURL.appending(path: "generated", directoryHint: .isDirectory)
    let files =
      [generationURL.appending(path: "manifest.json")]
      + artifactPaths.map { generationURL.appending(path: $0) }
    for file in files {
      try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: generated.path)
  }

  private func makeWritableForRemoval(_ generationURL: URL) {
    let generated = generationURL.appending(path: "generated", directoryHint: .isDirectory)
    for directory in [generationURL, generated] {
      let descriptor = directory.path.withCString {
        Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      }
      guard descriptor >= 0 else { continue }
      _ = Darwin.fchmod(descriptor, 0o700)
      Darwin.close(descriptor)
    }
  }

  private func atomicallyReplaceCurrent(with temporaryPointer: URL) throws {
    let current = root.appending(path: "current")
    let result = temporaryPointer.path.withCString { source in
      current.path.withCString { destination in
        Darwin.rename(source, destination)
      }
    }
    guard result == 0 else {
      throw ThemeActivationError.cannotReplaceCurrent(errno)
    }
  }
}

private struct LockedActivationResult {
  let manifest: GenerationManifest
  let trashURLs: [URL]
  let cleanupError: String?
}

private struct GenerationInput: Encodable {
  let manifestSchemaVersion: Int
  let themeDigest: String
  let background: GenerationBackground?
  let wallpaperDigest: String?

  enum CodingKeys: String, CodingKey {
    case manifestSchemaVersion = "manifest_schema_version"
    case themeDigest = "theme_digest"
    case background
    case wallpaperDigest = "wallpaper_digest"
  }
}

private struct GenerationThemeInput: Encodable {
  let manifestSchemaVersion: Int
  let themeSchemaVersion: Int
  let themeID: String
  let appearance: ThemeAppearance
  let semantic: SemanticColors
  let terminal: TerminalColors
  let mappings: [String: String]
  let rendererVersions: [String: Int]

  enum CodingKeys: String, CodingKey {
    case manifestSchemaVersion = "manifest_schema_version"
    case themeSchemaVersion = "theme_schema_version"
    case themeID = "theme_id"
    case appearance, semantic, terminal, mappings
    case rendererVersions = "renderer_versions"
  }
}
