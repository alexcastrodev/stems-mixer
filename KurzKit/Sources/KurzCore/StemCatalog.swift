// O que se sabe de um stem pelo nome que o servidor lhe da: como se mostra, a cor da faixa e a ordem em que aparece.
public enum StemCatalog {
    static let drumColor = "#4aa6a8"
    static let info: [String: (name: String, color: String)] = [
        "vocals": ("Vocais", "#e8737a"), "drums": ("Bateria", drumColor), "bass": ("Baixo", "#5b9be8"),
        "guitar": ("Guitarras", "#e8b84a"), "piano": ("Piano", "#6fcf97"), "other": ("Outros", "#9b87e8"),
        "drum_kick": ("Bombo", drumColor), "drum_snare": ("Caixa", drumColor), "drum_hihat": ("Hi-hat", drumColor),
        "drum_toms": ("Tons", drumColor), "drum_cymbals": ("Pratos", drumColor),
    ]

    // O nome com que uma faixa se mostra e se exporta ("vocals" -> "Vocais"); um stem desconhecido fica como veio.
    public static func displayName(_ stem: String) -> String { info[stem]?.name ?? stem }
    public static func color(_ stem: String) -> String { info[stem]?.color ?? drumColor }
    // A ordem em que as faixas se mostram: bateria, vozes, guitarras, baixo e o resto (como o servidor o deu).
    public static func rank(_ stem: String) -> Int { ["drums": 0, "vocals": 1, "guitar": 2, "bass": 3][stem] ?? 4 }

    // Os stems na ordem em que se mostram: primeiro a que o utilizador guardou (`saved`, pelos nomes com que se mostram); os que ela
    // nao conhece ficam a seguir, pela ordem de omissao (`rank`, e depois a do servidor).
    public static func sorted(_ stems: [String], saved: [String]) -> [String] {
        func key(_ s: (offset: Int, element: String)) -> (Int, Int, Int) { (saved.firstIndex(of: displayName(s.element)) ?? .max, rank(s.element), s.offset) }
        return stems.enumerated().sorted { key($0) < key($1) }.map(\.element)
    }

    // O metronomo entra na ordem guardada como mais um nome. `metronomeSlot`: quantos `stems` ficam antes dele (sem ordem guardada, vai no fim).
    public static let metronome = "Metrónomo"
    public static func metronomeSlot(_ stems: [String], saved: [String]) -> Int {
        guard let m = saved.firstIndex(of: metronome) else { return stems.count }
        return stems.filter { (saved.firstIndex(of: displayName($0)) ?? .max) < m }.count
    }
}
