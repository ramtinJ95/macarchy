import Testing

@testable import TestSafety

/// These tests exercise decisions only. They never create special files.
struct IsolatedTestEnvironmentTests {
  @Test
  func anEnvironmentVariableCannotAuthorizeThePhysicalHost() {
    #expect(throws: IsolatedTestEnvironment.Refusal.self) {
      try IsolatedTestEnvironment.validateGuest(optedIn: true, virtualized: 0, extensions: "")
    }
  }

  @Test
  func unknownVirtualizationAndMissingOptInFailClosed() {
    for value: Int32 in [-1, 2] {
      #expect(throws: IsolatedTestEnvironment.Refusal.self) {
        try IsolatedTestEnvironment.validateGuest(
          optedIn: true, virtualized: value, extensions: "")
      }
    }
    #expect(throws: IsolatedTestEnvironment.Refusal.self) {
      try IsolatedTestEnvironment.validateGuest(optedIn: false, virtualized: 1, extensions: "")
    }
  }

  @Test
  func affectedGuestIsRefusedEvenIfExtensionIsDisabled() {
    #expect(throws: IsolatedTestEnvironment.Refusal.self) {
      try IsolatedTestEnvironment.validateGuest(
        optedIn: true, virtualized: 1,
        extensions: "io.kandji.KandjiAgent.ESF-Extension [terminated waiting to uninstall]")
    }
  }

  @Test
  func explicitUnaffectedGuestIsAccepted() throws {
    try IsolatedTestEnvironment.validateGuest(
      optedIn: true, virtualized: 1, extensions: "0 extension(s)")
    try IsolatedTestEnvironment.validateFilesystem(
      type: "apfs", source: "/dev/disk3s5", local: true)
  }

  @Test
  func sharedAndUnknownFilesystemsAreRejected() {
    for (type, source, local) in [
      ("virtiofs", "share", true), ("nfs", "host:/src", false),
      ("apfs", "share", true), ("apfs", "/dev/disk3s5", false),
    ] {
      #expect(throws: IsolatedTestEnvironment.Refusal.self) {
        try IsolatedTestEnvironment.validateFilesystem(type: type, source: source, local: local)
      }
    }
  }
}
