import Darwin
import Foundation
import ThemeCore

guard CommandLine.arguments.count == 4 else {
  exit(64)
}

let checkpoint: ActivationCheckpoint
switch CommandLine.arguments[2] {
case "generationWritten":
  checkpoint = .generationWritten
case "currentReplaced":
  checkpoint = .currentReplaced
default:
  exit(65)
}

do {
  let package = try ThemePackageLoader().load(
    packageURL: URL(filePath: CommandLine.arguments[3], directoryHint: .isDirectory)
  )
  let activator = ThemeActivator(
    root: URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory),
    faultInjector: { reached in
      if reached == checkpoint {
        Darwin._exit(86)
      }
    }
  )
  _ = try activator.activate(package: package)
  exit(70)
} catch {
  exit(1)
}
