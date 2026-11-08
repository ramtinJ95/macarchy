/// Publishes a reviewed, ownership-only migration under locks the caller already holds; lock
/// order stays with the caller. `candidate` reads fresh evidence and returns its report and the
/// write that would publish it. The evidence must still carry the approved digest, and all of it
/// is re-read immediately before publication and must be unchanged.
func publishReviewedOwnershipMigration<Report: Equatable>(
  approval: String,
  status: WritableKeyPath<Report, String>,
  evidenceDigest: KeyPath<Report, String>,
  stale: @autoclosure () -> any Error,
  changed: @autoclosure () -> any Error,
  candidate: () throws -> (report: Report, persist: () throws -> Void)
) throws -> Report {
  let reviewed = try candidate()
  guard reviewed.report[keyPath: evidenceDigest] == approval else { throw stale() }
  if reviewed.report[keyPath: status] == "already_bound" { return reviewed.report }
  let current = try candidate()
  guard current.report == reviewed.report else { throw changed() }
  try current.persist()
  var report = current.report
  report[keyPath: status] = "migrated"
  return report
}
