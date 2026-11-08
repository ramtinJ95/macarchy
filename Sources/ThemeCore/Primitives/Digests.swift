import CryptoKit
import Foundation

/// The SHA-256 of `data` as 64 lowercase hex digits, without a prefix.
package func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

package func sha256Digest(_ data: Data) -> String {
  "sha256:" + sha256Hex(data)
}

/// Digest of each value's UTF-8 bytes framed as `<byte count>:<bytes>`, in order.
package func lengthPrefixedSHA256Digest(_ values: some Sequence<String>) -> String {
  var data = Data()
  for value in values {
    let bytes = Data(value.utf8)
    data.append(Data("\(bytes.count):".utf8))
    data.append(bytes)
  }
  return sha256Digest(data)
}

/// Digest of the compact, key-sorted JSON encoding used for composition input identities.
package func canonicalJSONDigest<Value: Encodable>(_ value: Value) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return sha256Digest(try encoder.encode(value))
}

/// Compact, key-sorted JSON with Foundation's default escaping, so slashes stay escaped. Review
/// approval and evidence digests hash these bytes; they differ from `canonicalJSONDigest`'s.
package func sortedKeysJSON<Value: Encodable>(_ value: Value) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return try encoder.encode(value)
}

/// Whether `value` matches `^[0-9a-f]{64}$` as Foundation's regular-expression search reads it,
/// where `$` also matches before one final line terminator.
package func isSHA256Hex(_ value: String) -> Bool {
  value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
}

package func isSHA256Digest(_ value: String) -> Bool {
  let digest = value.dropFirst("sha256:".count)
  return value.hasPrefix("sha256:")
    && digest.count == 64
    && digest.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
}
