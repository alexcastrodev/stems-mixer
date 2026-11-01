import Testing
@testable import KurzCore

// 40 batidas de 0,5 s (120 BPM) a partir de 0,5 s, um compasso de 4 tempos.
func analyzed(bpm: Int? = 120) -> Song {
    let beats = (0..<40).map { 0.5 + Double($0) * 0.5 }
    return Song(id: "1", title: "x", status: .done, stems: [], bpm: bpm, downbeatOffset: 0.5, beats: beats,
                downbeats: beats.enumerated().filter { $0.offset % 4 == 0 }.map(\.element), bpmAuto: 120)
}
func loaded(_ s: Song) -> Metro { let m = Metro(); m.load(s, duration: 20, pcm: []); return m }

@Suite struct MetroTests {
    @Test func analyzedSongFollowsItsRealBeatsAndSavesOnlyTheFirstBar() {
        let m = loaded(analyzed())
        #expect(m.follows)
        #expect(m.bpm == 120 && m.bpmText == "120" && m.map.times.count == 40)
        #expect(m.fix.bpm == nil && m.fix.offset == 0.5)                   // no nivel da analise: o BPM nao se grava
    }

    @Test func songWithoutAnalysisUsesAFixedGridAtTheServerTempo() {
        let m = loaded(Song(id: "1", title: "x", status: .done, stems: [], bpm: 90))
        #expect(!m.follows)
        #expect(m.bpm == 90 && m.map.bpm == 90)
        #expect(m.fix.bpm == 90 && m.fix.offset == 0)
    }

    @Test func aHandCorrectedTempoIsNotAnOctaveOfTheAnalysisSoTheGridGoesFixed() {
        let m = loaded(analyzed(bpm: 100))
        #expect(!m.follows && m.bpm == 100)
    }

    @Test func noTempoAnywhereShowsADashAndClicksAt120() {
        let m = loaded(Song(id: "1", title: "x", status: .done, stems: []))   // sem BPM, e o pcm vazio nao deixa estimar
        #expect(m.bpm == 120 && m.bpmText == "—" && m.value == "—")
    }

    @Test func userBpmStopsFollowingAndStaysBetween30And300() {
        let m = loaded(analyzed())
        m.userBpm(500)
        #expect(!m.follows && m.bpm == 300 && m.map.bpm == 300)
        m.userBpm(1)
        #expect(m.bpm == 30)
    }

    @Test func octaveKeepsTheRealBeatsAndSavesTheLevel() {
        let m = loaded(analyzed())
        #expect(m.octave(+1))                                              // pontos medios entre cada par de batidas
        #expect(m.follows && m.bpm == 240 && m.map.times.count == 79)
        #expect(m.fix.bpm == 240)
        #expect(!m.octave(+1))                                             // 480 BPM nao existe: nada muda
        #expect(m.bpm == 240)
        #expect(m.octave(-1))
        #expect(m.fix.bpm == nil)                                          // de volta ao nivel da analise
        #expect(m.octave(-1))                                              // larga uma batida em duas
        #expect(m.bpm == 60 && m.map.times.count == 20 && m.fix.bpm == 60)
    }

    @Test func subdivisionIsHalfOneOrTwoTimesTheDetectedTempoAndOneGoesBack() {
        let m = loaded(analyzed())
        #expect(m.subdivision == 0)
        #expect(m.setSubdivision(1) && m.subdivision == 1 && m.bpm == 240 && m.follows)
        #expect(m.setSubdivision(-1) && m.subdivision == -1 && m.bpm == 60)   // de 2.0x direto a 0.5x
        #expect(m.setSubdivision(0) && m.subdivision == 0 && m.bpm == 120 && m.fix.bpm == nil)
        let fixed = loaded(Song(id: "1", title: "x", status: .done, stems: [], bpm: 100, bpmAuto: 120))   // corrigido a mao antes: nao segue as batidas
        #expect(fixed.subdivision == 0 && fixed.setSubdivision(1) && fixed.subdivision == 1 && fixed.bpm == 240)
        #expect(fixed.setSubdivision(0) && fixed.bpm == 120)
    }

    @Test func octaveWithoutRealBeatsJustDoublesOrHalvesTheFixedTempo() {
        let m = loaded(Song(id: "1", title: "x", status: .done, stems: [], bpm: 90))
        _ = m.octave(+1)
        #expect(m.bpm == 180)
        _ = m.octave(-1); _ = m.octave(-1)
        #expect(m.bpm == 45)
    }

    @Test func markMovesTheFirstBarToTheGivenPosition() {
        let m = loaded(analyzed())
        m.mark(2)
        #expect(m.offset == 2 && m.fix.offset == 2)
        #expect(abs(m.map.times[0] - 2) < 0.001)                           // a batida mais proxima de 2 s
    }

    @Test func resetGoesBackToTheDetectedTempo() {
        let m = loaded(analyzed())
        m.userBpm(100)
        m.reset(bpm: 120, offset: 0.5)
        #expect(m.follows && m.bpm == 120 && m.offset == 0.5)
    }
}
