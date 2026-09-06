import Foundation
import TOMLDecoder
import ThemeCore

enum SetupPackageProfileEdit {
  /// Edit only selected package fields. The normal loader validates both the
  /// original and proposed document; this is not a profile serializer.
  static func prepare(
    source: URL, fragment: URL, needsWiring: Bool, removing names: Set<String>
  ) throws -> SetupPackageInputEdit {
    var edit = try SetupPackageInputEdit.inspect(url: source)
    if edit.before == nil { edit.after = "schema_version = 1\n" }
    if !names.isEmpty {
      let selector = CanonicalTOMLSelector(
        configuration: edit.after, table: "packages", key: "exclude_formulae")
      guard selector.assignments.count == 1 else {
        throw SetupPackageAdoptionError(
          "Cannot locate the selected formula exclusions in \(source.path).")
      }
      let range = selector.assignments[0].contentRange
      let assignment = String(edit.after[range])
      edit.after.replaceSubrange(range, with: try remove(names, from: assignment))
    }
    if needsWiring {
      // A source-specific basename keeps portable and machine defaults separate,
      // even when their profiles share a directory.
      let value = try String(
        decoding: JSONEncoder().encode(fragment.lastPathComponent), as: UTF8.self)
      let line = "brewfile = \(value)\n"
      let selector = CanonicalTOMLSelector(
        configuration: edit.after, table: "packages", key: "brewfile")
      guard selector.assignments.isEmpty, selector.tableHeaderCount <= 1 else {
        throw SetupPackageAdoptionError("Ambiguous package wiring in \(source.path).")
      }
      if let header = selector.selectionTableHeader {
        let separator = header.terminator.isEmpty ? "\n" : ""
        edit.after.insert(contentsOf: separator + line, at: header.fullRange.upperBound)
      } else {
        if !edit.after.hasSuffix("\n") { edit.after += "\n" }
        edit.after += "\n[packages]\n" + line
      }
    }
    guard edit.after.utf8.count <= 65_536 else {
      throw SetupPackageAdoptionError("Proposed profile exceeds 64 KiB.")
    }
    return edit
  }

  private static func remove(_ names: Set<String>, from assignment: String) throws -> String {
    // Tokenize strings, comments and commas only. Retain every byte outside the
    // removed values/separators, including inline and multiline-array comments.
    let expression = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'[^']*'|#[^\r\n]*|,"#)
    let tokens = expression.matches(
      in: assignment, range: NSRange(assignment.startIndex..., in: assignment)
    )
    .compactMap { Range($0.range, in: assignment) }
    .filter { assignment[$0].first != "#" }
    var deleted = Set<Int>()
    struct Value: Decodable { let value: String }
    for (index, range) in tokens.enumerated() where assignment[range] != "," {
      let value = try TOMLDecoder().decode(
        Value.self, from: "value = " + assignment[range]
      ).value
      if names.contains(value) {
        deleted.insert(index)
        if index + 1 < tokens.count, assignment[tokens[index + 1]] == "," {
          deleted.insert(index + 1)
        }
      }
    }
    var result = assignment
    for index in deleted.sorted(by: >) { result.removeSubrange(tokens[index]) }
    return result
  }
}
