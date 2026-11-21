import DebugSwiftCore
import Foundation
import FoundationNetworking

// The few DebugSwiftUI pieces the capture refers to, without the rest of the module.
public enum DebugSwiftRuntime {}

public protocol CustomHTTPProtocolDelegate: AnyObject {
    func urlSession(_ protocol: URLProtocol, didReceive response: URLResponse)
    func urlSession(_ protocol: URLProtocol, didReceive data: Data)
    func didFinishLoading(_ protocol: URLProtocol)
    func urlSession(_ protocol: URLProtocol, didFailWithError error: Error)
}

public class DebugSwift {
    public final class Network: @unchecked Sendable {
        public static let shared = Network()
        public var delegate: CustomHTTPProtocolDelegate?
        static func accepts(_ url: URL) -> Bool { true }
        func decryptedBody(_ data: Data, for url: URL) -> String? { nil }
    }
}
