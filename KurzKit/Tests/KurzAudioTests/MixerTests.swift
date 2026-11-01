import Foundation
import KurzCore
import Testing
@testable import KurzAudio

// Um stem constante: `value` em todas as amostras, `frames` frames.
func flat(_ value: Int16, frames: Int) -> Track { Track(name: "t", pcm: [Int16](repeating: value, count: frames * 2)) }

func render(_ m: Mixer, _ frames: Int) -> [Int16] {
    var out = [Int16](repeating: 99, count: frames * 2)
    out.withUnsafeMutableBufferPointer { m.fill($0.baseAddress!, frames: frames) }
    return out
}

@Suite struct MixerTests {
    @Test func advanceWrapsInsideALoopWithoutCuttingTheSound() {
        let loop = (start: 100, end: 150)
        #expect(Mixer.advance(cursor: 0, length: 1000, loop: nil, chunk: 4096) == (0, 1000, 1000))
        #expect(Mixer.advance(cursor: 120, length: 1000, loop: loop, chunk: 4096) == (120, 30, 100))
        #expect(Mixer.advance(cursor: 150, length: 1000, loop: loop, chunk: 20) == (100, 20, 120))
    }

    @Test func silentUntilPlayThenSumsTheAudibleTracksWithVolume() throws {
        let a = flat(1000, frames: 100), b = flat(2000, frames: 100)
        b.volume = 0.5
        let m = Mixer()
        m.load([a, b])
        #expect(render(m, 4) == [Int16](repeating: 0, count: 8))
        try m.play()
        #expect(render(m, 4) == [Int16](repeating: 2000, count: 8))      // 1000 + 2000 * 0.5
        #expect(m.position == 4.0 / 44100)
    }

    @Test func muteAndSoloDecideWhatIsHeard() throws {
        let a = flat(1000, frames: 100), b = flat(2000, frames: 100)
        let m = Mixer(); m.load([a, b]); try m.play()
        a.muted = true
        #expect(render(m, 2)[0] == 2000)
        a.muted = false; a.solo = true
        #expect(render(m, 2)[0] == 1000)
    }

    @Test func sumsClipInsteadOfWrapping() throws {
        let m = Mixer(); m.load([flat(30000, frames: 10), flat(30000, frames: 10)]); try m.play()
        #expect(render(m, 2)[0] == Int16.max)
    }

    @Test func endsOnceAndStaysSilent() throws {
        let m = Mixer(); m.load([flat(1000, frames: 10)])
        var ended = 0
        m.onEnded = { ended += 1 }
        try m.play()
        let out = render(m, 16)
        #expect(Array(out[0..<20]) == [Int16](repeating: 1000, count: 20) && Array(out[20...]) == [Int16](repeating: 0, count: 12))
        #expect(ended == 1 && !m.playing && m.position == 10.0 / 44100)
        _ = render(m, 16)
        #expect(ended == 1)
        try m.play()                                                         // no fim, tocar recomeca
        #expect(render(m, 2)[0] == 1000)
    }

    @Test func loopRepeatsTheStretchAndShortOnesDoNotCount() throws {
        let pcm = (0..<44100 * 2).flatMap { [Int16($0 % 1000), Int16($0 % 1000)] }.prefix(44100 * 2 * 2)
        let m = Mixer(); m.load([Track(name: "t", pcm: Array(pcm))]); try m.play()
        m.setLoop(0.5, 0.8)
        #expect(m.looping)
        m.seek(0.5)
        _ = render(m, 13230 * 3)                                             // 3 voltas ao trecho de 0,3 s
        #expect(m.looping && abs(m.position - 0.5) < 0.001 && m.playing)
        m.setLoop(1, 1.1)                                                    // menos de 0,2 s
        #expect(!m.looping)
    }

    @Test func seekClampsAndPartsPlayInsteadOfTheirParent() throws {
        let drums = Track(name: "d", pcm: [Int16](repeating: 5000, count: 200), isDrums: true)
        let kick = Track(name: "k", pcm: [Int16](repeating: 100, count: 200), parent: drums)
        drums.parts = [kick]
        let m = Mixer(); m.load([drums, kick]); try m.play()
        #expect(render(m, 1)[0] == 100)                                      // o pai e so cabecalho
        m.seek(99)
        #expect(m.position == m.duration)
    }

    @Test func metronomeClicksOnTheBeatsOnly() throws {
        let m = Mixer(); m.load([flat(0, frames: 44100)])
        m.map = BeatMap.fixed(bpm: 120, offset: 0, duration: 1); m.metronome = true; m.metroVolume = 1
        try m.play()
        let out = render(m, 2000)
        #expect(out.contains { abs(Int($0)) > 1000 })                        // o clique em 0 s
        m.seek(0.1)
        #expect(render(m, 2000).allSatisfy { $0 == 0 })                      // 0,1 s a 0,145 s: entre batidas (e o clique de 50 ms ja acabou)
    }

    final class FakeOut: AudioOut {
        var pull: Pull?, rate = 1.0, latency = 0.1
        func play() throws {}
        func pause() {}
    }

    @Test func theLatencyIsDiscountedInSongTime() throws {
        let out = FakeOut(), m = Mixer(out: out)
        m.load([flat(0, frames: 44100 * 2)]); try m.play(); m.seek(1)
        #expect(abs(m.position - 0.9) < 1e-9)
        m.rate = 0.5
        #expect(out.rate == 0.5 && abs(m.position - 0.95) < 1e-9)            // a meia velocidade, 0,1 s de som no ar sao 0,05 s da musica
    }

    @Test func soloingTheClickSilencesTheStems() throws {
        let m = Mixer(); m.load([flat(1000, frames: 44100)])
        m.map = BeatMap.fixed(bpm: 120, offset: 0, duration: 1); m.metronome = true; m.metroVolume = 1
        try m.play(); m.seek(0.1)
        m.soloClick = true
        #expect(render(m, 2000).allSatisfy { $0 == 0 })                      // entre batidas: so o clique soa, e nao ha clique
        m.soloClick = false; m.seek(0.1)
        #expect(render(m, 2000).contains { $0 == 1000 })
    }

    @Test func renderMixesTheWholeSongWithoutTheClick() {
        let a = flat(1000, frames: 10000), b = flat(-400, frames: 5000)
        let mix = Mixer.render([a, b])
        #expect(mix.count == 20000 && mix[0] == 600 && mix[19999] == 1000)
        b.muted = true
        #expect(Mixer.render([a, b])[0] == 1000)
    }
}
