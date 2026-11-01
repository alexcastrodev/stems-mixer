import KurzPresentation
import SwiftUI

// A raiz: no Mac e no iPad (largura regular) o studio, no iPhone (largura compacta) a vista de telemovel; os paineis e o aviso ficam por cima.
struct RootView: View {
    @Environment(AppModel.self) private var app
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        @Bindable var library = app.library
        @Bindable var account = app.account
        @Bindable var importer = app.importer
        @Bindable var metronome = app.player.metronome
        Group {
            #if os(iOS)
            if sizeClass == .compact || Platform.isPhone { PhoneView() } else { StudioView() }   // um iPhone deitado pode ter largura "regular": continua a ser o iPhone
            #else
            StudioView()
            #endif
        }
        .background(K.bg.ignoresSafeArea())
        .overlay(alignment: .bottomTrailing) { ToastView() }
        .animation(.default, value: app.toast.isVisible)
        .sheet(isPresented: $importer.isOpen) { ImportSheet() }
        .sheet(isPresented: $account.isInviteOpen) { InviteSheet() }
        .sheet(isPresented: $account.isAccountOpen) { AccountSheet() }
        .sheet(isPresented: $metronome.isInfoOpen) { TempoSheet() }
        .alert("Apagar música?", isPresented: $library.isDeleteOpen) {
            Button("Cancelar", role: .cancel) { library.cancelDelete() }
            Button("Apagar", role: .destructive) { Task { await library.confirmDelete() } }
        } message: { Text(library.deleteText) }
        .preferredColorScheme(.dark)
        .tint(K.accent)
        .task { await app.start() }
        .task {                                                   // o estado do servidor e as separacoes em curso, a cada 3 s
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3)); await app.library.poll(app.account) }
        }
        .task {                                                   // a posicao, os tempos e as ondas, 20 vezes por segundo, so enquanto toca
            while !Task.isCancelled {
                if app.player.isPlayingNow || app.player.isPlaying { app.player.tick() }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
