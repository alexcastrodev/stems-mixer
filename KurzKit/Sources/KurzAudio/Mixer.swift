import Foundation
import KurzCore
import os

// Mixer de stems: mistura em blocos, a pedido de quem toca (AudioOut). Volume / mute / solo sao lidos dos Track a cada bloco.
// A mistura (`fill`) nao sabe de som: testa-se sem dispositivo, e `out` so liga e desliga a saida.
public final class Mixer: @unchecked Sendable {
    public static let rate = 44100, chunk = 4096

    struct State {
        var tracks: [Track] = []
        var cursor = 0, length = 0
        var loop: (start: Int, end: Int)?
        var playing = false
        var metronome = false
        var soloClick = false
        var rate = 1.0
        var map: BeatMap?
        var metroVolume: Float = 0.25
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let out: AudioOut?
    let acc = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)     // so `fill` o usa, sob o cadeado
    public var onEnded: (() -> Void)?
    // Ajuste manual do atraso (s) por cima do que a saida diz: a placa de som tem um atraso proprio que nem sempre se mede.
    public var latencyAdjust = 0.0

    public init(out: AudioOut? = nil) {
        self.out = out
        out?.pull = { [unowned self] buf, frames in fill(buf, frames: frames) }
        out?.prepare()
    }
    deinit { acc.deallocate() }

    public var playing: Bool { state.withLock { $0.playing } }
    public var metronome: Bool { get { state.withLock { $0.metronome } } set { state.withLock { $0.metronome = newValue } } }
    // A velocidade: a saida estica o som, e o cursor (em tempo da musica) anda mais depressa ou mais devagar sozinho.
    public var rate: Double { get { state.withLock { $0.rate } } set { state.withLock { $0.rate = newValue }; out?.rate = newValue } }
    public var soloClick: Bool { get { state.withLock { $0.soloClick } } set { state.withLock { $0.soloClick = newValue } } }   // so o clique se ouve: os stems calam-se
    public var map: BeatMap? { get { state.withLock { $0.map } } set { state.withLock { $0.map = newValue } } }   // batidas onde o clique soa
    public var metroVolume: Float { get { state.withLock { $0.metroVolume } } set { state.withLock { $0.metroVolume = newValue } } }
    public var duration: Double { state.withLock { Double($0.length) / Double(Self.rate) } }
    public var looping: Bool { state.withLock { $0.loop != nil } }
    public var position: Double {
        let latency = (out?.latency ?? 0) + latencyAdjust
        return state.withLock { max(0, Double(min(max($0.cursor, 0), $0.length)) / Double(Self.rate) - ($0.playing ? latency * $0.rate : 0)) }   // a latencia e em tempo real: em tempo da musica vale `rate` vezes
    }

    public func load(_ tracks: [Track]) {
        pause()
        state.withLock {
            $0.tracks = tracks
            $0.loop = nil
            $0.cursor = 0
            $0.length = tracks.compactMap { $0.pcm?.count }.map { $0 / 2 }.max() ?? 0
        }
    }

    public func play() throws {
        let ok = state.withLock { s -> Bool in
            guard s.length > 0 else { return false }
            if s.cursor >= s.length { s.cursor = 0 }
            s.playing = true
            return true
        }
        guard ok else { return }
        do { try out?.play() } catch { state.withLock { $0.playing = false }; throw error }
    }

    public func pause() {
        state.withLock { $0.playing = false }
        out?.pause()
    }

    public func seek(_ sec: Double) {
        state.withLock { $0.cursor = Int(min(max(sec, 0), Double($0.length) / Double(Self.rate)) * Double(Self.rate)) }
    }

    // Repete [start, end] (s) ate ser limpo; trechos com menos de 0.2 s nao contam.
    public func setLoop(_ start: Double, _ end: Double) {
        state.withLock { $0.loop = end - start >= 0.2 ? (Int(start * Double(Self.rate)), min($0.length, Int(end * Double(Self.rate)))) : nil }
    }
    public func clearLoop() { state.withLock { $0.loop = nil } }

    // Proximo bloco a misturar: de onde le, quantos frames (ate `chunk`) e onde fica o cursor depois.
    // Num ciclo, o cursor volta ao inicio do trecho assim que chega ao fim, sem cortes no som.
    public static func advance(cursor: Int, length: Int, loop: (start: Int, end: Int)?, chunk: Int) -> (from: Int, frames: Int, next: Int) {
        var cursor = cursor
        if let l = loop, cursor >= l.end { cursor = l.start }
        let frames = min(chunk, (loop?.end ?? length) - cursor)
        let next = cursor + frames
        return (cursor, frames, loop.map { next >= $0.end } == true ? loop!.start : next)
    }

    // Enche `out` com `frames` frames da mistura; silencio se nao esta a tocar. Corre na thread de audio.
    public func fill(_ out: UnsafeMutablePointer<Int16>, frames: Int) {
        var done = 0, ended = false
        state.withLockUnchecked { s in           // a thread de audio: sem a garantia de Sendable do withLock, que obrigava a copiar o buffer
            while done < frames && s.playing {
                let (from, n, next) = Self.advance(cursor: s.cursor, length: s.length, loop: s.loop, chunk: min(Self.chunk, frames - done))
                guard n > 0 else { break }
                s.cursor = from
                mix(s, into: out + done * 2, frames: n)
                s.cursor = next
                done += n
            }
            if s.playing && s.loop == nil && s.cursor >= s.length { s.playing = false; s.cursor = s.length; ended = true }
        }
        if done < frames { (out + done * 2).update(repeating: 0, count: (frames - done) * 2) }
        if ended { onEnded?() }
    }

    // Soma, a partir do frame `from`, os stems que se ouvem com o seu volume (mute e solo contam): a mistura que o utilizador tem em maos.
    static func sum(_ tracks: [Track], _ acc: UnsafeMutablePointer<Float>, from: Int, frames: Int) {
        let anySolo = tracks.contains { $0.solo }
        for t in tracks {
            guard let pcm = t.pcm, !t.hasParts, t.audible(anySolo: anySolo) else { continue }
            let v = Float(t.volume), off = from * 2, n = min(frames * 2, pcm.count - off)
            if n <= 0 { continue }
            pcm.withUnsafeBufferPointer { p in for i in 0..<n { acc[i] += Float(p[off + i]) * v } }
        }
    }

    static func clip(_ acc: UnsafeMutablePointer<Float>, _ out: UnsafeMutablePointer<Int16>, samples: Int) {
        for i in 0..<samples { out[i] = Int16(min(max(acc[i], Float(Int16.min)), Float(Int16.max))) }
    }

    func mix(_ s: State, into out: UnsafeMutablePointer<Int16>, frames: Int) {
        acc.update(repeating: 0, count: frames * 2)
        if !s.soloClick { Self.sum(s.tracks, acc, from: s.cursor, frames: frames) }
        if s.metronome, let map = s.map { Click.render(acc, start: s.cursor, frames: frames, map: map, volume: s.metroVolume) }
        Self.clip(acc, out, samples: frames * 2)
    }

    // A mistura de agora (volumes, mute e solo; sem o clique) da musica toda, estereo a 44.1 kHz: para a exportar num so ficheiro.
    public static func render(_ tracks: [Track]) -> [Int16] {
        let frames = tracks.compactMap { $0.pcm?.count }.map { $0 / 2 }.max() ?? 0
        var pcm = [Int16](repeating: 0, count: frames * 2)
        let acc = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)
        defer { acc.deallocate() }
        for f in stride(from: 0, to: frames, by: chunk) {
            let n = min(chunk, frames - f)
            acc.update(repeating: 0, count: n * 2)
            sum(tracks, acc, from: f, frames: n)
            pcm.withUnsafeMutableBufferPointer { clip(acc, $0.baseAddress! + f * 2, samples: n * 2) }
        }
        return pcm
    }
}
