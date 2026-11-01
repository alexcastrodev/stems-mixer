import KurzCore
import KurzPresentation
import SwiftUI
import UniformTypeIdentifiers

// Um painel: titulo, conteudo e botoes. Em folha no iPhone/iPad e em janela no Mac.
struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 20, weight: .semibold))
                content
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(K.bg).foregroundStyle(K.text)
        #if os(macOS)
        .frame(width: 460).frame(minHeight: 240)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}

struct ImportSheet: View {
    @Environment(AppModel.self) private var app
    @State private var picking = false
    @State private var dropping = false

    var body: some View {
        @Bindable var importer = app.importer
        Panel(title: "Importar música") {
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 34)).foregroundStyle(K.accent)
                #if os(macOS)
                Text("Arraste os arquivos de áudio para aqui")
                #endif
                Button("Escolher arquivos") { picking = true }.buttonStyle(OutlineButtonStyle())
                Text("MP3, WAV, FLAC, M4A, OGG, AAC ou MP4").font(.system(size: 11)).foregroundStyle(K.textDim)
            }
            .frame(maxWidth: .infinity).padding(20)
            .background(dropping ? K.accentWash : K.surface, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(K.borderStrong))
            .dropDestination(for: URL.self, action: { urls, _ in importer.add(Platform.pick(urls)); return true }, isTargeted: { dropping = $0 })

            ForEach(importer.pending) { f in
                HStack(spacing: 10) {
                    Image(systemName: "music.note").foregroundStyle(K.accent)
                    Text(f.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    IconButton(system: "xmark", label: "Remover", size: 28) { importer.remove(f) }
                }
            }

            Text("Como separar").fontWeight(.semibold)
            ForEach([(ImportViewModel.fast, "Rápido", "Voz, bateria, baixo e outros. O mais rápido."),
                     (ImportViewModel.quality, "Qualidade", "Os mesmos 4 stems, melhor resultado. Cerca de 4 vezes mais lento."),
                     (ImportViewModel.full, "Completo (recomendado)", "6 stems: separa também guitarra e piano. O piano sai com ruído; a guitarra é razoável.")], id: \.0) { model, name, hint in
                Button { importer.model = model } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: importer.model == model ? "largecircle.fill.circle" : "circle").foregroundStyle(importer.model == model ? K.accent : K.textDim)
                        VStack(alignment: .leading, spacing: 2) { Text(name); Text(hint).font(.system(size: 11)).foregroundStyle(K.textDim).multilineTextAlignment(.leading) }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Toggle(isOn: $importer.hiFi) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hi-Fi")
                    Text("Ligado: sem perdas (FLAC), o mesmo som do original, cerca de 3 vezes mais leve que o WAV. Desligado: otimizado (Opus 96 kbps), cerca de 13 vezes mais leve, com uma pequena perda.")
                        .font(.system(size: 11)).foregroundStyle(K.textDim)
                }
            }
            .tint(K.accent)
            Toggle(isOn: $importer.drums) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dividir a bateria (demora mais)")
                    Text("Bombo, caixa, hi-hat, tons e pratos. Pode também fazer-se depois.").font(.system(size: 11)).foregroundStyle(K.textDim)
                }
            }
            .tint(K.accent)

            HStack {
                Text(importer.hint).font(.system(size: 12)).foregroundStyle(K.textDim)
                Spacer()
                Button("Cancelar") { importer.close() }.buttonStyle(OutlineButtonStyle())
                Button(importer.startText) { Task { await importer.start() } }.buttonStyle(PrimaryButtonStyle()).disabled(!importer.canStart).opacity(importer.canStart ? 1 : 0.5)
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.audio, .mpeg4Movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importer.add(Platform.pick(urls)) }
        }
    }
}

struct InviteSheet: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var a = app.account
        Panel(title: "Convite") {
            Text("Cole o código de convite da sua conta para entrar no servidor.").foregroundStyle(K.textDim)
            HStack(spacing: 8) {
                TextField("Código de convite", text: $a.inviteCode).textFieldStyle(.roundedBorder).autocorrectionDisabledCompat().onSubmit { Task { await a.submitInvite() } }
                Button { a.pasteInvite(Platform.clipboard()) } label: { Label("Colar", systemImage: "doc.on.clipboard") }.buttonStyle(OutlineButtonStyle())
            }
            if let e = a.inviteError { Text(e).foregroundStyle(K.errorText) }
            Text("Peça o convite a quem administra o servidor.").font(.system(size: 11)).foregroundStyle(K.textDim)
            HStack {
                Spacer()
                Button("Cancelar") { a.cancelInvite() }.buttonStyle(OutlineButtonStyle())
                Button("Entrar") { Task { await a.submitInvite() } }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

struct AccountSheet: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var a = app.account
        Panel(title: "Servidor") {
            Text(a.statusText)
            if a.canEditName {
                Divider()
                Text("Nome da conta").fontWeight(.medium)
                Text("Só serve para reconhecer a conta; quem a identifica é o convite.").font(.system(size: 11)).foregroundStyle(K.textDim)
                HStack(spacing: 8) {
                    TextField("Nome", text: $a.nameDraft).textFieldStyle(.roundedBorder).onSubmit { Task { await a.saveName() } }
                    Button("Guardar") { Task { await a.saveName() } }.buttonStyle(OutlineButtonStyle())
                }
                if let e = a.nameError { Text(e).foregroundStyle(K.errorText) }
            }
            Divider()
            Button("Sair") { a.logout() }.buttonStyle(OutlineButtonStyle()).disabled(!a.canLogout)
            Text(a.logoutHint).font(.system(size: 11)).foregroundStyle(K.textDim)
            HStack { Spacer(); Button("Fechar") { a.closeAccount() }.buttonStyle(OutlineButtonStyle()) }
        }
    }
}

struct TempoSheet: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let m = app.player.metronome
        Panel(title: "Tempo avaliado") {
            Text(m.tempoValue).font(.system(size: 32, weight: .medium, design: .monospaced))
            Text(m.tempoNote).foregroundStyle(K.textDim)
            HStack { Spacer(); Button("Fechar") { m.closeInfo() }.buttonStyle(OutlineButtonStyle()) }
        }
    }
}

// A configuracao do metronomo no iPhone, em blocos grandes: ligar, subdivisao (so o clique), BPM (a velocidade da musica) e o compasso 1.
// O volume, o M e o S ficam na faixa dos stems.
struct MetronomeSheet: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let m = app.player.metronome
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("Metrónomo").font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Toggle("Ligar o clique", isOn: Binding(get: { m.isOn }, set: { _ in m.toggleClick() })).labelsHidden().tint(K.accent).scaleEffect(1.15)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Subdivisão").font(.system(size: 15)).foregroundStyle(K.textDim)
                    HStack(spacing: 10) {
                        ForEach([(-1, "0.5x"), (0, "1.0x"), (1, "2.0x")], id: \.0) { step, text in
                            Button { m.setSubdivision(step) } label: {
                                Text(text).font(.system(size: 18, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 56)
                                    .foregroundStyle(m.subdivision == step ? K.onAccent : K.text)
                                    .background(m.subdivision == step ? K.accent : K.surface2, in: Capsule())
                            }
                            .buttonStyle(.plain).accessibilityLabel("Subdivisão \(text)").accessibilityAddTraits(m.subdivision == step ? .isSelected : [])
                        }
                    }
                }

                Rectangle().fill(K.line).frame(height: 1)

                VStack(spacing: 14) {
                    HStack(spacing: 24) {
                        stepButton("minus", "Menos 1 BPM") { m.bpmDown() }
                        VStack(spacing: 2) {
                            Text(m.bpmText).font(.system(size: 56, weight: .semibold, design: .monospaced)).minimumScaleFactor(0.6)
                            Text("BPM · velocidade \(Int((m.speed * 100).rounded()))%").font(.system(size: 13)).foregroundStyle(K.textDim)
                        }
                        .frame(maxWidth: .infinity)
                        stepButton("plus", "Mais 1 BPM") { m.bpmUp() }
                    }
                    Slider(value: Binding(get: { m.bpm }, set: { m.setBpm($0) }), in: m.bpmRange).tint(K.accent).accessibilityLabel("BPM")
                    Text("Tempo da música: \(m.tempoValue)").font(.system(size: 13)).foregroundStyle(K.textDim)
                }

                VStack(spacing: 10) {
                    if m.speed != 1 { actionButton("Velocidade original", "gobackward") { m.resetSpeed() } }
                    actionButton("O compasso 1 começa aqui", "mappin.and.ellipse") { Task { await m.markBar() } }
                }
            }
            .padding(24)
        }
        .background(K.bg).foregroundStyle(K.text)
        .presentationDetents([.fraction(0.85), .large])
        #if os(macOS)
        .frame(width: 460, height: 560)
        #endif
    }

    // − e +: grandes, para acertar sem olhar.
    private func stepButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 24, weight: .semibold)).frame(width: 64, height: 64).background(K.surface2, in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    private func actionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 16, weight: .medium)).frame(maxWidth: .infinity, minHeight: 52)
                .background(K.surface, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(K.border))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

// O aviso curto no canto do ecra, com a barra de carga enquanto uma musica abre.
struct ToastView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let t = app.toast, p = app.player
        if t.isVisible || p.isLoading {
            VStack(alignment: .leading, spacing: 8) {
                if t.isVisible { Text(t.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true) }
                if p.isLoading { ProgressView(value: p.loadProgress).tint(K.accent) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: 520, alignment: .leading)
            .background(K.surface2, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(K.border))
            .padding(16).allowsHitTesting(false).transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

extension View {
    // Convites e nomes nao se corrigem: so no iOS esta opcao existe com este nome.
    func autocorrectionDisabledCompat() -> some View { autocorrectionDisabled() }
}

extension Platform {
    // Os ficheiros escolhidos (ou largados) ficam num sitio so nosso: o acesso do sistema acaba quando esta funcao devolve, e o envio demora.
    static func pick(_ urls: [URL]) -> [PickedFile] {
        urls.compactMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), dest = dir.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: dest)
                return PickedFile(name: url.lastPathComponent, url: dest)
            } catch { return nil }
        }
    }
}
