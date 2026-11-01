import Foundation
import KurzData
import Observation

// A conta e o servidor: o estado que o selo mostra, o convite, o nome e o sair. A logica e a mesma em todas as plataformas;
// cada vista so desenha o selo (a partir de `status`) e os paineis, que se ligam a isto.
@MainActor @Observable public final class AccountViewModel {
    let stems: StemService
    let refreshLibrary: () async -> Void
    let loggedOut: () -> Void
    let notify: (String) -> Void
    @ObservationIgnored var checking = false
    @ObservationIgnored var inviteAsked = false
    @ObservationIgnored var nameFilled = false
    @ObservationIgnored var epoch = 0   // sobe ao trocar de convite ou de nome: uma resposta de estado que ainda vinha a caminho com o estado anterior e descartada

    public init(stems: StemService, place: String = "computador", closeAccountOnRename: Bool = false, refreshLibrary: @escaping () async -> Void, loggedOut: @escaping () -> Void, notify: @escaping (String) -> Void) {
        (self.stems, self.place, self.closeAccountOnRename, self.refreshLibrary, self.loggedOut, self.notify) = (stems, place, closeAccountOnRename, refreshLibrary, loggedOut, notify)
    }

    // No telemovel o painel da conta fecha ao gravar o nome; no desktop fica aberto.
    let closeAccountOnRename: Bool
    // Onde ficam os stems guardados, para a dica do selo ("Mac", "iPhone").
    let place: String

    // --- servidor ---
    // O ultimo estado conhecido (nil: ainda se nao sabe).
    public private(set) var status: ServerStatus?
    public var hasInvite: Bool { stems.hasInvite }

    // Consultado a cada tick; um pedido de cada vez (o servidor pode demorar a responder).
    public func refreshStatus() async {
        if checking { return }
        checking = true
        let mine = epoch
        defer { checking = false }
        let s = await stems.status()
        if mine == epoch { show(s) }
    }

    func show(_ s: ServerStatus) {
        status = s
        syncName()
        if s.state == .unauthorized && !inviteAsked { askInvite() }
    }

    // --- o selo do servidor ---
    public var isOnline: Bool { status?.state == .online }
    public var isBad: Bool { status?.state == .unauthorized || status?.state == .error }
    // O nome de um simbolo SF.
    public var badgeIcon: String {
        switch status?.state {
        case nil: "icloud"
        case .online: "checkmark.icloud"
        case .busy: "arrow.triangle.2.circlepath.icloud"
        case .offline: "icloud.slash"
        default: "exclamationmark.icloud"
        }
    }
    public var badgeText: String {
        guard let s = status else { return "Servidor" }
        switch s.state {
        case .online: return (["Servidor", s.name, s.device, s.active > 0 ? "\(s.active) em curso" : nil].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " · ")
        case .busy: return "Sem resposta"
        case .offline: return "Offline"
        case .unauthorized: return stems.hasInvite ? "Convite recusado — toque para colocar outro" : "Sem convite — toque para colocar"
        default: return "Erro no servidor"
        }
    }
    public var badgeShortText: String {
        guard let s = status else { return "Servidor" }
        switch s.state {
        case .online: return s.name ?? "Online"
        case .unauthorized: return stems.hasInvite ? "Convite recusado" : "Sem convite"
        default: return badgeText                                  // Sem resposta, Offline, Erro no servidor: ja sao curtos
        }
    }
    public var badgeTip: String {
        guard let s = status else { return "A verificar o servidor…" }
        switch s.state {
        case .online: return "Servidor ligado\(s.name.map { " como «\($0)»" } ?? ""). A separar em: \(s.device ?? "?"). Separações na fila ou em curso: \(s.active)."
        case .busy: return "O servidor não respondeu em 5 s. Costuma estar ocupado a enviar ficheiros; tente daqui a pouco."
        case .offline: return "Sem servidor: a mostrar a biblioteca guardada. Só tocam as músicas já abertas neste \(place)."
        case .unauthorized: return stems.hasInvite ? "O servidor não aceitou o convite. Toque aqui para colocar outro." : "Ainda não entrou com um convite. Toque aqui para o colocar."
        case .error: return "O servidor respondeu, mas não com o estado esperado (versão antiga, sem /status?)."
        }
    }

    // O estado em palavras, para o painel da conta.
    public var statusText: String {
        guard let s = status else { return "A verificar o servidor…" }
        switch s.state {
        case .online: return "Online\(s.name.map { " como «\($0)»" } ?? "")\nA separar em: \(s.device ?? "?")\nSeparações na fila ou em curso: \(s.active)"
        case .busy: return "O servidor não respondeu em 5 s.\nCostuma estar ocupado a enviar ficheiros (stems); tente daqui a pouco."
        case .offline: return "Sem ligação ao servidor.\nA mostrar a biblioteca guardada."
        case .unauthorized: return "O servidor não aceitou o convite."
        case .error: return "O servidor respondeu, mas não como esperado (versão antiga?)."
        }
    }

    // Tocar no selo: com um convite aceite mostra o estado e a conta (com o Sair); sem convite, ou recusado, abre o painel do convite.
    public func openBadge() {
        if stems.hasInvite && status?.state != .unauthorized { openAccount() } else { askInvite() }
    }

    // --- convite ---
    public var isInviteOpen = false
    public var inviteCode = ""
    public var inviteError: String?

    // O painel abre sozinho uma vez (sem convite, ou recusado); depois so pelo selo do servidor.
    public func askInvite() {
        inviteAsked = true
        inviteCode = ""
        inviteError = nil
        isAccountOpen = false
        isInviteOpen = true
    }

    public func cancelInvite() { isInviteOpen = false }

    // Colar o convite da area de transferencia (a vista le-a). Um convite colado traz muitas vezes um espaco ou uma mudanca de linha no fim.
    public func pasteInvite(_ clipboard: String?) {
        let code = clipboard?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        inviteError = code.isEmpty ? "Não há nada para colar: copie primeiro o convite." : nil
        if !code.isEmpty { inviteCode = code }
    }

    public func submitInvite() async {
        let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.isEmpty { return }
        let state = await stems.tryInvite(code)
        guard state == .online else {
            inviteError = switch state {
            case .unauthorized: "Convite inválido."
            case .busy: "O servidor não respondeu a tempo. Tente outra vez daqui a pouco."
            case .offline: "Sem ligação ao servidor. Verifique a rede e tente outra vez."
            default: "O servidor respondeu, mas não como esperado (versão antiga?)."
            }
            return
        }
        isInviteOpen = false
        inviteCode = ""                           // o codigo nao fica no campo
        await refreshLibrary()                    // a biblioteca e a da conta nova
        epoch += 1; checking = false              // um pedido de estado ainda da conta anterior fica descartado
        await refreshStatus()                     // e o selo mostra o nome da conta nova
        notify("Convite aceite")
    }

    // --- conta ---
    public var isAccountOpen = false
    public var nameDraft = ""
    public var nameError: String?

    // A linha do nome so existe com o servidor ligado e a dizer o nome da conta.
    public var canEditName: Bool { status?.state == .online && status?.name != nil }

    // Preenche-se ao aparecer, nunca por cima do que se escreve.
    func syncName() {
        guard canEditName else { nameFilled = false; return }
        if nameFilled { return }
        nameDraft = status!.name!
        nameError = nil
        nameFilled = true
    }

    func openAccount() {
        nameFilled = false                        // volta a preencher-se com o nome de agora
        syncName()
        isAccountOpen = true
    }

    public func closeAccount() { isAccountOpen = false }

    public func saveName() async {
        nameError = nil
        do {
            let saved = try await stems.rename(nameDraft)
            nameDraft = saved
            epoch += 1                            // uma resposta de estado ainda com o nome antigo nao pode repo-lo
            if var st = status { st.name = saved; show(st) }
            if closeAccountOnRename { isAccountOpen = false }
            notify("Nome guardado")
        } catch { nameError = StemService.nameError(error) }
    }

    // O convite vem de fora (KURZ_INVITE): nao se pode esquecer daqui.
    public var canLogout: Bool { !stems.inviteFromEnv }
    public var logoutHint: String { canLogout ? "Guarde o seu convite: ao sair terá de o colar de novo." : "O convite vem da variável KURZ_INVITE." }

    // Sair, sem confirmar: esquece o convite neste aparelho (o servidor nao o revoga) e o que era da conta; volta a pedir um convite.
    public func logout() {
        guard stems.logout() else { return }
        loggedOut()                               // a vista para o som, volta a biblioteca e esvazia a lista
        epoch += 1; checking = false              // um pedido de estado ainda da conta anterior fica descartado
        isAccountOpen = false
        show(ServerStatus(.unauthorized))         // o selo passa logo a "Sem convite"
        askInvite()
    }
}
