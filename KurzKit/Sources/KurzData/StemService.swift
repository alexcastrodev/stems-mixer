import Foundation
import KurzCore

// A porta do modulo de dados: tudo o que as vistas pedem ao servidor (server/app.py) e ao disco deste aparelho. Compoe as pecas internas:
// ServerAPI (HTTP), Account (convite), LibraryStore (biblioteca e correcoes em fila) e StemCache (stems no disco).
// Offline first: a biblioteca e os stems abertos ficam em disco e abrem-se sem o servidor; as correcoes de tempo feitas sem ele
// ficam em fila (pending.json) e seguem quando ele voltar. Separar, dividir a bateria, importar e apagar precisam do servidor.
@MainActor public final class StemService {
    let server: ServerAPI
    let account: Account
    let library: LibraryStore
    let cache: StemCache

    // `api`: o servidor (por omissao KURZ_API ou o de producao). `directory`: onde ficam a biblioteca e os stems. `configuration`: so os testes a mudam.
    public init(api: String? = nil, directory: URL? = nil, invite: String? = nil, stall: TimeInterval = 30, configuration: URLSessionConfiguration = .default) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KurzMusic")
        server = ServerAPI(api: api ?? ProcessInfo.processInfo.environment["KURZ_API"] ?? "https://musik-api.kurz.fyi", stall: stall, configuration: configuration)
        library = LibraryStore(server: server, dir: dir)
        cache = StemCache(server: server, dir: dir)
        account = Account(server: server, library: library, dir: dir, invite: invite)
    }

    // false quando a ultima consulta a biblioteca nao chegou ao servidor (a mostrar o que esta guardado).
    public var online: Bool { library.online }

    // O que dizer ao utilizador quando rename falha.
    public static func nameError(_ e: Error) -> String {
        switch e {
        case let s as ServerError where s.isUnauthorized: "O servidor recusou o convite."
        case let s as ServerError: s.localizedDescription
        default: "Sem ligação ao servidor. Tente outra vez."
        }
    }

    // --- servidor ---
    public func status(timeout: TimeInterval = 5) async -> ServerStatus { await server.status(timeout: timeout) }
    public func rename(_ name: String) async throws -> String { try await server.rename(name) }
    public func upload(_ file: URL, name: String, model: String, drums: Bool, hifi: Bool = true, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> String {
        try await server.upload(file: file, name: name, model: model, drums: drums, hifi: hifi, progress: progress)
    }
    public func splitDrums(_ id: String, status: @escaping @Sendable (String) -> Void, poll: Duration = .seconds(2)) async throws -> [String] {
        try await server.splitDrums(id, status: status, poll: poll)
    }

    // Apaga a musica no servidor (falha se ainda estiver a ser processada) e os seus stems neste aparelho.
    public func delete(_ id: String) async throws {
        try await server.deleteJob(id)
        cache.evict(id)
    }

    // --- conta ---
    public var hasInvite: Bool { account.hasInvite }
    public var inviteFromEnv: Bool { account.inviteFromEnv }
    public func tryInvite(_ code: String) async -> ServerState { await account.tryInvite(code) }
    public func logout() -> Bool { account.logout() }

    // --- biblioteca ---
    public func list() async throws -> [Song] { try await library.list() }
    public func cached() -> [Song] { library.cached() }
    public func fixTempo(_ id: String, bpm: Int? = nil, downbeatOffset: Double? = nil) async throws -> Bool { try await library.fixTempo(id, bpm: bpm, downbeatOffset: downbeatOffset) }
    public func resetTempo(_ id: String) async throws -> (bpm: Int?, offset: Double) { try await library.resetTempo(id) }

    // --- stems no disco ---
    public func isCached(_ song: Song) -> Bool { cache.isCached(song) }
    public func evict(_ song: Song) { cache.evict(song.id) }
    // O ficheiro de um stem; se ainda nao esta no disco, descarrega-o primeiro.
    public func stemFile(_ id: String, _ name: String, _ format: StemFormat, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try await cache.file(id, name, format, progress: progress)
    }
}
