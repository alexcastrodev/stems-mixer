import Foundation
import KurzCore
import KurzData
import Observation

// Um ficheiro escolhido para importar: o nome (que o servidor guarda) e um ficheiro que se pode ler ate ao fim do envio (cada plataforma sabe como o obtem).
public struct PickedFile: Equatable, Identifiable, Sendable {
    public var name: String, url: URL
    public var id: String { name }
    public init(name: String, url: URL) { (self.name, self.url) = (name, url) }
}

// O painel de importar: os ficheiros escolhidos a espera de se dizer como separar, as opcoes (modo, bateria, Hi-Fi) e o envio, que a biblioteca faz.
// As vistas so escolhem os ficheiros (cada plataforma tem o seu seletor) e entregam-nos aqui.
@MainActor @Observable public final class ImportViewModel {
    public static let fast = "htdemucs", quality = "htdemucs_ft", full = "htdemucs_6s"
    let stems: StemService
    let library: LibraryViewModel
    let notify: (String) -> Void
    let showLibrary: () -> Void

    public init(stems: StemService, library: LibraryViewModel, notify: @escaping (String) -> Void, showLibrary: @escaping () -> Void) {
        (self.stems, self.library, self.notify, self.showLibrary) = (stems, library, notify, showLibrary)
    }

    public var isOpen = false
    public private(set) var pending: [PickedFile] = []
    public private(set) var hint = "Escolha pelo menos uma música."
    public private(set) var startText = "Separar"

    // --- como separar ---
    public var model = ImportViewModel.full
    public var drums = false           // dividir a bateria (demora mais)
    public var hiFi = true             // stems sem perdas (FLAC); desligado, otimizados (Opus)

    public var canStart: Bool { !pending.isEmpty }

    public func open() { isOpen = true; show() }

    // Largar em qualquer parte da janela abre o painel e junta os ficheiros.
    public func add(_ files: [PickedFile]) {
        var names = pending.map(\.name), added: [PickedFile] = [], skipped = 0
        for f in files {
            let before = names.count
            skipped += Import.add(&names, [f.name])                                    // so audio e so o que ainda nao esta na lista
            if names.count > before { added.append(f) }
        }
        pending += added
        show(skipped > 0 ? "\(skipped) ignorado(s): não é áudio ou já estava na lista." : nil)
    }

    public func remove(_ file: PickedFile) { pending.removeAll { $0 == file }; show() }

    public func close() { isOpen = false; pending = []; show() }

    func show(_ note: String? = nil) {
        startText = pending.count > 1 ? "Separar \(pending.count) músicas" : "Separar"
        hint = note ?? (pending.isEmpty ? "Escolha pelo menos uma música." : "As músicas ficam na fila; pode continuar a usar a app.")
    }

    // Envia cada musica (so envia: o progresso ve-se na biblioteca) e fecha o painel logo.
    public func start() async {
        guard canStart else { return }
        guard stems.online else { notify("Sem servidor: importar precisa de ligação."); return }   // os ficheiros ficam para tentar outra vez
        let list = pending
        isOpen = false
        pending = []
        show()
        showLibrary()
        await library.upload(list, model: model, drums: drums, hifi: hiFi)
    }
}
