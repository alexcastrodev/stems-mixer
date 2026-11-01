import Observation

public enum DownloadState { case none, downloading, saved }

// O passo de uma musica nova ate estar pronta: 1/3 enviar, 2/3 separar (inclui a fila), 3/3 descarregar. none: pronta (ou sem nada a decorrer).
public enum Step { case none, upload, separate, fetch }

// Uma musica na lista, com o que so este aparelho sabe dela: se os stems estao guardados, se estao a descarregar (e quanto), se e a que esta aberta.
// Muda no sitio (@Observable): o progresso de uma descarga nao obriga a refazer a lista.
@Observable public final class SongRow: Identifiable {
    public let song: Song
    public var saved = false
    public var current = false
    public var offline = false           // sem servidor
    public var downloading = false
    public var progress = 0.0            // 0...1

    public init(_ song: Song) { self.song = song }

    public var id: String { song.id }
    public var state: DownloadState { downloading ? .downloading : saved ? .saved : .none }
    public var title: String { song.displayTitle }
    public var sub: String { song.isDone && saved ? "\(song.subtitle) · guardada" : song.subtitle }

    // Os passos (cada um com a sua cor e icone na vista): o 2.o leva a percentagem estimada do servidor, o 3.o a da descarga.
    public var step: Step { song.isUploading ? .upload : song.isActive ? .separate : downloading && song.isDone ? .fetch : .none }
    public var inStep: Bool { step != .none }
    public var stepText: String {
        switch step {
        case .upload: "1/3 · A enviar \(Int(progress * 100))%"
        case .separate: "2/3 · \(song.statusLabel)"
        case .fetch: "3/3 · A descarregar \(Int(progress * 100))%"
        case .none: ""
        }
    }
    // O texto da etiqueta da lista: o passo, ou o estado (Separada, Erro).
    public var label: String { inStep ? stepText : song.statusLabel }
    // Esmaecida: ainda nao separada, ou so no servidor quando ele nao esta (nao abre).
    public var opacity: Double { !song.isDone ? 0.65 : offline && !saved && !downloading ? 0.45 : 1 }
}
