// Quem toca: o mixer entrega blocos estereo 16-bit 44.1 kHz entrelacados a quem os pede (a thread de audio do sistema), `frames` de cada vez.
public typealias Pull = (_ out: UnsafeMutablePointer<Int16>, _ frames: Int) -> Void

public protocol AudioOut: AnyObject {
    var pull: Pull? { get set }
    var rate: Double { get set }     // velocidade de reproducao (1 = a original), sem mudar o tom
    var latency: Double { get }      // s entre o mixer entregar um bloco e ele soar
    func prepare()                   // deixa a saida pronta antes do 1.o "tocar" (fora do fio principal)
    func play() throws
    func pause()
}

extension AudioOut { public func prepare() {} }
