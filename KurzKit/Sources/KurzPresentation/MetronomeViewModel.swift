import Foundation
import KurzAudio
import KurzCore
import KurzData
import Observation

// O tempo da musica aberta e o clique: BPM (que e a velocidade), oitava (½ / ×2), 1.o compasso, volume, e as batidas que o painel de compassos segue.
// O calculo e do `Metro` (nucleo); aqui passa-se ao misturador e grava-se a correcao no servidor (ou na fila offline), com 0.8 s de espera para o slider.
@MainActor @Observable public final class MetronomeViewModel {
    static let defaultVolume = 0.25
    unowned let player: PlayerViewModel
    let stems: StemService
    let library: LibraryViewModel
    let notify: (String) -> Void
    @ObservationIgnored let metro = Metro()
    @ObservationIgnored var saveSoon: Task<Void, Never>?

    init(player: PlayerViewModel, stems: StemService, library: LibraryViewModel, notify: @escaping (String) -> Void) {
        (self.player, self.stems, self.library, self.notify) = (player, stems, library, notify)
    }

    // Quanto se espera por mais um ajuste antes de gravar.
    public var saveDelay: Duration = .milliseconds(800)

    // --- o tempo ---
    public private(set) var map = BeatMap.fixed(bpm: 120, offset: 0, duration: 0)
    public private(set) var bpmText = "120"
    public private(set) var tempoValue = "—"                 // o valor exato, para o «i» ao lado do metronomo
    public private(set) var tempoNote = ""
    // O BPM a que se toca: o da musica vezes a velocidade. Mudar o BPM acelera ou atrasa a musica (sem mudar o tom), como no Moises;
    // a subdivisao (½ / ×2) so muda o clique. A velocidade nao se grava: cada musica abre a 1x.
    public private(set) var bpm = 120.0
    public private(set) var speed = 1.0
    public var bpmRange: ClosedRange<Double> { Double(Tempo.playMin)...max(Double(Tempo.playMax), metro.bpm) }
    public func resetSpeed() { speed = 1; apply() }
    public func setBpm(_ v: Double) {
        speed = min(max(v, bpmRange.lowerBound), bpmRange.upperBound) / metro.bpm
        apply()
    }
    public var isInfoOpen = false

    func load(_ song: Song, duration: Double, tracks: [Track]) {
        speed = 1
        metro.load(song, duration: duration, pcm: (tracks.first { $0.isDrums && !$0.isPart } ?? tracks.first)?.pcm ?? [])
        apply()
    }

    // Passa ao mixer e ao painel o que o metronomo calculou, e ao campo e ao slider o BPM.
    func apply() {
        if player.hasMixer { player.mixer.map = metro.map; player.mixer.rate = speed }
        let shown = metro.bpm * speed
        subdivision = metro.subdivision
        (map, bpm, bpmText, tempoValue, tempoNote) = (metro.map, shown, speed == 1 ? metro.bpmText : String(Int(shown.rounded())), metro.value, metro.note)
    }

    public func bpmDown() { setBpm(bpm.rounded() - 1) }
    public func bpmUp() { setBpm(bpm.rounded() + 1) }
    // A subdivisao do clique (so o clique, nao a musica): -1 = 0.5x, 0 = 1.0x, +1 = 2.0x do tempo detetado. Grava-se no servidor.
    public private(set) var subdivision = 0
    public func setSubdivision(_ s: Int) {
        guard (-1...1).contains(s), s != subdivision, metro.setSubdivision(s) else { return }
        apply()
        scheduleSave()
    }
    public func half() { setSubdivision(subdivision - 1) }
    public func double() { setSubdivision(subdivision + 1) }

    // Marca a posicao atual como o 1.o tempo do 1.o compasso.
    public func markBar() async {
        guard player.hasMixer, player.current != nil else { return }
        metro.mark(player.position)
        apply()
        await save()
    }

    public func openInfo() { isInfoOpen = true }
    public func closeInfo() { isInfoOpen = false }

    func scheduleSave() {
        saveSoon?.cancel()
        saveSoon = Task { [saveDelay] in
            try? await Task.sleep(for: saveDelay)
            if Task.isCancelled { return }
            saveSoon = nil                                         // ja a gravar: o save nao se cancela a si proprio (o cancelamento passava ao pedido de rede)
            await save()
        }
    }

    public func save() async {
        saveSoon?.cancel()
        guard let id = player.current?.id else { return }
        do {
            let (bpm, offset) = metro.fix
            let sent = try await stems.fixTempo(id, bpm: bpm, downbeatOffset: offset)
            notify(sent ? "Tempo guardado" : "Tempo guardado offline: segue quando o servidor voltar")
            await library.refresh()
        } catch { notify("Erro ao guardar o tempo: " + error.localizedDescription) }
    }

    // --- o clique ---
    public private(set) var isOn = false
    public var volume = MetronomeViewModel.defaultVolume { didSet { if player.hasMixer { player.mixer.metroVolume = Float(volume) } } }

    public func toggleClick() {
        let m = player.mixer
        m.metronome.toggle()
        m.metroVolume = Float(volume)
        isOn = m.metronome
        if !isOn { isSolo = false; m.soloClick = false }              // sem clique, o solo seria silencio
        player.tick()
    }

    // Solo no clique: os stems calam-se e so ele se ouve (liga-o se estava desligado).
    public private(set) var isSolo = false
    public func toggleSolo() {
        isSolo.toggle()
        player.mixer.soloClick = isSolo
        if isSolo && !isOn { toggleClick() }
    }

    // --- as batidas (para os pontos e o painel de compassos) ---
    public private(set) var cell = -1.0                       // a celula do painel de compassos em que vai a musica
    public private(set) var beatIndex = -1                    // o ponto aceso (0 a 3): so com o clique ligado e a tocar; -1 nenhum

    func tickBeat() {
        guard player.hasMixer else { return }
        let c = metro.map.cell(player.position)
        let beat = isOn && player.isPlayingNow && c >= 0 ? Int(c) % 4 : -1
        if cell != c { cell = c }                              // so se escreve o que mudou: cada escrita refaz as vistas que o leem
        if beatIndex != beat { beatIndex = beat }
    }

    // Repoe o clique (desligado, volume por omissao) e o tempo (volta ao detetado pelo servidor).
    func reset() async {
        speed = 1
        apply()
        volume = Self.defaultVolume
        if player.hasMixer { player.mixer.metronome = false; player.mixer.soloClick = false; player.mixer.metroVolume = Float(Self.defaultVolume) }
        isOn = false; isSolo = false
        do {
            if let id = player.current?.id {
                let (bpm, off) = try await stems.resetTempo(id)
                metro.reset(bpm: bpm, offset: off)
                apply()
                await library.refresh()
            } else { metro.setBpm(120); apply() }
            notify("Configurações repostas")
        } catch { notify(isOffline(error) ? "Sem servidor: voltar ao tempo detetado precisa de ligação." : "Erro ao repor o tempo: " + error.localizedDescription) }
    }
}
