import Foundation
import Testing
@testable import KurzAudio

func fixture(_ name: String) -> URL { Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)! }

// tone.wav: 0,6 s de um tom estereo a 44,1 kHz; tone.flac e tone.opus sao o mesmo som codificado.
@Suite struct AudioFileTests {
    @Test func wavComesOutAsStereo16BitAt44100() throws {
        let pcm = try AudioFile.pcm(at: fixture("tone.wav"))
        #expect(pcm.count == 26460 * 2)
        #expect(pcm.contains { abs(Int($0)) > 1000 })
    }

    @Test func flacIsLosslessSoItEqualsTheWav() throws {
        #expect(try AudioFile.pcm(at: fixture("tone.flac")) == AudioFile.pcm(at: fixture("tone.wav")))
    }

    // tone.opus.s16: o mesmo Opus descodificado pelo ffmpeg (-ar 44100 -ac 2 -f s16le), a referencia de comprimento e de alinhamento.
    @Test func opusIsResampledTo44100WithTheSameLengthAndAlignmentAsFfmpeg() throws {
        let opus = try AudioFile.pcm(at: fixture("tone.opus"))
        let ref = try Data(contentsOf: fixture("tone.opus.s16")).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(opus.count == ref.count)                                     // 0 amostras de diferenca
        var err = 0.0, energy = 0.0
        for i in 0..<min(opus.count, ref.count) { let d = Double(opus[i]) - Double(ref[i]); err += d * d; energy += Double(ref[i]) * Double(ref[i]) }
        #expect(err / energy < 0.02)                                         // reamostradores diferentes; um desfasamento de 15 frames daria ~0.3
    }

    @Test func aFileThatIsNotAudioFails() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio.flac")
        try? Data("isto nao e audio".utf8).write(to: url)
        #expect(throws: (any Error).self) { try AudioFile.pcm(at: url) }
    }
}
