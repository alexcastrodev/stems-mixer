import Foundation

public enum Tempo {
    public static let min = 30, max = 300 // o servidor aceita o mesmo intervalo
    public static let playMin = 30, playMax = 210   // o BPM a que se toca (a velocidade): mais ou menos que o da musica acelera-a ou atrasa-a

    // BPM por autocorrelacao da energia (mesmo metodo do servidor): 70-180 depois de dobrar/dividir. nil se nao der.
    // pcm = estereo 16-bit entrelacado a 44.1 kHz.
    public static func detect(_ pcm: [Int16]) -> Int? {
        let hop = 512, n = pcm.count / 2 / hop
        guard n >= 200 else { return nil }                          // menos de ~2 s
        var env = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = 0.0
            for j in i * hop..<(i + 1) * hop { let m = (Double(pcm[2 * j]) + Double(pcm[2 * j + 1])) / 65536.0; sum += m * m }
            env[i] = (sum / Double(hop)).squareRoot()
        }
        var onset = (0..<n - 1).map { Swift.max(env[$0 + 1] - env[$0], 0) }
        let mean = onset.reduce(0, +) / Double(onset.count)
        for i in onset.indices { onset[i] -= mean }

        let fps = 44100.0 / Double(hop)
        let lo = Int(fps * 60 / 180), hi = Int(fps * 60 / 60)
        var ac = [Double](repeating: 0, count: hi + 2)
        for lag in lo - 1...hi + 1 { var s = 0.0; var i = 0; while i + lag < onset.count { s += onset[i] * onset[i + lag]; i += 1 }; ac[lag] = s }
        var k = lo
        for lag in lo...hi where ac[lag] > ac[k] { k = lag }
        guard ac[k] > 0 else { return nil }
        var l = Double(k)
        if k > lo && k < hi {                                       // interpolacao parabolica do pico
            let y0 = ac[k - 1], y1 = ac[k], y2 = ac[k + 1], d = y0 - 2 * y1 + y2
            if d != 0 { l = Double(k) + 0.5 * (y0 - y2) / d }
        }
        var bpm = 60 * fps / l
        while bpm < 70 { bpm *= 2 }
        while bpm > 180 { bpm /= 2 }
        return Int(bpm.rounded())
    }
}
