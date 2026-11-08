import Darwin

/// `"<strerror text> (errno N)"`.
package func errnoDescription(_ code: Int32) -> String {
  "\(String(cString: strerror(code))) (errno \(code))"
}
