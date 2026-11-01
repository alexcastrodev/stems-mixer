import KurzCore
import KurzPresentation
import SwiftUI

// A biblioteca: o selo do servidor, quantas musicas, pesquisa, ordem e a lista. E a mesma no Mac, no iPad e no iPhone.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var searching = false

    var body: some View {
        @Bindable var library = app.library
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Logo().frame(width: 28, height: 28)
                Text("Kurz Music").font(.system(size: 18, weight: .semibold))
                Spacer()
                ServerBadge()
            }
            .padding(.horizontal, 16).padding(.top, 12)

            HStack {
                IconButton(system: "line.3.horizontal.decrease", label: "Pesquisar", on: searching) { searching.toggle() }
                Text(library.countText).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { library.cycleSort() } label: { Text(library.sortText).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 8).frame(minHeight: 36) }
                    .buttonStyle(.plain).accessibilityLabel("Mudar a ordem")
                IconButton(system: "plus", label: "Importar música", tint: K.accentText) { app.importer.open() }
            }
            .padding(.horizontal, 12).padding(.top, 8)

            if searching {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(K.textDim)
                    TextField("Pesquisar músicas…", text: $library.search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).frame(height: 36).background(K.surface, in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 16).padding(.top, 4)
            }

            if library.rows.isEmpty {
                ContentUnavailableView(library.search.isEmpty ? "Sem músicas" : "Nada encontrado", systemImage: "waveform",
                                       description: Text(library.search.isEmpty ? "Toque em + para importar uma música." : "Nenhuma música tem este nome."))
                    .foregroundStyle(K.textDim)
            } else {
                List(library.rows) { row in
                    SongRowView(row: row)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 8))
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
    }
}

struct SongRowView: View {
    @Environment(AppModel.self) private var app
    let row: SongRow

    var body: some View {
        HStack(spacing: 8) {
            Button { app.open(row.song) } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 12).fill(K.surface2).frame(width: 52, height: 52)
                        .overlay(Image(systemName: "waveform").font(.system(size: 22)).foregroundStyle(K.accent))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(row.title).font(.system(size: 16, weight: .medium)).foregroundStyle(row.current ? K.accent : K.text).lineLimit(1)
                            if row.song.hiFi && row.song.isDone { Pill(text: "Hi-Fi", tint: K.accent) }
                        }
                        if row.inStep { StepPill(row: row) }
                        else { Text(row.sub).font(.system(size: 13)).foregroundStyle(K.textDim).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 6) {
                            if row.current { Image(systemName: "waveform.path").foregroundStyle(K.accent) }
                            if row.song.isDone { Image(systemName: "checkmark.circle.fill").foregroundStyle(K.done).accessibilityLabel("Separada") }
                            if row.song.isError { Pill(text: row.song.statusLabel, tint: K.danger) }
                        }
                        Text(row.song.length).font(K.mono).foregroundStyle(K.textDim)
                    }
                }
                .contentShape(Rectangle()).opacity(row.opacity)
            }
            .buttonStyle(.plain)

            Menu {
                if row.song.isDone {
                    switch row.state {
                    case .downloading: Button("Cancelar a descarga", systemImage: "xmark.circle") { app.library.toggleDownload(row) }
                    case .saved: Button("Remover do \(Platform.words.place)", systemImage: "trash.slash") { app.library.toggleDownload(row) }
                    case .none: Button("Guardar no \(Platform.words.place)", systemImage: "arrow.down.circle") { app.library.toggleDownload(row) }
                    }
                }
                if !row.song.isBusy { Button("Apagar", systemImage: "trash", role: .destructive) { app.library.askDelete(row.song) } }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 18)).foregroundStyle(K.textDim).frame(width: 36, height: 44).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Mais opções")
        }
    }
}

// Os 3 passos de uma musica nova, cada um com a sua cor: 1 enviar (azul), 2 separar (ambar), 3 descarregar (roxo).
struct StepPill: View {
    let row: SongRow
    var body: some View {
        let (icon, tint): (String, Color) = switch row.step {
        case .upload: ("arrow.up.circle.fill", Color(hex: "#7bbcff"))
        case .separate: ("waveform.path.ecg", Color(hex: "#f5b942"))
        default: ("arrow.down.circle.fill", Color(hex: "#b48cff"))
        }
        Pill(text: row.stepText, system: icon, tint: tint)
    }
}

// O selo do servidor: o estado numa pilula; tocar abre o convite ou a conta.
struct ServerBadge: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let a = app.account
        Button { a.openBadge() } label: {
            Pill(text: a.badgeShortText, system: a.badgeIcon, tint: a.isOnline ? K.done : a.isBad ? K.danger : K.textDim).frame(maxWidth: 190)
        }
        .buttonStyle(.plain).help(a.badgeTip).accessibilityLabel(a.badgeTip)
    }
}

// A marca: uma barra e um triangulo, como no icone.
struct Logo: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 64
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: 64 * s, height: 64 * s), cornerRadius: 15 * s), with: .color(K.bg))
            ctx.stroke(Path(roundedRect: CGRect(x: 0.75 * s, y: 0.75 * s, width: 62.5 * s, height: 62.5 * s), cornerRadius: 14 * s), with: .color(K.border), lineWidth: 1.5 * s)
            ctx.fill(Path(roundedRect: CGRect(x: 14 * s, y: 13 * s, width: 10 * s, height: 38 * s), cornerRadius: 2.5 * s), with: .color(K.text))
            var low = Path(); low.move(to: CGPoint(x: 27 * s, y: 32 * s)); low.addLine(to: CGPoint(x: 38.5 * s, y: 32 * s)); low.addLine(to: CGPoint(x: 52 * s, y: 51 * s)); low.addLine(to: CGPoint(x: 40.5 * s, y: 51 * s)); low.closeSubpath()
            var high = Path(); high.move(to: CGPoint(x: 27 * s, y: 32 * s)); high.addLine(to: CGPoint(x: 40.5 * s, y: 13 * s)); high.addLine(to: CGPoint(x: 52 * s, y: 13 * s)); high.addLine(to: CGPoint(x: 38.5 * s, y: 32 * s)); high.closeSubpath()
            ctx.fill(low, with: .color(Color(hex: "#1f8f8b"))); ctx.fill(high, with: .color(Color(hex: "#2fa9a5")))
        }
    }
}
