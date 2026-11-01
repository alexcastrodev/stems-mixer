import KurzCore
import KurzPresentation
import SwiftUI
import UniformTypeIdentifiers

// O Mac e o iPad: a biblioteca ao lado e, a direita, as ondas de cada stem, as seccoes, o metronomo e o transporte.
struct StudioView: View {
    @Environment(AppModel.self) private var app
    @State private var visibility = NavigationSplitViewVisibility.all

    var body: some View {
        GeometryReader { geo in
            NavigationSplitView(columnVisibility: $visibility) {
                LibraryView().navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460).background(K.bg)
            } detail: {
                Group { if app.player.hasSong { StudioDetail() } else { ContentUnavailableView("Escolha uma música", systemImage: "waveform", description: Text("As músicas separadas abrem aqui, com uma onda por stem.")).foregroundStyle(K.textDim).navigationTitle("") } }   // sem titulo: o por omissao (nome da app) ficava por cima de tudo
                    .background(K.bg)
            }
            .navigationSplitViewStyle(.balanced)
            .onChange(of: app.player.current?.id) { if app.player.hasSong && geo.size.width < 900 { visibility = .detailOnly } }   // ecra estreito: a biblioteca sai da frente
        }
    }
}

struct StudioDetail: View {
    @Environment(AppModel.self) private var app
    @State private var showBars = false
    @State private var showMetronome = false
    @State private var showCamera = false
    static let head: CGFloat = 280

    // As ondas: uma faixa por stem (cabeca + onda), a tira de seccoes e a faixa do metronomo.
    private var lanes: some View {
        let p = app.player
        return ScrollView {
            VStack(spacing: 0) {
                if p.hasSections {
                    HStack(spacing: 0) {
                        Text("Seções").font(.system(size: 13)).foregroundStyle(K.textDim).padding(.horizontal, 16).frame(width: Self.head, alignment: .leading)
                        SectionStrip(sections: p.current?.sections ?? [], duration: p.length)
                    }
                    .frame(height: 32).background(K.laneHead).overlay(alignment: .bottom) { Rectangle().fill(K.line).frame(height: 1) }
                }
                ForEach(p.laneRows, id: \.name) { track in
                    HStack(spacing: 0) {
                        LaneControls(track: track).frame(width: Self.head)
                        WaveformView(track: track)
                    }
                    .frame(height: 84).overlay(alignment: .bottom) { Rectangle().fill(K.line).frame(height: 1) }
                }
                HStack(spacing: 0) {
                    MetronomeLaneHead(open: { showMetronome = true }).frame(width: Self.head)
                    BeatGridView()
                }
                .frame(height: 80)
            }
            .overlay { LoopBand(start: p.loopStart, end: p.loopEnd).padding(.leading, Self.head) }
        }
    }

    var body: some View {
        @Bindable var app = app
        let p = app.player
        VStack(spacing: 0) {
            if showBars { BarsTab().frame(maxWidth: 720).frame(maxWidth: .infinity) } else { lanes }
            PlayerBottomBar(showBars: $showBars, openMetronome: { showMetronome = true })
        }
        // A musica e os botoes vivem na barra do titulo da janela (no iPad, na barra de navegacao; la o subtitulo nao existe, fica por baixo do titulo).
        #if os(macOS)
        .navigationTitle(p.current?.displayTitle ?? "").navigationSubtitle(p.infoText)
        #else
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { VStack(spacing: 0) { Text(p.current?.displayTitle ?? "").font(.headline).lineLimit(1); Text(p.infoText).font(.caption).foregroundStyle(K.textDim).lineLimit(1) } } }
        #endif
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { Button("Filmar enquanto toca", systemImage: "video") { showCamera = true }; SongMenu() } }
        .cameraCover(isPresented: $showCamera)
        .sheet(isPresented: $showMetronome) { MetronomeSheet() }
        .fileExporter(isPresented: $app.isExporting, document: app.mix, contentType: .wav, defaultFilename: Song.safeFileName((p.current?.displayTitle ?? "Mistura") + " - Mistura")) { _ in }
    }
}

// A cabeca da faixa do metronomo: o volume do clique, M (cala o clique), S (so o clique) e o nome, que abre a folha com o BPM e a subdivisao.
struct MetronomeLaneHead: View {
    @Environment(AppModel.self) private var app
    let open: () -> Void
    var body: some View {
        @Bindable var m = app.player.metronome
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
                HStack(spacing: 6) {
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
                ChipButton(text: "M", label: m.isOn ? "Silenciar o clique" : "Ligar o clique", on: !m.isOn, tint: K.danger) { m.toggleClick() }
                ChipButton(text: "S", label: "Solo no metrónomo", on: m.isSolo) { m.toggleSolo() }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxHeight: .infinity).background(K.laneHead)
    }
}
