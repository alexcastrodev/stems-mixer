import Foundation
import KurzCore
import Observation

// O aviso curto no canto do ecra ("Convite aceite", "A descarregar…"). As mensagens que acabam em «…» (a trabalhar) ficam ate mudarem;
// as outras desaparecem sozinhas. Quem avisa chama `show`: os outros ViewModels recebem-no como o seu `notify`.
@MainActor @Observable public final class ToastViewModel {
    @ObservationIgnored var timer: Task<Void, Never>?
    public private(set) var text = ""
    public var isVisible: Bool { !text.isEmpty }

    // Quanto tempo fica uma mensagem que nao e de trabalho.
    public var lifetime: Duration = .seconds(6)

    public init() {}

    public func show(_ message: String?) {
        timer?.cancel()
        text = message ?? ""
        guard Notice.isTransient(text) else { return }
        timer = Task { [lifetime] in
            try? await Task.sleep(for: lifetime)
            if !Task.isCancelled { text = "" }                      // uma mensagem mais nova ja cancelou esta
        }
    }
}
