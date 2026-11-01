import Foundation
import KurzAudio
import KurzCore
import KurzData
@testable import KurzPresentation

// Um servidor de mentira, por "host" (cada teste o seu), com os caminhos que a app usa.
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

func json(_ s: String) -> Data { Data(s.utf8) }
func tone(_ amp: Int16, frames: Int = 44100) -> Data { Wav.encode([Int16](repeating: amp, count: frames * 2)) }

// Tudo o que uma app precisa: o servidor de mentira, o disco temporario e os ViewModels ligados como na app (sem saida de som).
@MainActor final class World {
    let host = "t" + UUID().uuidString.lowercased().prefix(12)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kurz-" + UUID().uuidString)
    var jobs: [String] = []                 // o JSON de cada job que o servidor lista
    var up = true
    var patches: [(String, String)] = []    // (id, corpo) dos PATCH /jobs/<id>
    var drumsDone = false
    var uploads = 0
    var notes: [String] = []
    let stems: StemService
    let toast = ToastViewModel()
    var library: LibraryViewModel!
    var player: PlayerViewModel!
    var account: AccountViewModel!
    var importer: ImportViewModel!
    var played: [String] = []
    var shown = 0

    init(invite: String? = "ok") {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Stub.self]
        stems = StemService(api: "https://\(host)", directory: dir, invite: invite ?? "", configuration: c)
        let host = host
        nonisolated(unsafe) let me = self
        Stub.lock.withLock { Stub.handlers[host] = { r, b in try me.route(r, b) } }
        library = LibraryViewModel(stems: stems, words: DeviceWords(place: "Mac", tap: "clique")) { [unowned self] in notes.append($0) }
        player = PlayerViewModel(stems: stems, library: library, makeOut: { nil }, notify: { [unowned self] in notes.append($0) }, words: DeviceWords(place: "Mac", tap: "clique"))
        library.hooks = LibraryHooks(play: { [unowned self] s in played.append(s.id); return await player.play(s) }, playerBusy: { [unowned self] in player.isPlayingNow }, showPlayer: { [unowned self] in shown += 1 }, closeOpenSong: { [unowned self] in player.close() })
        account = AccountViewModel(stems: stems, refreshLibrary: { [unowned self] in await library.refresh() }, loggedOut: { [unowned self] in player.close(); library.clear() }, notify: { [unowned self] in notes.append($0) })
        importer = ImportViewModel(stems: stems, library: library, notify: { [unowned self] in notes.append($0) }, showLibrary: { [unowned self] in shown += 1 })
    }

    func route(_ r: URLRequest, _ body: Data?) throws -> (status: Int, body: Data) {
        guard up else { throw URLError(.cannotConnectToHost) }
        let path = r.url!.path, m = r.httpMethod ?? "GET"
        switch (m, path) {
        case ("GET", "/status"): return (200, json("{\"device\":\"cpu\",\"active\":0,\"name\":\"Ana\"}"))
        case ("GET", "/jobs"): return (200, json("[" + jobs.joined(separator: ",") + "]"))
        case ("POST", "/separate"): uploads += 1; return (200, json("{\"id\":\"new\"}"))
        case ("POST", _) where path.hasSuffix("/drums"): drumsDone = true; return (200, json("{}"))
        case ("GET", _) where path.hasPrefix("/jobs/"): return (200, json("{\"drums_running\":false,\"drum_stems\":[\"drum_kick\"]}"))
        case ("PATCH", _) where path.hasPrefix("/jobs/"): patches.append((String(path.dropFirst(6)), String(decoding: body ?? Data(), as: UTF8.self))); return (200, json("{\"bpm\":100,\"downbeat_offset\":0.25}"))
        case ("PATCH", "/me"): return (200, json("{\"name\":\"Bia\"}"))
        case ("DELETE", _): jobs.removeAll { $0.contains("\"id\":\"\(path.split(separator: "/").last!)\"") }; return (200, json("{}"))
        case ("GET", _) where path.hasPrefix("/stems/"): return (200, tone(path.contains("drum_kick") ? 300 : path.contains("vocals") ? 1000 : 2000))
        default: return (404, json("{}"))
        }
    }

    // Um job do servidor no JSON da lista.
    func job(_ id: String, name: String? = nil, status: String = "done", stems: [String] = ["vocals", "drums"], created: Double = 1_700_000_000, bpm: Int? = 120) -> String {
        "{\"id\":\"\(id)\",\"name\":\"\(name ?? id + ".mp3")\",\"status\":\"\(status)\",\"stems\":[\(stems.map { "\"\($0)\"" }.joined(separator: ","))],\"created\":\(created),\"duration\":1.0,\"format\":\"wav\"\(bpm.map { ",\"bpm\":\($0)" } ?? "")}"
    }

    // Poe as musicas no servidor, lista-as e espera que fiquem no disco (as que ja separadas).
    func start(_ jobs: [String]) async {
        self.jobs = jobs
        await library.refresh()
    }

    func waitUntil(_ what: String = "", timeout: Double = 5, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
    }
}
