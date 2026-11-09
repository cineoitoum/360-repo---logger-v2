import Foundation
import XCTest
@testable import UnificadorCore

/// Pasta temporária isolada por teste.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnificadorVRTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func dir(_ rel: String) throws -> URL {
        let u = url.appendingPathComponent(rel, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    func file(_ rel: String, _ content: String) throws -> URL {
        try file(rel, Data(content.utf8))
    }

    @discardableResult
    func file(_ rel: String, _ data: Data) throws -> URL {
        let u = url.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        return u
    }

    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent(rel).path) }

    func read(_ rel: String) throws -> String {
        String(decoding: try Data(contentsOf: url.appendingPathComponent(rel)), as: UTF8.self)
    }

    /// Lista recursiva de caminhos relativos de arquivos (ignora o log CSV).
    func files(under rel: String) -> [String] {
        let base = url.appendingPathComponent(rel).path
        guard let e = FileManager.default.enumerator(atPath: base) else { return [] }
        var out: [String] = []
        while let p = e.nextObject() as? String {
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: (base as NSString).appendingPathComponent(p), isDirectory: &isDir)
            if !isDir.boolValue && !p.hasPrefix("UnificadorVR_log_") { out.append(p) }
        }
        return out.sorted()
    }
}

func randomData(_ count: Int, seed: UInt8 = 1) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    var x = UInt32(seed) &* 2654435761 | 1
    for i in 0..<count {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5
        bytes[i] = UInt8(truncatingIfNeeded: x)
    }
    return Data(bytes)
}

func makePlan(_ root: URL, _ dest: URL, _ options: UnifierOptions = UnifierOptions()) throws -> Plan {
    try Planner.makePlan(root: root, destination: dest, options: options)
}

func execute(_ plan: Plan, chunkSize: Int = 64 * 1024, token: CancellationToken = CancellationToken(),
             onProgress: @escaping @Sendable (ExecutionProgress) -> Void = { _ in }) -> ExecutionSummary {
    Executor(chunkSize: chunkSize, progressInterval: 0).runSync(plan: plan, token: token, onProgress: onProgress)
}

func logText(_ s: ExecutionSummary) throws -> String {
    guard let u = s.logURL else { return "" }
    return String(decoding: try Data(contentsOf: u), as: UTF8.self)
}
