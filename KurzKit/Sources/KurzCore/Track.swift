import Observation

// Uma faixa (stem) aberta: o PCM, as ondas e o que o utilizador mexe (volume, mute, solo). O mixer le o volume, o mute e o solo a cada bloco.
@Observable public final class Track: @unchecked Sendable {
    public let name: String
    public let color: String
    public let isDrums: Bool
    @ObservationIgnored public let peaks: [Float]?
    @ObservationIgnored public let pcm: [Int16]?
    // Bateria dividida: o pai fica so como cabecalho (a onda e o export); o som vem das partes.
    @ObservationIgnored public weak var parent: Track?
    public var parts: [Track] = []
    public var volume = 1.0
    public var muted = false
    public var solo = false
    public var expanded = false
    // Cor de fundo da faixa na tela de stems (degrade azul -> verde-agua pela ordem).
    public var lane = "#3ba4ff"
    // Posicao de reproducao, 0...1 (so para a UI pintar a parte ja tocada).
    public var progress = 0.0
    // Opacidade da onda: 0.25 se esta fora do que se ouve (mute, ou solo noutro stem).
    public var dim = 1.0

    public init(name: String, color: String = "#4aa6a8", pcm: [Int16]? = nil, peaks: [Float]? = nil, parent: Track? = nil, isDrums: Bool = false) {
        (self.name, self.color, self.pcm, self.peaks, self.parent, self.isDrums) = (name, color, pcm, peaks, parent, isDrums)
    }

    public var isPart: Bool { parent != nil }
    public var hasParts: Bool { !parts.isEmpty }
    // Faixa da bateria ainda inteira: oferece "Dividir" (musicas ja processadas).
    public var canSplit: Bool { isDrums && parent == nil && parts.isEmpty }
    // Configuracao inicial do mixer: volume 100%, sem mute nem solo.
    public func reset() { volume = 1; muted = false; solo = false }

    public func audible(anySolo: Bool) -> Bool {
        // Solo da bateria vale para as partes, salvo se alguma parte tem solo proprio: ai so essas se ouvem.
        let m = muted || (parent?.muted ?? false)
        let s = solo || (parent.map { $0.solo && !$0.parts.contains { $0.solo } } ?? false)
        return !m && (!anySolo || s)
    }
    public func refresh(anySolo: Bool) { dim = audible(anySolo: anySolo) ? 1 : 0.25 }
}
