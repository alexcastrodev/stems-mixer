import Foundation
import KurzCore

// Descarrega em segundo plano os stems das musicas, uma musica de cada vez (e 3 ficheiros de cada vez), sem prender ninguem:
// quem a usa pede (enqueue) e ouve os eventos. O que ja esta no disco nao se descarrega outra vez, por isso retomar e pedir de novo.
@MainActor public final class Downloads {
    final class Item {
        let song: Song
        var progress = 0.0, raised = 0.0, cancelled = false
        var done: [Double]                  // o que ja se leu de cada ficheiro
        init(_ song: Song) { self.song = song; done = Array(repeating: 0, count: song.stems.count + song.drums.count) }
    }

    let stems: StemService
    var items: [String: Item] = [:]     // as musicas na fila ou a descarregar, por id
    var order: [String] = []            // ... pela ordem em que foram pedidas
    var waiting: [String] = []
    var pumping = false

    public var onChanged: (() -> Void)?
    public var onCompleted: ((Song) -> Void)?             // a musica ficou toda no disco
    public var onFailed: ((Song, Error) -> Void)?         // as descargas ja feitas ficam: pedir de novo retoma

    public init(_ stems: StemService) { self.stems = stems }

    public var busy: Bool { !items.isEmpty }
    public func has(_ id: String) -> Bool { items[id] != nil }
    public func progress(_ id: String) -> Double { items[id]?.progress ?? 0 }

    // A musica em curso (a primeira da fila) e quanto vai.
    public var now: (title: String, progress: Double)? { order.first.flatMap { items[$0] }.map { ($0.song.displayTitle, $0.progress) } }

    // As musicas que acabaram de ser separadas: ativas na lista de antes, prontas na de agora. Descarregam-se logo, para nao esperar ao tocar.
    // Uma musica que nunca esteve ativa neste aparelho (ex. separada noutro) nao conta: senao uma conta nova descarregava a biblioteca toda.
    nonisolated public static func finished(before: [Song], after: [Song]) -> [Song] {
        let active = Set(before.filter(\.isActive).map(\.id))
        return after.filter { $0.isDone && active.contains($0.id) }
    }

    // Pede a descarga; nao faz nada se a musica ja esta no disco, ainda nao esta separada ou ja foi pedida.
    public func enqueue(_ song: Song) {
        guard song.isDone, items[song.id] == nil, !stems.isCached(song) else { return }
        items[song.id] = Item(song)
        order.append(song.id)
        waiting.append(song.id)
        if !pumping { pumping = true; Task { await pump() } }
        onChanged?()
    }

    // Para a descarga: a que esta na fila sai ja; a que corre acaba o lote de ficheiros em curso. O que ja desceu fica no disco.
    public func cancel(_ id: String) { items[id]?.cancelled = true }

    func pump() async {
        while !waiting.isEmpty {
            if let item = items[waiting.removeFirst()] { await run(item) }
        }
        pumping = false
    }

    func run(_ item: Item) async {
        var failure: Error?
        do { if !item.cancelled { try await fetch(item) } } catch { failure = error }
        items[item.song.id] = nil
        order.removeAll { $0 == item.song.id }
        if let failure { onFailed?(item.song, failure) } else if !item.cancelled { onCompleted?(item.song) }
        onChanged?()
    }

    func report(_ item: Item, _ i: Int, _ f: Double) {
        item.done[i] = max(item.done[i], f)
        item.progress = item.done.reduce(0, +) / Double(item.done.count)
        if item.progress < 1 && item.progress - item.raised < 0.01 { return }   // ao centesimo: cada bloco lido nao precisa de redesenhar nada
        item.raised = item.progress
        onChanged?()
    }

    func fetch(_ item: Item) async throws {
        let song = item.song, names = song.stems + song.drums
        for from in stride(from: 0, to: names.count, by: 3) where !item.cancelled {   // 3 de cada vez; cancelar vale entre lotes
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in from..<min(from + 3, names.count) {
                    group.addTask { @MainActor [self] in
                        _ = try await stems.stemFile(song.id, names[i], song.format) { f in Task { @MainActor in self.report(item, i, f * 0.99) } }
                        report(item, i, 1)
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}
