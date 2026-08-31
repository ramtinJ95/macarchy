import Foundation

package func containsExactLine(_ expected: String, in text: String) -> Bool {
  text.split(separator: "\n").contains {
    $0.trimmingCharacters(in: .whitespaces) == expected
  }
}
