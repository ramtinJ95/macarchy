import Darwin
import Foundation

enum KeybindingProviderPrimitives {
  struct POSIXFailure: Error, Equatable, Sendable {
    let code: Int32
  }

  static let claimMarkerAttribute = "io.github.ramtinj95.macarchy.keybinding-claim"

  static func resolveSymlink(_ destination: String, relativeTo parent: URL) -> URL {
    if NSString(string: destination).isAbsolutePath {
      return URL(filePath: destination).standardizedFileURL
    }
    return parent.appending(path: destination).standardizedFileURL
  }

  /// Probes only the marker's size. In particular, a foreign oversized value is
  /// reported as present without allocating or reading its contents.
  static func claimMarkerExists(descriptor: Int32) throws -> Bool {
    let size = claimMarkerAttribute.withCString {
      Darwin.fgetxattr(descriptor, $0, nil, 0, 0, 0)
    }
    if size < 0, errno == ENOATTR { return false }
    guard size >= 0 else { throw POSIXFailure(code: errno) }
    return true
  }

  static func claimMarkerMatches(descriptor: Int32, nonce: String) throws -> Bool {
    // Claim nonces are UUID strings. Keep the bounded direct read so a foreign
    // oversized marker fails with ERANGE rather than being allocated or read.
    var value = [UInt8](repeating: 0, count: 64)
    let count = claimMarkerAttribute.withCString {
      Darwin.fgetxattr(descriptor, $0, &value, value.count, 0, 0)
    }
    if count < 0, errno == ENOATTR { return false }
    guard count >= 0 else { throw POSIXFailure(code: errno) }
    return Data(value.prefix(count)) == Data(nonce.utf8)
  }

  static func createClaimMarker(descriptor: Int32, nonce: String) throws {
    let result = Data(nonce.utf8).withUnsafeBytes { value in
      claimMarkerAttribute.withCString {
        Darwin.fsetxattr(descriptor, $0, value.baseAddress, value.count, 0, XATTR_CREATE)
      }
    }
    guard result == 0 else { throw POSIXFailure(code: errno) }
  }

  /// What a claim-marker read establishes about a pinned item.
  enum ClaimMarkerCheck {
    /// Any marker is present. Only its size is probed.
    case present
    /// The marker is exactly this ownership nonce.
    case matches(nonce: String)
  }

  /// Reads the claim marker of a pinned item. A POSIX failure is reported as `failure` on `url`;
  /// each caller keeps the wording it has always reported.
  static func readClaimMarker(
    _ check: ClaimMarkerCheck,
    descriptor: Int32,
    failure: String,
    url: URL
  ) throws -> Bool {
    do {
      switch check {
      case .present:
        return try claimMarkerExists(descriptor: descriptor)
      case .matches(let nonce):
        return try claimMarkerMatches(descriptor: descriptor, nonce: nonce)
      }
    } catch let error as POSIXFailure {
      throw SetupOwnershipError.posix(failure, url, code: error.code)
    }
  }

  static func removeClaimMarker(descriptor: Int32) throws {
    let result = claimMarkerAttribute.withCString {
      Darwin.fremovexattr(descriptor, $0, 0)
    }
    guard result == 0 else { throw POSIXFailure(code: errno) }
  }
}
