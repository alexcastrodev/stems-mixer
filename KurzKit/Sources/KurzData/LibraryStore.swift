import Foundation
import KurzCore

// A biblioteca de musicas no disco (library.json) e as correcoes de tempo feitas sem servidor, em fila (pending.json): offline first.
// A lista guardada aparece logo ao abrir; as correcoes em fila seguem, por ordem, quando o servidor voltar.
final class LibraryStore: @unchecked Sendable {
    struct Pending: Codable { let id: String, body: String }
    let server: ServerAPI
    let dir: URL
    let lock = NSLock()                // uma sincronizacao de cada vez (a fila e o seu ficheiro)
    var queue: [Pending]?

    // false quando a ultima consulta a biblioteca nao chegou ao servidor (a mostrar o que esta guardado).
    private(set) var online = true

    init(server: ServerAPI, dir: URL) { (self.server, self.dir) = (server, dir) }

    var libraryFile: URL { dir.appendingPathComponent("library.json") }
    var pendingFile: URL { dir.appendingPathComponent("pending.json") }
    var pending: [Pending] {
        get { lock.withLock { queue ?? ((try? JSONDecoder().decode([Pending].self, from: Data(contentsOf: pendingFile))) ?? []) } }
        set { lock.withLock { queue = newValue }; try? Disk.save(pendingFile, JSONEncoder().encode(newValue)) }
    }

    // Envia, por ordem, as correcoes feitas sem servidor; para na primeira que ainda nao chega la.
    func sync() async {
        while let first = pending.first {
            do { _ = try await server.patchJob(first.id, json: first.body) }
            catch let e where isOffline(e) { return }
            catch let e as ServerError where e.isUnauthorized { return }   // convite recusado (ou servidor errado): a correcao e do utilizador, fica em fila
            catch {}                                                        // o servidor recusou (ex.: musica apagada): nao vale a pena insistir
            pending = Array(pending.dropFirst())
        }
    }

    // Corrige o tempo de uma musica no servidor (fica gravado): BPM e/ou segundo do 1.o compasso.
    // Devolve false se estava sem servidor: a correcao ficou em fila e segue quando ele voltar.
    func fixTempo(_ id: String, bpm: Int? = nil, downbeatOffset: Double? = nil) async throws -> Bool {
        var body: [String: Any] = [:]
        if let bpm { body["bpm"] = bpm }
        if let downbeatOffset { body["downbeat_offset"] = downbeatOffset }
        let json = String(data: try JSONSerialization.data(withJSONObject: body, options: .sortedKeys), encoding: .utf8)!
        await sync()                                                        // as anteriores primeiro, para manter a ordem
        if pending.isEmpty {
            do { _ = try await server.patchJob(id, json: json); return true }
            catch let e where isOffline(e) {}
        }
        pending += [Pending(id: id, body: json)]
        return false
    }

    // Repoe o tempo detetado pelo servidor (BPM e 1.o compasso), desfazendo as correcoes do utilizador.
    func resetTempo(_ id: String) async throws -> (bpm: Int?, offset: Double) {
        await sync()
        let j = try JSONSerialization.jsonObject(with: try await server.patchJob(id, json: "{\"reset\":true}")) as? [String: Any] ?? [:]   // so o servidor sabe o tempo detetado
        return (j["bpm"] as? Int, j["downbeat_offset"] as? Double ?? 0)
    }

    // Jobs conhecidos pelo servidor, do mais recente para o mais antigo. Sem servidor, a ultima lista guardada
    // (com as correcoes de tempo ainda em fila); sem lista guardada, falha.
    func list() async throws -> [Song] {
        let data: Data
        do {
            await sync()
            data = try await server.getJobs()
            try? Disk.save(libraryFile, data)
            online = true
        } catch let e where isOffline(e) {
            online = false
            guard let saved = try? Data(contentsOf: libraryFile) else { throw e }
            data = saved
        }
        return try parse(data)
    }

    // A lista como o servidor a deu, com as correcoes de tempo ainda em fila por cima.
    func parse(_ data: Data) throws -> [Song] {
        var songs = try JobDTO.list(data).map { $0.toSong() }
        for p in pending {
            guard let i = songs.firstIndex(where: { $0.id == p.id }),
                  let f = try? JSONSerialization.jsonObject(with: Data(p.body.utf8)) as? [String: Any] else { continue }
            songs[i].bpm = f["bpm"] as? Int ?? songs[i].bpm
            songs[i].downbeatOffset = f["downbeat_offset"] as? Double ?? songs[i].downbeatOffset
        }
        return songs
    }

    // A lista guardada da ultima vez que o servidor respondeu: aparece logo, sem esperar pela rede. Vazia se nunca houve ou se o arquivo estiver estragado.
    func cached() -> [Song] { (try? Data(contentsOf: libraryFile)).flatMap { try? parse($0) } ?? [] }

    // A biblioteca guardada e as correcoes em fila sao da conta: saem quando ela sai.
    func forget() {
        try? FileManager.default.removeItem(at: libraryFile)
        try? FileManager.default.removeItem(at: pendingFile)
        lock.withLock { queue = [] }
    }
}
