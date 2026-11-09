import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

public struct ExecutionProgress: Sendable {
    public var totalWork: Int64 = 0
    public var doneWork: Int64 = 0
    public var filesTotal = 0
    public var filesDone = 0
    public var currentFile = ""
    public var currentPhase = ""
    public var currentFileDone: Int64 = 0
    public var currentFileTotal: Int64 = 0
    public var bytesPerSecond: Double = 0
    public var etaSeconds: Double?

    public init() {}
    public var fraction: Double { totalWork > 0 ? min(1, Double(doneWork) / Double(totalWork)) : 0 }
    public var fileFraction: Double { currentFileTotal > 0 ? min(1, Double(currentFileDone) / Double(currentFileTotal)) : 0 }
}

public struct ExecutionSummary: Sendable {
    public var copied = 0
    public var moved = 0
    public var skippedDuplicates = 0
    public var alreadyPresent = 0
    public var conflicts = 0
    /// Arquivos que deveriam sair da origem (modo Mover) mas foram mantidos por segurança.
    public var keptInSource = 0
    public var partialsRemoved = 0
    public var errors: [String] = []
    public var notices: [Notice] = []
    public var cancelled = false
    public var fatalError: String?
    public var logURL: URL?
    public var bytesWritten: Int64 = 0
    public var duration: TimeInterval = 0
    public init() {}
    public var succeeded: Bool { !cancelled && fatalError == nil && errors.isEmpty }
}

/// Executa o plano. Garantias:
/// - Nada é sobrescrito (O_EXCL / rename exclusivo).
/// - Cópia vai para "<nome>.partial" e só vira "<nome>" depois de verificada.
/// - Cancelar deixa no máximo um ".partial", que é apagado na próxima execução.
/// - No modo Mover, a origem só é apagada depois de tamanho (+ checksum, se ligado) conferirem.
public final class Executor: @unchecked Sendable {
    let chunkSize: Int
    let progressInterval: TimeInterval

    public init(chunkSize: Int = 8 << 20, progressInterval: TimeInterval = 0.1) {
        self.chunkSize = chunkSize
        self.progressInterval = progressInterval
    }

    public func run(plan: Plan, token: CancellationToken = CancellationToken(),
                    onProgress: @escaping @Sendable (ExecutionProgress) -> Void = { _ in }) async -> ExecutionSummary {
        await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                self.runSync(plan: plan, token: token, onProgress: onProgress)
            }.value
        } onCancel: {
            token.cancel()
        }
    }

    public func runSync(plan: Plan, token: CancellationToken = CancellationToken(),
                        onProgress: @escaping @Sendable (ExecutionProgress) -> Void = { _ in }) -> ExecutionSummary {
        let run = Run(plan: plan, token: token, chunkSize: chunkSize,
                      tracker: ProgressTracker(interval: progressInterval, emit: onProgress))
        return run.execute()
    }
}

private final class Run {
    let plan: Plan
    let opts: UnifierOptions
    let token: CancellationToken
    let chunkSize: Int
    let tracker: ProgressTracker
    var summary = ExecutionSummary()
    var log: CSVLog!

    // Estado por grupo.
    var finalOK: [Int: Bool] = [:]
    var finalHash: [Int: String] = [:]

    init(plan: Plan, token: CancellationToken, chunkSize: Int, tracker: ProgressTracker) {
        self.plan = plan
        self.opts = plan.options
        self.token = token
        self.chunkSize = chunkSize
        self.tracker = tracker
    }

    func execute() -> ExecutionSummary {
        let start = Date()
        defer { summary.duration = Date().timeIntervalSince(start) }

        guard FileOps.isAccessibleDirectory(plan.destination.path) else {
            summary.fatalError = UnifierError.destinationNotFound(path: plan.destination.path).errorDescription
            return summary
        }
        guard FileOps.isAccessibleDirectory(plan.root.path) else {
            summary.fatalError = UnifierError.rootNotFound(path: plan.root.path).errorDescription
            return summary
        }
        do {
            log = try CSVLog(directory: plan.destination)
        } catch {
            summary.fatalError = "Não foi possível criar o log no destino: \(error.localizedDescription)"
            return summary
        }
        summary.logURL = log.url
        defer { log.close() }

        for g in plan.groups { cleanOrphanPartials(in: g) }

        var total: Int64 = 0
        var files = 0
        for g in plan.groups {
            for t in g.tasks {
                if case let .transfer(m) = t.kind {
                    total += workBudget(t, m)
                    files += 1
                }
            }
        }
        tracker.p.totalWork = total
        tracker.p.filesTotal = files

        outer: for g in plan.groups {
            finalOK = [:]
            finalHash = [:]
            for t in g.tasks {
                if token.isCancelled { summary.cancelled = true; break outer }
                do {
                    switch t.kind {
                    case let .transfer(method):
                        try transfer(t, method)
                    case let .duplicate(p, caseOnly):
                        try duplicate(t, primary: g.tasks[p], caseOnly: caseOnly)
                    }
                } catch UnifierError.cancelled {
                    summary.cancelled = true
                    log.write(source: t.source.path, destination: t.destination.path, action: .error, size: t.size,
                              result: "cancelado — o .partial será apagado na próxima execução")
                    break outer
                } catch {
                    finalOK[t.id] = false
                    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    summary.errors.append(msg)
                    log.write(source: t.source.path, destination: t.destination.path, action: .error, size: t.size, result: msg)
                    if !t.isDuplicate { tracker.finishFile() }
                    if let ue = error as? UnifierError, ue.isFatal {
                        summary.fatalError = msg
                        break outer
                    }
                    if !FileOps.isAccessibleDirectory(plan.root.path) {
                        summary.fatalError = UnifierError.rootNotFound(path: plan.root.path).errorDescription
                        break outer
                    }
                    if !FileOps.isAccessibleDirectory(plan.destination.path) {
                        summary.fatalError = UnifierError.destinationNotFound(path: plan.destination.path).errorDescription
                        break outer
                    }
                }
            }
        }
        tracker.emit(force: true)
        return summary
    }

    // MARK: - Trabalho estimado (para progresso/ETA)

    func workBudget(_ t: FileTask, _ m: TransferMethod) -> Int64 {
        if t.existingDestinationSize != nil { return t.size }
        if m == .stream && opts.verifyChecksum { return t.size * 2 }
        return t.size
    }

    // MARK: - Limpeza de .partial órfãos

    func cleanOrphanPartials(in g: GroupPlan) {
        let root = g.destinationFolder.path
        guard FileOps.isAccessibleDirectory(root) else { return }
        let planned = Set(g.transferTasks.map(\.relativePath))
        func walk(_ dir: String, _ rel: String) {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for name in entries {
                let path = (dir as NSString).appendingPathComponent(name)
                let relPath = rel.isEmpty ? name : rel + "/" + name
                guard let info = FileOps.info(path) else { continue }
                if info.isDirectory && !info.isSymlink {
                    walk(path, relPath)
                } else if info.isRegular, name.hasSuffix(FileOps.partialSuffix), !planned.contains(relPath) {
                    do {
                        try FileOps.remove(path)
                        summary.partialsRemoved += 1
                        log.write(source: "", destination: path, action: .cleanup, size: info.size,
                                  result: "cópia incompleta de execução anterior removida")
                    } catch {
                        let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                        summary.errors.append(msg)
                    }
                }
            }
        }
        walk(root, "")
    }

    // MARK: - Arquivo principal

    func transfer(_ t: FileTask, _ method: TransferMethod) throws {
        let src = t.source.path
        let dst = t.destination.path
        tracker.startFile(t.relativePath, budget: workBudget(t, method), fileTotal: t.size,
                          phase: opts.mode == .move ? "movendo" : "copiando")

        if FolderScanner.canonicalPath(t.source) == FolderScanner.canonicalPath(t.destination) {
            throw UnifierError.destinationExists(path: dst)
        }
        do {
            try FileManager.default.createDirectory(at: t.destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            throw UnifierError.posix(op: "criar a pasta", path: t.destination.deletingLastPathComponent().path,
                                     code: posixCode(of: error))
        }

        // Já existe no destino: retomada (mesmo tamanho) ou conflito (tamanho diferente).
        if let existing = FileOps.info(dst) {
            defer { tracker.finishFile() }
            guard existing.size == t.size else {
                finalOK[t.id] = false
                summary.conflicts += 1
                log.write(source: src, destination: dst, action: .conflict, size: t.size,
                          result: "já existe no destino com tamanho diferente (\(existing.size) bytes); não sobrescrito")
                return
            }
            if opts.mode == .move {
                if opts.verifyChecksum {
                    tracker.phase("verificando")
                    let a = try hash(src), b = try hash(dst)
                    guard a == b else {
                        finalOK[t.id] = false
                        summary.conflicts += 1
                        summary.keptInSource += 1
                        summary.notices.append(Notice(.critical, "“\(dst)” tem o mesmo tamanho mas checksum diferente da origem. Origem mantida."))
                        log.write(source: src, destination: dst, action: .conflict, size: t.size,
                                  result: "mesmo tamanho, checksum diferente; origem mantida, destino não sobrescrito")
                        return
                    }
                    finalHash[t.id] = b
                }
                try removeSourceAfterVerifiedCopy(t, result: "já estava completo no destino; origem removida após verificação")
            } else {
                summary.alreadyPresent += 1
                log.write(source: src, destination: dst, action: .alreadyPresent, size: t.size,
                          result: "retomada: arquivo completo já estava no destino")
            }
            finalOK[t.id] = true
            return
        }

        switch method {
        case .rename:
            try FileOps.renameNoReplace(src, dst)
            summary.moved += 1
            log.write(source: src, destination: dst, action: .moved, size: t.size, result: "ok (mesmo volume, movimentação direta)")
            finalOK[t.id] = true
            tracker.finishFile()
        case .clone:
            let partial = dst + FileOps.partialSuffix
            if FileOps.exists(partial) { try FileOps.remove(partial) }
            if let err = FileOps.clone(src, partial) {
                if err == ENOTSUP || err == EXDEV || err == EINVAL || err == ENOTTY {
                    try stream(t)  // volume não suporta clone: cópia em blocos
                    return
                }
                throw UnifierError.posix(op: "clonar", path: src, code: err)
            }
            guard let info = FileOps.info(partial), info.size == t.size else {
                try? FileOps.remove(partial)
                throw UnifierError.sizeMismatch(path: src, expected: t.size, actual: FileOps.info(partial)?.size ?? -1)
            }
            try FileOps.renameNoReplace(partial, dst)
            summary.copied += 1
            log.write(source: src, destination: dst, action: .copied, size: t.size, result: "ok (clone APFS)")
            finalOK[t.id] = true
            tracker.finishFile()
        case .stream:
            try stream(t)
        }
    }

    func stream(_ t: FileTask) throws {
        let src = t.source.path
        let dst = t.destination.path
        let partial = dst + FileOps.partialSuffix
        if FileOps.exists(partial) { try FileOps.remove(partial) }  // .partial é sempre nosso
        let verify = opts.verifyChecksum
        var sourceHash: String?
        do {
            tracker.phase(opts.mode == .move ? "movendo" : "copiando")
            sourceHash = try FileOps.streamCopy(from: src, to: partial, chunkSize: chunkSize, computeHash: verify,
                                                shouldCancel: { self.token.isCancelled },
                                                onBytes: { self.tracker.add($0) })
            FileOps.copyDates(from: src, to: partial)
            let written = FileOps.info(partial)?.size ?? -1
            guard written == t.size else { throw UnifierError.sizeMismatch(path: src, expected: t.size, actual: written) }
            if verify {
                tracker.phase("verificando")
                let destHash = try FileOps.hashFile(partial, chunkSize: chunkSize,
                                                    shouldCancel: { self.token.isCancelled },
                                                    onBytes: { self.tracker.add($0) })
                guard destHash == sourceHash else { throw UnifierError.checksumMismatch(path: src) }
            }
        } catch UnifierError.cancelled {
            throw UnifierError.cancelled  // .partial fica; limpo na próxima execução
        } catch {
            try? FileOps.remove(partial)
            throw error
        }
        try FileOps.renameNoReplace(partial, dst)
        summary.bytesWritten += t.size
        finalOK[t.id] = true
        if let h = sourceHash { finalHash[t.id] = h }
        let how = verify ? "verificado por checksum SHA-256" : "verificado por tamanho"
        if opts.mode == .move {
            try removeSourceAfterVerifiedCopy(t, result: "ok (\(how)); origem removida")
        } else {
            summary.copied += 1
            log.write(source: src, destination: dst, action: .copied, size: t.size, result: "ok (\(how))")
        }
        tracker.finishFile()
    }

    func removeSourceAfterVerifiedCopy(_ t: FileTask, result: String) throws {
        do {
            try FileOps.remove(t.source.path)
            summary.moved += 1
            log.write(source: t.source.path, destination: t.destination.path, action: .moved, size: t.size, result: result)
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            summary.copied += 1
            summary.keptInSource += 1
            summary.notices.append(Notice(.warning, "Copiado, mas a origem não pôde ser removida: \(msg)"))
            log.write(source: t.source.path, destination: t.destination.path, action: .copied, size: t.size,
                      result: "copiado e verificado, mas a origem não pôde ser removida: \(msg)")
        }
    }

    // MARK: - Duplicatas

    func duplicate(_ t: FileTask, primary: FileTask, caseOnly: Bool) throws {
        let src = t.source.path
        let dst = primary.destination.path
        let sizeDiffers = t.size != primary.size
        let diffNote = sizeDiffers ? " — ATENÇÃO: TAMANHO DIFERENTE (\(t.size) vs \(primary.size) bytes)" : ""
        summary.skippedDuplicates += 1

        if caseOnly {
            if opts.mode == .move { summary.keptInSource += 1 }
            log.write(source: src, destination: dst, action: .skippedDuplicate, size: t.size,
                      result: "nome difere só em maiúsculas/minúsculas de “\(primary.relativePath)”; mantido na origem\(diffNote)")
            return
        }
        if opts.mode == .copy {
            log.write(source: src, destination: dst, action: .skippedDuplicate, size: t.size,
                      result: sizeDiffers ? "não copiado\(diffNote)" : "não copiado (mesmo tamanho do primeiro)")
            return
        }
        // Modo Mover: só apaga da origem se for idêntica (tamanho E checksum) ao arquivo final.
        guard finalOK[primary.id] == true else {
            summary.keptInSource += 1
            log.write(source: src, destination: dst, action: .skippedDuplicate, size: t.size,
                      result: "mantido na origem: o primeiro arquivo não foi transferido\(diffNote)")
            return
        }
        guard !sizeDiffers else {
            summary.keptInSource += 1
            log.write(source: src, destination: dst, action: .skippedDuplicate, size: t.size,
                      result: "mantido na origem\(diffNote)")
            return
        }
        tracker.phase("comparando duplicata")
        let destHash: String
        if let h = finalHash[primary.id] { destHash = h } else { destHash = try hash(dst); finalHash[primary.id] = destHash }
        let srcHash = try hash(src)
        if srcHash == destHash {
            try FileOps.remove(src)
            log.write(source: src, destination: dst, action: .skippedDuplicate, size: t.size,
                      result: "idêntico (tamanho e checksum) ao já transferido; removido da origem")
        } else {
            summary.keptInSource += 1
            summary.notices.append(Notice(.critical, "Duplicata “\(src)” tem o mesmo tamanho mas checksum diferente. Mantida na origem."))
            log.write(source: src, destination: dst, action: .skippedDuplicate, size: t.size,
                      result: "ATENÇÃO: mesmo tamanho, checksum diferente; mantido na origem")
        }
    }

    func posixCode(of error: Error) -> Int32 {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain { return Int32(u.code) }
        switch ns.code {
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return EACCES
        case NSFileWriteOutOfSpaceError: return ENOSPC
        case NSFileWriteVolumeReadOnlyError: return EROFS
        default: return EIO
        }
    }

    func hash(_ path: String) throws -> String {
        try FileOps.hashFile(path, chunkSize: chunkSize, shouldCancel: { self.token.isCancelled }, onBytes: { _ in })
    }
}

/// Acumula progresso e emite no máximo a cada `interval` segundos.
final class ProgressTracker {
    var p = ExecutionProgress()
    let interval: TimeInterval
    let sink: @Sendable (ExecutionProgress) -> Void
    private var lastEmit: TimeInterval = -.infinity
    private var samples: [(t: TimeInterval, done: Int64)] = []
    private var fileBudget: Int64 = 0
    private var fileWorkDone: Int64 = 0
    private var fileOpen = false

    init(interval: TimeInterval, emit: @escaping @Sendable (ExecutionProgress) -> Void) {
        self.interval = interval
        self.sink = emit
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func startFile(_ name: String, budget: Int64, fileTotal: Int64, phase: String) {
        p.currentFile = name
        p.currentPhase = phase
        p.currentFileDone = 0
        p.currentFileTotal = fileTotal
        fileBudget = budget
        fileWorkDone = 0
        fileOpen = true
        emit()
    }

    func phase(_ name: String) {
        p.currentPhase = name
        p.currentFileDone = 0
        emit()
    }

    func add(_ n: Int) {
        let n = Int64(n)
        p.currentFileDone += n
        let credited = max(0, min(n, fileBudget - fileWorkDone))
        fileWorkDone += credited
        p.doneWork += credited
        emit()
    }

    func finishFile() {
        guard fileOpen else { return }
        fileOpen = false
        p.doneWork += max(0, fileBudget - fileWorkDone)
        fileBudget = 0
        fileWorkDone = 0
        p.filesDone += 1
        p.currentFileDone = p.currentFileTotal
        emit()
    }

    func emit(force: Bool = false) {
        let t = now
        guard force || t - lastEmit >= interval else { return }
        lastEmit = t
        samples.append((t, p.doneWork))
        while let first = samples.first, t - first.t > 5, samples.count > 2 { samples.removeFirst() }
        if let first = samples.first, t - first.t > 0.2 {
            p.bytesPerSecond = Double(p.doneWork - first.done) / (t - first.t)
        }
        let remaining = Double(p.totalWork - p.doneWork)
        p.etaSeconds = p.bytesPerSecond > 0 ? remaining / p.bytesPerSecond : nil
        sink(p)
    }
}
