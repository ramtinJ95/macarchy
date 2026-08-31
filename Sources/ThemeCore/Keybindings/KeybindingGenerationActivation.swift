import Darwin
import Foundation

package enum KeybindingGenerationCheckpoint: Equatable, Sendable {
  case stagingCreated
  case generationWritten
  case generationPublished
  case generationSealed
  case generationCommitted
  case currentReady
  case currentReplaced
}

package struct StagedKeybindingGeneration: Sendable {
  package let manifest: KeybindingGenerationManifest
  package let generationURL: URL
}

package struct KeybindingGenerationActivator: Sendable {
  private let stateRoot: URL
  private let faultInjector: @Sendable (KeybindingGenerationCheckpoint) throws -> Void

  package init(
    stateRoot: URL,
    faultInjector: @escaping @Sendable (KeybindingGenerationCheckpoint) throws -> Void = { _ in }
  ) {
    self.stateRoot = stateRoot.standardizedFileURL
    self.faultInjector = faultInjector
  }

  package func stage(
    _ composition: KeybindingComposition,
    generationID requestedGenerationID: String? = nil
  ) throws -> StagedKeybindingGeneration {
    guard
      !composition.isBlocked,
      let rendered = composition.renderedConfiguration,
      let renderedDigest = composition.renderedDigest,
      let inputDigest = composition.inputDigest
    else {
      throw KeybindingGenerationActivationError.invalidComposition
    }
    let generationID =
      requestedGenerationID
      ?? "k-\(UUID().uuidString.lowercased())"
    guard KeybindingGenerationInspector.isGenerationID(generationID) else {
      throw KeybindingGenerationActivationError.invalidGenerationIdentity
    }
    let manifest = KeybindingGenerationManifest(
      generationID: generationID,
      inputDigest: inputDigest,
      renderedDigest: renderedDigest
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let manifestData = try encoder.encode(manifest)
    let keybindingsRoot = stateRoot.appending(path: "keybindings", directoryHint: .isDirectory)
    let generationsRoot = keybindingsRoot.appending(
      path: "generations",
      directoryHint: .isDirectory
    )
    let stagingName = ".staging-\(generationID)"
    let stagingURL = generationsRoot.appending(path: stagingName, directoryHint: .isDirectory)
    let generationURL = generationsRoot.appending(path: generationID, directoryHint: .isDirectory)

    let stateDescriptor = try PinnedFilesystem.openDirectory(at: stateRoot)
    defer { Darwin.close(stateDescriptor) }
    let keybindingsDescriptor = try existingOrCreateDirectory(
      parentDescriptor: stateDescriptor,
      name: "keybindings",
      url: keybindingsRoot
    )
    defer { Darwin.close(keybindingsDescriptor) }
    let generationsDescriptor = try existingOrCreateDirectory(
      parentDescriptor: keybindingsDescriptor,
      name: "generations",
      url: generationsRoot
    )
    defer { Darwin.close(generationsDescriptor) }
    let stagingDescriptor = try PinnedFilesystem.createDirectory(
      parentDescriptor: generationsDescriptor,
      name: stagingName,
      url: stagingURL
    )
    var removeUncommittedGeneration = true
    var cleanupName = stagingName
    var cleanupURL = stagingURL
    defer {
      Darwin.close(stagingDescriptor)
      if removeUncommittedGeneration {
        try? removeDirectory(
          parentDescriptor: generationsDescriptor,
          name: cleanupName,
          url: cleanupURL,
          allowPartial: true
        )
      }
    }
    try faultInjector(.stagingCreated)
    try PinnedFilesystem.writeNewRegularFile(
      parentDescriptor: stagingDescriptor,
      name: "skhdrc",
      url: stagingURL.appending(path: "skhdrc"),
      data: Data(rendered.utf8),
      mode: 0o444
    )
    try PinnedFilesystem.writeNewRegularFile(
      parentDescriptor: stagingDescriptor,
      name: "manifest.json",
      url: stagingURL.appending(path: "manifest.json"),
      data: manifestData,
      mode: 0o444
    )
    try faultInjector(.generationWritten)
    try PinnedFilesystem.publishDirectoryAtomicallyAndSeal(
      parentDescriptor: generationsDescriptor,
      directoryDescriptor: stagingDescriptor,
      sourceName: stagingName,
      destinationName: generationID,
      sourceURL: stagingURL,
      destinationURL: generationURL,
      didPublish: {
        cleanupName = generationID
        cleanupURL = generationURL
        try faultInjector(.generationPublished)
      }
    )
    try faultInjector(.generationSealed)
    removeUncommittedGeneration = false
    try faultInjector(.generationCommitted)
    return StagedKeybindingGeneration(manifest: manifest, generationURL: generationURL)
  }

  package func select(_ generation: StagedKeybindingGeneration) throws {
    let keybindingsRoot = stateRoot.appending(path: "keybindings", directoryHint: .isDirectory)
    let descriptor = try PinnedFilesystem.openDirectory(at: keybindingsRoot)
    defer { Darwin.close(descriptor) }
    let temporaryName =
      ".current-\(generation.manifest.generationID)-\(UUID().uuidString.lowercased())"
    let temporaryURL = keybindingsRoot.appending(path: temporaryName)
    let destination = "generations/\(generation.manifest.generationID)"
    let created = destination.withCString { destinationPath in
      temporaryName.withCString { name in
        Darwin.symlinkat(destinationPath, descriptor, name)
      }
    }
    guard created == 0 else {
      throw KeybindingGenerationActivationError.system(
        "create current pointer",
        temporaryURL,
        errno
      )
    }
    defer { temporaryName.withCString { _ = Darwin.unlinkat(descriptor, $0, 0) } }
    try faultInjector(.currentReady)
    let replaced = temporaryName.withCString { source in
      "current".withCString { destinationName in
        Darwin.renameat(descriptor, source, descriptor, destinationName)
      }
    }
    guard replaced == 0, fsync(descriptor) == 0 else {
      throw KeybindingGenerationActivationError.system(
        "replace current pointer",
        keybindingsRoot.appending(path: "current"),
        errno
      )
    }
    try faultInjector(.currentReplaced)
  }

  package func restoreCurrent(generationID: String?) throws {
    let keybindingsRoot = stateRoot.appending(path: "keybindings", directoryHint: .isDirectory)
    let descriptor = try PinnedFilesystem.openDirectory(at: keybindingsRoot)
    defer { Darwin.close(descriptor) }
    if let generationID {
      let temporaryName = ".current-restore-\(UUID().uuidString.lowercased())"
      let destination = "generations/\(generationID)"
      let created = destination.withCString { destinationPath in
        temporaryName.withCString { name in
          Darwin.symlinkat(destinationPath, descriptor, name)
        }
      }
      guard created == 0 else {
        throw KeybindingGenerationActivationError.system(
          "create rollback pointer",
          keybindingsRoot.appending(path: temporaryName),
          errno
        )
      }
      defer { temporaryName.withCString { _ = Darwin.unlinkat(descriptor, $0, 0) } }
      let replaced = temporaryName.withCString { source in
        "current".withCString { destinationName in
          Darwin.renameat(descriptor, source, descriptor, destinationName)
        }
      }
      guard replaced == 0 else {
        throw KeybindingGenerationActivationError.system(
          "restore current pointer",
          keybindingsRoot.appending(path: "current"),
          errno
        )
      }
    } else {
      let removed = "current".withCString { Darwin.unlinkat(descriptor, $0, 0) }
      guard removed == 0 || errno == ENOENT else {
        throw KeybindingGenerationActivationError.system(
          "remove current pointer",
          keybindingsRoot.appending(path: "current"),
          errno
        )
      }
    }
    guard fsync(descriptor) == 0 else {
      throw KeybindingGenerationActivationError.system(
        "sync restored current pointer",
        keybindingsRoot,
        errno
      )
    }
  }

  package func removeGeneration(_ generationID: String) throws {
    let generationsRoot = stateRoot.appending(
      path: "keybindings/generations",
      directoryHint: .isDirectory
    )
    let descriptor: Int32
    do {
      descriptor = try PinnedFilesystem.openDirectory(at: generationsRoot)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
    defer { Darwin.close(descriptor) }
    do {
      try removeDirectory(
        parentDescriptor: descriptor,
        name: generationID,
        url: generationsRoot.appending(path: generationID, directoryHint: .isDirectory)
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
    guard fsync(descriptor) == 0 else {
      throw KeybindingGenerationActivationError.system(
        "sync removed generation",
        generationsRoot,
        errno
      )
    }
  }

  package func recoverResidue() throws {
    let keybindingsRoot = stateRoot.appending(path: "keybindings", directoryHint: .isDirectory)
    let keybindingsDescriptor: Int32
    do {
      keybindingsDescriptor = try PinnedFilesystem.openDirectory(at: keybindingsRoot)
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
    defer { Darwin.close(keybindingsDescriptor) }
    let keybindingItems = try PinnedFilesystem.directoryEntries(
      descriptor: keybindingsDescriptor,
      url: keybindingsRoot,
      limit: 1_024
    )
    guard !keybindingItems.truncated else {
      throw KeybindingGenerationActivationError.invalidGenerationInventory
    }
    for name in keybindingItems.entries where Self.isTemporaryPointer(name) {
      let metadata = try PinnedFilesystem.metadata(
        parentDescriptor: keybindingsDescriptor,
        name: name,
        url: keybindingsRoot.appending(path: name)
      )
      guard metadata.st_mode & S_IFMT == S_IFLNK else {
        throw KeybindingGenerationActivationError.invalidGenerationInventory
      }
      let removed = name.withCString { Darwin.unlinkat(keybindingsDescriptor, $0, 0) }
      guard removed == 0 else {
        throw KeybindingGenerationActivationError.system(
          "remove temporary current pointer",
          keybindingsRoot.appending(path: name),
          errno
        )
      }
    }

    let generationsRoot = keybindingsRoot.appending(
      path: "generations",
      directoryHint: .isDirectory
    )
    let generationsDescriptor: Int32
    do {
      generationsDescriptor = try PinnedFilesystem.openDirectory(
        parentDescriptor: keybindingsDescriptor,
        name: "generations",
        url: generationsRoot
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return
    }
    defer { Darwin.close(generationsDescriptor) }
    let generations = try PinnedFilesystem.directoryEntries(
      descriptor: generationsDescriptor,
      url: generationsRoot,
      limit: 1_024
    )
    guard !generations.truncated else {
      throw KeybindingGenerationActivationError.invalidGenerationInventory
    }
    for name in generations.entries where Self.isStagingName(name) {
      try removeDirectory(
        parentDescriptor: generationsDescriptor,
        name: name,
        url: generationsRoot.appending(path: name, directoryHint: .isDirectory),
        allowPartial: true
      )
    }
    guard fsync(keybindingsDescriptor) == 0, fsync(generationsDescriptor) == 0 else {
      throw KeybindingGenerationActivationError.system(
        "sync recovered keybinding residue",
        keybindingsRoot,
        errno
      )
    }
  }

  package func retainGenerations(_ retained: Set<String>) throws {
    let generationsRoot = stateRoot.appending(
      path: "keybindings/generations",
      directoryHint: .isDirectory
    )
    let descriptor = try PinnedFilesystem.openDirectory(at: generationsRoot)
    defer { Darwin.close(descriptor) }
    let inventory = try PinnedFilesystem.directoryEntries(
      descriptor: descriptor,
      url: generationsRoot,
      limit: 1_024
    )
    guard !inventory.truncated else {
      throw KeybindingGenerationActivationError.invalidGenerationInventory
    }
    for name in inventory.entries
    where Self.isGenerationID(name) && !retained.contains(name) {
      try removeDirectory(
        parentDescriptor: descriptor,
        name: name,
        url: generationsRoot.appending(path: name, directoryHint: .isDirectory)
      )
    }
  }

  private func existingOrCreateDirectory(
    parentDescriptor: Int32,
    name: String,
    url: URL
  ) throws -> Int32 {
    do {
      return try PinnedFilesystem.openDirectory(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url
      )
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      return try PinnedFilesystem.createDirectory(
        parentDescriptor: parentDescriptor,
        name: name,
        url: url
      )
    }
  }

  private func removeDirectory(
    parentDescriptor: Int32,
    name: String,
    url: URL,
    allowPartial: Bool = false
  ) throws {
    let descriptor = try PinnedFilesystem.openDirectory(
      parentDescriptor: parentDescriptor,
      name: name,
      url: url
    )
    defer { Darwin.close(descriptor) }
    let inventory = try PinnedFilesystem.directoryEntries(
      descriptor: descriptor,
      url: url,
      limit: 3
    )
    let expected = Set(["manifest.json", "skhdrc"])
    guard
      !inventory.truncated,
      allowPartial
        ? Set(inventory.entries).isSubset(of: expected)
        : Set(inventory.entries) == expected
    else {
      throw KeybindingGenerationActivationError.invalidGenerationInventory
    }
    guard fchmod(descriptor, 0o755) == 0 else {
      throw KeybindingGenerationActivationError.system("make generation removable", url, errno)
    }
    for file in ["manifest.json", "skhdrc"] {
      let removed = file.withCString { Darwin.unlinkat(descriptor, $0, 0) }
      guard removed == 0 || errno == ENOENT else {
        throw KeybindingGenerationActivationError.system(
          "remove generation artifact",
          url.appending(path: file),
          errno
        )
      }
    }
    let removed = name.withCString { Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
    guard removed == 0 else {
      throw KeybindingGenerationActivationError.system("remove generation", url, errno)
    }
  }

  private static func isGenerationID(_ value: String) -> Bool {
    KeybindingGenerationInspector.isGenerationID(value)
  }

  private static func isStagingName(_ value: String) -> Bool {
    value.hasPrefix(".staging-") && isGenerationID(String(value.dropFirst(9)))
  }

  private static func isTemporaryPointer(_ value: String) -> Bool {
    if value.hasPrefix(".current-restore-") {
      let nonce = String(value.dropFirst(17))
      return nonce == nonce.lowercased() && UUID(uuidString: nonce) != nil
    }
    guard value.hasPrefix(".current-") else { return false }
    let suffix = value.dropFirst(9)
    guard suffix.count == 75 else { return false }
    let separator = suffix.index(suffix.startIndex, offsetBy: 38)
    guard suffix[separator] == "-" else { return false }
    let generationID = String(suffix[..<separator])
    let nonce = String(suffix[suffix.index(after: separator)...])
    return isGenerationID(generationID)
      && nonce == nonce.lowercased()
      && UUID(uuidString: nonce) != nil
  }
}

package enum KeybindingGenerationActivationError: Error, CustomStringConvertible, Sendable {
  case invalidGenerationInventory
  case invalidGenerationIdentity
  case invalidComposition
  case system(String, URL, Int32)

  package var description: String {
    switch self {
    case .invalidGenerationInventory:
      "keybinding generation inventory exceeds the supported bound"
    case .invalidGenerationIdentity:
      "keybinding generation identity is invalid"
    case .invalidComposition:
      "cannot activate a blocked or incomplete keybinding composition"
    case .system(let operation, let url, let code):
      "cannot \(operation) \(url.path): \(String(cString: strerror(code))) (errno \(code))"
    }
  }
}
