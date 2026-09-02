import Darwin
import Foundation
import ThemeCore

struct EnvironmentBtopOriginalAssignment: Codable, Equatable, Sendable {
  let key: String
  let line: String?
}

struct EnvironmentBtopOwnership: Codable, Equatable, Sendable {
  let path: String
  let originalFileExisted: Bool
  let originalAssignments: [EnvironmentBtopOriginalAssignment]

  enum CodingKeys: String, CodingKey {
    case path
    case originalFileExisted = "original_file_existed"
    case originalAssignments = "original_assignments"
  }

  var hasValidShape: Bool {
    path.hasPrefix("/")
      && Set(originalAssignments.map(\.key)) == Set(EnvironmentBtopDocument.ownedKeys)
      && originalAssignments.count == EnvironmentBtopDocument.ownedKeys.count
      && originalAssignments.allSatisfy { assignment in
        guard assignment.line?.utf8.count ?? 0 <= 4_096 else { return false }
        return assignment.line.map {
          (try? EnvironmentBtopDocument.assignmentValue(
            key: assignment.key,
            in: $0,
            source: URL(filePath: path)
          )) != nil
        } ?? true
      }
  }
}

struct EnvironmentBtopDocument: Sendable {
  static let ownedKeys = [
    "color_theme",
    "theme_background",
    "truecolor",
    "vim_keys",
    "update_ms",
    "proc_mem_bytes",
  ]

  private struct Line: Sendable {
    var body: String
    var terminator: String
  }

  private struct Assignment: Sendable {
    let lineIndex: Int
    let value: String
    let rawLine: String
  }

  static func desiredValues(in text: String, source: URL) throws -> [String: String] {
    let assignments = try parse(text, source: source)
    guard assignments.count == ownedKeys.count else {
      let missing = ownedKeys.filter { assignments[$0] == nil }
      throw EnvironmentLifecycleError.blocked(
        "btop baseline is missing owned keys: \(missing.joined(separator: ", "))"
      )
    }
    return assignments.mapValues(\.value)
  }

  static func originalAssignments(
    in text: String,
    source: URL
  ) throws -> [EnvironmentBtopOriginalAssignment] {
    let assignments = try parse(text, source: source)
    return ownedKeys.map {
      EnvironmentBtopOriginalAssignment(key: $0, line: assignments[$0]?.rawLine)
    }
  }

  static func matchesManaged(
    _ text: String,
    values: [String: String],
    source: URL
  ) throws -> Bool {
    let assignments = try parse(text, source: source)
    return ownedKeys.allSatisfy { assignments[$0]?.value == values[$0] }
  }

  static func matchesOriginal(
    _ text: String,
    ownership: EnvironmentBtopOwnership,
    source: URL
  ) throws -> Bool {
    let assignments = try parse(text, source: source)
    return ownership.originalAssignments.allSatisfy {
      assignments[$0.key]?.rawLine == $0.line
    }
  }

  static func applyingManaged(
    to text: String,
    values: [String: String],
    source: URL
  ) throws -> String {
    var lines = split(text)
    let assignments = try parse(lines, source: source)
    var missing = [Line]()
    let newline = lines.first(where: { !$0.terminator.isEmpty })?.terminator ?? "\n"
    for key in ownedKeys {
      guard let value = values[key] else {
        throw EnvironmentLifecycleError.blocked("missing managed btop value for \(key)")
      }
      if let assignment = assignments[key] {
        lines[assignment.lineIndex].body = try replacingValue(
          in: lines[assignment.lineIndex].body,
          key: key,
          value: value,
          source: source
        )
      } else {
        missing.append(Line(body: "\(key) = \(value)", terminator: newline))
      }
    }
    lines.insert(contentsOf: missing, at: 0)
    return render(lines)
  }

  static func restoringOriginal(
    in text: String,
    ownership: EnvironmentBtopOwnership,
    source: URL
  ) throws -> String {
    var lines = split(text)
    for original in ownership.originalAssignments {
      let assignments = try parse(lines, source: source)
      if let line = original.line {
        if let current = assignments[original.key] {
          lines[current.lineIndex].body = line
        } else {
          append(line, to: &lines)
        }
      } else if let current = assignments[original.key] {
        lines.remove(at: current.lineIndex)
      }
    }
    return render(lines)
  }

  static func assignmentValue(key: String, in line: String, source: URL) throws -> String {
    let assignments = try parse(line, source: source)
    guard let value = assignments[key]?.value, assignments.count == 1 else {
      throw EnvironmentLifecycleError.blocked("invalid original btop assignment for \(key)")
    }
    return value
  }

  private static func parse(_ text: String, source: URL) throws -> [String: Assignment] {
    try parse(split(text), source: source)
  }

  private static func parse(_ lines: [Line], source: URL) throws -> [String: Assignment] {
    var assignments = [String: Assignment]()
    for index in lines.indices {
      let raw = lines[index].body
      let visible = visibleContent(raw).trimmingCharacters(in: .whitespaces)
      guard !visible.isEmpty else { continue }
      let ownedPrefix = ownedKeys.first { key in
        visible == key || visible.hasPrefix(key + " ") || visible.hasPrefix(key + "\t")
          || visible.hasPrefix(key + "=")
      }
      guard let equals = visible.firstIndex(of: "=") else {
        if let ownedPrefix {
          throw malformed(ownedPrefix, source: source)
        }
        continue
      }
      let key = visible[..<equals].trimmingCharacters(in: .whitespaces)
      guard ownedKeys.contains(key) else {
        if let ownedPrefix { throw malformed(ownedPrefix, source: source) }
        continue
      }
      let value = visible[visible.index(after: equals)...]
        .trimmingCharacters(in: .whitespaces)
      guard !value.isEmpty, !value.contains("=") else {
        throw malformed(key, source: source)
      }
      guard assignments[key] == nil else {
        throw EnvironmentLifecycleError.blocked(
          "duplicate btop key \(key) in \(source.path)"
        )
      }
      assignments[key] = Assignment(lineIndex: index, value: value, rawLine: raw)
    }
    return assignments
  }

  private static func malformed(_ key: String, source: URL) -> EnvironmentLifecycleError {
    .blocked("malformed btop key \(key) in \(source.path)")
  }

  private static func replacingValue(
    in line: String,
    key: String,
    value: String,
    source: URL
  ) throws -> String {
    let comment = commentStart(in: line) ?? line.endIndex
    guard let equals = line[..<comment].firstIndex(of: "=") else {
      throw malformed(key, source: source)
    }
    var start = line.index(after: equals)
    while start < comment, line[start].isWhitespace { start = line.index(after: start) }
    var end = comment
    while end > start {
      let previous = line.index(before: end)
      guard line[previous].isWhitespace else { break }
      end = previous
    }
    return String(line[..<start]) + value + String(line[end...])
  }

  private static func visibleContent(_ line: String) -> String {
    String(line[..<(commentStart(in: line) ?? line.endIndex)])
  }

  private static func commentStart(in line: String) -> String.Index? {
    var quoted = false
    var escaped = false
    var index = line.startIndex
    while index < line.endIndex {
      let character = line[index]
      if quoted {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          quoted = false
        }
      } else if character == "\"" {
        quoted = true
      } else if character == "#" {
        return index
      }
      index = line.index(after: index)
    }
    return nil
  }

  private static func append(_ body: String, to lines: inout [Line]) {
    let newline = lines.first(where: { !$0.terminator.isEmpty })?.terminator ?? "\n"
    if !lines.isEmpty, lines[lines.count - 1].terminator.isEmpty {
      lines[lines.count - 1].terminator = newline
    }
    lines.append(Line(body: body, terminator: newline))
  }

  private static func split(_ text: String) -> [Line] {
    var lines = [Line]()
    var start = text.startIndex
    var index = start
    while index < text.endIndex {
      let character = text[index]
      guard character == "\n" || character == "\r" else {
        index = text.index(after: index)
        continue
      }
      let next = text.index(after: index)
      if character == "\r", next < text.endIndex, text[next] == "\n" {
        lines.append(Line(body: String(text[start..<index]), terminator: "\r\n"))
        index = text.index(after: next)
      } else {
        lines.append(Line(body: String(text[start..<index]), terminator: String(character)))
        index = next
      }
      start = index
    }
    if start < text.endIndex {
      lines.append(Line(body: String(text[start...]), terminator: ""))
    }
    return lines
  }

  private static func render(_ lines: [Line]) -> String {
    lines.map { $0.body + $0.terminator }.joined()
  }
}

struct EnvironmentBtopFileTransaction: Sendable {
  private enum ExpectedState {
    case original(EnvironmentBtopOwnership)
    case managed(values: [String: String], artifact: Data)
  }

  let homeDirectory: URL
  let stateRoot: URL

  func generationState(_ generationID: String) throws -> (values: [String: String], data: Data) {
    let url = stateRoot.appending(
      path: "environment/generations/\(generationID)/btop/btop.conf"
    )
    let data = try EnvironmentGenerationStore(stateRoot: stateRoot).validatedArtifact(
      generationID: generationID,
      path: "btop/btop.conf"
    )
    guard let text = String(data: data, encoding: .utf8) else {
      throw EnvironmentLifecycleError.blocked("btop generation is not UTF-8")
    }
    return (try EnvironmentBtopDocument.desiredValues(in: text, source: url), data)
  }

  func transition(
    from old: EnvironmentOwnership?,
    to new: EnvironmentOwnership?,
    replacementName: String
  ) throws {
    guard let ownership = new?.btop ?? old?.btop else { return }
    if let oldBtop = old?.btop, let newBtop = new?.btop, oldBtop != newBtop {
      throw EnvironmentLifecycleError.blocked("btop ownership changed unexpectedly")
    }
    let source: ExpectedState =
      try old.map {
        let state = try generationState($0.generationID)
        return .managed(values: state.values, artifact: state.data)
      } ?? .original(ownership)
    let target: ExpectedState =
      try new.map {
        let state = try generationState($0.generationID)
        return .managed(values: state.values, artifact: state.data)
      } ?? .original(ownership)
    let url = URL(filePath: ownership.path)
    let residue = url.deletingLastPathComponent().appending(path: replacementName)
    var current = try read(url)
    if let residueData = try read(residue) {
      if try matches(current, target, at: url), try matches(residueData, source, at: residue) {
        try remove(residue)
        return
      }
      if try matches(current, source, at: url), try matches(residueData, target, at: residue) {
        try remove(residue)
      } else {
        throw EnvironmentLifecycleError.drift("btop replacement residue")
      }
      current = try read(url)
    }
    if try matches(current, target, at: url) { return }
    guard try matches(current, source, at: url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }

    switch target {
    case .managed(let values, let artifact):
      if current == nil {
        try create(artifact, at: url, replacementName: replacementName)
      } else {
        let text = try utf8(current!, at: url)
        let updated = try EnvironmentBtopDocument.applyingManaged(
          to: text,
          values: values,
          source: url
        )
        try replace(
          Data(updated.utf8), current: current!, at: url, replacementName: replacementName)
      }
    case .original(let original):
      guard let current else { return }
      if !original.originalFileExisted {
        if case .managed(_, let artifact) = source, current == artifact {
          try claimAndRemove(at: url, replacementName: replacementName, expected: current)
        } else {
          let updated = try EnvironmentBtopDocument.restoringOriginal(
            in: try utf8(current, at: url),
            ownership: original,
            source: url
          )
          try replace(
            Data(updated.utf8), current: current, at: url, replacementName: replacementName)
        }
      } else {
        let updated = try EnvironmentBtopDocument.restoringOriginal(
          in: try utf8(current, at: url),
          ownership: original,
          source: url
        )
        try replace(Data(updated.utf8), current: current, at: url, replacementName: replacementName)
      }
    }
    guard try matches(try read(url), target, at: url) else {
      throw EnvironmentLifecycleError.drift(url.path)
    }
  }

  private func matches(_ data: Data?, _ state: ExpectedState, at url: URL) throws -> Bool {
    switch state {
    case .original(let ownership):
      guard let data else { return !ownership.originalFileExisted }
      return try EnvironmentBtopDocument.matchesOriginal(
        try utf8(data, at: url),
        ownership: ownership,
        source: url
      )
    case .managed(let values, _):
      guard let data else { return false }
      return try EnvironmentBtopDocument.matchesManaged(
        try utf8(data, at: url),
        values: values,
        source: url
      )
    }
  }

  private func read(_ url: URL) throws -> Data? {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      if errno == ENOENT { return nil }
      throw EnvironmentLifecycleError.system("inspect btop configuration", url, errno)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else {
      throw EnvironmentLifecycleError.blocked(
        "btop configuration is not an ordinary file: \(url.path)")
    }
    return try BoundedRegularFile.read(at: url).data
  }

  private func utf8(_ data: Data, at url: URL) throws -> String {
    guard let text = String(data: data, encoding: .utf8) else {
      throw EnvironmentLifecycleError.blocked("btop configuration is not UTF-8: \(url.path)")
    }
    return text
  }

  private func replace(
    _ data: Data,
    current: Data,
    at url: URL,
    replacementName: String
  ) throws {
    guard data != current else { return }
    do {
      try SetupOwnershipManager().replaceRegularFile(
        target: url,
        replacementName: replacementName,
        homeDirectory: homeDirectory,
        expectedDigest: sha256Digest(current),
        data: data,
        label: "btop owned keys"
      )
    } catch {
      throw EnvironmentLifecycleError.blocked("cannot replace btop owned keys: \(error)")
    }
  }

  private func create(_ data: Data, at url: URL, replacementName: String) throws {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let temporary = url.deletingLastPathComponent().appending(path: replacementName)
    try PinnedFilesystem.writeNewRegularFile(
      parentDescriptor: parent,
      name: replacementName,
      url: temporary,
      data: data,
      mode: 0o600
    )
    let published = replacementName.withCString { source in
      url.lastPathComponent.withCString { destination in
        Darwin.renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
      }
    }
    guard published == 0, fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("publish btop configuration", url, errno)
    }
  }

  private func claimAndRemove(at url: URL, replacementName: String, expected: Data) throws {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let claimed = url.lastPathComponent.withCString { source in
      replacementName.withCString { destination in
        Darwin.renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
      }
    }
    guard claimed == 0, fsync(parent) == 0 else {
      throw EnvironmentLifecycleError.system("claim btop configuration", url, errno)
    }
    let residue = url.deletingLastPathComponent().appending(path: replacementName)
    guard try read(residue) == expected else {
      throw EnvironmentLifecycleError.drift("claimed btop configuration")
    }
    try remove(residue)
  }

  private func remove(_ url: URL) throws {
    let parent = try PinnedFilesystem.openDirectory(at: url.deletingLastPathComponent())
    defer { Darwin.close(parent) }
    let removed = url.lastPathComponent.withCString { Darwin.unlinkat(parent, $0, 0) }
    guard removed == 0 || errno == ENOENT else {
      throw EnvironmentLifecycleError.system("remove btop transaction residue", url, errno)
    }
    if removed == 0, fsync(parent) != 0 {
      throw EnvironmentLifecycleError.system("sync btop transaction residue", url, errno)
    }
  }
}
