import ArgumentParser
import Darwin

@main
@MainActor
enum FocusRingMain {
  static func main() {
    let options: FocusRingOptions
    do {
      options = try FocusRingOptions.parse()
    } catch {
      FocusRingOptions.exit(withError: error)
    }
    // Late output to a closed pipe must fail the write, never kill the process.
    Darwin.signal(SIGPIPE, SIG_IGN)
    Darwin.exit(FocusRingSession.run(options))
  }
}
