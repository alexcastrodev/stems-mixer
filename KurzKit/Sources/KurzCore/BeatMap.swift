import Foundation

// As batidas da musica (s, por ordem) e quais abrem um compasso: o que o clique, a faixa de batidas e o painel de compassos seguem.
// Vem das batidas reais da analise (acompanham um tempo que oscila e nao e inteiro) ou de um BPM fixo.
public final class BeatMap: Sendable {
    public let times: [Double]
    public let down: [Bool]
    public let bpm: Double                      // tempo medio, para mostrar
    let bar: [Int], inBar: [Int]                // compasso (0 = o do 1.o tempo) e tempo dentro dele, por batida

    public init(times: [Double], down: [Bool], bpm: Double) {
        (self.times, self.down, self.bpm) = (times, down, bpm)
        var bar = [Int](repeating: 0, count: times.count), inBar = bar
        var b = -1, k = 0
        for i in times.indices {
            if down[i] { b += 1; k = 0 }
            (bar[i], inBar[i]) = (b, k)
            k += 1
        }
        (self.bar, self.inBar) = (bar, inBar)
    }

    // BPM fixo (pode ser fracionario) a partir do 1.o compasso, 4 tempos por compasso. Antes do `offset` nao ha batidas.
    public static func fixed(bpm: Double, offset: Double, duration: Double) -> BeatMap {
        let p = 60 / bpm
        let n = max(1, Int((duration - offset) / p) + 1)
        return BeatMap(times: (0..<n).map { offset + Double($0) * p }, down: (0..<n).map { $0 % 4 == 0 }, bpm: bpm)
    }

    // Batidas reais da analise a partir do 1.o compasso (`offset`). Se ele e o 1.o downbeat da analise, os compassos seguem os
    // downbeats (a analise so da compassos de 3 ou 4 tempos); se o utilizador o moveu, contam-se 4 tempos a partir da batida mais proxima dele.
    // `level` troca a oitava sem perder os instantes reais: +1 insere pontos medios (o dobro), -1 larga uma batida em duas (a metade);
    // nesses casos tambem se contam 4 tempos por compasso. `beats` nao pode ser vazio.
    public static func fromBeats(_ beats: [Double], downbeats: [Double], offset: Double, level: Int = 0) -> BeatMap {
        var t = Array(beats[nearest(beats, offset)...])
        if level < 0 { t = t.enumerated().filter { $0.offset % (1 << -level) == 0 }.map(\.element) }
        else if level > 0 { t = subdivide(t, 1 << level) }
        var d = [Bool](repeating: false, count: t.count)
        if level == 0, let first = downbeats.first, abs(first - offset) < 0.001 {
            for db in downbeats { let j = nearest(t, db); if abs(t[j] - db) < 0.05 { d[j] = true } }
        } else {
            for i in d.indices { d[i] = i % 4 == 0 }
        }
        d[0] = true
        let iv = zip(t, t.dropFirst()).map { $1 - $0 }.sorted()
        return BeatMap(times: t, down: d, bpm: iv.isEmpty ? 120 : 60 / iv[iv.count / 2])   // mediana: uma batida que falte na analise nao estraga o tempo
    }

    // `n` partes iguais entre cada par de batidas reais: n-1 pontos medios.
    static func subdivide(_ t: [Double], _ n: Int) -> [Double] {
        guard t.count > 1 else { return t }
        var r = [Double](repeating: 0, count: (t.count - 1) * n + 1)
        for i in 0..<t.count - 1 { for j in 0..<n { r[i * n + j] = t[i] + (t[i + 1] - t[i]) * Double(j) / Double(n) } }
        r[r.count - 1] = t[t.count - 1]
        return r
    }

    // Indice da maior que `x` (ou a.count): busca binaria.
    static func upper(_ a: [Double], _ x: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let m = (lo + hi) / 2; if a[m] <= x { lo = m + 1 } else { hi = m } }
        return lo
    }

    static func nearest(_ a: [Double], _ x: Double) -> Int {
        let i = upper(a, x)                         // primeira maior que x
        if i > 0 && a[i - 1] == x { return i - 1 }
        return i == 0 ? 0 : i == a.count ? a.count - 1 : x - a[i - 1] <= a[i] - x ? i - 1 : i
    }

    // Batida em curso em `sec` (a ultima que ja soou); -1 antes da primeira.
    public func at(_ sec: Double) -> Int { BeatMap.upper(times, sec) - 1 }

    // Posicao no painel de compassos (4 casas por compasso): compasso*4 + tempo. Antes da 1.a batida e negativa (extrapola a 4/4).
    public func cell(_ sec: Double) -> Double {
        let i = at(sec)
        return i < 0 ? ((sec - times[0]) * bpm / 60).rounded(.down) : Double(bar[i] * 4 + min(inBar[i], 3))
    }

    // Quantos compassos tem a musica (a partir do 1.o) e o instante (s) em que abre o `b`; antes do 1.o extrapola a 4/4, sem passar de 0.
    public var barCount: Int { (bar.last ?? -1) + 1 }
    public func barStart(_ b: Int) -> Double {
        if b < 0 { return max(0, times[0] + Double(b) * 240 / bpm) }
        return bar.firstIndex(of: b).map { times[$0] } ?? times[times.count - 1]
    }

    // Compasso mais antigo do painel: o que contem o inicio da musica, antes do compasso 1.
    public var minBar: Int { Int((-times[0] * bpm / 240).rounded(.down)) }
}
