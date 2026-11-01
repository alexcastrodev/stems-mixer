import Foundation

public enum Wav {
    // Picos por intervalo (0...1) para desenhar a onda: o maior valor absoluto do canal esquerdo em cada um dos `buckets` intervalos.
    public static func peaks(_ pcm: [Int16], buckets: Int) -> [Float] {
        let frames = pcm.count / 2
        return (0..<buckets).map { b in
            let from = frames * b / buckets, to = frames * (b + 1) / buckets
            var mx = 0
            for f in stride(from: from, to: to, by: 16) { mx = max(mx, abs(Int(pcm[f * 2]))) }
            return Float(mx) / 32768
        }
    }

    // Estereo 16-bit 44.1 kHz entrelacado -> arquivo WAV.
    public static func encode(_ pcm: [Int16]) -> Data {
        let bytes = pcm.count * 2
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(2); u32(44100); u32(44100 * 4); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        pcm.withUnsafeBufferPointer { d.append(contentsOf: UnsafeRawBufferPointer($0)) }   // little-endian: o que os Macs e iPhones sao
        return d
    }
}
