import Foundation
import Testing
@testable import KurzCore

func clicks(_ bpm: Double, secs: Int = 40) -> [Int16] {
    var pcm = [Int16](repeating: 0, count: 44100 * secs * 2)
    for beat in 0..<Int(Double(secs) * bpm / 60) {
        let at = Int(Double(beat) * 60 / bpm * 44100)
        for i in 0..<400 where (at + i) * 2 + 1 < pcm.count {
            pcm[(at + i) * 2] = Int16(20000 * (0.5 - 0.5 * cos(2 * .pi * Double(i) / 399))); pcm[(at + i) * 2 + 1] = pcm[(at + i) * 2]
        }
    }
    return pcm
}

@Suite struct TempoTests {
    @Test(arguments: [82, 96, 120, 133]) func detectsAClickTrackWithinOneBpm(_ bpm: Int) {
        let d = Tempo.detect(clicks(Double(bpm)))
        #expect(d != nil && abs(d! - bpm) <= 1)
    }
    @Test func foldsVerySlowOrFastTempoInto70To180() {
        #expect(abs(Tempo.detect(clicks(200))! - 100) <= 1)
        #expect(abs(Tempo.detect(clicks(60))! - 120) <= 1)
    }
    @Test func silenceAndVeryShortAudioGiveNoTempo() {
        #expect(Tempo.detect([Int16](repeating: 0, count: 44100 * 2 * 30)) == nil)
        #expect(Tempo.detect([Int16](repeating: 0, count: 44100)) == nil)
    }
    @Test func boundsMatchTheServer() { #expect(Tempo.min == 30 && Tempo.max == 300) }
}

@Suite struct BeatMapTests {
    @Test func fixedGridHasFourBeatsPerBarFromTheOffset() {
        let m = BeatMap.fixed(bpm: 120, offset: 1, duration: 5)
        #expect(m.times.first == 1 && m.times.count == 9)
        #expect(m.down == [true, false, false, false, true, false, false, false, true])
        #expect(m.cell(1.0) == 0 && m.cell(2.6) == 3 && m.cell(3.0) == 4)
        #expect(m.at(0.9) == -1 && m.at(1.0) == 0 && m.at(1.7) == 1)
    }
    @Test func beforeTheFirstBeatTheCellsExtrapolateTo44() {
        let m = BeatMap.fixed(bpm: 120, offset: 2, duration: 8)
        #expect(m.cell(1.0) == -2 && m.minBar == -1)
    }
    @Test func aBarKnowsWhereItStarts() {
        let m = BeatMap.fixed(bpm: 120, offset: 2, duration: 8)          // compassos de 2 s a partir dos 2 s
        #expect(m.barCount == 4 && m.barStart(0) == 2 && m.barStart(2) == 6 && m.barStart(-1) == 0 && m.barStart(99) == m.times.last)
    }
    @Test func realBeatsFollowTheAnalysisDownbeats() {
        let beats = (0..<12).map { Double($0) * 0.5 }
        let m = BeatMap.fromBeats(beats, downbeats: [0, 1.5, 3.0, 4.5], offset: 0)     // compassos de 3 tempos
        #expect(m.down.enumerated().filter(\.element).map(\.offset) == [0, 3, 6, 9] && m.bpm == 120)
    }
    @Test func levelUpInsertsMidpointsAndDownHalvesTheBeats() {
        let beats = (0..<8).map { Double($0) * 0.5 }
        #expect(BeatMap.fromBeats(beats, downbeats: [], offset: 0, level: 1).times.count == 15)
        #expect(BeatMap.fromBeats(beats, downbeats: [], offset: 0, level: -1).times == [0, 1, 2, 3])
    }
    @Test func medianTempoIgnoresAMissingBeat() {
        let m = BeatMap.fromBeats([0, 0.5, 1, 2, 2.5, 3, 3.5], downbeats: [], offset: 0)
        #expect(m.bpm == 120)
    }
}

@Suite struct DomainTests {
    @Test func songDisplay() {
        let s = Song(id: "1", title: "Banda - Musica.mp3", status: .done, stems: ["a", "b"], created: Date(timeIntervalSince1970: 1_700_000_000), duration: 222.5, artist: "Banda")
        #expect(s.displayTitle == "Banda - Musica" && s.subtitle == "Banda" && s.length == "3:42" && s.statusLabel == "Separada")
        #expect(Song(id: "2", title: "Mr. Brightside", status: .queued, stems: []).displayTitle == "Mr. Brightside")
        #expect(Song(id: "3", title: "x", status: .processing, stems: [], progress: 0.456).statusLabel == "A separar 45%")
        #expect(Song(id: "4", title: "x", status: .done, stems: ["a", "b", "c"]).subtitle == "3 stems")
    }
    @Test func safeFileNameReplacesWhatTheFileSystemRefuses() { #expect(Song.safeFileName("a/b:c?d") == "a_b_c_d") }
    @Test func beatLevelIsTheOctaveOfTheDetectedTempo() {
        func level(_ bpm: Int) -> Int? { var s = analyzed(bpm: bpm); s.bpmAuto = 120; return s.beatLevel }
        #expect(level(120) == 0 && level(240) == 1 && level(60) == -1 && level(100) == nil)
        #expect(Song(id: "1", title: "x", status: .done, stems: [], bpm: 120, bpmAuto: 120).beatLevel == nil)   // sem batidas: grelha fixa
    }
    @Test func agoCountsFromNow() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        func ago(_ secs: Double) -> String { Song(id: "1", title: "x", status: .done, stems: [], created: now.addingTimeInterval(-secs)).ago(now: now) }
        #expect(ago(60) == "agora" && ago(7200) == "há 2 h" && ago(100_000) == "ontem" && ago(86400 * 10) == "há 10 dias" && ago(86400 * 90) == "há 3 meses")
    }
    @Test func importKeepsOnlyNewAudio() {
        var list = ["a.mp3"]
        #expect(Import.add(&list, ["b.WAV", "a.mp3", "c.txt"]) == 2)
        #expect(list == ["a.mp3", "b.WAV"])
    }
    @Test func noticeSticksWhileWorking() { #expect(Notice.isTransient("Pronto") && !Notice.isTransient("A carregar…") && !Notice.isTransient("")) }
    @Test func stemCatalog() {
        #expect(StemCatalog.displayName("vocals") == "Vocais" && StemCatalog.displayName("xyz") == "xyz")
        #expect(["other", "bass", "vocals", "drums"].sorted { StemCatalog.rank($0) < StemCatalog.rank($1) } == ["drums", "vocals", "bass", "other"])
    }
    @Test func playlistStopsAtTheEnds() {
        let songs = ["a", "b", "c"].map { Song(id: $0, title: $0, status: $0 == "b" ? .queued : .done, stems: []) }
        #expect(Playlist.neighbour(songs, from: "a", step: 1)?.id == "c")
        #expect(Playlist.neighbour(songs, from: "a", step: -1) == nil && Playlist.neighbour(songs, from: "c", step: 1) == nil)
    }
    @Test func lanesColorStemsBlueToTealAndPartsVioletToPink() {
        #expect(Lanes.color(0, of: 3) == "#3ba4ff" && Lanes.color(2, of: 3) == "#4bd8cf")
        let drums = Track(name: "Bateria", isDrums: true), part = Track(name: "Bombo", parent: drums), vocals = Track(name: "Vocais")
        drums.parts = [part]; drums.expanded = true
        let rows = Lanes.rows([drums, vocals])
        #expect(rows.map(\.name) == ["Bateria", "Bombo", "Vocais"] && part.lane == "#9b8cff" && vocals.lane == "#4bd8cf")
    }
    @Test func soloOnTheDrumsAlsoPlaysItsPartsUnlessAPartHasItsOwn() {
        let drums = Track(name: "d", isDrums: true), a = Track(name: "a", parent: drums), b = Track(name: "b", parent: drums)
        drums.parts = [a, b]
        drums.solo = true
        #expect(a.audible(anySolo: true) && b.audible(anySolo: true))
        a.solo = true
        #expect(a.audible(anySolo: true) && !b.audible(anySolo: true))
        drums.muted = true
        #expect(!a.audible(anySolo: true))
    }
    @Test func peaksAndWavEncoding() {
        let pcm = [Int16](repeating: 16384, count: 64) + [Int16](repeating: -32768, count: 64)   // 64 frames: metade a 0,5 e metade a -1
        #expect(Wav.peaks(pcm, buckets: 2) == [0.5, 1])
        let w = Wav.encode(pcm)
        #expect(w.count == 44 + 256 && String(decoding: w.prefix(4), as: UTF8.self) == "RIFF" && w[40] == 0 && w[41] == 1)   // 256 bytes de dados, little-endian
    }
    @Test func rowStepsFollowUploadSeparationAndFetch() {
        let r = SongRow(Song(id: "1", title: "x", status: .processing, stems: [], progress: 0.5))
        #expect(r.step == .separate && r.label == "2/3 · A separar 50%" && r.opacity == 0.65)
        let up = SongRow(.uploading("x.mp3", hifi: true)); up.progress = 0.25
        #expect(up.stepText == "1/3 · A enviar 25%")
        let done = SongRow(Song(id: "2", title: "x", status: .done, stems: ["a"])); done.downloading = true; done.progress = 0.4
        #expect(done.stepText == "3/3 · A descarregar 40%" && done.state == .downloading)
    }
}
