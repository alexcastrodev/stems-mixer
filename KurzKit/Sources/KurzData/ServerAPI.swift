import Foundation
import KurzCore

// No maximo 3 downloads de cada vez: o servidor tem poucas threads e cada stem pesa dezenas de MB.
actor Gate {
    var free: Int
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { free = n }
    func enter() async { if free > 0 { free -= 1 } else { await withCheckedContinuation { waiters.append($0) } } }
    func leave() { if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() } }
}

// Os pedidos HTTP ao server/app.py, sem saber de disco: o que se pede, com que cabecalhos e quanto se espera.
// O convite viaja num header em todos os pedidos, e esse header e a fonte da verdade do convite em uso.
final class ServerAPI: @unchecked Sendable {
    let api: String
    let session: URLSession
    let downloads = Gate(3)
    let lock = NSLock()
    var _invite: String?

    // `stall`: quanto tempo um pedido pode ficar sem receber um byte antes de se dar por morto (e o prazo de cada pacote, nao do ficheiro todo).
    init(api: String, stall: TimeInterval = 30, configuration: URLSessionConfiguration = .default) {
        self.api = api.hasSuffix("/") ? String(api.dropLast()) : api
        configuration.timeoutIntervalForRequest = stall
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration)
    }

    // O servidor identifica o utilizador pelo invite code, enviado em todos os pedidos.
    var invite: String? {
        get { lock.withLock { _invite } }
        set { lock.withLock { _invite = (newValue?.isEmpty ?? true) ? nil : newValue } }   // um arquivo estragado nao pode derrubar o arranque
    }

    func request(_ path: String, method: String = "GET", json: String? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: api + path)!)
        r.httpMethod = method
        if let invite { r.setValue(invite, forHTTPHeaderField: "X-Invite-Code") }
        if let json { r.httpBody = Data(json.utf8); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    // Os cabecalhos que seguem em todos os pedidos (o convite).
    var headers: [String: String] { invite.map { ["X-Invite-Code": $0] } ?? [:] }

    static func check(_ data: Data, _ response: URLResponse) throws {
        guard let r = response as? HTTPURLResponse, !(200..<300).contains(r.statusCode) else { return }
        let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        throw ServerError.http(r.statusCode, msg)
    }

    func send(_ r: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: r)
        try Self.check(data, response)
        return data
    }

    // Estado do servidor para a UI: pedido leve e com prazo curto. Nunca lanca.
    func status(timeout: TimeInterval = 5) async -> ServerStatus {
        struct Body: Decodable { let device: String; let active: Int; let name: String? }
        var r = request("/status")
        r.timeoutInterval = timeout
        do {
            let b = try JSONDecoder().decode(Body.self, from: try await send(r))
            return ServerStatus(.online, device: b.device, active: b.active, name: b.name)
        } catch let e as URLError where e.code == .timedOut { return ServerStatus(.busy) }
        catch let e where isOffline(e) { return ServerStatus(.offline) }
        catch let e as ServerError where e.isUnauthorized { return ServerStatus(.unauthorized) }
        catch { return ServerStatus(.error) }   // o servidor respondeu, mas nao com o que se esperava (ex.: versao antiga, sem /status)
    }

    // Muda o nome da conta (so serve para a reconhecer). Devolve o nome gravado pelo servidor; em erro lanca:
    // ServerError (a mensagem do servidor, ou 401); URLError = sem ligacao.
    func rename(_ name: String) async throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ServerError.invalid("O nome não pode estar vazio.") }
        let body = String(data: try JSONSerialization.data(withJSONObject: ["name": name]), encoding: .utf8)!
        let data = try await send(request("/me", method: "PATCH", json: body))
        return (try JSONSerialization.jsonObject(with: data) as! [String: Any])["name"] as! String
    }

    // Envia a musica e devolve logo o id do job: o progresso ve-se na biblioteca (GET /jobs), sem bloquear a janela.
    // `hifi`: stems sem perdas (FLAC); desligado, otimizados (Opus 96 kbps) e uns 10x mais leves. `progress` recebe de 0 a 1 o que ja foi enviado.
    func upload(file: URL, name: String, model: String, drums: Bool, hifi: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let boundary = "kurz-" + UUID().uuidString
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: body) }
        try Self.multipart(to: body, boundary: boundary, file: file, name: name, fields: ["model": model, "drums": drums ? "1" : "0", "hifi": hifi ? "1" : "0"])
        var r = request("/separate", method: "POST")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: r, fromFile: body, delegate: Sent(progress))
        try Self.check(data, response)
        return (try JSONSerialization.jsonObject(with: data) as! [String: Any])["id"] as! String
    }

    // O corpo multipart num ficheiro (e nao em memoria): uma musica pesa dezenas de MB.
    static func multipart(to url: URL, boundary: String, file: URL, name: String, fields: [String: String]) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url), input = try FileHandle(forReadingFrom: file)
        defer { try? out.close(); try? input.close() }
        let quoted = name.replacingOccurrences(of: "\"", with: "%22")
        out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(quoted)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { out.write(chunk) }
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            out.write(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)".utf8))
        }
        out.write(Data("\r\n--\(boundary)--\r\n".utf8))
    }

    final class Sent: NSObject, URLSessionTaskDelegate {
        let progress: @Sendable (Double) -> Void
        var last = -1
        init(_ progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
        func urlSession(_ s: URLSession, task: URLSessionTask, didSendBodyData _: Int64, totalBytesSent sent: Int64, totalBytesExpectedToSend total: Int64) {
            let pct = Int(sent * 100 / max(total, 1))
            if pct != last { last = pct; progress(Double(pct) / 100) }       // so uns 100 avisos, seja qual for o tamanho
        }
    }

    // Apaga a musica (e os seus arquivos) no servidor; falha se ainda estiver a ser processada.
    func deleteJob(_ id: String) async throws { _ = try await send(request("/jobs/\(id)", method: "DELETE")) }
    func patchJob(_ id: String, json: String) async throws -> Data { try await send(request("/jobs/\(id)", method: "PATCH", json: json)) }
    // O JSON da lista de jobs, como o servidor o deu.
    func getJobs() async throws -> Data { try await send(request("/jobs")) }

    // Divide a bateria de uma musica ja separada; espera pelo fim e devolve as pecas (drum_kick, ...).
    func splitDrums(_ id: String, status: @Sendable (String) -> Void, poll: Duration) async throws -> [String] {
        status("Dividindo a bateria…")
        _ = try await send(request("/jobs/\(id)/drums", method: "POST"))
        while true {
            let j = try JSONSerialization.jsonObject(with: try await send(request("/jobs/\(id)"))) as! [String: Any]
            if j["drums_running"] as? Bool != true {
                if let e = j["drum_error"] as? String { throw ServerError.invalid(e) }
                return j["drum_stems"] as? [String] ?? []
            }
            try await Task.sleep(for: poll)
        }
    }

    func stemURL(_ id: String, _ name: String, _ format: StemFormat) -> URL { URL(string: "\(api)/stems/\(id)/\(name).\(format.ext)")! }

    // Um stem para `dest` (nunca fica a meio: escreve-se ao lado e muda-se o nome). `progress`: 0...1 do que ja se leu.
    func download(_ id: String, _ name: String, _ format: StemFormat, to dest: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        await downloads.enter()
        do {
            var r = URLRequest(url: stemURL(id, name, format))
            headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            let (tmp, response) = try await session.download(for: r, delegate: Received(progress))
            if let h = response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw ServerError.http(h.statusCode, nil) }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
            await downloads.leave()
        } catch { await downloads.leave(); throw error }
    }

    final class Received: NSObject, URLSessionDownloadDelegate {
        let progress: (@Sendable (Double) -> Void)?
        init(_ progress: (@Sendable (Double) -> Void)?) { self.progress = progress }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten done: Int64, totalBytesExpectedToWrite total: Int64) {
            if total > 0 { progress?(Double(done) / Double(total)) }
        }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
