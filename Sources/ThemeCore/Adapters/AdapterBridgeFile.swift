import Darwin
import Foundation

protocol AdapterBridgeFileError: Error {
  static func bridgeIsNotRegularFile(_ url: URL) -> Self
  static func bridgeDoesNotMatch(_ url: URL) -> Self
  static func cannotReadBridge(_ url: URL, _ cause: String) -> Self
  static func cannotPublishBridge(_ url: URL, _ cause: String) -> Self
}

struct AdapterBridgeFile<BridgeError: AdapterBridgeFileError>: Sendable {
  let url: URL

  func read() throws -> Data {
    do {
      return try BoundedRegularFile.read(at: url).data
    } catch BoundedRegularFileError.notRegular {
      throw BridgeError.bridgeIsNotRegularFile(url)
    } catch BoundedRegularFileError.system(operation: "open", code: ELOOP) {
      throw BridgeError.bridgeIsNotRegularFile(url)
    } catch BoundedRegularFileError.system(operation: "open", code: ENOENT),
      BoundedRegularFileError.tooLarge
    {
      throw BridgeError.bridgeDoesNotMatch(url)
    } catch {
      throw BridgeError.cannotReadBridge(url, String(describing: error))
    }
  }

  func publish(_ data: Data) throws {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: url, options: .atomic)
    } catch {
      throw BridgeError.cannotPublishBridge(url, String(describing: error))
    }
    guard try read() == data else {
      throw BridgeError.bridgeDoesNotMatch(url)
    }
  }
}
