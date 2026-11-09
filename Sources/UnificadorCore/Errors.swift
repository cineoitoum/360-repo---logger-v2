import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Erros do núcleo, com mensagens claras em português.
public enum UnifierError: Error, LocalizedError, Equatable {
    case posix(op: String, path: String, code: Int32)
    case cancelled
    case checksumMismatch(path: String)
    case sizeMismatch(path: String, expected: Int64, actual: Int64)
    case destinationExists(path: String)
    case rootNotFound(path: String)
    case destinationNotFound(path: String)
    case rootInsideDestination
    case sameRootAndDestination

    public var errorDescription: String? {
        switch self {
        case let .posix(op, path, code):
            return Self.posixMessage(op: op, path: path, code: code)
        case .cancelled:
            return "Operação cancelada pelo usuário."
        case let .checksumMismatch(path):
            return "Checksum divergente após a cópia de “\(path)”. A cópia foi descartada e o original mantido."
        case let .sizeMismatch(path, expected, actual):
            return "Tamanho divergente após a cópia de “\(path)” (esperado \(expected), obtido \(actual)). A cópia foi descartada."
        case let .destinationExists(path):
            return "Já existe um arquivo em “\(path)”. Nada foi sobrescrito."
        case let .rootNotFound(path):
            return "A pasta raiz “\(path)” não está acessível. O cartão ou disco pode ter sido desmontado."
        case let .destinationNotFound(path):
            return "A pasta de destino “\(path)” não está acessível. O disco pode ter sido desmontado."
        case .rootInsideDestination:
            return "A pasta raiz está dentro da pasta de destino. Escolha pastas separadas."
        case .sameRootAndDestination:
            return "A pasta raiz e a pasta de destino são a mesma. Escolha pastas diferentes."
        }
    }

    static func posixMessage(op: String, path: String, code: Int32) -> String {
        switch code {
        case EACCES, EPERM:
            return "Sem permissão para \(op) “\(path)”. Verifique as permissões da pasta ou conceda Acesso Total ao Disco em Ajustes do Sistema › Privacidade e Segurança."
        case ENOENT:
            return "Não encontrado: “\(path)”. O cartão ou disco pode ter sido desmontado."
        case ENXIO, ENODEV, EIO:
            return "Volume desmontado ou com erro de leitura/gravação ao \(op) “\(path)”."
        case ENOSPC:
            return "Sem espaço livre no destino ao \(op) “\(path)”."
        case EROFS:
            return "Volume somente leitura ao \(op) “\(path)”. Cartões SD com trava ativada não permitem o modo Mover."
        default:
            let sys = String(cString: strerror(code))
            return "Erro ao \(op) “\(path)”: \(sys) (código \(code))."
        }
    }

    /// Erros que tornam inútil continuar (o resto falharia igual).
    var isFatal: Bool {
        if case let .posix(_, _, code) = self {
            return code == ENOSPC || code == ENXIO || code == ENODEV
        }
        return false
    }
}
