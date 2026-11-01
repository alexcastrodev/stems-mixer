public enum Lanes {
    // As faixas que se veem (uma bateria aberta mostra as suas partes a seguir a ela), cada uma com a sua cor.
    public static func rows(_ top: [Track]) -> [Track] {
        let rows = top.flatMap { $0.expanded ? [$0] + $0.parts : [$0] }
        let parts = rows.filter(\.isPart).count, stems = rows.count - parts
        var s = 0, p = 0
        for r in rows {
            if r.isPart { r.lane = color(p, of: parts, from: 0x9b8cff, to: 0xd98cf0); p += 1 }
            else { r.lane = color(s, of: stems); s += 1 }
        }
        return rows
    }

    // Degrade de cima para baixo: stems azul (#3ba4ff) -> verde-agua (#4bd8cf);
    // partes de um stem (bateria dividida) violeta -> rosa, para nao se confundirem com os stems.
    public static func color(_ i: Int, of n: Int, from: Int = 0x3ba4ff, to: Int = 0x4bd8cf) -> String {
        let f = n <= 1 ? 0 : Double(i) / Double(n - 1)
        func mix(_ shift: Int) -> Int { let a = from >> shift & 0xff, b = to >> shift & 0xff; return Int((Double(a) + Double(b - a) * f).rounded()) }
        return "#" + [16, 8, 0].map { String(format: "%02x", mix($0)) }.joined()
    }
}
