import Foundation

/// Monta o plano completo (pré-visualização). Não grava nada no disco.
public enum Planner {
    struct SourceFile {
        let url: URL
        let relativePath: String
        let size: Int64
        let device: UInt64
    }

    public static func makePlan(root: URL, destination: URL, options: UnifierOptions) throws -> Plan {
        let rootPath = FolderScanner.canonicalPath(root)
        let destPath = FolderScanner.canonicalPath(destination)
        guard FileOps.isAccessibleDirectory(rootPath) else { throw UnifierError.rootNotFound(path: root.path) }
        guard FileOps.isAccessibleDirectory(destPath) else { throw UnifierError.destinationNotFound(path: destination.path) }
        if rootPath == destPath { throw UnifierError.sameRootAndDestination }
        if FolderScanner.isSameOrInside(rootPath, destPath) { throw UnifierError.rootInsideDestination }

        let destURL = URL(fileURLWithPath: destPath, isDirectory: true)
        let scan = FolderScanner.scan(root: root, excluding: destURL)
        var notices = scan.notices
        if scan.folders.isEmpty {
            notices.append(Notice(.warning, "Nenhuma pasta começando com “\(FolderScanner.prefix)” foi encontrada na raiz."))
        }

        let destDevice = FileOps.info(destPath)?.device
        let canClone = options.allowFastPaths && FileOps.volumeSupportsCloning(destURL)

        var groups: [GroupPlan] = []
        var bytesNeeded: Int64 = 0

        for (name, folders) in FolderScanner.group(scan.folders) {
            let dateFolder = DateFolder.dateFolderName(for: name)
            if dateFolder == nil {
                notices.append(Notice(.warning, "“\(name)” não segue o padrão VID_AAAAMMDD_HHMMSS e irá para “\(DateFolder.undatedFolderName)”."))
            }
            if folders.count != options.expectedFoldersPerGroup {
                notices.append(Notice(.warning, "“\(name)”: \(folders.count) pasta(s) de origem (esperado \(options.expectedFoldersPerGroup))."))
            }
            let groupDest = destURL
                .appendingPathComponent(dateFolder ?? DateFolder.undatedFolderName, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)

            var tasks: [FileTask] = []
            var exact: [String: Int] = [:]
            var folded: [String: Int] = [:]

            for folder in folders {
                for file in listFiles(in: folder, excluding: destPath, notices: &notices) {
                    let target = groupDest.appendingPathComponent(file.relativePath)
                    let index = tasks.count
                    let key = foldKey(file.relativePath)

                    if let p = exact[file.relativePath] {
                        let primary = tasks[p]
                        if primary.size != file.size {
                            notices.append(Notice(.critical,
                                "Duplicata com TAMANHO DIFERENTE em “\(name)”: “\(file.relativePath)” — mantido \(primary.source.path) (\(primary.size) bytes), ignorado \(file.url.path) (\(file.size) bytes)."))
                        }
                        tasks.append(FileTask(id: index, source: file.url, relativePath: file.relativePath, size: file.size,
                                              destination: primary.destination, kind: .duplicate(primaryIndex: p, caseOnly: false),
                                              existingDestinationSize: nil))
                        continue
                    }
                    if let p = folded[key] {
                        let primary = tasks[p]
                        let sev: Severity = primary.size != file.size ? .critical : .warning
                        notices.append(Notice(sev,
                            "Nomes que diferem só em maiúsculas/minúsculas em “\(name)”: “\(primary.relativePath)” (\(primary.size) bytes) e “\(file.relativePath)” (\(file.size) bytes). Mantido o primeiro; o segundo fica na origem."))
                        tasks.append(FileTask(id: index, source: file.url, relativePath: file.relativePath, size: file.size,
                                              destination: primary.destination, kind: .duplicate(primaryIndex: p, caseOnly: true),
                                              existingDestinationSize: nil))
                        continue
                    }

                    let sameVolume = options.allowFastPaths && destDevice != nil && destDevice == file.device
                    let method: TransferMethod
                    switch options.mode {
                    case .move: method = sameVolume ? .rename : .stream
                    case .copy: method = (sameVolume && canClone) ? .clone : .stream
                    }
                    let existing = FileOps.info(target.path)?.size
                    if let ex = existing, ex != file.size {
                        notices.append(Notice(.critical,
                            "Conflito: “\(target.path)” já existe com tamanho diferente (\(ex) vs \(file.size) bytes). Não será sobrescrito."))
                    }
                    if existing == nil && method == .stream { bytesNeeded += file.size }

                    exact[file.relativePath] = index
                    folded[key] = index
                    tasks.append(FileTask(id: index, source: file.url, relativePath: file.relativePath, size: file.size,
                                          destination: target, kind: .transfer(method), existingDestinationSize: existing))
                }
            }
            groups.append(GroupPlan(name: name, sourceFolders: folders, dateFolder: dateFolder,
                                    destinationFolder: groupDest, tasks: tasks))
        }

        let free = FileOps.freeSpace(at: destURL)
        if let free, bytesNeeded > free {
            notices.append(Notice(.critical,
                "Espaço insuficiente no destino: necessário \(ByteFormat.string(bytesNeeded)), livre \(ByteFormat.string(free))."))
        }

        return Plan(root: URL(fileURLWithPath: rootPath, isDirectory: true), destination: destURL, options: options,
                    groups: groups, notices: notices, bytesNeeded: bytesNeeded, freeSpace: free)
    }

    static func foldKey(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Lista arquivos (recursivo) preservando o caminho relativo exato.
    static func listFiles(in folder: URL, excluding destPath: String, notices: inout [Notice]) -> [SourceFile] {
        var out: [SourceFile] = []
        func walk(_ dir: String, _ rel: String) {
            let entries: [String]
            do {
                entries = try FileManager.default.contentsOfDirectory(atPath: dir)
            } catch {
                notices.append(Notice(.critical, "Não foi possível ler “\(dir)”: \(error.localizedDescription)"))
                return
            }
            for name in entries.sorted() where !FolderScanner.isIgnored(name) {
                let path = (dir as NSString).appendingPathComponent(name)
                let relPath = rel.isEmpty ? name : rel + "/" + name
                guard let info = FileOps.info(path) else { continue }
                if info.isSymlink {
                    notices.append(Notice(.warning, "Link simbólico ignorado: “\(path)”."))
                } else if info.isDirectory {
                    if FolderScanner.isSameOrInside(path, destPath) { continue }
                    walk(path, relPath)
                } else if info.isRegular {
                    out.append(SourceFile(url: URL(fileURLWithPath: path), relativePath: relPath,
                                          size: info.size, device: info.device))
                }
            }
        }
        walk(FolderScanner.canonicalPath(folder), "")
        return out
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(bytes)
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return "\(bytes) B" }
        let s = String(format: v >= 100 ? "%.0f" : "%.1f", v).replacingOccurrences(of: ".", with: ",")
        return "\(s) \(units[i])"
    }
}
