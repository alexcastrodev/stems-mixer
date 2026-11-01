import Foundation

public enum Click {
    public static let rate = 44100, len = 2205 // 50 ms

    // Soma o clique em `acc` (estereo entrelacado, escala de 16 bits) para os frames [start, start+frames), um por batida de `map`.
    public static func render(_ acc: UnsafeMutablePointer<Float>, start: Int, frames: Int, map: BeatMap, volume: Float) {
        var i = max(0, map.at(Double(start - len) / Double(rate)))
        while i < map.times.count {
            let at = Int((map.times[i] * Double(rate)).rounded())
            if at >= start + frames { break }
            let freq = map.down[i] ? 1500.0 : 1000.0
            for f in stride(from: max(at, start), to: min(at + len, start + frames), by: 1) {
                let t = Double(f - at) / Double(rate)
                let v = Float(sin(2 * .pi * freq * t) * exp(-t * 80) * 32767) * volume
                let j = (f - start) * 2
                acc[j] += v; acc[j + 1] += v
            }
            i += 1
        }
    }
}
