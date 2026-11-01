import Foundation

// Escrita em disco: sempre atomica (um corte a meio nao deixa um arquivo pela metade).
enum Disk {
    static func save(_ url: URL, _ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // Como save, mas o arquivo nasce so legivel pelo dono (0600): e um segredo.
    static func saveSecret(_ url: URL, _ text: String) throws {
        let fm = FileManager.default, part = url.appendingPathExtension("part")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: part)                                // um resto antigo nao pode deixar as suas permissoes
        guard fm.createFile(atPath: part.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        _ = try fm.replaceItemAt(url, withItemAt: part)
    }
}
