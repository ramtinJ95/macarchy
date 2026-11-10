import Darwin
import Foundation

/// A regular theme file must be replaced in the consumer's watched directory. Receipts
/// authenticate a previous successful publication even after its generation was collected.
enum WatchedThemePublication {
  enum Failure: Error { case invalidPublicationReceipt }
  private struct PublicationReceipt: Codable {
    let path: String
    let digest: String
  }

  /// Persist only after the family rename/readback, and before reporting success. Unlike
  /// generation artifacts, this evidence survives collection after interrupted activation.
  static func recordPublication(_ data: Data, at target: URL, root: URL, receiptURL: URL) throws {
    let parent = try PinnedFilesystem.openDirectory(at: root)
    defer { Darwin.close(parent) }
    let url = receiptURL
    let state = try PinnedFilesystem.openOrCreateChildDirectory(
      parentDescriptor: parent, name: "state", url: url.deletingLastPathComponent(), mode: 0o700)
    defer { Darwin.close(state) }
    try StateFile.write(
      PublicationReceipt(path: target.standardizedFileURL.path, digest: sha256Digest(data)),
      parentDescriptor: state, name: url.lastPathComponent, url: url)
  }

  /// A last-published digest is authority for exactly that owned destination. The active
  /// render also permits retry if publication succeeded but receipt persistence failed.
  static func matchesPublished(
    _ data: Data, at target: URL, receiptURL: URL, active: () throws -> Data
  ) throws -> Bool {
    let receiptData: Data?
    do {
      receiptData = try PinnedFilesystem.readRegularFile(at: receiptURL).data
    } catch let error as PinnedFilesystemError where error.code == ENOENT {
      receiptData = nil
    }
    if let receiptData {
      guard let receipt = try? JSONDecoder().decode(PublicationReceipt.self, from: receiptData),
        receipt.path.hasPrefix("/"), isSHA256Digest(receipt.digest)
      else { throw Failure.invalidPublicationReceipt }
      if receipt.path == target.standardizedFileURL.path, receipt.digest == sha256Digest(data) {
        return true
      }
    }
    do {
      return try data == active()
    } catch ReconciliationStatusError.noActiveGeneration {
      return false
    }
  }

}
