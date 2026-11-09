import Darwin
import Foundation

/// Children started with posix_spawn and reaped with waitpid, for callers that need spawn
/// attributes Foundation's Process cannot set or must own the reap themselves. A child stays
/// unreaped until the caller reaps it, so its PID cannot be reused while it is signalled.
package enum ChildProcess {
  package enum FileAction: Sendable {
    case open(descriptor: Int32, path: String, flags: Int32, mode: mode_t)
    case duplicate(Int32, to: Int32)
    case inherit(Int32)
  }

  /// Raw error numbers, so each caller keeps its own messages.
  package enum SpawnFailure: Error, Equatable, Sendable {
    /// A posix_spawnattr or file-action call returned this error number.
    case prepare(Int32)
    /// An argument could not be copied into C storage.
    case allocateArguments
    /// posix_spawn returned this error number.
    case spawn(Int32)
  }

  /// Spawns `path` with argv `[path] + arguments` and `environment` (`NAME=value` entries), or
  /// this process's environment when nil. Attributes apply in this order: signal defaults, signal
  /// mask, flags, process group, then file actions. A nil `fileActions` passes no file-actions
  /// object at all.
  package static func spawn(
    _ path: String,
    arguments: [String],
    flags: Int32,
    signalDefaults: sigset_t? = nil,
    signalMask: sigset_t? = nil,
    processGroup: pid_t? = nil,
    fileActions: [FileAction]? = nil,
    environment: [String]? = nil
  ) -> Result<pid_t, SpawnFailure> {
    var attributes: posix_spawnattr_t?
    var code = posix_spawnattr_init(&attributes)
    guard code == 0 else { return .failure(.prepare(code)) }
    defer { posix_spawnattr_destroy(&attributes) }
    if var signalDefaults {
      code = posix_spawnattr_setsigdefault(&attributes, &signalDefaults)
      guard code == 0 else { return .failure(.prepare(code)) }
    }
    if var signalMask {
      code = posix_spawnattr_setsigmask(&attributes, &signalMask)
      guard code == 0 else { return .failure(.prepare(code)) }
    }
    code = posix_spawnattr_setflags(&attributes, Int16(flags))
    guard code == 0 else { return .failure(.prepare(code)) }
    if let processGroup {
      code = posix_spawnattr_setpgroup(&attributes, processGroup)
      guard code == 0 else { return .failure(.prepare(code)) }
    }

    var actions: posix_spawn_file_actions_t?
    var actionsInitialized = false
    defer {
      if actionsInitialized { posix_spawn_file_actions_destroy(&actions) }
    }
    if let fileActions {
      code = posix_spawn_file_actions_init(&actions)
      guard code == 0 else { return .failure(.prepare(code)) }
      actionsInitialized = true
      for action in fileActions {
        switch action {
        case .open(let descriptor, let file, let openFlags, let mode):
          code = posix_spawn_file_actions_addopen(&actions, descriptor, file, openFlags, mode)
        case .duplicate(let descriptor, let target):
          code = posix_spawn_file_actions_adddup2(&actions, descriptor, target)
        case .inherit(let descriptor):
          code = posix_spawn_file_actions_addinherit_np(&actions, descriptor)
        }
        guard code == 0 else { return .failure(.prepare(code)) }
      }
    }

    let argv = [path] + arguments
    let storage = argv.compactMap { strdup($0) }
    defer {
      for pointer in storage { free(pointer) }
    }
    guard storage.count == argv.count else { return .failure(.allocateArguments) }
    var pointers: [UnsafeMutablePointer<CChar>?] = storage.map { $0 } + [nil]
    let environmentStorage = (environment ?? []).compactMap { strdup($0) }
    defer {
      for pointer in environmentStorage { free(pointer) }
    }
    guard environmentStorage.count == (environment ?? []).count else {
      return .failure(.allocateArguments)
    }
    var environmentPointers: [UnsafeMutablePointer<CChar>?] = environmentStorage.map { $0 } + [nil]
    var pid: pid_t = 0
    code = environmentPointers.withUnsafeMutableBufferPointer { custom in
      let envp = environment == nil ? environ : custom.baseAddress
      return actionsInitialized
        ? posix_spawn(&pid, path, &actions, &attributes, &pointers, envp)
        : posix_spawn(&pid, path, nil, &attributes, &pointers, envp)
    }
    guard code == 0 else { return .failure(.spawn(code)) }
    return .success(pid)
  }

  /// The exit status of a wait status, or 128 + n when signal n ended the child.
  package static func exitCode(waitStatus status: Int32) -> Int32 {
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
  }

  /// SIGKILLs `target` and the owned child, then blocks until `pid` is reaped. Killing
  /// the original group alone cannot stop a child that has moved to a different group.
  /// Descendants that leave that original group may survive; this is not a sandbox.
  package static func killAndReap(_ pid: pid_t, target: pid_t) {
    _ = kill(target, SIGKILL)
    if target != pid { _ = kill(pid, SIGKILL) }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1, errno == EINTR {}
  }

  /// SIGTERM, then up to `polls` checks of `exited` `interval` apart, then SIGKILL and reap.
  /// No check follows the last pause.
  package static func terminateThenKill(
    _ pid: pid_t, polls: Int, interval: TimeInterval, exited: () -> Bool
  ) {
    _ = kill(pid, SIGTERM)
    for _ in 0..<polls {
      if exited() { return }
      Thread.sleep(forTimeInterval: interval)
    }
    killAndReap(pid, target: pid)
  }
}
