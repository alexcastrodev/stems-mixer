import Foundation

// O metronomo de uma musica aberta: o BPM, a oitava das batidas reais, o 1.o compasso e as batidas que o clique, a faixa e o painel seguem.
// Sem interface, som nem rede: quem o usa passa `map` ao mixer e grava `fix` no servidor.
public final class Metro {
    var meta: Song?                    // a musica aberta: de onde vem as batidas reais
    var follow = false                 // o clique segue as batidas reais; senao, o BPM inteiro (corrigido a mao ou sem analise)
    var level = 0                      // oitava das batidas reais: +1 o dobro, -1 a metade
    var duration = 0.0
    var pcm: [Int16] = []              // so para estimar o tempo quando nem o servidor nem a analise o deram

    public private(set) var offset = 0.0                           // s ate ao 1.o compasso
    public private(set) var bpm = 120.0                            // o BPM inteiro da grelha fixa
    public private(set) var map = BeatMap.fixed(bpm: 120, offset: 0, duration: 0)
    public var follows: Bool { follow }
    public private(set) var bpmText = "120"                        // o que o campo mostra: sempre inteiro, ou "—" sem tempo
    public private(set) var value = "—"                            // o valor exato, para o «i» ao lado do metronomo
    public private(set) var note = ""

    public init() {}

    // A musica aberta, com o tempo, o 1.o compasso e as batidas que o servidor deu. `pcm` (a bateria) so serve se nem o servidor nem a analise deram BPM.
    public func load(_ song: Song, duration: Double, pcm: [Int16]) {
        (meta, self.duration, self.pcm) = (song, duration, pcm)
        (offset, follow, level) = (song.downbeatOffset ?? 0, song.followsBeats, song.beatLevel ?? 0)
        show(song.bpm)
    }

    // Mostra o BPM da musica: o das batidas reais (ex. 123.3) se o clique as segue. Sem BPM do servidor, estima-o da bateria: o campo e o clique tem de coincidir.
    func show(_ serverBpm: Int?) {
        if follow { rebuild() }
        let b = follow ? Int(map.bpm.rounded()) : serverBpm ?? Tempo.detect(pcm)
        setBpm(Double(b ?? 120))
        if b == nil { (bpmText, value, note) = ("—", "—", "Sem tempo detetado: o clique usa 120 BPM.") }   // nem o servidor nem a app conseguiram: o clique usa 120
    }

    public func setBpm(_ v: Double) {
        bpm = Swift.min(Swift.max(v.rounded(), Double(Tempo.min)), Double(Tempo.max))
        rebuild()
        bpmText = String(Int(bpm))                                 // sempre inteiro: o valor exato (ex. 122,45) esta em `value`
    }

    // Corrigir o BPM a mao: o clique passa a uma grelha fixa.
    public func userBpm(_ v: Double) { follow = false; setBpm(v) }

    // Corrigir a oitava (½ / ×2). Com batidas reais mantem-nas: insere pontos medios ou larga uma batida em duas; sem elas, e BPM fixo.
    // false se nao ha para onde ir (fora de 30-300 BPM): nada muda.
    public func octave(_ step: Int) -> Bool {
        if !follow { userBpm(step > 0 ? bpm * 2 : bpm / 2); return true }
        let b = levelBpm(level + step)
        if b < Double(Tempo.min) || b > Double(Tempo.max) { return false }
        level += step
        rebuild()
        setBpm(map.bpm)
        return true
    }

    // Em que oitava vai o clique em relacao ao tempo detetado: -1 (0.5x), 0 (1.0x) ou +1 (2.0x). Correcoes antigas a mao contam como 1.0x.
    public var subdivision: Int {
        if follow { return Swift.min(Swift.max(level, -1), 1) }
        guard let auto = meta?.bpmAuto, auto > 0 else { return 0 }
        let r = bpm / Double(auto)
        return abs(r - 2) < 0.02 ? 1 : abs(r - 0.5) < 0.02 ? -1 : 0
    }

    // Passa o clique a 0.5x, 1.0x ou 2.0x do tempo detetado (1.0x volta a ele). false se sai de 30-300 BPM: nada muda.
    public func setSubdivision(_ s: Int) -> Bool {
        let b = levelBpm(s)
        if b < Double(Tempo.min) || b > Double(Tempo.max) { return false }
        if follow { level = s; rebuild(); setBpm(map.bpm) } else { userBpm(b) }
        return true
    }

    // O 1.o compasso comeca em `position` (s).
    public func mark(_ position: Double) { offset = position; rebuild() }

    // Repoe o tempo detetado pelo servidor (BPM e 1.o compasso), desfazendo as correcoes do utilizador.
    public func reset(bpm: Int?, offset: Double) {
        (self.offset, follow, level) = (offset, meta?.hasBeats == true, 0)
        show(bpm)
    }

    // O que gravar no servidor depois de uma correcao: o BPM e o 1.o compasso. bpm nil: a seguir as batidas no nivel da analise, so o 1.o compasso mudou.
    public var fix: (bpm: Int?, offset: Double) {
        (!follow ? Int(bpm) : level == 0 ? nil : Int(levelBpm(level).rounded()), offset)
    }

    // A que BPM guardado corresponde a oitava `k` das batidas reais (o detetado vezes 2^k): e o que o servidor aprende por musica.
    func levelBpm(_ k: Int) -> Double { (meta?.bpmAuto.map(Double.init) ?? bpm) * pow(2, Double(k)) }

    // As batidas que o clique, a faixa e o painel seguem: as reais da analise ou o BPM fixo a partir do 1.o compasso.
    func rebuild() {
        if follow, let b = meta?.beats, !b.isEmpty { map = BeatMap.fromBeats(b, downbeats: meta?.downbeats ?? [], offset: offset, level: level) }
        else { map = BeatMap.fixed(bpm: bpm, offset: offset, duration: duration) }
        if follow {
            value = String(format: "%.2f BPM", map.bpm)
            note = "Mediana de \(map.times.count) batidas detetadas; o tempo da música oscila à volta dele."
        } else {
            value = (bpm == bpm.rounded() ? String(Int(bpm)) : String(bpm)) + " BPM"
            note = "BPM fixo: o clique usa este valor exato, sem seguir as batidas da música."
        }
    }
}
