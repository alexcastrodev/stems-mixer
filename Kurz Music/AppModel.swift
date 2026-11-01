import KurzCore
import KurzData
import KurzPresentation
import Observation
import SwiftUI

// Que ecra o iPhone mostra: a biblioteca ou o leitor (no Mac e no iPad os dois estao sempre a vista).
@MainActor @Observable final class Nav {
    var showingPlayer = false
}

// A composicao da app: cria os ViewModels e liga-os uns aos outros. As vistas so lhes pedem coisas.
@MainActor @Observable final class AppModel {
    let nav = Nav()
    let toast: ToastViewModel
    let library: LibraryViewModel
    let player: PlayerViewModel
    let account: AccountViewModel
    let importer: ImportViewModel
    var mix = WAVFile()
    var isExporting = false

    init() {
        let stems = StemService(), toast = ToastViewModel(), words = Platform.words, nav = nav
        let notify: (String) -> Void = { toast.show($0) }
        let library = LibraryViewModel(stems: stems, words: words, notify: notify)
        let player = PlayerViewModel(stems: stems, library: library, notify: notify, words: words)
        player.expandPartsAfterSplit = Platform.isPhone                    // no iPhone nao ha onde abrir as partes depois
        library.hooks = LibraryHooks(play: { await player.play($0) }, playerBusy: { player.isPlayingNow },
                                     showPlayer: { nav.showingPlayer = true }, closeOpenSong: { player.close(); nav.showingPlayer = false })
        self.toast = toast
        self.library = library
        self.player = player
        account = AccountViewModel(stems: stems, place: words.place, closeAccountOnRename: Platform.isPhone, refreshLibrary: { await library.refresh() },
                                   loggedOut: { player.close(); library.clear(); nav.showingPlayer = false }, notify: notify)
        importer = ImportViewModel(stems: stems, library: library, notify: notify, showLibrary: { nav.showingPlayer = false })
    }

    // Ao abrir: a biblioteca guardada aparece logo (offline first), e so depois se pergunta ao servidor.
    func start() async {
        library.loadCached()
        await library.refresh(quiet: true)
        await account.refreshStatus()
    }

    // Abre uma musica da lista; no iPhone passa ao leitor quando ela abre.
    func open(_ song: Song) {
        guard song.isDone else { toast.show("«\(song.displayTitle)» ainda não está separada."); return }
        Task { if await library.openOrFetch(song) { nav.showingPlayer = true } }
    }

    func exportMix() {
        mix = WAVFile(data: player.renderMix())
        isExporting = true
    }
}
