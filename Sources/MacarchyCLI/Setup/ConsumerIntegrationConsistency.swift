import ThemeCore

enum ConsumerIntegrationConsistencyError: Error, CustomStringConvertible, Equatable {
  case dependencyCoverage(expected: [String], actual: [String])
  case dependencyRole(id: String)
  case setupCoverage(expected: [String], actual: [String])

  var description: String {
    switch self {
    case .dependencyCoverage(let expected, let actual):
      "Consumer dependency coverage differs from the catalog; expected \(expected), got \(actual)"
    case .dependencyRole(let id):
      "Dependency capability '\(id)' has a category inconsistent with the consumer catalog"
    case .setupCoverage(let expected, let actual):
      "Consumer setup coverage differs from the catalog; expected \(expected), got \(actual)"
    }
  }
}

enum ConsumerIntegrationConsistency {
  static func validateSetupPlans(_ plans: [ConsumerSetupPlan]) throws {
    let expected = ConsumerCatalog.shared.setupConsumerIDs.map(\.rawValue).sorted()
    let actual = plans.map { $0.consumerID.rawValue }.sorted()
    guard actual == expected else {
      throw ConsumerIntegrationConsistencyError.setupCoverage(
        expected: expected,
        actual: actual
      )
    }
  }

  static func validateDependencyCapabilities(
    _ capabilities: [DependencyCapability]
  ) throws {
    let registrations = ConsumerCatalog.shared.entries.flatMap(\.dependencies)
    let expected = registrations.map(\.id).sorted()
    let expectedIDs = Set(expected)
    let unexpectedAdapterIDs = capabilities.filter {
      ($0.category == .requiredAdapter || $0.category == .optionalAdapter)
        && !expectedIDs.contains($0.id)
    }.map(\.id)
    let actual = (capabilities.map(\.id).filter(expectedIDs.contains) + unexpectedAdapterIDs)
      .sorted()
    guard actual == expected else {
      throw ConsumerIntegrationConsistencyError.dependencyCoverage(
        expected: expected,
        actual: actual
      )
    }

    let categories = Dictionary(
      uniqueKeysWithValues: capabilities.filter { expectedIDs.contains($0.id) }.map {
        ($0.id, $0.category)
      }
    )
    for registration in registrations {
      let expectedCategory: DependencyCapabilityCategory =
        switch registration.role {
        case .desktopSubstrate:
          .desktopSubstrate
        case .requiredAdapter:
          .requiredAdapter
        case .optionalAdapter:
          .optionalAdapter
        }
      guard categories[registration.id] == expectedCategory else {
        throw ConsumerIntegrationConsistencyError.dependencyRole(id: registration.id)
      }
    }
  }
}
