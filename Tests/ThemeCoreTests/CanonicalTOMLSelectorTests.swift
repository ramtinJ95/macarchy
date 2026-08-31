import Testing

@testable import ThemeCore

struct CanonicalTOMLSelectorTests {
  @Test
  func exactSelectionRequiresOneCanonicalTableAndOneExpectedValue() {
    let expected = "\"macarchy-current\""

    #expect(
      CanonicalTOMLSelector(
        configuration: "[theme]\nname = \(expected)\n",
        table: "theme",
        key: "name"
      ).selectsExactly(expected)
    )
    #expect(
      !CanonicalTOMLSelector(
        configuration: "[theme]\nname = \(expected)\nname = \(expected)\n",
        table: "theme",
        key: "name"
      ).selectsExactly(expected)
    )
    #expect(
      !CanonicalTOMLSelector(
        configuration: "[theme]\nname = \(expected)\n[theme]\n",
        table: "theme",
        key: "name"
      ).selectsExactly(expected)
    )
    #expect(
      !CanonicalTOMLSelector(
        configuration: "[theme]\nname = \"other\"\n",
        table: "theme",
        key: "name"
      ).selectsExactly(expected)
    )
  }
}
