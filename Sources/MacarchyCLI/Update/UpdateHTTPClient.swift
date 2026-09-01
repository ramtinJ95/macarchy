import Foundation
import Synchronization

struct UpdateHTTPRequest: Equatable, Sendable {
  let url: URL
  let headers: [String: String]
}

struct UpdateHTTPResponse: Equatable, Sendable {
  let statusCode: Int
  let headers: [String: String]
  let body: Data

  func header(_ name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}

struct UpdateHTTPClient: Sendable {
  static let maximumResponseSize = 256 * 1024

  let send: @Sendable (UpdateHTTPRequest) throws -> UpdateHTTPResponse

  static let live = UpdateHTTPClient { request in
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    let delegate = BoundedHTTPResponseDelegate(maximumSize: maximumResponseSize)
    let session = URLSession(
      configuration: configuration,
      delegate: delegate,
      delegateQueue: nil
    )
    defer { session.invalidateAndCancel() }

    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = "GET"
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }

    let task = session.dataTask(with: urlRequest)
    task.resume()

    guard delegate.wait(timeout: .now() + 21) == .success else {
      task.cancel()
      throw UpdateHTTPClientError.timedOut
    }
    return try delegate.response()
  }
}

enum UpdateHTTPClientError: Error, CustomStringConvertible, Equatable, Sendable {
  case invalidResponse
  case requestFailed(String)
  case responseTooLarge
  case timedOut

  var description: String {
    switch self {
    case .invalidResponse:
      "GitHub returned a non-HTTP response"
    case .requestFailed(let error):
      "GitHub release request failed: \(error)"
    case .responseTooLarge:
      "GitHub release response exceeded the 256 KiB limit"
    case .timedOut:
      "GitHub release check exceeded its 20-second timeout"
    }
  }
}

private final class BoundedHTTPResponseDelegate: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  private struct State {
    var response: HTTPURLResponse?
    var body = Data()
    var error: UpdateHTTPClientError?
  }

  private let maximumSize: Int
  private let completion = DispatchSemaphore(value: 0)
  private let state = Mutex(State())

  init(maximumSize: Int) {
    self.maximumSize = maximumSize
  }

  func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
    completion.wait(timeout: timeout)
  }

  func response() throws -> UpdateHTTPResponse {
    try state.withLock { state in
      if let error = state.error { throw error }
      guard let response = state.response else {
        throw UpdateHTTPClientError.invalidResponse
      }
      let headers = response.allHeaderFields.reduce(into: [String: String]()) {
        if let name = $1.key as? String {
          $0[name] = String(describing: $1.value)
        }
      }
      return UpdateHTTPResponse(
        statusCode: response.statusCode,
        headers: headers,
        body: state.body
      )
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse else {
      state.withLock { $0.error = .invalidResponse }
      completionHandler(.cancel)
      return
    }
    guard response.expectedContentLength <= maximumSize else {
      state.withLock { $0.error = .responseTooLarge }
      completionHandler(.cancel)
      return
    }
    state.withLock { $0.response = response }
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    let exceeded = state.withLock { state in
      guard state.body.count + data.count <= maximumSize else {
        state.error = .responseTooLarge
        return true
      }
      state.body.append(data)
      return false
    }
    if exceeded {
      dataTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    if let error {
      state.withLock { state in
        if state.error == nil {
          state.error = .requestFailed(String(describing: error))
        }
      }
    }
    completion.signal()
  }
}
