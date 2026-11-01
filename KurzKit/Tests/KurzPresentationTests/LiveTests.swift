import Foundation
import KurzAudio
import KurzCore
import KurzData
import Testing

// Contra o servidor a serio, so quando pedido (os outros testes nao saem da maquina):
//   KURZ_LIVE_INVITE=<convite> [KURZ_API=http://localhost:8000] swift test --filter Live
//   KURZ_LIVE_UPLOAD=1 junta o envio de uma musica de 4 s (gasta a GPU uns segundos); apaga-a no fim.
// Corre em pasta temporaria: nao mexe na biblioteca da app.
let invite = ProcessInfo.processInfo.environment["KURZ_LIVE_INVITE"]
let live = invite?.isEmpty == false

@MainActor @Suite("Live", .serialized) struct LiveTests {
    func service() -> (StemService, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kurz-live-" + UUID().uuidString)
        return (StemService(directory: dir, invite: invite), dir)
    }

    @Test(.enabled(if: live)) func readsLibraryAndPlaysAStem() async throws {
        let (s, dir) = service()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await s.status().state == .online)
        let songs = try await s.list()                                  // decodifica o JSON de verdade, incluindo jobs antigos sem `format`
        let song = try #require(songs.first { $0.isDone && !$0.stems.isEmpty }, "nenhuma musica separada na conta")
        let url = try await s.stemFile(song.id, song.stems[0], song.format)
        let pcm = try AudioFile.pcm(at: url)
        #expect(pcm.count > 44100 * 2, "\(song.title): \(url.lastPathComponent) tem \(pcm.count / 2) frames")
        #expect(pcm.contains { $0 != 0 })
    }

    @Test(.enabled(if: live && ProcessInfo.processInfo.environment["KURZ_LIVE_UPLOAD"] == "1")) func separatesAndDeletes() async throws {
        let (s, dir) = service()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = 44100, secs = 4
        let pcm = (0..<rate * secs).flatMap { i -> [Int16] in let v = Int16(8000 * sin(2 * .pi * 220 * Double(i) / Double(rate))); return [v, v] }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kurz-live-\(UUID().uuidString).wav")
        try Wav.encode(pcm).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let id = try await s.upload(file, name: "kurz-live-teste.wav", model: "htdemucs_6s", drums: false, hifi: false)   // Opus: o mais leve
        var done: Song?
        for _ in 0..<90 {                                               // ate 3 min
            done = try await s.list().first { $0.id == id }
            if done?.status == .done || done?.status == .error { break }
            try await Task.sleep(for: .seconds(2))
        }
        // apaga sempre, mesmo que as verificacoes falhem (um job a meio devolve 409: espera-se o fim acima)
        defer { Task { try? await s.delete(id) } }
        let song = try #require(done)
        #expect(song.status == .done)
        #expect(song.format == .opus)
        #expect(song.stems.count == 6)
        let url = try await s.stemFile(id, try #require(song.stems.first), .opus)
        #expect(try AudioFile.pcm(at: url).count > rate)
        try await s.delete(id)
        #expect(try await s.list().contains { $0.id == id } == false)
    }
}
