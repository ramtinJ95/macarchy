import Foundation

package func isGenerationID(_ value: String) -> Bool {
  isPrefixedLowercaseUUID(value, prefix: "g-")
}

/// `<prefix><lowercase UUID>`, the identifier shape shared by the generation stores.
func isPrefixedLowercaseUUID(_ value: String, prefix: String) -> Bool {
  guard value.hasPrefix(prefix) else { return false }
  let nonce = String(value.dropFirst(prefix.count))
  return nonce == nonce.lowercased() && UUID(uuidString: nonce) != nil
}

/// `<prefix><generation ID>-<lowercase UUID>` for 38-character generation IDs.
func isGenerationScopedTemporaryName(
  _ name: String, prefix: String, isGenerationID: (String) -> Bool
) -> Bool {
  guard name.hasPrefix(prefix) else { return false }
  let value = name.dropFirst(prefix.count)
  guard value.count == 75 else { return false }
  let separator = value.index(value.startIndex, offsetBy: 38)
  guard value[separator] == "-" else { return false }
  return isGenerationID(String(value[..<separator]))
    && isPrefixedLowercaseUUID(String(value[value.index(after: separator)...]), prefix: "")
}
