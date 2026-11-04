import Foundation
import KurzAudio
import KurzCore
import KurzData
import Observation

// O leitor: a musica aberta (as suas faixas e o misturador), o transporte, o volume e o silencio de cada faixa, o ciclo e dividir a bateria.
// A logica e a mesma em todas as plataformas; cada vista desenha as ondas ou as pastilhas e trata do que e so de toque ou de rato.
// O tempo (BPM, compassos, clique) e do `metronome`. As vistas chamam `tick()` a cada 50 ms; o som corre numa thread propria (o Mixer).
@MainActor @Observable public final class PlayerViewModel {
    let stems: StemService
    let loader: SongLoader
    let library: LibraryViewModel
    let makeOut: () -> AudioOut?
    let notify: (String) -> Void
    let words: DeviceWords
    @ObservationIgnored var _mixer: Mixer?
    @ObservationIgnored var opening = false                                      // ja se esta a abrir uma musica: outro toque nao a atropela
    @ObservationIgnored var _metronome: MetronomeViewModel!
    public var metronome: MetronomeViewModel { _metronome }

    // `makeOut`: a saida de som (EngineOut na app; nil nos testes, que so olham para a mistura).
    public init(stems: StemService, library: LibraryViewModel, makeOut: @escaping () -> AudioOut? = { EngineOut() }, notify: @escaping (String) -> Void, words: DeviceWords) {
        (self.stems, self.library, self.makeOut, self.notify, self.words) = (stems, library, makeOut, notify, words)
        loader = SongLoader(stems)
        _metronome = MetronomeViewModel(player: self, stems: stems, library: library, notify: notify)
    }

    // Depois de dividir a bateria, as partes aparecem logo abertas (no iPhone nao ha onde as abrir depois).
    public var expandPartsAfterSplit = false

    // O misturador cria-se quando faz falta (a 1.a musica, ou o clique antes de haver musica).
    var mixer: Mixer {
        if let m = _mixer { return m }
        let m = Mixer(out: makeOut())
        m.metroVolume = Float(metronome.volume)
        m.onEnded = { [weak self] in Task { @MainActor in self?.endedPlaying() } }
        _mixer = m
        return m
    }
    var hasMixer: Bool { _mixer != nil }
    public var position: Double { _mixer?.position ?? 0 }
    public var duration: Double { _mixer?.duration ?? 0 }
    public var isPlayingNow: Bool { _mixer?.playing == true }      // o que o misturador diz agora (isPlaying so muda no tick)

    func endedPlaying() { _mixer?.pause(); tick() }

    // A mistura de agora (volumes, mute e solo; sem o clique) como WAV, para exportar.
    public func renderMix() -> Data { Wav.encode(Mixer.render(tracks)) }

    // O mesmo, para correr fora do fio principal (a mistura de uma musica inteira demora): fixa as faixas de agora.
    public func mixRenderer() -> @Sendable () -> Data { let t = tracks; return { Wav.encode(Mixer.render(t)) } }

    // --- a musica aberta ---
    public private(set) var current: Song? { didSet { library.openId = current?.id } }
    public var hasSong: Bool { current != nil }
    public var hasSections: Bool { !(current?.sections ?? []).isEmpty }
    public private(set) var length = 0.0                     // a duracao da musica aberta (s): so muda ao abrir ou fechar
    public private(set) var tops: [Track] = []               // as faixas de topo; as partes da bateria ficam em Track.parts
    public private(set) var tracks: [Track] = []             // todas, as partes incluidas: o que se ouve e se exporta
    public private(set) var laneRows: [Track] = []           // o que a lista de faixas mostra (uma bateria aberta mostra as suas partes)
    public private(set) var infoText = ""
    public private(set) var isLoading = false
    public private(set) var loadProgress = 0.0

    // Abre a musica a tocar. false se ja se esta a abrir outra, ou se falhou (o motivo fica no aviso).
    public func play(_ song: Song) async -> Bool {
        if opening { return false }
        opening = true
        defer { opening = false }
        do {
            try await load(song)
            try mixer.play()
            tick()
            return true
        } catch {
            notify(isOffline(error) ? "Sem servidor, e esta música ainda não foi guardada neste \(words.place)." : "Erro: " + error.localizedDescription)
            return false
        }
    }

    // Carrega a musica nas faixas, sem tocar. `drums` sobrepoe as partes da bateria (logo a seguir a dividi-la).
    // A barra de carga conta os bytes descarregados e depois o descodificar.
    public func load(_ song: Song, drums: [String]? = nil) async throws {
        loadProgress = 0
        isLoading = true
        defer { isLoading = false }
        _ = mixer                                            // cria a saida e prepara a sessao de audio (em segundo plano) enquanto as faixas carregam: o 1.o "tocar" ja a encontra pronta
        let top = try await loader.load(id: song.id, stems: song.stems, drums: drums ?? song.drums, status: notify, progress: { [self] f in loadProgress = f }, format: song.format)
        tops = top
        tracks = top.flatMap { [$0] + $0.parts }
        current = song
        metroSlot = StemCatalog.metronomeSlot(top.map(\.name), saved: stems.stemOrder)
        showLanes()
        let m = mixer
        m.load(tracks)                                       // o load limpa o ciclo do mixer
        length = m.duration
        showLoop()
        metronome.load(song, duration: m.duration, tracks: tracks)
        infoText = [song.artist, "\(tops.count) stems", song.hiFi ? "Hi-Fi" : nil, Self.fmt(m.duration), song.bpm != nil ? "\(metronome.bpmText) BPM" : nil]
            .compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " · ")
        notify("")
        tick()
    }

    // Para o som, descarrega a musica aberta (ao apagar a musica aberta, ou ao sair da conta).
    public func close() {
        _mixer?.pause()
        _mixer?.load([])
        loopMark = nil
        tops = []; tracks = []; laneRows = []
        infoText = ""
        current = nil
        length = 0
        showLoop()
        tick()
    }

    // --- transporte ---
    public private(set) var isPlaying = false
    public private(set) var progress = 0.0                   // 0...1
    public private(set) var elapsed = "0:00"
    public private(set) var total = "0:00"
    public private(set) var remaining = "-0:00"
    public private(set) var isScrubbing = false              // o dedo esta na barra de posicao: o tick nao a mexe

    public static func fmt(_ s: Double) -> String { "\(Int(s) / 60):" + String(format: "%02d", Int(s) % 60) }

    public func tick() {
        guard let m = _mixer else { return }
        // @Observable avisa as vistas a cada escrita, mesmo com o mesmo valor: a 20 Hz so se escreve o que mudou (o texto dos tempos muda 1 vez por segundo).
        func put<T: Equatable>(_ p: ReferenceWritableKeyPath<PlayerViewModel, T>, _ v: T) { if self[keyPath: p] != v { self[keyPath: p] = v } }
        put(\.isPlaying, m.playing)
        let pos = m.position, dur = m.duration, f = dur > 0 ? pos / dur : 0
        put(\.total, Self.fmt(dur))
        if !isScrubbing {
            put(\.progress, f)
            put(\.elapsed, Self.fmt(pos))
            put(\.remaining, "-" + Self.fmt(max(0, dur - pos)))
        }
        for t in tracks where t.progress != f { t.progress = f }   // a parte ja tocada das ondas
        metronome.tickBeat()
    }

    public func togglePlay() {
        do {
            let m = mixer
            if m.playing { m.pause() } else { try m.play() }
        } catch { notify("Erro de áudio: " + error.localizedDescription) }
        tick()
    }

    // Anterior: recomeca a musica se ja vai adiantada (>3 s), senao volta a anterior. Seguinte: proxima separada.
    public func previous() async {
        if let m = _mixer, m.position > 3 { m.seek(0); tick(); return }
        guard let prev = Playlist.neighbour(library.shown, from: current?.id, step: -1) else { _mixer?.seek(0); tick(); return }
        _ = await library.openOrFetch(prev, force: true)
    }

    public func next() async {
        if let n = Playlist.neighbour(library.shown, from: current?.id, step: +1) { _ = await library.openOrFetch(n, force: true) }
    }

    public func seek(_ fraction: Double) {
        guard let m = _mixer else { return }
        m.seek(min(max(fraction, 0), 1) * m.duration)
        tick()
    }

    // Salta para o inicio do compasso `b` (0 = o 1.o).
    public func seekBar(_ b: Int) {
        guard let m = _mixer else { return }
        m.seek(metronome.map.barStart(b))
        tick()
    }

    // Arrastar a barra de posicao mostra onde vai cair e so salta ao largar.
    public func beginScrub(_ fraction: Double) { isScrubbing = true; preview(fraction) }
    public func preview(_ f: Double) {
        progress = f
        guard let m = _mixer else { return }
        elapsed = Self.fmt(f * m.duration)
        remaining = "-" + Self.fmt(max(0, m.duration - f * m.duration))
    }
    public func endScrub(_ fraction: Double) { guard isScrubbing else { return }; isScrubbing = false; seek(fraction) }
    public func cancelScrub() { isScrubbing = false }

    // --- faixas ---
    public func toggleMute(_ t: Track) { t.muted.toggle(); refreshDim() }
    public func toggleSolo(_ t: Track) { t.solo.toggle(); refreshDim() }
    public func toggleExpanded(_ t: Track) { t.expanded.toggle(); showLanes() }
    func refreshDim() { let any = tracks.contains { $0.solo }; for t in tracks { t.refresh(anySolo: any) } }
    func showLanes() {
        laneRows = Lanes.rows(tops)
        metroRow = tops.prefix(metroSlot).reduce(0) { $0 + 1 + ($1.expanded ? $1.parts.count : 0) }
    }

    // O metronomo e uma faixa como as outras na ordem: `metroSlot` e quantas faixas de topo vem antes dele, `metroRow` o mesmo em linhas de
    // `laneRows` (uma bateria aberta conta com as suas partes).
    public private(set) var metroSlot = 0
    public private(set) var metroRow = 0

    // As faixas de topo e o metronomo, na ordem em que se mostram: o que "Ordenar as faixas" mexe.
    public var order: [String] { var n = tops.map(\.name); n.insert(StemCatalog.metronome, at: min(metroSlot, n.count)); return n }

    // Poe as faixas de topo e o metronomo nesta ordem (as partes da bateria vao com a sua faixa) e guarda-a no aparelho como a de todas as
    // musicas; o que esta musica nao tem (stems) fica a seguir na ordem guardada.
    public func reorder(_ names: [String]) {
        guard let m = names.firstIndex(of: StemCatalog.metronome) else { return }
        tops.sort { (names.firstIndex(of: $0.name) ?? .max) < (names.firstIndex(of: $1.name) ?? .max) }
        tracks = tops.flatMap { [$0] + $0.parts }
        metroSlot = min(m, tops.count)
        showLanes()
        stems.stemOrder = names + stems.stemOrder.filter { !names.contains($0) }
    }

    // --- repetir trecho ---
    // Mac e iPad: arrasta-se sobre as ondas. iPhone: o 1.o toque marca o inicio, o 2.o o fim (e repete-o), o 3.o sai.
    public private(set) var isLooping = false
    public private(set) var loopStart = 0.0                  // fracoes 0...1 (so o inicio marcado: um risco)
    public private(set) var loopEnd = 0.0
    public private(set) var loopMark: Double?                // o inicio marcado (s) enquanto falta o fim
    public var isLoopActive: Bool { isLooping || loopMark != nil }

    public func setLoop(_ startFraction: Double, _ endFraction: Double) {
        guard let m = _mixer else { return }
        let d = m.duration, start = min(startFraction, endFraction) * d, end = max(startFraction, endFraction) * d
        m.setLoop(start, end)                                // trechos demasiado curtos nao ficam (ver Mixer.setLoop)
        if m.looping { m.seek(start) }
        showLoop(start / d, end / d)
        tick()
    }

    public func clearLoop() { _mixer?.clearLoop(); loopMark = nil; showLoop() }

    public func toggleLoopMark() {
        guard let m = _mixer else { return }
        if m.looping { clearLoop(); notify("Repetição desligada"); return }
        if loopMark != nil { closeLoop(m); return }
        loopMark = m.position
        showLoop()
        notify("Início marcado. Toque outra vez no fim do trecho")
    }

    func closeLoop(_ m: Mixer) {
        let a = loopMark!, b = m.position
        loopMark = nil
        m.setLoop(min(a, b), max(a, b))
        guard m.looping else { showLoop(); notify("Trecho demasiado curto"); return }
        m.seek(min(a, b))
        showLoop(min(a, b) / m.duration, max(a, b) / m.duration)
        notify("A repetir o trecho. Toque outra vez para sair")
        tick()
    }

    func showLoop(_ start: Double = 0, _ end: Double = 0) {
        let on = _mixer?.looping == true, d = _mixer?.duration ?? 0
        isLooping = on
        (loopStart, loopEnd) = on ? (start, end) : loopMark.map { d > 0 ? ($0 / d, $0 / d + 0.004) : (0, 0) } ?? (0, 0)
    }

    // --- bateria e repor ---
    public private(set) var isSplitting = false

    // Divide a bateria da musica aberta (ja processada) e recarrega-a, mantendo a posicao.
    public func splitDrums() async {
        guard let song = current, let m = _mixer, !isSplitting else { return }
        guard stems.online else { notify("Sem servidor: dividir a bateria precisa de ligação."); return }
        isSplitting = true                                   // a divisao demora e nao pode ser pedida duas vezes
        defer { isSplitting = false }
        do {
            let pos = m.position, was = m.playing
            m.pause()
            let parts = try await stems.splitDrums(song.id, status: { [notify] s in Task { @MainActor in notify(s) } })
            await library.refresh()
            try await load(library.songs.first { $0.id == song.id } ?? song, drums: parts)
            if expandPartsAfterSplit { for t in tops where t.hasParts { t.expanded = true }; showLanes() }
            m.seek(pos)
            if was { try m.play() }
            notify("Bateria dividida")
            tick()
        } catch { notify("Erro: " + error.localizedDescription) }
    }

    // Repoe tudo o que o utilizador mexeu: volumes, mute e solo, ciclo, metronomo e o tempo (volta ao detetado pelo servidor).
    public func resetAll() async {
        for t in tracks { t.reset() }
        refreshDim()
        clearLoop()
        await metronome.reset()
        tick()
    }
}
