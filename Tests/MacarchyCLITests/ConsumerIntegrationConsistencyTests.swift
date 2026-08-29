import Foundation
import Testing

@testable import MacarchyCLI
@testable import ThemeCore

struct ConsumerIntegrationConsistencyTests {
  @Test
  func productionSetupAndDependencyLayersCoverCatalogDeclarations() throws {
    let home = URL(filePath: "/Users/test")
    let plans = SetupOwnershipManager().consumerSetupPlans(
      context: SetupOwnershipManager.Context(homeDirectory: home)
    )
    let capabilities = DependencyProfile.personal(homeDirectory: home).capabilities

    try ConsumerIntegrationConsistency.validateSetupPlans(plans)
    try ConsumerIntegrationConsistency.validateDependencyCapabilities(capabilities)
  }

  @Test
  func consistencyValidationRejectsMissingSetupAndWrongDependencyRole() throws {
    let home = URL(filePath: "/Users/test")
    let plans = SetupOwnershipManager().consumerSetupPlans(
      context: SetupOwnershipManager.Context(homeDirectory: home)
    )
    let incompletePlans = plans.filter { $0.consumerID != .bat }
    let expectedSetup = ConsumerCatalog.shared.setupConsumerIDs.map(\.rawValue).sorted()
    let actualSetup = incompletePlans.map { $0.consumerID.rawValue }.sorted()
    #expect(
      throws: ConsumerIntegrationConsistencyError.setupCoverage(
        expected: expectedSetup,
        actual: actualSetup
      )
    ) {
      try ConsumerIntegrationConsistency.validateSetupPlans(incompletePlans)
    }

    let capabilities = DependencyProfile.personal(homeDirectory: home).capabilities
    let wrongRole = capabilities.map { capability in
      guard capability.id == ConsumerID.bat.rawValue else { return capability }
      return DependencyCapability(
        id: capability.id,
        category: .optionalAdapter,
        probes: capability.probes,
        remediation: capability.remediation
      )
    }
    #expect(throws: ConsumerIntegrationConsistencyError.dependencyRole(id: "bat")) {
      try ConsumerIntegrationConsistency.validateDependencyCapabilities(wrongRole)
    }

    let rogueCapability = DependencyCapability(
      id: "rogue-adapter",
      category: .requiredAdapter,
      probes: [.exists(URL(filePath: "/tmp/rogue-adapter"))],
      remediation: .external("Install the rogue adapter.")
    )
    let expectedDependencyIDs = ConsumerCatalog.shared.entries.flatMap(\.dependencies).map(\.id)
      .sorted()
    #expect(
      throws: ConsumerIntegrationConsistencyError.dependencyCoverage(
        expected: expectedDependencyIDs,
        actual: (expectedDependencyIDs + [rogueCapability.id]).sorted()
      )
    ) {
      try ConsumerIntegrationConsistency.validateDependencyCapabilities(
        capabilities + [rogueCapability]
      )
    }
  }
}
