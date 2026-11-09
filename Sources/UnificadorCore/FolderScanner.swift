import Foundation

public struct ScanResult: Sendable {
    public let folders: [URL]
    public let notices: [Notice]
}

/// Varredura recursiva de pastas "VID_20*".
public enum FolderScanner {
    public static let prefix = "VID_20"

    /// Arquivos/pastas de sistema ignorados dentro das pastas VID_.
    public static func isIgnored(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == ".Trashes"
    }

    static func canonicalPath(_ url: URL) -> String {
        var p = url.standardizedFileURL.resolvingSymlinksInPath().path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func isSameOrInside(_ path: String, _ container: String) -> Bool {
        path == container || path.hasPrefix(container == "/" ? "/" : container + "/")
    }

    /// - Não entra em pastas já encontradas.
    /// - Ignora o destino (e tudo abaixo dele) quando estiver dentro da raiz.
    /// - Não segue links simbólicos; ignora pastas ocultas (.Trashes, .Spotlight-V100…).
    public static func scan(root: URL, excluding destination: URL?) -> ScanResult {
        let rootPath = canonicalPath(root)
        let excluded = destination.map(canonicalPath)
        var found: [URL] = []
        var notices: [Notice] = []

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        if rootURL.lastPathComponent.hasPrefix(prefix) {
            return ScanResult(folders: [rootURL], notices: [])
        }

        var stack: [String] = [rootPath]
        while let dir = stack.popLast() {
            let entries: [String]
            do {
                entries = try FileManager.default.contentsOfDirectory(atPath: dir)
            } catch {
                notices.append(Notice(.warning, "Não foi possível ler a pasta “\(dir)”: \(error.localizedDescription)"))
                continue
            }
            for name in entries.sorted() {
                if name.hasPrefix(".") { continue }
                let child = (dir as NSString).appendingPathComponent(name)
                guard let info = FileOps.info(child), info.isDirectory, !info.isSymlink else { continue }
                if let ex = excluded, isSameOrInside(child, ex) { continue }
                if name.hasPrefix(prefix) {
                    found.append(URL(fileURLWithPath: child, isDirectory: true))
                } else {
                    stack.append(child)
                }
            }
        }
        found.sort { $0.path < $1.path }
        return ScanResult(folders: found, notices: notices)
    }

    /// Agrupa pelo nome EXATO da pasta. Dentro de cada grupo, ordem determinística por caminho.
    public static func group(_ folders: [URL]) -> [(name: String, folders: [URL])] {
        var dict: [String: [URL]] = [:]
        var order: [String] = []
        for f in folders {
            let name = f.lastPathComponent
            if dict[name] == nil { order.append(name) }
            dict[name, default: []].append(f)
        }
        return order.sorted().map { (name: $0, folders: dict[$0]!.sorted { $0.path < $1.path }) }
    }
}
