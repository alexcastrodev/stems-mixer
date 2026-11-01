import Foundation
import KurzCore

// Um job como o GET /jobs do servidor o escreve (server/app.py): o unico sitio que conhece os nomes dos campos no JSON.
// Campos em falta ficam nil (servidores antigos nao enviam todos); so o id, o estado e os stems sao obrigatorios.
struct JobDTO: Decodable {
    struct SectionDTO: Decodable { let start: Double, end: Double; let label: String? }
    let id: String, status: String, stems: [String]
    let name: String?, created: Double?, duration: Double?, drumStems: [String]?, bpm: Int?, artist: String?, downbeatOffset: Double?
    let sections: [SectionDTO]?, analyzed: Bool?, beats: [Double]?, downbeats: [Double]?, bpmAuto: Int?, format: String?, progress: Double?

    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }()
    static func list(_ data: Data) throws -> [JobDTO] { try decoder.decode([JobDTO].self, from: data) }

    func toSong() -> Song {
        Song(id: id, title: name ?? "",
             status: ["done": .done, "queued": .queued, "processing": .processing][status] ?? .error,
             stems: stems, created: created.map { Date(timeIntervalSince1970: $0.rounded(.down)) }, duration: duration, drumStems: drumStems, bpm: bpm,
             artist: artist, downbeatOffset: downbeatOffset, sections: sections?.map { Section(start: $0.start, end: $0.end, label: $0.label ?? "") },
             analyzed: analyzed ?? false, beats: beats, downbeats: downbeats, bpmAuto: bpmAuto, format: StemFormat(rawValue: format ?? "") ?? .wav, progress: progress)
    }
}
