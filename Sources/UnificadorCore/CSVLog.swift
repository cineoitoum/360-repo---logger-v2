import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum LogAction: String, Sendable {
    case copied = "copiado"
    case moved = "movido"
    case skippedDuplicate = "pulado como duplicata"
    case alreadyPresent = "já presente no destino"
    case conflict = "conflito"
    case error = "erro"
    case cleanup = "limpeza de .partial"
}

/// Log CSV no destino. Separador ";" + BOM UTF-8 para abrir direto no Excel/Numbers em pt-BR.
/// Cada linha é gravada e enviada ao disco na hora: um travamento ainda deixa o log útil.
final class CSVLog {
    let url: URL
    private let handle: FileHandle

    init(directory: URL, date: Date = Date()) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        var candidate = directory.appendingPathComponent("UnificadorVR_log_\(f.string(from: date)).csv")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("UnificadorVR_log_\(f.string(from: date))_\(n).csv")
            n += 1
        }
        url = candidate
        var header = Data([0xEF, 0xBB, 0xBF])
        header.append(Self.line(["origem", "destino", "ação", "tamanho", "resultado"]))
        guard FileManager.default.createFile(atPath: url.path, contents: header) else {
            throw UnifierError.posix(op: "criar o log", path: url.path, code: EACCES)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func write(source: String, destination: String, action: LogAction, size: Int64?, result: String) {
        let row = Self.line([source, destination, action.rawValue, size.map(String.init) ?? "", result])
        try? handle.write(contentsOf: row)
    }

    func close() {
        try? handle.synchronize()
        try? handle.close()
    }

    static func escape(_ field: String) -> String {
        if field.contains(";") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    static func line(_ fields: [String]) -> Data {
        Data((fields.map(escape).joined(separator: ";") + "\r\n").utf8)
    }
}
