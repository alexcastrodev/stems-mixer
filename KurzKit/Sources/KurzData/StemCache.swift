import Foundation
import KurzCore

// Os stems no disco (`stems/<id>/<nome>.<formato>`): so fica la o que ja se abriu ou guardou, e abre-se sem servidor.
final class StemCache: @unchecked Sendable {
    let server: ServerAPI
    let dir: URL
    let lock = NSLock()
    var inflight: [URL: Task<URL, Error>] = [:]    // stems a descarregar agora, por ficheiro: quem pedir o mesmo junta-se em vez de o descarregar outra vez

    init(server: ServerAPI, dir: URL) { (self.server, self.dir) = (server, dir) }

    func path(_ id: String, _ name: String, _ format: StemFormat) -> URL { dir.appendingPathComponent("stems/\(id)/\(name).\(format.ext)") }

    // Todos os stems da musica (e as partes da bateria) ja estao no disco: abre-se sem servidor.
    func isCached(_ song: Song) -> Bool {
        !song.stems.isEmpty && (song.stems + song.drums).allSatisfy { FileManager.default.fileExists(atPath: path(song.id, $0, song.format).path) }
    }

    // Tira da musica os stems do disco (continuam no servidor): liberta espaco. Nao se chama com a musica a descarregar.
    func evict(_ id: String) { try? FileManager.default.removeItem(at: dir.appendingPathComponent("stems/\(id)")) }

    // O ficheiro de um stem, no disco; se ainda nao esta la, descarrega-o primeiro.
    // `progress`: 0...1 do que ja se leu deste stem (quem se junta a uma descarga em curso nao o recebe).
    func file(_ id: String, _ name: String, _ format: StemFormat, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let url = path(id, name, format)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let task: Task<URL, Error> = lock.withLock {
            if let running = inflight[url] { return running }
            let t = Task { [server] in try await server.download(id, name, format, to: url, progress: progress); return url }
            inflight[url] = t
            return t
        }
        defer { lock.withLock { inflight[url] = nil } }
        return try await task.value
    }
}
