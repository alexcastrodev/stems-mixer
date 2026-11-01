public enum Playlist {
    // Proxima musica separada a partir de `id` (step = +1 / -1), sem dar a volta; nil se nao houver.
    public static func neighbour(_ songs: [Song], from id: String?, step: Int) -> Song? {
        let done = songs.filter(\.isDone)
        let i = (done.firstIndex { $0.id == id } ?? -1) + step
        return done.indices.contains(i) ? done[i] : nil
    }
}
