import Foundation

// busy: ligou mas nao respondeu a tempo (costuma estar a enviar ficheiros); offline: nao se consegue ligar.
public enum ServerState: Sendable { case online, offline, unauthorized, error, busy }

// device: onde o servidor separa (mps, cuda, cpu); active: separacoes na fila ou a correr (de todos os utilizadores);
// name: o nome da conta dona do convite (nil num servidor antigo, que nao o envia).
public struct ServerStatus: Equatable, Sendable {
    public var state: ServerState
    public var device: String?
    public var active = 0
    public var name: String?
    public init(_ state: ServerState, device: String? = nil, active: Int = 0, name: String? = nil) { (self.state, self.device, self.active, self.name) = (state, device, active, name) }
}

public enum ServerError: Error, LocalizedError, Equatable {
    case http(Int, String?)          // o servidor respondeu com erro (estado e a mensagem dele, se a deu)
    case invalid(String)             // recusado aqui, antes de chegar ao servidor
    public var errorDescription: String? {
        switch self { case .http(let code, let msg): msg ?? "Erro \(code)"; case .invalid(let msg): msg }
    }
    public var isUnauthorized: Bool { if case .http(401, _) = self { true } else { false } }
}

// Sem rede/servidor (recusou a ligacao ou demorou), em vez de o servidor ter respondido com erro.
public func isOffline(_ e: Error) -> Bool { e is URLError }
