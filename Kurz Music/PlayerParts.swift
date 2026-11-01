import KurzCore
import KurzPresentation
import SwiftUI

// O cabecalho de uma faixa: nome, volume, silencio (M) e solo (S). Uma bateria dividida abre-se para mostrar as suas partes.
struct LaneControls: View {
    @Environment(AppModel.self) private var app
    @Bindable var track: Track

    // O simbolo do instrumento (pelo nome com que o stem se mostra).
    static func icon(_ name: String) -> String {
        ["Vocais": "music.mic", "Bateria": "cylinder", "Guitarras": "guitars", "Baixo": "waveform.low", "Piano": "pianokeys"][name] ?? "music.note"
    }

    var body: some View {
        let p = app.player
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if track.hasParts {
                    IconButton(system: "chevron.right", label: track.expanded ? "Fechar as partes" : "Abrir as partes", size: 24) { p.toggleExpanded(track) }
                        .rotationEffect(.degrees(track.expanded ? 90 : 0))
                }
                if track.isPart { Image(systemName: "arrow.turn.down.right").foregroundStyle(K.textDim).font(.system(size: 13)) }
                if !track.isPart { Image(systemName: Self.icon(track.name)).font(.system(size: 16, weight: .medium)).frame(width: 22) }
                Text(track.name).font(.system(size: 14)).lineLimit(1)
                Spacer(minLength: 0)
                if track.canSplit {
                    Button { Task { await p.splitDrums() } } label: { Text(p.isSplitting ? "A dividir…" : "Dividir").font(.system(size: 11)) }
                        .buttonStyle(OutlineButtonStyle()).controlSize(.small).disabled(p.isSplitting).help("Dividir a bateria em bombo, caixa, hi-hat, tons e pratos")
                }
            }
            HStack(spacing: 8) {
                Slider(value: $track.volume, in: 0...1.5).tint(K.accent).accessibilityLabel("Volume de \(track.name)")
                ChipButton(text: "M", label: "Silenciar \(track.name)", on: track.muted, tint: K.danger) { p.toggleMute(track) }
                ChipButton(text: "S", label: "Solo em \(track.name)", on: track.solo) { p.toggleSolo(track) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(track.isPart ? K.laneSub : K.laneHead)
        .overlay(alignment: .leading) { if track.isPart { Rectangle().fill(Color(hex: track.lane)).frame(width: 4) } }
    }
}

// Anterior, tocar/pausar, seguinte, a barra de posicao e os tempos.
struct PlaybackRow: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let p = app.player
        HStack(spacing: 10) {
            IconButton(system: "backward.fill", label: "Anterior") { Task { await p.previous() } }
            Button { p.togglePlay() } label: {
                Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 20)).foregroundStyle(K.onAccent).frame(width: 44, height: 44).background(K.accent, in: Circle())
            }
            .buttonStyle(.plain).keyboardShortcut(.space, modifiers: []).accessibilityLabel(p.isPlaying ? "Pausar" : "Tocar")
            IconButton(system: "forward.fill", label: "Seguinte") { Task { await p.next() } }
            Text(p.elapsed).font(K.mono).foregroundStyle(K.textDim).frame(width: 40, alignment: .trailing)
            Slider(value: Binding(get: { p.progress }, set: { p.preview($0) }), in: 0...1) { editing in
                if editing { p.beginScrub(p.progress) } else { p.endScrub(p.progress) }
            }
            .tint(K.accent).frame(minWidth: 120).accessibilityLabel("Posição")
            Text(p.total).font(K.mono).foregroundStyle(K.textDim).frame(width: 40, alignment: .leading)
        }
    }
}

// O menu "…" da musica aberta: exportar a mistura, repor tudo e apagar.
struct SongMenu: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Menu("Mais", systemImage: "ellipsis") {
            Button("Exportar a mistura (WAV)", systemImage: "square.and.arrow.down") { app.exportMix() }
            Button("Repor volumes, solo, repetição e tempo", systemImage: "arrow.counterclockwise") { Task { await app.player.resetAll() } }
            Button("Apagar a música", systemImage: "trash", role: .destructive) { app.library.askDeleteOpen() }
        }
    }
}

// O fundo do leitor em todas as plataformas: o player por cima das abas de vidro (que ficam no fundo).
struct PlayerBottomBar: View {
    @Binding var showBars: Bool
    let openMetronome: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            PhonePlayer(openMetronome: openMetronome).frame(maxWidth: 640)                      // no iPad nao estica pela largura toda
                .padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity)
                .background(.ultraThinMaterial).overlay(alignment: .top) { Rectangle().fill(K.border).frame(height: 1) }
            PlayerTabs(showBars: $showBars).frame(maxWidth: 420).padding(.horizontal, 16).padding(.top, 8)
        }
    }
}

// As abas do fundo, em liquid glass: a escolhida acende com um vidro tingido.
struct PlayerTabs: View {
    @Binding var showBars: Bool
    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 4) {
                tab("Stems", "slider.horizontal.3", bars: false)
                tab("Compassos", "square.grid.2x2", bars: true)
            }
            .padding(4).glassEffect(.regular, in: Capsule())
        }
    }

    private func tab(_ title: String, _ icon: String, bars: Bool) -> some View {
        let on = showBars == bars
        return Button { showBars = bars } label: {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(on ? K.accentText : K.textDim)
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Capsule())
        }
        .buttonStyle(.plain).glassEffect(on ? .regular.tint(K.accent.opacity(0.35)).interactive() : .identity, in: Capsule())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// O player do iPhone: a barra de posicao com os tempos por baixo e, por baixo, metronomo (abre a folha), anterior, tocar, seguinte e repetir.
struct PhonePlayer: View {
    @Environment(AppModel.self) private var app
    let openMetronome: () -> Void
    var body: some View {
        let p = app.player, m = p.metronome
        VStack(spacing: 6) {
            Slider(value: Binding(get: { p.progress }, set: { p.preview($0) }), in: 0...1) { editing in
                if editing { p.beginScrub(p.progress) } else { p.endScrub(p.progress) }
            }
            .tint(K.accent).accessibilityLabel("Posição")
            HStack { Text(p.elapsed); Spacer(); Text(p.remaining) }.font(K.mono).foregroundStyle(K.textDim)
            HStack {
                IconButton(system: "metronome", label: "Configurar o metrónomo", size: 48, on: m.isOn, action: openMetronome)
                Spacer()
                IconButton(system: "backward.fill", label: "Anterior", size: 56) { Task { await p.previous() } }
                Button { p.togglePlay() } label: {
                    Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30)).foregroundStyle(K.onAccent).frame(width: 64, height: 64).background(K.accent, in: Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.space, modifiers: []).accessibilityLabel(p.isPlaying ? "Pausar" : "Tocar")
                IconButton(system: "forward.fill", label: "Seguinte", size: 56) { Task { await p.next() } }
                Spacer()
                IconButton(system: "repeat", label: "Marcar o trecho a repetir", size: 48, on: p.isLoopActive) { p.toggleLoopMark() }
            }
        }
    }
}
