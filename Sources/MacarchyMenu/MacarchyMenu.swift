import ApplicationServices
import Carbon
import Darwin
import Foundation

// This executable alone crosses the approved private SkyLight boundary. Neither
// ThemeCore nor the main CLI links or loads SkyLight. Permission is manual.
enum MenuFailure: Error, CustomStringConvertible {
  case permission, unsupported, frontApplication
  case accessibility(AXError)
  var description: String {
    switch self {
    case .permission:
      "Accessibility permission required for macarchy-menu. Enable it manually in System Settings > Privacy & Security > Accessibility."
    case .unsupported:
      "Required private SkyLight entry points are unavailable on this macOS release."
    case .frontApplication: "Cannot identify the front application's Apple menu."
    case .accessibility(let error): "Apple menu Accessibility operation failed: \(error.rawValue)."
    }
  }
}

final class SkyLightMenuOwner {
  private let handle: UnsafeMutableRawPointer
  private let connection: @convention(c) () -> Int32
  private let front: @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> Void
  private let processConnection:
    @convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<Int32>)
      -> Void
  private let processID: @convention(c) (Int32, UnsafeMutablePointer<pid_t>) -> Void

  init() throws {
    guard
      let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL)
    else { throw MenuFailure.unsupported }
    guard let connection = dlsym(handle, "SLSMainConnectionID"),
      let front = dlsym(handle, "_SLPSGetFrontProcess"),
      let processConnection = dlsym(handle, "SLSGetConnectionIDForPSN"),
      let processID = dlsym(handle, "SLSConnectionGetPID")
    else {
      dlclose(handle)
      throw MenuFailure.unsupported
    }
    self.handle = handle
    self.connection = unsafeBitCast(connection, to: (@convention(c) () -> Int32).self)
    self.front = unsafeBitCast(
      front, to: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> Void).self)
    self.processConnection = unsafeBitCast(
      processConnection,
      to: (@convention(c) (
        Int32, UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<Int32>
      ) -> Void).self)
    self.processID = unsafeBitCast(
      processID, to: (@convention(c) (Int32, UnsafeMutablePointer<pid_t>) -> Void).self)
  }
  deinit { dlclose(handle) }

  func application() throws -> AXUIElement {
    var serial = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
    front(&serial)
    var target: Int32 = 0
    processConnection(connection(), &serial, &target)
    guard target > 0 else { throw MenuFailure.frontApplication }
    var pid: pid_t = 0
    processID(target, &pid)
    guard pid > 0 else { throw MenuFailure.frontApplication }
    return AXUIElementCreateApplication(pid)
  }
}

func attribute(_ element: AXUIElement, _ name: CFString) throws -> CFTypeRef {
  var value: CFTypeRef?
  let result = AXUIElementCopyAttributeValue(element, name, &value)
  guard result == .success else { throw MenuFailure.accessibility(result) }
  guard let value else { throw MenuFailure.frontApplication }
  return value
}

func openAppleMenu(_ owner: SkyLightMenuOwner) throws {
  let application = try owner.application()
  let timeout = AXUIElementSetMessagingTimeout(application, 1)
  guard timeout == .success else { throw MenuFailure.accessibility(timeout) }
  let value = try attribute(application, kAXMenuBarAttribute as CFString)
  guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw MenuFailure.frontApplication }
  let menu = value as! AXUIElement
  guard
    let children = try attribute(menu, kAXVisibleChildrenAttribute as CFString) as? [AXUIElement],
    let apple = children.first,
    try attribute(apple, kAXRoleAttribute as CFString) as? String == kAXMenuBarItemRole
  else { throw MenuFailure.frontApplication }
  let result = AXUIElementPerformAction(apple, kAXPressAction as CFString)
  guard result == .success else { throw MenuFailure.accessibility(result) }
}

struct MenuCommand {
  let check: () throws -> Void
  let open: () throws -> Void
  func execute(_ arguments: [String]) throws -> String {
    switch arguments {
    case ["--help"]:
      return
        "macarchy-menu --check | --open-apple-menu\nSeparate SkyLight/Accessibility helper. Permission must be enabled manually; --check never requests it."
    case ["--check"]:
      try check()
      return "ready"
    case ["--open-apple-menu"]:
      try check()
      try open()
      return ""
    default: throw InvalidMenuArguments()
    }
  }
}

struct InvalidMenuArguments: Error {}

@main struct MacarchyMenu {
  static func main() {
    do {
      var owner: SkyLightMenuOwner?
      let command = MenuCommand(
        check: {
          owner = try SkyLightMenuOwner()
          guard AXIsProcessTrusted() else { throw MenuFailure.permission }
        },
        open: {
          guard let owner else { throw MenuFailure.frontApplication }
          try openAppleMenu(owner)
        })
      let output = try command.execute(Array(CommandLine.arguments.dropFirst()))
      if !output.isEmpty { print(output) }
    } catch is InvalidMenuArguments {
      FileHandle.standardError.write(
        Data("Usage: macarchy-menu --check | --open-apple-menu\n".utf8))
      exit(64)
    } catch {
      FileHandle.standardError.write(Data("Macarchy menu: \(error)\n".utf8))
      exit(1)
    }
  }
}
