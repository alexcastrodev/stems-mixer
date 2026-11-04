import Foundation
import KurzAudio
import KurzCore
import KurzData

// Abre uma musica: traz os stems (do disco, ou do servidor se ainda la nao estao), descodifica-os e devolve uma Track por stem.
@MainActor public struct SongLoader {
    let stems: StemService
    public init(_ stems: StemService) { self.stems = stems }

    // Devolve as faixas de topo, por essa ordem; as partes da bateria ficam em Track.parts.
    // `progress`: 0...1 do conjunto (uma barra para os stems todos); os 10% finais de cada stem sao o descodificar.
    // `format`: como o servidor guardou os stems (Song.format). A descodificacao corre fora da thread da interface.
    public func load(id: String, stems names: [String], drums: [String], status: (String) -> Void, progress: ((Double) -> Void)? = nil, format: StemFormat = .wav) async throws -> [Track] {
        status("Carregando stems…")
        let names = StemCatalog.sorted(names, saved: stems.stemOrder)   // a ordem do utilizador; o resto, por omissao (estavel: fica na ordem do servidor)
        let all = names + drums
        var done = [Double](repeating: 0, count: all.count)                    // o que ja se leu de cada stem
        func report(_ i: Int, _ f: Double) { done[i] = max(done[i], f); progress?(done.reduce(0, +) / Double(done.count)) }

        func get(_ i: Int, parent: Track?) async throws -> Track {
            let name = all[i]
            let url = try await stems.stemFile(id, name, format) { f in Task { @MainActor in report(i, f * 0.9) } }
            let (pcm, peaks) = try await Task.detached { let p = try AudioFile.pcm(at: url); return (p, Wav.peaks(p, buckets: 1200)) }.value
            report(i, 1)
            return Track(name: StemCatalog.displayName(name), color: StemCatalog.color(name), pcm: pcm, peaks: peaks, parent: parent, isDrums: name == "drums")
        }
        // Os stems todos ao mesmo tempo (o servidor limita as ligacoes a 3): `get` corre na thread principal, so o descodificar sai dela.
        let tracks = try await withThrowingTaskGroup(of: (Int, Track).self) { group in
            for i in names.indices { group.addTask { @MainActor in (i, try await get(i, parent: nil)) } }
            return try await group.reduce(into: [(Int, Track)]()) { $0.append($1) }.sorted { $0.0 < $1.0 }.map(\.1)
        }
        if let d = tracks.first(where: \.isDrums), !drums.isEmpty {
            d.parts = try await withThrowingTaskGroup(of: (Int, Track).self) { group in
                for i in names.count..<all.count { group.addTask { @MainActor in (i, try await get(i, parent: d)) } }
                return try await group.reduce(into: [(Int, Track)]()) { $0.append($1) }.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }
        return tracks
    }
}
