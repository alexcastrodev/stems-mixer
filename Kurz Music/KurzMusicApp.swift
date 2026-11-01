import SwiftUI

@main struct KurzMusicApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 600)
                #endif
        }
    }
}
