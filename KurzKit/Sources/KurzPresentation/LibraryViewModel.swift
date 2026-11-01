import Foundation
import KurzCore
import KurzData
import Observation

// As palavras que mudam de aparelho nas mensagens: onde ficam os stems guardados ("Mac", "iPhone") e como se toca numa musica ("clique", "toque").
public struct DeviceWords: Sendable {
    public var place: String, tap: String
    public init(place: String, tap: String) { (self.place, self.tap) = (place, tap) }
}

// O que a biblioteca pede a vista (que e dona do leitor): abrir a musica a tocar (true se abriu), saber se o leitor esta ocupado, mostrar o leitor e fechar a musica aberta.
public struct LibraryHooks {
    public var play: (Song) async -> Bool
    public var playerBusy: () -> Bool
    public var showPlayer: () -> Void
    public var closeOpenSong: () -> Void
    public init(play: @escaping (Song) async -> Bool, playerBusy: @escaping () -> Bool, showPlayer: @escaping () -> Void, closeOpenSong: @escaping () -> Void) {
        (self.play, self.playerBusy, self.showPlayer, self.closeOpenSong) = (play, playerBusy, showPlayer, closeOpenSong)
    }
}

public enum LibrarySort { case server, newestFirst, oldestFirst, title }

// A biblioteca de musicas: a lista (da rede ou do disco), o filtro e a ordem, o estado de cada linha (guardada, a descarregar, a enviar), as descargas em
// segundo plano, abrir ou descarregar, enviar e apagar. A logica e a mesma em todas as plataformas; cada vista desenha as linhas e e dona do leitor.
@MainActor @Observable public final class LibraryViewModel {
    let stems: StemService
    let downloads: Downloads
    let words: DeviceWords
    let notify: (String) -> Void
    @ObservationIgnored public var hooks: LibraryHooks!                          // a biblioteca e o leitor precisam um do outro: quem os junta liga-os depois de os criar
    @ObservationIgnored var uploading: [Song] = []                               // as musicas que se estao a enviar: ainda nao estao no servidor, mas ja aparecem na lista (passo 1/3)
    @ObservationIgnored var uploadProgress: [String: Double] = [:]               // quanto ja foi enviado de cada uma (0...1), para a percentagem do passo 1/3
    @ObservationIgnored var openWhenReady: String?           // a musica que se tocou mas ainda descarrega: abre quando acabar, se nao se abriu outra entretanto
    @ObservationIgnored var openAtTap: String?
    @ObservationIgnored var forceOpen = false                                    // ... mesmo com outra a tocar (anterior/seguinte)

    public init(stems: StemService, words: DeviceWords, notify: @escaping (String) -> Void) {
        (self.stems, self.words, self.notify) = (stems, words, notify)
        downloads = Downloads(stems)
        downloads.onChanged = { [unowned self] in onDownloads() }
        downloads.onCompleted = { [unowned self] song in Task { await onDownloaded(song) } }
        downloads.onFailed = { [unowned self] song, e in onDownloadFailed(song, e) }
    }

    // Avisa a cada passo das descargas (e quando acabam): a vista pode manter a app viva com isto.
    public var onDownloadsChanged: (() -> Void)?
    public var downloadNow: (title: String, progress: Double)? { downloads.busy ? downloads.now : nil }

    // --- a lista ---
    public private(set) var songs: [Song] = []              // o que o servidor (ou o disco) deu
    public private(set) var shown: [Song] = []              // o que a lista mostra (filtrado e ordenado): de onde vem o anterior e o seguinte
    public private(set) var rows: [SongRow] = []            // as linhas: o progresso das descargas muda-lhes o estado no sitio
    public private(set) var recent: [SongRow] = []          // as primeiras, para a faixa dos recentes
    public var search = "" { didSet { applyFilter() } }
    public var sort = LibrarySort.server { didSet { applyFilter() } }
    public private(set) var countText = ""
    public private(set) var sortText = ""
    public var openId: String? { didSet { applyFilter() } }  // a musica aberta no leitor: a sua linha fica marcada

    public func cycleSort() {
        sort = switch sort { case .newestFirst: .oldestFirst; case .oldestFirst: .title; default: .newestFirst }
    }

    // Offline first: a biblioteca guardada aparece logo, sem esperar pela rede.
    public func loadCached() { songs = stems.cached(); applyFilter() }

    // Esvazia a lista (ao sair da conta).
    public func clear() { songs = []; shown = []; applyFilter() }

    public func refresh(quiet: Bool = false) async {
        let was = stems.online, before = songs
        do { songs = try await stems.list() }
        catch {
            if !quiet && (error as? ServerError)?.isUnauthorized != true { notify("Servidor indisponível: " + error.localizedDescription) }   // convite recusado: o selo e o painel tratam disso
            return
        }
        if !was && stems.online { notify("De volta online") }   // offline: a biblioteca vem do disco
        if stems.online { for done in Downloads.finished(before: before, after: songs) { downloads.enqueue(done) } }   // a seguir a separar, descarrega (passo 3/3): ao tocar ja la esta
        applyFilter()
    }

    // O que se faz a cada 3 s: o estado do servidor e, se ha separacoes em curso, a lista.
    public func poll(_ account: AccountViewModel) async {
        await account.refreshStatus()
        if !stems.online { await refresh(quiet: true) }       // sem servidor, tenta voltar sem barulho
        else if songs.contains(where: \.isActive) || (account.status?.active ?? 0) > 0 { await refresh() }
    }

    public func applyFilter() {
        let q = search.trimmingCharacters(in: .whitespaces)
        let found = (uploading + songs).filter { q.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(q) }
        shown = switch sort {
        case .newestFirst: found.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        case .oldestFirst: found.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
        case .title: found.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        case .server: found
        }
        let made = shown.map { s -> SongRow in
            let r = SongRow(s)
            r.saved = s.isDone && stems.isCached(s)
            r.current = s.id == openId
            r.offline = !stems.online
            r.downloading = downloads.has(s.id)
            r.progress = s.isUploading ? uploadProgress[s.id] ?? 0 : downloads.progress(s.id)
            return r
        }
        // So se refaz a lista se algo que se ve mudou: reconstrui-la fecha o menu aberto e faz saltar o scroll (e a lista refaz-se a cada 3 s com separacoes em curso).
        // Compara-se com as linhas de agora (que as descargas mudam no sitio), nao com um resumo guardado: esse ficava desatualizado.
        func key(_ rows: [SongRow]) -> String {
            rows.map { r in "\(r.song.id)/\(r.title)/\(r.song.subtitle)/\(r.state)/\(r.step)/\(r.song.statusLabel)/\(r.song.length)/\(r.song.bpmText)/\(r.song.stems.count)/\(r.song.drums.count)/\(r.current)/\(r.opacity)" }.joined(separator: "|")
        }
        if key(made) != key(rows) { rows = made; recent = Array(made.prefix(8)) }
        countText = "Todas (\(shown.count))"
        sortText = switch sort { case .newestFirst: "Data ↓"; case .oldestFirst: "Data ↑"; case .title: "Título A–Z"; case .server: "" }
    }

    // --- abrir ---
    // Abre a musica; se os stems nao estao neste aparelho, poe-nos a descarregar em segundo plano e abre quando acabar, sem prender a app.
    // `force`: abre mesmo com outra a tocar (anterior/seguinte). false enquanto descarrega.
    public func openOrFetch(_ song: Song, force: Bool = false) async -> Bool {
        if stems.isCached(song) { return await hooks.play(song) }
        guard stems.online else { notify("Sem servidor, e esta música ainda não foi guardada neste \(words.place)."); return false }
        (openWhenReady, openAtTap, forceOpen) = (song.id, openId, force)
        downloads.enqueue(song)
        notify("A descarregar «\(song.displayTitle)»: abre quando acabar")
        return false
    }

    // --- descargas em segundo plano ---
    // O progresso muda as linhas no sitio (nada de refazer a lista a cada passo).
    func onDownloads() {
        for r in rows {
            let on = downloads.has(r.song.id)
            r.downloading = on
            r.progress = on ? downloads.progress(r.song.id) : 0
            if !on { r.saved = r.song.isDone && stems.isCached(r.song) }
        }
        onDownloadsChanged?()
    }

    func onDownloaded(_ song: Song) async {
        notify("«\(song.displayTitle)» guardada")
        guard openWhenReady == song.id else { return }
        openWhenReady = nil
        // Abre-a se era o que se queria: nao se abriu outra entretanto e nao se interrompe o que toca nem o que se esta a ver.
        if openId != openAtTap || (!forceOpen && hooks.playerBusy()) { notify("«\(song.displayTitle)» pronta: \(words.tap) nela para abrir"); return }
        if await hooks.play(song) { hooks.showPlayer() }
    }

    func onDownloadFailed(_ song: Song, _ e: Error) {
        if openWhenReady == song.id { openWhenReady = nil }
        notify(isOffline(e) ? "Sem servidor: a descarga de «\(song.displayTitle)» ficou a meio e retoma ao tentar de novo." : "Erro ao descarregar «\(song.displayTitle)»: \(e.localizedDescription)")
    }

    // O botao da linha: guardar neste aparelho (so descarrega), cancelar a descarga, ou remover os stems do disco (ocupam centenas de MB; continuam no servidor).
    public func toggleDownload(_ row: SongRow) {
        switch row.state {
        case .downloading: cancelDownload(row.song)
        case .saved: removeDownload(row.song)
        case .none: saveOffline(row.song)
        }
    }

    public func cancelDownload(_ song: Song) {
        downloads.cancel(song.id)
        if openWhenReady == song.id { openWhenReady = nil }
        notify("Download cancelado")
    }

    public func removeDownload(_ song: Song) {
        stems.evict(song)
        applyFilter()
        notify("«\(song.displayTitle)» removida do \(words.place)")
    }

    public func saveOffline(_ song: Song) {
        guard stems.online else { notify("Sem servidor: guardar precisa de ligação."); return }
        downloads.enqueue(song)                               // o passo 3/3 ve-se na linha
    }

    // --- enviar ---
    // Envia cada musica (so envia: o progresso ve-se na biblioteca). Paramos na primeira que falha.
    public func upload(_ files: [PickedFile], model: String, drums: Bool, hifi: Bool) async {
        let ups = Dictionary(files.map { ($0.name, Song.uploading($0.name, hifi: hifi)) }, uniquingKeysWith: { a, _ in a })
        uploading += ups.values
        applyFilter()                                         // as musicas aparecem logo, no passo 1/3
        defer { uploading = []; applyFilter() }               // as que ficaram por enviar (erro) saem
        for f in files {
            let up = ups[f.name]!
            defer { uploading.removeAll { $0.id == up.id }; uploadProgress[up.id] = nil; applyFilter() }
            do {
                _ = try await stems.upload(f.url, name: f.name, model: model, drums: drums, hifi: hifi) { [weak self] p in
                    Task { @MainActor in
                        self?.uploadProgress[up.id] = p
                        for r in self?.rows ?? [] where r.song.id == up.id { r.progress = p }     // a linha muda no sitio
                    }
                }
                await refresh()                               // ja esta no servidor: passa ao passo 2/3
            } catch { notify("Erro ao enviar \(f.name): \(error.localizedDescription)"); return }
        }
    }

    // --- apagar ---
    public var isDeleteOpen = false
    public private(set) var deleteText = ""
    @ObservationIgnored var toDelete: Song?

    public func askDelete(_ song: Song) {
        guard stems.online else { notify("Sem servidor: apagar precisa de ligação."); return }
        toDelete = song
        deleteText = "«\(song.displayTitle)» e todos os seus stems vão ser apagados. Não se pode desfazer."
        isDeleteOpen = true
    }

    public func askDeleteOpen() {
        if let id = openId, let song = songs.first(where: { $0.id == id }) { askDelete(song) }
    }

    public func cancelDelete() { isDeleteOpen = false; toDelete = nil }

    public func confirmDelete() async {
        let song = toDelete
        isDeleteOpen = false
        toDelete = nil
        guard let song else { return }
        do {
            if song.id == openId { hooks.closeOpenSong() }     // a musica aberta: para o som e volta a biblioteca
            try await stems.delete(song.id)
            notify("«\(song.displayTitle)» apagada")
            await refresh()
        } catch { notify("Erro ao apagar: \(error.localizedDescription)"); await refresh() }
    }
}
