enum EnvironmentInspectionStatus: String, Encodable, Sendable {
  case managed
  case external
  case drifted
  case unsupported
  case installRequired = "install_required"
  case adoptionRequired = "adoption_required"
  case restorationRequired = "restoration_required"
  case migrationRequired = "migration_required"
  case authorityRequired = "authority_required"
}
