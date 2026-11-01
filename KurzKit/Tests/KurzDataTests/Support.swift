import Foundation
import KurzCore
@testable import KurzData

// Um servidor de mentira: cada teste tem o seu "host" e responde pelo seu handler. Sem rede.
final class Stub: URLProtocol {
    typealias Handler = (URLRequest, Data?) throws -> (status: Int, body: Data)
    nonisolated(unsafe) static var handlers: [String: Handler] = [:]
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let req = request
        var body = req.httpBody
        if let s = req.httpBodyStream {
            s.open(); defer { s.close() }
            var d = Data(), buf = [UInt8](repeating: 0, count: 65536)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            body = d
        }
        guard let h = Self.lock.withLock({ Self.handlers[req.url!.host!] }) else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        do {
            let (status, data) = try h(req, body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

struct Fake {
    let host = "t" + UUID().uuidString.lowercased().prefix(12)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kurz-" + UUID().uuidString)
    var calls: Calls { Calls(host: host) }
    func serve(_ h: @escaping Stub.Handler) { Stub.lock.withLock { Stub.handlers[host] = h } }
    func down() { Stub.lock.withLock { Stub.handlers[host] = { _, _ in throw URLError(.cannotConnectToHost) } } }
    func fixture(_ name: String) -> Data { try! Data(contentsOf: Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)!) }

    @MainActor func service(invite: String? = nil, stall: TimeInterval = 5) -> StemService {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Stub.self]
        return StemService(api: "https://\(host)", directory: dir, invite: invite ?? "", stall: stall, configuration: c)
    }
}
struct Calls { let host: String }

func json(_ s: String) -> Data { Data(s.utf8) }
func job(_ id: String, status: String = "done", stems: [String] = ["vocals", "drums"], bpm: Int? = nil) -> String {
    "{\"id\":\"\(id)\",\"name\":\"\(id).mp3\",\"status\":\"\(status)\",\"stems\":[\(stems.map { "\"\($0)\"" }.joined(separator: ","))],\"format\":\"wav\"\(bpm.map { ",\"bpm\":\($0)" } ?? "")}"
}
