import Foundation

// Quem esta a usar a app: o convite (invite code) que o servidor reconhece. Guarda-se em invite.txt (so legivel pelo dono) e vive no header dos pedidos.
final class Account {
    let server: ServerAPI
    let library: LibraryStore
    let file: URL

    // Convite: o parametro ou KURZ_INVITE vencem o que a app guardou em invite.txt quando o utilizador o colou.
    init(server: ServerAPI, library: LibraryStore, dir: URL, invite: String?, env: String? = ProcessInfo.processInfo.environment["KURZ_INVITE"]) {
        (self.server, self.library) = (server, library)
        file = dir.appendingPathComponent("invite.txt")
        let given = [invite, env].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        inviteFromEnv = given != nil
        server.invite = given ?? Self.read(file)
    }

    var hasInvite: Bool { server.invite != nil }
    // O convite vem de fora (KURZ_INVITE ou o parametro): nao se pode esquecer daqui, voltava no arranque.
    let inviteFromEnv: Bool

    // Experimenta um convite colado pelo utilizador: so fica em uso (e em arquivo) se o servidor o aceitar; senao volta ao anterior.
    // Trocar de conta apaga o que era da anterior (biblioteca guardada e correcoes em fila). Devolve o estado do servidor.
    func tryInvite(_ code: String) async -> ServerState {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.isEmpty || code.unicodeScalars.contains(where: { $0.value < 33 || $0.value > 126 }) { return .unauthorized }   // um convite e ASCII sem espacos
        let before = server.invite
        server.invite = code
        let state = await server.status().state
        if state != .online { server.invite = before; return state }
        if code != before { library.forget() }
        try? Disk.saveSecret(file, code)
        return state
    }

    // Sair: esquece o convite neste aparelho (nao o revoga: o servidor nao tem revogacao) e o que era da conta; os stems descarregados
    // ficam em disco. Com o convite vindo de fora nao faz nada e devolve false.
    func logout() -> Bool {
        if inviteFromEnv { return false }
        server.invite = nil
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: file.appendingPathExtension("part"))
        library.forget()
        return true
    }

    static func read(_ file: URL) -> String? {
        guard let t = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
