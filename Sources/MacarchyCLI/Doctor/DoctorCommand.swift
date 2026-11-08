import ArgumentParser
import Foundation
import ThemeCore

extension Macarchy {
  struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Diagnose canonical theme state and consumer integration."
    )

    @OptionGroup var state: StateOptions

    @Flag(help: "Emit machine-readable output.")
    var json = false

    mutating func run() throws {
      let execution = try DoctorCommandRunner.live.execute(
        stateRoot: state.stateRootURL,
        consumerPaths: state.consumerPaths,
        json: json
      )
      try emitExecution(execution)
    }
  }
}
