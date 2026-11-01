import AVFoundation

// Os stems chegam em WAV (servidores antigos), FLAC (Hi-Fi: sem perdas) ou Opus (otimizado, 96 kbps): o AVFoundation le os tres, e aqui todos viram
// PCM estereo 16-bit a 44.1 kHz, o que o mixer espera (o Opus, de 48 kHz, e reamostrado; com o priming por omissao do conversor, o inicio e o comprimento saem exatos: medido, 0 amostras de diferenca do WAV). Custa CPU: chamar fora da thread da interface.
public enum AudioFile {
    public static let rate = 44100.0
    static let block: AVAudioFrameCount = 65536

    public static func pcm(at url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 2, interleaved: true)!
        guard let conv = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: block * 2) else { throw CocoaError(.fileReadUnknown) }
        var pcm: [Int16] = []
        pcm.reserveCapacity(Int(Double(file.length) * rate / file.processingFormat.sampleRate) * 2 + 8192)
        var readError: Error?
        var eof = false
        while true {
            var error: NSError?
            let status = conv.convert(to: output, error: &error) { _, flag in
                if eof || file.framePosition >= file.length { eof = true; flag.pointee = .endOfStream; return nil }
                do { try file.read(into: input, frameCount: block) } catch { readError = error; eof = true; flag.pointee = .endOfStream; return nil }
                flag.pointee = .haveData
                return input
            }
            if let readError { throw readError }
            if let error { throw error }
            pcm.append(contentsOf: UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength) * 2))
            if status == .endOfStream || status == .error || (eof && output.frameLength == 0) { break }
        }
        return pcm
    }
}
