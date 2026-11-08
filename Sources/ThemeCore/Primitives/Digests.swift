import CryptoKit
import Foundation

package func sha256Digest(_ data: Data) -> String {
  "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

package func isSHA256Digest(_ value: String) -> Bool {
  let digest = value.dropFirst("sha256:".count)
  return value.hasPrefix("sha256:")
    && digest.count == 64
    && digest.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
}
