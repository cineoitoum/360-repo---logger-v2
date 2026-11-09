import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct FileInfo {
    let size: Int64
    let device: UInt64
    let isRegular: Bool
    let isDirectory: Bool
    let isSymlink: Bool
}

/// Operações de baixo nível (POSIX). Nenhuma função aqui renomeia arquivos do usuário:
/// `renameNoReplace` só é usado para (a) promover o nosso `.partial` ao nome original e
/// (b) mover um arquivo para outra pasta mantendo exatamente o mesmo nome.
enum FileOps {
    static let partialSuffix = ".partial"

    static func info(_ path: String) -> FileInfo? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let fmt = st.st_mode & S_IFMT
        return FileInfo(
            size: Int64(st.st_size),
            device: UInt64(truncatingIfNeeded: st.st_dev),
            isRegular: fmt == S_IFREG,
            isDirectory: fmt == S_IFDIR,
            isSymlink: fmt == S_IFLNK
        )
    }

    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    static func isAccessibleDirectory(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func freeSpace(at url: URL) -> Int64? {
        #if os(macOS)
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = v.volumeAvailableCapacityForImportantUsage, cap > 0 {
            return cap
        }
        #endif
        var s = statvfs()
        guard statvfs(url.path, &s) == 0 else { return nil }
        return Int64(s.f_bavail) * Int64(s.f_frsize)
    }

    static func volumeSupportsCloning(_ url: URL) -> Bool {
        #if os(macOS)
        return (try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning ?? false
        #else
        return false
        #endif
    }

    /// Renomeia `from` → `to` sem nunca sobrescrever `to`.
    static func renameNoReplace(_ from: String, _ to: String) throws {
        #if canImport(Darwin)
        if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return }
        let e = errno
        if e == EEXIST { throw UnifierError.destinationExists(path: to) }
        if e != ENOTSUP && e != EINVAL {
            throw UnifierError.posix(op: "mover", path: to, code: e)
        }
        #else
        if link(from, to) == 0 {
            if unlink(from) != 0 { throw UnifierError.posix(op: "remover", path: from, code: errno) }
            return
        }
        if errno == EEXIST { throw UnifierError.destinationExists(path: to) }
        #endif
        // Sistemas de arquivos sem rename exclusivo (ex.: exFAT): checa e renomeia.
        if exists(to) { throw UnifierError.destinationExists(path: to) }
        if rename(from, to) != 0 { throw UnifierError.posix(op: "mover", path: to, code: errno) }
    }

    /// clonefile (APFS). Retorna nil em sucesso ou o errno.
    static func clone(_ from: String, _ to: String) -> Int32? {
        #if canImport(Darwin)
        return clonefile(from, to, 0) == 0 ? nil : errno
        #else
        return ENOTSUP
        #endif
    }

    static func remove(_ path: String) throws {
        if unlink(path) != 0 { throw UnifierError.posix(op: "remover", path: path, code: errno) }
    }

    static func copyDates(from src: String, to dst: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: src) else { return }
        var newAttrs: [FileAttributeKey: Any] = [:]
        if let m = attrs[.modificationDate] { newAttrs[.modificationDate] = m }
        #if os(macOS)
        if let c = attrs[.creationDate] { newAttrs[.creationDate] = c }
        #endif
        try? FileManager.default.setAttributes(newAttrs, ofItemAtPath: dst)
    }

    /// Copia em blocos (streaming), sem carregar o arquivo em memória.
    /// Cria `dst` com O_EXCL: nunca sobrescreve. Retorna o SHA-256 da origem se pedido.
    static func streamCopy(
        from src: String, to dst: String, chunkSize: Int, computeHash: Bool,
        shouldCancel: () -> Bool, onBytes: (Int) -> Void
    ) throws -> String? {
        let inFD = open(src, O_RDONLY)
        guard inFD >= 0 else { throw UnifierError.posix(op: "ler", path: src, code: errno) }
        defer { close(inFD) }

        let outFD = open(dst, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard outFD >= 0 else {
            let e = errno
            if e == EEXIST { throw UnifierError.destinationExists(path: dst) }
            throw UnifierError.posix(op: "criar", path: dst, code: e)
        }
        var outOpen = true
        defer { if outOpen { close(outFD) } }
        #if canImport(Darwin)
        // Não mantém no cache o que foi gravado, para a verificação reler do disco.
        _ = fcntl(outFD, F_NOCACHE, 1)
        #endif

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16384)
        defer { buffer.deallocate() }
        var hasher: SHA256Stream? = computeHash ? SHA256Stream() : nil

        while true {
            if shouldCancel() { throw UnifierError.cancelled }
            let n = read(inFD, buffer, chunkSize)
            if n < 0 {
                if errno == EINTR { continue }
                throw UnifierError.posix(op: "ler", path: src, code: errno)
            }
            if n == 0 { break }
            hasher?.update(UnsafeRawBufferPointer(start: buffer, count: n))
            var off = 0
            while off < n {
                let w = write(outFD, buffer.advanced(by: off), n - off)
                if w < 0 {
                    if errno == EINTR { continue }
                    throw UnifierError.posix(op: "gravar", path: dst, code: errno)
                }
                off += w
            }
            onBytes(n)
        }
        if fsync(outFD) != 0 { throw UnifierError.posix(op: "gravar", path: dst, code: errno) }
        outOpen = false
        if close(outFD) != 0 { throw UnifierError.posix(op: "gravar", path: dst, code: errno) }
        return hasher?.finalizeHex()
    }

    static func hashFile(
        _ path: String, chunkSize: Int, shouldCancel: () -> Bool, onBytes: (Int) -> Void
    ) throws -> String {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw UnifierError.posix(op: "ler", path: path, code: errno) }
        defer { close(fd) }
        #if canImport(Darwin)
        _ = fcntl(fd, F_NOCACHE, 1)
        #endif
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16384)
        defer { buffer.deallocate() }
        var hasher = SHA256Stream()
        while true {
            if shouldCancel() { throw UnifierError.cancelled }
            let n = read(fd, buffer, chunkSize)
            if n < 0 {
                if errno == EINTR { continue }
                throw UnifierError.posix(op: "ler", path: path, code: errno)
            }
            if n == 0 { break }
            hasher.update(UnsafeRawBufferPointer(start: buffer, count: n))
            onBytes(n)
        }
        return hasher.finalizeHex()
    }
}
