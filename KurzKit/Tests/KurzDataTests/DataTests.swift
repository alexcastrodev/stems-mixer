import Foundation
import KurzCore
import Testing
@testable import KurzData

@MainActor @Suite struct ContractTests {
    // O mesmo JSON de exemplo que o servidor tem de produzir (contract/jobs.sample.json): o cliente le-o por inteiro.
    @Test func theSharedSampleJobIsReadWholeIntoASong() throws {
        let data = try Data(contentsOf: Bundle.module.url(forResource: "Fixtures/jobs.sample.json", withExtension: nil)!)
        let s = try JobDTO.list(data)[0].toSong()
        #expect(s.id == "a1b2c3d4e5f6" && s.title == "Banda - Musica.mp3" && s.status == .done && s.stems == ["drums", "vocals"])
        #expect(s.drums == ["drum_kick", "drum_snare"] && s.created == Date(timeIntervalSince1970: 1_700_000_000) && s.duration == 222.5 && s.artist == "Banda")
        #expect(s.format == .flac && s.bpm == 122 && s.bpmAuto == 122 && s.downbeatOffset == 0.5 && s.analyzed && s.beats == [0.5, 1.0] && s.downbeats == [0.5])
        #expect(s.sections == [Section(start: 0, end: 10, label: "intro")] && s.progress == nil)
    }

    @Test func oldServersWithoutTheOptionalFieldsStillParse() throws {
        let s = try JobDTO.list(json("[{\"id\":\"1\",\"status\":\"weird\",\"stems\":[]}]"))[0].toSong()
        #expect(s.status == .error && s.title == "" && s.format == .wav && !s.analyzed)
        #expect(throws: (any Error).self) { try JobDTO.list(json("[{\"id\":\"1\"}]")) }          // so o id, o estado e os stems sao obrigatorios
    }
}

@MainActor @Suite struct ServerTests {
    @Test func statusMapsEveryOutcome() async {
        let f = Fake(), svc = f.service()
        f.serve { _, _ in (200, json("{\"device\":\"mps\",\"active\":2,\"name\":\"Ana\"}")) }
        #expect(await svc.status() == ServerStatus(.online, device: "mps", active: 2, name: "Ana"))
        f.serve { _, _ in (401, json("{}")) }
        #expect(await svc.status().state == .unauthorized)
        f.serve { _, _ in (200, json("{\"oops\":1}")) }
        #expect(await svc.status().state == .error)
        f.serve { _, _ in throw URLError(.timedOut) }
        #expect(await svc.status().state == .busy)
        f.down()
        #expect(await svc.status().state == .offline)
    }

    @Test func everyRequestCarriesTheInviteHeader() async throws {
        let f = Fake(), svc = f.service(invite: "abc")
        nonisolated(unsafe) var seen: [String?] = []
        f.serve { r, _ in seen.append(r.value(forHTTPHeaderField: "X-Invite-Code")); return (200, json("[]")) }
        _ = try await svc.list()
        _ = await svc.status()
        #expect(seen == ["abc", "abc"])
    }

    @Test func renameTrimsRefusesEmptyAndReportsTheServerMessage() async throws {
        let f = Fake(), svc = f.service()
        nonisolated(unsafe) var sent: Data?
        f.serve { _, b in sent = b; return (200, json("{\"name\":\"Ana\"}")) }
        let renamed = try await svc.rename("  Ana ")
        #expect(renamed == "Ana")
        #expect(String(decoding: sent!, as: UTF8.self) == "{\"name\":\"Ana\"}")
        await #expect(throws: ServerError.invalid("O nome não pode estar vazio.")) { try await svc.rename("  ") }
        f.serve { _, _ in (400, json("{\"error\":\"Nome longo demais\"}")) }
        do { _ = try await svc.rename("x") } catch { #expect(StemService.nameError(error) == "Nome longo demais") }
        f.serve { _, _ in (401, json("{}")) }
        do { _ = try await svc.rename("x") } catch { #expect(StemService.nameError(error) == "O servidor recusou o convite.") }
        f.down()
        do { _ = try await svc.rename("x") } catch { #expect(StemService.nameError(error) == "Sem ligação ao servidor. Tente outra vez.") }
    }

    @Test func uploadSendsTheFileAndOptionsAsMultipartAndReturnsTheId() async throws {
        let f = Fake(), svc = f.service()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("song-\(UUID()).mp3")
        try Data("AUDIO-BYTES".utf8).write(to: file)
        nonisolated(unsafe) var body = ""
        nonisolated(unsafe) var type = ""
        f.serve { r, b in body = String(decoding: b ?? Data(), as: UTF8.self); type = r.value(forHTTPHeaderField: "Content-Type") ?? ""; return (200, json("{\"id\":\"j1\"}")) }
        let id = try await svc.upload(file, name: "Banda - \"Musica\".mp3", model: "htdemucs_6s", drums: true, hifi: false)
        #expect(id == "j1" && type.hasPrefix("multipart/form-data; boundary="))
        for part in ["name=\"file\"; filename=\"Banda - %22Musica%22.mp3\"", "AUDIO-BYTES", "name=\"model\"\r\n\r\nhtdemucs_6s", "name=\"drums\"\r\n\r\n1", "name=\"hifi\"\r\n\r\n0"] { #expect(body.contains(part), "falta \(part)") }
    }

    @Test func splitDrumsPollsUntilTheServerIsDone() async throws {
        let f = Fake(), svc = f.service()
        nonisolated(unsafe) var polls = 0
        f.serve { r, _ in
            if r.httpMethod == "POST" { return (200, json("{}")) }
            polls += 1
            return (200, json(polls < 3 ? "{\"drums_running\":true}" : "{\"drums_running\":false,\"drum_stems\":[\"drum_kick\"]}"))
        }
        let parts = try await svc.splitDrums("j", status: { _ in }, poll: .milliseconds(1))
        #expect(parts == ["drum_kick"])
        f.serve { r, _ in r.httpMethod == "POST" ? (200, json("{}")) : (200, json("{\"drums_running\":false,\"drum_error\":\"sem GPU\"}")) }
        await #expect(throws: ServerError.invalid("sem GPU")) { try await svc.splitDrums("j", status: { _ in }, poll: .milliseconds(1)) }
    }
}

@MainActor @Suite struct AccountTests {
    @Test func aCorrectInviteIsKeptInAFileOnlyTheOwnerCanReadAndWinsNextLaunch() async throws {
        let f = Fake(), svc = f.service(), file = f.dir.appendingPathComponent("invite.txt")
        f.serve { _, _ in (200, json("{\"device\":\"cpu\",\"active\":0}")) }
        #expect(await svc.tryInvite("  code-1\n") == .online)
        let saved = try String(contentsOf: file, encoding: .utf8), mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(svc.hasInvite && saved == "code-1" && mode == 0o600)
        #expect(f.service().hasInvite)                                       // o arranque seguinte le-o do arquivo
    }

    @Test func aRefusedInviteGoesBackToThePreviousOne() async {
        let f = Fake()
        let svc = f.service(invite: nil)
        f.serve { r, _ in r.value(forHTTPHeaderField: "X-Invite-Code") == "good" ? (200, json("{\"device\":\"cpu\",\"active\":0}")) : (401, json("{}")) }
        #expect(await svc.tryInvite("good") == .online)
        #expect(await svc.tryInvite("bad") == .unauthorized)
        #expect(svc.hasInvite)
        let spaced = await svc.tryInvite("with space"), empty = await svc.tryInvite("")
        #expect(spaced == .unauthorized && empty == .unauthorized)
        f.serve { r, _ in r.value(forHTTPHeaderField: "X-Invite-Code") == "good" ? (200, json("[]")) : (401, json("{}")) }
        #expect((try? await svc.list()) != nil)                              // ainda o "good"
    }

    @Test func switchingAccountForgetsTheSavedLibraryAndLogoutForgetsTheInvite() async throws {
        let f = Fake(), svc = f.service()
        f.serve { r, _ in r.url!.path == "/status" ? (200, json("{\"device\":\"cpu\",\"active\":0}")) : (200, json("[\(job("a"))]")) }
        #expect(await svc.tryInvite("one") == .online)
        _ = try await svc.list()
        #expect(svc.cached().count == 1)
        #expect(await svc.tryInvite("one") == .online)
        #expect(svc.cached().count == 1)                                    // o mesmo convite: fica
        #expect(await svc.tryInvite("two") == .online)
        #expect(svc.cached().isEmpty)                                       // outra conta: sai
        _ = try await svc.list()
        #expect(svc.logout() && !svc.hasInvite && svc.cached().isEmpty && !FileManager.default.fileExists(atPath: f.dir.appendingPathComponent("invite.txt").path))
    }
}

@MainActor @Suite struct OfflineTests {
    @Test func theSavedLibraryAnswersWithoutTheServerAndWithoutOneItFails() async throws {
        let f = Fake(), svc = f.service()
        f.down()
        await #expect(throws: URLError.self) { try await svc.list() }
        #expect(svc.cached().isEmpty)
        f.serve { _, _ in (200, json("[\(job("a")),\(job("b"))]")) }
        let live = try await svc.list()
        #expect(live.count == 2 && svc.online)
        f.down()
        let saved = try await svc.list()
        #expect(saved.map(\.id) == ["a", "b"] && !svc.online)
        #expect(svc.cached().count == 2)
    }

    @Test func tempoFixesMadeOfflineShowAtOnceAndGoInOrderWhenTheServerReturns() async throws {
        let f = Fake(), svc = f.service()
        f.serve { _, _ in (200, json("[\(job("a", bpm: 100))]")) }
        _ = try await svc.list()
        f.down()
        let first = try await svc.fixTempo("a", bpm: 90, downbeatOffset: 1.5), second = try await svc.fixTempo("a", bpm: 80)
        #expect(!first && !second)
        let shown = try await svc.list()
        #expect(shown[0].bpm == 80 && svc.cached()[0].downbeatOffset == 1.5)   // a lista mostra as correcoes por cima
        nonisolated(unsafe) var patches: [String] = []
        f.serve { r, b in
            if r.httpMethod == "PATCH" { patches.append(String(decoding: b!, as: UTF8.self)); return (200, json("{}")) }
            return (200, json("[\(job("a", bpm: 80))]"))
        }
        _ = try await svc.list()
        #expect(patches == ["{\"bpm\":90,\"downbeat_offset\":1.5}", "{\"bpm\":80}"])
        let direct = try await svc.fixTempo("a", bpm: 70)
        #expect(direct)                                                     // fila vazia: vai logo
    }

    @Test func aFixTheServerRefusesIsDroppedButAnUnauthorizedOneStaysQueued() async throws {
        let f = Fake(), svc = f.service()
        f.down()
        _ = try await svc.fixTempo("gone", bpm: 90)
        f.serve { _, _ in (404, json("{}")) }
        await svc.library.sync()
        #expect(svc.library.pending.isEmpty)                                // apagada no servidor: nao vale a pena insistir
        f.down()
        _ = try await svc.fixTempo("a", bpm: 90)
        f.serve { _, _ in (401, json("{}")) }
        await svc.library.sync()
        #expect(svc.library.pending.count == 1)
    }

    @Test func resetTempoAsksTheServerForTheDetectedOne() async throws {
        let f = Fake(), svc = f.service()
        f.serve { _, b in (200, json(String(decoding: b!, as: UTF8.self) == "{\"reset\":true}" ? "{\"bpm\":122,\"downbeat_offset\":0.5}" : "{}")) }
        let r = try await svc.resetTempo("a")
        #expect(r.bpm == 122 && r.offset == 0.5)
    }
}

@MainActor @Suite struct StemTests {
    func song(_ stems: [String] = ["vocals", "drums"], drums: [String]? = nil, format: StemFormat = .wav) -> Song {
        Song(id: "j", title: "x", status: .done, stems: stems, drumStems: drums, format: format)
    }

    @Test func aStemIsDownloadedOnceThenServedFromDisk() async throws {
        let f = Fake(), svc = f.service()
        nonisolated(unsafe) var hits = 0
        f.serve { _, _ in hits += 1; return (200, Data("WAVDATA".utf8)) }
        let s = song(["vocals"])
        #expect(!svc.isCached(s))
        let url = try await svc.stemFile("j", "vocals", .wav)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "WAVDATA" && url.path.hasSuffix("stems/j/vocals.wav") && svc.isCached(s))
        _ = try await svc.stemFile("j", "vocals", .wav)
        #expect(hits == 1)
        svc.evict(s)
        #expect(!svc.isCached(s))
    }

    @Test func twoRequestsForTheSameStemShareOneDownload() async throws {
        let f = Fake(), svc = f.service()
        nonisolated(unsafe) var hits = 0
        f.serve { _, _ in hits += 1; Thread.sleep(forTimeInterval: 0.1); return (200, Data("X".utf8)) }
        async let a = svc.stemFile("j", "bass", .flac), b = svc.stemFile("j", "bass", .flac)
        let (x, y) = try await (a, b)
        #expect(x == y)
        #expect(hits == 1)
    }

    @Test func aFailedDownloadLeavesNothingHalfWrittenAndRetries() async throws {
        let f = Fake(), svc = f.service()
        f.serve { _, _ in (500, json("{}")) }
        await #expect(throws: ServerError.http(500, nil)) { try await svc.stemFile("j", "bass", .wav) }
        #expect(!svc.isCached(song(["bass"])))
        f.serve { _, _ in (200, Data("OK".utf8)) }
        _ = try await svc.stemFile("j", "bass", .wav)
        #expect(svc.isCached(song(["bass"])))
    }

    @Test func theDrumPartsCountForBeingCached() async throws {
        let f = Fake(), svc = f.service()
        f.serve { _, _ in (200, Data("OK".utf8)) }
        _ = try await svc.stemFile("j", "drums", .wav)
        #expect(!svc.isCached(song(["drums"], drums: ["drum_kick"])))
        _ = try await svc.stemFile("j", "drum_kick", .wav)
        #expect(svc.isCached(song(["drums"], drums: ["drum_kick"])))
        #expect(!svc.isCached(song([])))                                    // sem stems nao ha nada guardado
    }

    @Test func downloadsFetchEveryFileThenReportCompletedAndSkipWhatIsOnDisk() async throws {
        let f = Fake(), svc = f.service()
        nonisolated(unsafe) var paths: [String] = []
        f.serve { r, _ in paths.append(r.url!.path); return (200, Data("OK".utf8)) }
        let d = Downloads(svc), s = song(["a", "b", "c", "d"], drums: ["drum_kick"])
        var done: [String] = [], changed = 0, last = 0.0
        d.onCompleted = { done.append($0.id) }
        d.onChanged = { changed += 1; last = max(last, d.progress("j")) }
        d.enqueue(s)
        #expect(d.has("j") && d.busy && d.now?.title == "x")
        d.enqueue(s)                                                        // ja pedida: nada
        while d.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(done == ["j"] && Set(paths) == ["/stems/j/a.wav", "/stems/j/b.wav", "/stems/j/c.wav", "/stems/j/d.wav", "/stems/j/drum_kick.wav"] && changed > 0 && last > 0.9)
        d.enqueue(s)                                                        // ja esta no disco
        #expect(!d.busy)
    }

    @Test func downloadsReportFailureAndCancelStopsBetweenBatches() async throws {
        let f = Fake(), svc = f.service()
        f.serve { _, _ in (500, json("{}")) }
        let d = Downloads(svc)
        var failed = 0
        d.onFailed = { _, _ in failed += 1 }
        d.enqueue(song(["a"]))
        while d.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(failed == 1)
        f.serve { _, _ in (200, Data("OK".utf8)) }
        var completed = 0
        d.onCompleted = { _ in completed += 1 }
        d.enqueue(song(["a", "b", "c", "d"]))
        d.cancel("j")
        while d.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(completed == 0)                                             // cancelada: nao conta como pronta
    }

    @Test func onlySongsSeenActiveBeforeAreFinished() {
        func s(_ id: String, _ st: JobStatus) -> Song { Song(id: id, title: id, status: st, stems: ["a"]) }
        let fin = Downloads.finished(before: [s("a", .processing), s("b", .queued), s("c", .done)], after: [s("a", .done), s("b", .processing), s("c", .done), s("d", .done)])
        #expect(fin.map(\.id) == ["a"])                                     // d e c nunca estiveram ativas aqui: uma conta nova nao descarrega tudo
    }
}
