import KurzCore
import KurzPresentation
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
// O iPhone: a biblioteca (com o mini-leitor por baixo) e, ao abrir uma musica, o leitor por cima. Sem ondas: so as pastilhas dos stems.
struct PhoneView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var nav = app.nav
        NavigationStack {
            LibraryView()
                .safeAreaInset(edge: .bottom, spacing: 0) { if app.player.hasSong { MiniPlayer() } }
                .navigationDestination(isPresented: $nav.showingPlayer) { PlayerScreen() }
                .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct MiniPlayer: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let p = app.player
        HStack(spacing: 12) {
            Button { app.nav.showingPlayer = true } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8).fill(K.surface2).frame(width: 40, height: 40).overlay(Image(systemName: "waveform").foregroundStyle(K.accent))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.current?.displayTitle ?? "").font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Text("\(p.elapsed) / \(p.total)").font(K.mono).foregroundStyle(K.textDim)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            IconButton(system: p.isPlaying ? "pause.fill" : "play.fill", label: p.isPlaying ? "Pausar" : "Tocar", size: 44, tint: K.accent) { p.togglePlay() }
        }
        .padding(.horizontal, 16).padding(.vertical, 8).background(.ultraThinMaterial).overlay(alignment: .top) { Rectangle().fill(K.border).frame(height: 1) }
    }
}

struct PlayerScreen: View {
    @Environment(AppModel.self) private var app
    @State private var showBars = false                    // a aba dos compassos em vez da dos stems
    @State private var showCamera = false
    @State private var showMetronome = false               // a folha do metronomo: abre pelo botao de baixo e pelo nome da faixa

    // A aba dos stems: o titulo, uma faixa por stem, o metronomo e o tempo.
    private var stems: some View {
        let p = app.player
        return ScrollView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.current?.displayTitle ?? "").font(.system(size: 20, weight: .semibold)).lineLimit(2)
                    Text(p.infoText).font(.system(size: 13)).foregroundStyle(K.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                ForEach(p.laneRows, id: \.name) { track in
                    LaneControls(track: track).overlay(alignment: .bottom) { Rectangle().fill(K.line).frame(height: 1) }
                }
                MetronomeLane(open: { showMetronome = true }).overlay(alignment: .bottom) { Rectangle().fill(K.line).frame(height: 1) }
            }
        }
    }

    var body: some View {
        @Bindable var app = app
        let p = app.player
        Group { if showBars { BarsTab() } else { stems } }
        .background(K.backdrop.ignoresSafeArea())
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Filmar enquanto toca", systemImage: "video") { showCamera = true }
                SongMenu()
            }
        }
        .cameraCover(isPresented: $showCamera)
        .sheet(isPresented: $showMetronome) { MetronomeSheet() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBottomBar(showBars: $showBars, openMetronome: { showMetronome = true })
        }
        .onChange(of: p.hasSong) { if !p.hasSong { app.nav.showingPlayer = false } }
        .fileExporter(isPresented: $app.isExporting, document: app.mix, contentType: .wav, defaultFilename: Song.safeFileName((p.current?.displayTitle ?? "Mistura") + " - Mistura")) { _ in }
    }
}

// A faixa do metronomo, como as dos stems: volume, M (ligado = clique calado; tocar liga-o) e S (so o clique). Tocar no nome abre a folha com o BPM.
struct MetronomeLane: View {
    @Environment(AppModel.self) private var app
    let open: () -> Void
    var body: some View {
        @Bindable var m = app.player.metronome
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: "metronome").font(.system(size: 16, weight: .medium)).frame(width: 22)
                    Text("Metrónomo").font(.system(size: 14))
                    Text("\(m.bpmText) BPM").font(K.mono).foregroundStyle(K.textDim)
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(K.textDim)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Configurar o metrónomo: \(m.bpmText) BPM")
            HStack(spacing: 8) {
                Slider(value: $m.volume, in: 0...1).tint(K.accent).accessibilityLabel("Volume do clique")
                ChipButton(text: "M", label: m.isOn ? "Silenciar o metrónomo" : "Ligar o metrónomo", on: !m.isOn, tint: K.danger) { m.toggleClick() }
                ChipButton(text: "S", label: "Solo no metrónomo", on: m.isSolo) { m.toggleSolo() }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8).background(K.laneHead)
    }
}

#endif
