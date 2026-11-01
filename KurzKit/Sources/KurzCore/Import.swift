import Foundation

public enum Import {
    static let exts = ["mp3", "wav", "flac", "m4a", "ogg", "aac", "mp4", "opus"]
    public static func isAudio(_ name: String) -> Bool { exts.contains((name as NSString).pathExtension.lowercased()) }

    // Junta novos nomes a lista, ignorando o que nao e audio e o que ja la esta; devolve quantos foram ignorados.
    public static func add(_ list: inout [String], _ names: [String]) -> Int {
        var skipped = 0
        for n in names { if isAudio(n) && !list.contains(n) { list.append(n) } else { skipped += 1 } }
        return skipped
    }
}

public enum Notice {
    // Mensagens de estado: as que acabam em "…" (a trabalhar) ficam ate mudarem; as outras desaparecem sozinhas.
    public static func isTransient(_ text: String?) -> Bool { text.map { !$0.isEmpty && !$0.hasSuffix("…") } ?? false }
}
