import Foundation
import Testing

@testable import MacarchyCLI

struct EnvironmentPiDocumentTests {
  private let source = URL(filePath: "/pi-settings.json")

  @Test(arguments: [
    (#"{"theme": "macarchy-current"}"#, true),
    (#"{"keep":1, "theme" : "macarchy-current"}"#, true),
    (#"{"nested":{"theme":"macarchy-current"}}"#, false),
    (#"{"th\u0065me":"macarchy-current"}"#, false),
    (#"{"theme":"macarchy-\u0063urrent"}"#, false),
    (#"{"theme":"personal"}"#, false),
    (#"{"theme":null}"#, false),
  ])
  func managedMatchingRequiresExactSelectorBytes(input: String, expected: Bool) throws {
    let data = Data(input.utf8)
    #expect(try EnvironmentPiDocument.matchesManaged(data, source: source) == expected)
    if !expected {
      do {
        _ = try EnvironmentPiDocument.restoringOriginal(
          in: data, ownership: ownership(), source: source)
        Issue.record("Expected noncanonical or absent Pi selector to block restoration")
      } catch EnvironmentLifecycleError.drift(let path) {
        #expect(path == source.path)
      }
    }
  }

  @Test(arguments: [
    (#"{"theme":"macarchy-current","theme":"personal"}"#, #"duplicate top-level JSON key "theme""#),
    (#"{"theme":"macarchy-current","nested":{"key":1,"key":2}}"#, #"duplicate JSON key "key""#),
    (#"{"nested":[1,]}"#, "trailing comma in JSON array"),
    (#"{"theme":"macarchy-current",}"#, "trailing comma in JSON object"),
  ])
  func malformedInputKeepsTheSameBlockedError(input: String, reason: String) throws {
    let data = Data(input.utf8)
    let expected =
      "invalid Pi settings at /pi-settings.json: Configuration for pi.selector at /pi-settings.json is invalid: \(reason)"
    do {
      _ = try EnvironmentPiDocument.matchesManaged(data, source: source)
      Issue.record("Expected invalid Pi settings to block matching")
    } catch EnvironmentLifecycleError.blocked(let message) {
      #expect(message == expected)
    }
    do {
      _ = try EnvironmentPiDocument.restoringOriginal(
        in: data, ownership: ownership(), source: source)
      Issue.record("Expected invalid Pi settings to block restoration")
    } catch EnvironmentLifecycleError.blocked(let message) {
      #expect(message == expected)
    }
  }

  @Test
  func restorationValidatesTheProducedDocument() throws {
    // Valid saved member bytes can collide with an unrelated later provider key.
    let saved = ownership(member: #""theme":"personal","later":1"#)
    #expect(saved.hasValidShape)
    do {
      _ = try EnvironmentPiDocument.restoringOriginal(
        in: Data(#"{"theme":"macarchy-current","later":2}"#.utf8),
        ownership: saved,
        source: source
      )
      Issue.record("Expected the duplicate key in restored output to block")
    } catch EnvironmentLifecycleError.blocked(let message) {
      #expect(
        message
          == #"invalid Pi settings at /pi-settings.json: Configuration for pi.selector at /pi-settings.json is invalid: duplicate top-level JSON key "later""#
      )
    }
  }

  private func ownership(member: String = #""theme":"personal""#) -> EnvironmentPiOwnership {
    EnvironmentPiOwnership(
      path: source.path, originalFileExisted: true, originalMember: Data(member.utf8))
  }
}
