import KurzPresentation
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// O que muda de um sistema para o outro: as palavras das mensagens e a area de transferencia.
enum Platform {
    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    static var words: DeviceWords {
        #if os(macOS)
        DeviceWords(place: "Mac", tap: "clique")
        #else
        DeviceWords(place: isPhone ? "iPhone" : "iPad", tap: "toque")
        #endif
    }

    static func clipboard() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}

// A mistura exportada: um WAV para o seletor de ficheiros do sistema.
struct WAVFile: FileDocument {
    nonisolated static var readableContentTypes: [UTType] { [.wav] }
    var data = Data()
    nonisolated init(data: Data = Data()) { self.data = data }
    nonisolated init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    nonisolated func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
