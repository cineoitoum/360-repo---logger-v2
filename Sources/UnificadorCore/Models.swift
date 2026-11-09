import Foundation

public enum TransferMode: String, CaseIterable, Sendable {
    case copy = "Copiar"
    case move = "Mover"
}

public struct UnifierOptions: Sendable, Equatable {
    public var mode: TransferMode = .copy
    /// Verificação por SHA-256 após copiar (ligada por padrão).
    public var verifyChecksum: Bool = true
    /// Número esperado de pastas de origem por grupo (6 lentes + 1 proxy na Pro 2).
    public var expectedFoldersPerGroup: Int = 7
    /// clonefile / rename direto no mesmo volume. Desligar força cópia em blocos (testes).
    public var allowFastPaths: Bool = true

    public init(mode: TransferMode = .copy, verifyChecksum: Bool = true,
                expectedFoldersPerGroup: Int = 7, allowFastPaths: Bool = true) {
        self.mode = mode
        self.verifyChecksum = verifyChecksum
        self.expectedFoldersPerGroup = expectedFoldersPerGroup
        self.allowFastPaths = allowFastPaths
    }
}

public enum Severity: Int, Sendable, Comparable {
    case info = 0, warning = 1, critical = 2
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

public struct Notice: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public let severity: Severity
    public let message: String
    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }
}

public enum TransferMethod: String, Sendable {
    /// rename(2) no mesmo volume (modo Mover).
    case rename
    /// clonefile no mesmo volume APFS (modo Copiar).
    case clone
    /// cópia em blocos para `.partial`.
    case stream
}

public enum FileTaskKind: Sendable, Equatable {
    case transfer(TransferMethod)
    /// Duplicata do arquivo `primaryIndex` do mesmo grupo. `caseOnly` = nome difere só em maiúsculas/minúsculas.
    case duplicate(primaryIndex: Int, caseOnly: Bool)
}

public struct FileTask: Sendable, Identifiable {
    public let id: Int
    public let source: URL
    /// Caminho relativo dentro da pasta VID_ (normalmente só o nome do arquivo).
    public let relativePath: String
    public let size: Int64
    public let destination: URL
    public let kind: FileTaskKind
    /// Tamanho de um arquivo que já existe no destino (retomada ou conflito).
    public let existingDestinationSize: Int64?

    public var isDuplicate: Bool {
        if case .duplicate = kind { return true }
        return false
    }
}

public struct GroupPlan: Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let sourceFolders: [URL]
    /// "AAMMDD" ou nil quando o nome está fora do padrão (vai para `_sem_data`).
    public let dateFolder: String?
    public let destinationFolder: URL
    public let tasks: [FileTask]

    public var destinationDateFolderName: String { dateFolder ?? DateFolder.undatedFolderName }
    public var transferTasks: [FileTask] { tasks.filter { !$0.isDuplicate } }
    public var fileCount: Int { transferTasks.count }
    public var duplicateCount: Int { tasks.count - fileCount }
    public var totalBytes: Int64 { transferTasks.reduce(0) { $0 + $1.size } }
    public func sourceCountMismatch(expected: Int) -> Bool { sourceFolders.count != expected }
}

public struct Plan: Sendable {
    public let root: URL
    public let destination: URL
    public let options: UnifierOptions
    public let groups: [GroupPlan]
    public let notices: [Notice]
    /// Bytes que realmente ocupam espaço novo no destino (exclui clone, rename e arquivos já presentes).
    public let bytesNeeded: Int64
    public let freeSpace: Int64?

    public var insufficientSpace: Bool {
        guard let free = freeSpace else { return false }
        return bytesNeeded > free
    }
    public var totalFiles: Int { groups.reduce(0) { $0 + $1.fileCount } }
    public var totalBytes: Int64 { groups.reduce(0) { $0 + $1.totalBytes } }
    public var totalDuplicates: Int { groups.reduce(0) { $0 + $1.duplicateCount } }
}
