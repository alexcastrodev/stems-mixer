import Foundation

public struct Section: Equatable, Sendable {
    public var start: Double, end: Double, label: String
    public init(start: Double, end: Double, label: String) { (self.start, self.end, self.label) = (start, end, label) }
}

// Job do servidor. progress: estimativa (0...1) do job todo enquanto processa (o servidor mede o Demucs e estima o resto).
public struct Song: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var status: JobStatus
    public var stems: [String]
    public var created: Date?
    public var duration: Double?
    public var drumStems: [String]?
    public var bpm: Int?
    public var artist: String?
    public var downbeatOffset: Double?
    public var sections: [Section]?
    public var analyzed = false
    public var beats: [Double]?
    public var downbeats: [Double]?
    public var bpmAuto: Int?
    public var format: StemFormat = .wav
    public var progress: Double?

    public init(id: String, title: String, status: JobStatus, stems: [String], created: Date? = nil, duration: Double? = nil, drumStems: [String]? = nil,
                bpm: Int? = nil, artist: String? = nil, downbeatOffset: Double? = nil, sections: [Section]? = nil, analyzed: Bool = false,
                beats: [Double]? = nil, downbeats: [Double]? = nil, bpmAuto: Int? = nil, format: StemFormat = .wav, progress: Double? = nil) {
        (self.id, self.title, self.status, self.stems, self.created, self.duration, self.drumStems, self.bpm, self.artist) = (id, title, status, stems, created, duration, drumStems, bpm, artist)
        (self.downbeatOffset, self.sections, self.analyzed, self.beats, self.downbeats, self.bpmAuto, self.format, self.progress) = (downbeatOffset, sections, analyzed, beats, downbeats, bpmAuto, format, progress)
    }

    public var drums: [String] { drumStems ?? [] }
    public var isDone: Bool { status == .done }
    // Hi-Fi: os stems nao perderam nada (WAV ou FLAC). Opus e a versao otimizada, mais leve.
    public var hiFi: Bool { format != .opus }
    public var isActive: Bool { status == .queued || status == .processing }
    // uploading so existe neste aparelho: a musica que se esta a enviar ainda nao esta no servidor.
    public var isUploading: Bool { status == .uploading }
    public var isBusy: Bool { isActive || isUploading }      // nao se abre, exporta nem apaga
    public var isError: Bool { status == .error }
    public static func uploading(_ name: String, hifi: Bool) -> Song {
        Song(id: "up:" + name, title: name, status: .uploading, stems: [], created: Date(), format: hifi ? .flac : .opus)
    }
    public var hasBeats: Bool { !(beats ?? []).isEmpty }

    // Oitava das batidas reais que o tempo guardado pede: 0 = as da analise, +1 = o dobro, -1 = a metade (o BPM guardado e o detetado
    // vezes 2^k). nil = um BPM corrigido a mao: o clique passa a uma grelha fixa.
    public var beatLevel: Int? {
        guard hasBeats, let b = bpm, let a = bpmAuto else { return nil }
        return [0, 1, -1, 2, -2].first { abs(Double(b) - Double(a) * pow(2, Double($0))) <= 0.5 }
    }
    public var followsBeats: Bool { beatLevel != nil }

    // Titulo sem a extensao do arquivo (so se for de audio: "Mr. Brightside" fica como esta).
    public var displayTitle: String { Import.isAudio(title) ? (title as NSString).deletingPathExtension : title }
    // Um texto como nome de ficheiro: sem / nem : nem os caracteres que o sistema de ficheiros recusa.
    public static func safeFileName(_ name: String) -> String { String(name.map { "/:\\?*\"<>|".contains($0) ? "_" : $0 }) }
    public var subtitle: String {
        if let a = artist, !a.trimmingCharacters(in: .whitespaces).isEmpty { return a }
        return stems.isEmpty ? "" : "\(stems.count) stems"
    }
    public var statusLabel: String {
        switch status {
        case .done: "Separada"
        case .uploading: "A enviar"
        case .processing: progress.map { "A separar \(Int($0 * 100))%" } ?? "A separar"
        case .queued: "Na fila"
        case .error: "Erro"
        }
    }
    // Sempre inteiro na tabela. Com batidas reais e o tempo da analise, arredonda o das batidas (ex. 122,4 -> 122), como o player; senao, o guardado.
    public var bpmText: String {
        guard let b = bpm else { return "" }
        guard let level = beatLevel, let beats else { return String(b) }
        return String(Int(BeatMap.fromBeats(beats, downbeats: downbeats ?? [], offset: downbeatOffset ?? 0, level: level).bpm.rounded()))
    }
    public var length: String { duration.map { "\(Int($0) / 60):" + String(format: "%02d", Int($0) % 60) } ?? "" }

    static let pt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt-PT"); f.dateFormat = "d MMM yyyy"; return f }()
    public var date: String { created.map { Self.pt.string(from: $0) } ?? "" }
    public func ago(now: Date = Date()) -> String {
        guard let c = created else { return "" }
        let d = now.timeIntervalSince(c), hours = d / 3600, days = d / 86400
        return d < 3600 ? "agora" : hours < 24 ? "há \(Int(hours)) h" : days < 2 ? "ontem" : days < 60 ? "há \(Int(days)) dias" : "há \(Int(days / 30)) meses"
    }
}
