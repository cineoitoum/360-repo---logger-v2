import Foundation
import XCTest
@testable import UnificadorCore

final class DateFolderTests: XCTestCase {
    func testExtractsDate() {
        XCTAssertEqual(DateFolder.dateFolderName(for: "VID_20261108_162608"), "261108")
        XCTAssertEqual(DateFolder.dateFolderName(for: "VID_20280229_000000"), "280229")  // ano bissexto
        XCTAssertEqual(DateFolder.dateFolderName(for: "VID_20991231_235959"), "991231")
    }

    func testRejectsNonStandardNames() {
        for name in ["VID_2026110_162608", "VID_20261108_16260", "VID_20261108_162608_1", "VID_20261108-162608",
                     "VID_20261308_162608", "VID_20261100_162608", "VID_20260229_120000", "VID_20261131_120000",
                     "VID_20261108_246000", "VID_20261108_166008", "VID_2026A108_162608", "VID_20261108_162608 ",
                     "vid_20261108_162608", "VID_20_teste"] {
            XCTAssertNil(DateFolder.dateFolderName(for: name), name)
        }
    }
}

final class ChecksumTests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(Checksum.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Checksum.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Checksum.sha256Hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(Checksum.sha256Hex(Data(repeating: UInt8(ascii: "a"), count: 1_000_000)),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testFileHashMatchesInMemoryWithOddChunks() throws {
        let t = try TempDir()
        let data = randomData(300_001)
        let u = try t.file("x.bin", data)
        for chunk in [1, 63, 64, 65, 4096, 1 << 20] {
            XCTAssertEqual(try Checksum.sha256Hex(fileAt: u, chunkSize: chunk), Checksum.sha256Hex(data), "chunk \(chunk)")
        }
    }
}

final class ScannerTests: XCTestCase {
    func testGroupsByExactName() throws {
        let t = try TempDir()
        try t.file("raiz/card1/VID_20261108_162608/origin_1.mp4", "1")
        try t.file("raiz/card2/DCIM/VID_20261108_162608/origin_2.mp4", "2")
        try t.file("raiz/card3/VID_20261108_162609/origin_3.mp4", "3")
        try t.file("raiz/card4/VID_20261108_162608_extra/x.mp4", "4")  // nome diferente: outro grupo
        try t.file("raiz/card5/vid_20261108_162608/y.mp4", "5")        // minúsculas: não casa com o prefixo
        try t.file("raiz/card6/IMG_20261108_162608/z.jpg", "6")

        let scan = FolderScanner.scan(root: t.url.appendingPathComponent("raiz"), excluding: nil)
        let groups = FolderScanner.group(scan.folders)
        XCTAssertEqual(groups.map(\.name), ["VID_20261108_162608", "VID_20261108_162608_extra", "VID_20261108_162609"])
        XCTAssertEqual(groups[0].folders.count, 2)
        XCTAssertEqual(groups[1].folders.count, 1)
        XCTAssertEqual(groups[2].folders.count, 1)
    }

    func testDoesNotDescendIntoFoundFolder() throws {
        let t = try TempDir()
        try t.file("raiz/VID_20261108_162608/VID_20261108_999999/dentro.mp4", "x")
        try t.file("raiz/VID_20261108_162608/a.mp4", "a")
        let scan = FolderScanner.scan(root: t.url.appendingPathComponent("raiz"), excluding: nil)
        XCTAssertEqual(scan.folders.map(\.lastPathComponent), ["VID_20261108_162608"])
    }

    func testDestinationInsideRootIsIgnored() throws {
        let t = try TempDir()
        try t.file("raiz/c1/VID_20261108_162608/a.mp4", "a")
        try t.file("raiz/c2/VID_20261108_162608/b.mp4", "b")
        let root = t.url.appendingPathComponent("raiz")
        let dest = try t.dir("raiz/saida")

        let plan1 = try makePlan(root, dest)
        XCTAssertEqual(plan1.groups.count, 1)
        XCTAssertEqual(plan1.groups[0].sourceFolders.count, 2)
        let s1 = execute(plan1)
        XCTAssertTrue(s1.succeeded, "\(s1.errors)")
        XCTAssertEqual(t.files(under: "raiz/saida"), ["261108/VID_20261108_162608/a.mp4", "261108/VID_20261108_162608/b.mp4"])

        // Segunda varredura: a pasta já unificada dentro do destino não pode virar uma 3ª origem.
        let plan2 = try makePlan(root, dest)
        XCTAssertEqual(plan2.groups[0].sourceFolders.count, 2)
        XCTAssertFalse(plan2.groups[0].sourceFolders.contains { $0.path.contains("/saida/") })
    }

    func testRootInsideDestinationIsRejected() throws {
        let t = try TempDir()
        let dest = try t.dir("destino")
        let root = try t.dir("destino/261108")
        XCTAssertThrowsError(try makePlan(root, dest)) { XCTAssertEqual($0 as? UnifierError, .rootInsideDestination) }
        XCTAssertThrowsError(try makePlan(dest, dest)) { XCTAssertEqual($0 as? UnifierError, .sameRootAndDestination) }
    }

    func testIgnoresSystemFiles() throws {
        let t = try TempDir()
        try t.file("raiz/c1/VID_20261108_162608/origin_1.mp4", "v")
        try t.file("raiz/c1/VID_20261108_162608/.DS_Store", "x")
        try t.file("raiz/c1/VID_20261108_162608/._origin_1.mp4", "x")
        try t.file("raiz/c1/VID_20261108_162608/.Trashes/lixo", "x")
        let dest = try t.dir("destino")
        let s = execute(try makePlan(t.url.appendingPathComponent("raiz"), dest))
        XCTAssertTrue(s.succeeded)
        XCTAssertEqual(t.files(under: "destino"), ["261108/VID_20261108_162608/origin_1.mp4"])
    }
}

final class UnifyTests: XCTestCase {
    func testNonStandardNameGoesToUndatedWithWarning() throws {
        let t = try TempDir()
        try t.file("raiz/c1/VID_2026_teste/a.mp4", "a")
        try t.file("raiz/c1/VID_20261108_162608/b.mp4", "b")
        let dest = try t.dir("destino")
        let plan = try makePlan(t.url.appendingPathComponent("raiz"), dest)
        XCTAssertTrue(plan.notices.contains { $0.severity >= .warning && $0.message.contains("VID_2026_teste") && $0.message.contains("_sem_data") })
        let g = plan.groups.first { $0.name == "VID_2026_teste" }!
        XCTAssertNil(g.dateFolder)
        XCTAssertEqual(g.destinationDateFolderName, "_sem_data")
        XCTAssertTrue(execute(plan).succeeded)
        XCTAssertEqual(t.files(under: "destino"), ["261108/VID_20261108_162608/b.mp4", "_sem_data/VID_2026_teste/a.mp4"])
    }

    func testRealDuplicateFirstCopiedOthersSkippedNeverOverwritten() throws {
        let t = try TempDir()
        try t.file("raiz/c1/VID_20261108_162608/dup.mp4", "PRIMEIRO")
        try t.file("raiz/c2/VID_20261108_162608/dup.mp4", "SEGUNDO-MAIOR")      // tamanho diferente
        try t.file("raiz/c3/VID_20261108_162608/dup.mp4", "PRIMEIRO")           // idêntico
        let root = t.url.appendingPathComponent("raiz")
        let dest = try t.dir("destino")

        let plan = try makePlan(root, dest)
        let g = plan.groups[0]
        XCTAssertEqual(g.fileCount, 1)
        XCTAssertEqual(g.duplicateCount, 2)
        XCTAssertTrue(plan.notices.contains { $0.severity == .critical && $0.message.contains("TAMANHO DIFERENTE") })

        let s = execute(plan)
        XCTAssertTrue(s.succeeded, "\(s.errors)")
        XCTAssertEqual(s.copied, 1)
        XCTAssertEqual(s.skippedDuplicates, 2)
        XCTAssertEqual(try t.read("destino/261108/VID_20261108_162608/dup.mp4"), "PRIMEIRO")
        let log = try logText(s)
        XCTAssertEqual(log.components(separatedBy: "pulado como duplicata").count - 1, 2)
        XCTAssertTrue(log.contains("TAMANHO DIFERENTE"))
        // Origens intocadas no modo Copiar.
        XCTAssertEqual(try t.read("raiz/c2/VID_20261108_162608/dup.mp4"), "SEGUNDO-MAIOR")

        // Nunca sobrescreve: mesmo que a origem mude depois, o destino fica igual (conflito).
        try t.file("raiz/c1/VID_20261108_162608/dup.mp4", "MUDOU-DE-TAMANHO")
        let s2 = execute(try makePlan(root, dest))
        XCTAssertEqual(s2.conflicts, 1)
        XCTAssertEqual(try t.read("destino/261108/VID_20261108_162608/dup.mp4"), "PRIMEIRO")
    }

    func testProxiesWithSameBaseNameAreAllCopied() throws {
        let t = try TempDir()
        try t.file("raiz/lente1/VID_20261108_162608/origin_1.mp4", "lente")
        try t.file("raiz/proxy/VID_20261108_162608/origin_1.insv", "proxy-insv")
        try t.file("raiz/proxy/VID_20261108_162608/origin_1.lrv", "proxy-lrv")
        try t.file("raiz/proxy/VID_20261108_162608/origin_1.MP4.thumb", "thumb")
        let dest = try t.dir("destino")
        let plan = try makePlan(t.url.appendingPathComponent("raiz"), dest)
        XCTAssertEqual(plan.totalDuplicates, 0)
        let s = execute(plan)
        XCTAssertEqual(s.copied, 4)
        XCTAssertEqual(t.files(under: "destino/261108/VID_20261108_162608"),
                       ["origin_1.MP4.thumb", "origin_1.insv", "origin_1.lrv", "origin_1.mp4"])
    }

    func testNamesArePreservedExactly() throws {
        let t = try TempDir()
        let names = ["Arquivo Ação (1).MP4", "UPPER.Mp4", "dois  espaços.mp4", "sem_extensao", "pré-visualização.jpg",
                     "ponto.final.", "sub pasta/interno.MOV"]
        for (i, n) in names.enumerated() { try t.file("raiz/c\(i % 3)/VID_20261108_162608/\(n)", n) }
        let dest = try t.dir("destino")
        let s = execute(try makePlan(t.url.appendingPathComponent("raiz"), dest))
        XCTAssertTrue(s.succeeded, "\(s.errors)")
        XCTAssertEqual(t.files(under: "destino/261108/VID_20261108_162608"), names.sorted())
        for n in names { XCTAssertEqual(try t.read("destino/261108/VID_20261108_162608/\(n)"), n) }
        // Origem com os mesmos nomes de antes.
        XCTAssertTrue(t.exists("raiz/c0/VID_20261108_162608/Arquivo Ação (1).MP4"))
        XCTAssertEqual(FileManager.default.subpaths(atPath: t.url.appendingPathComponent("destino/261108").path)?.contains("VID_20261108_162608"), true)
    }

    func testSevenCardsOnePerLensPlusProxyEndUpTogether() throws {
        let t = try TempDir()
        let take = "VID_20261108_162608"
        var expected: [String] = []
        for lens in 1...6 {
            for n in 0..<2 {
                let name = "origin_\(lens)_\(n).mp4"
                try t.file("raiz/microSD\(lens)/\(take)/\(name)", randomData(1000 + lens * 10 + n, seed: UInt8(lens)))
                expected.append(name)
            }
        }
        for name in ["preview.mp4", "preview.insv", "pro.prj", "gyro.dat"] {
            try t.file("raiz/SD_proxy/\(take)/\(name)", name)
            expected.append(name)
        }
        try t.file("raiz/microSD1/VID_20261109_101010/origin_1_0.mp4", "outro take")  // grupo incompleto
        let dest = try t.dir("destino")

        let plan = try makePlan(t.url.appendingPathComponent("raiz"), dest)
        let g = plan.groups.first { $0.name == take }!
        XCTAssertEqual(g.sourceFolders.count, 7)
        XCTAssertFalse(g.sourceCountMismatch(expected: 7))
        XCTAssertFalse(plan.notices.contains { $0.message.contains(take) })
        XCTAssertTrue(plan.notices.contains { $0.message.contains("VID_20261109_101010") && $0.message.contains("esperado 7") })

        let s = execute(plan)
        XCTAssertTrue(s.succeeded, "\(s.errors)")
        XCTAssertEqual(t.files(under: "destino/261108/\(take)"), expected.sorted())
        XCTAssertEqual(t.files(under: "destino/261109"), ["VID_20261109_101010/origin_1_0.mp4"])
        for lens in 1...6 {
            let d = try Data(contentsOf: t.url.appendingPathComponent("destino/261108/\(take)/origin_\(lens)_1.mp4"))
            XCTAssertEqual(d, randomData(1000 + lens * 10 + 1, seed: UInt8(lens)))
        }
    }

    func testCaseOnlyCollisionKeepsFirstAndWarns() throws {
        let t = try TempDir()
        try t.file("raiz/c1/VID_20261108_162608/Origin.MP4", "AAAA")
        try t.file("raiz/c2/VID_20261108_162608/origin.mp4", "BBBBBBBB")
        let dest = try t.dir("destino")
        let plan = try makePlan(t.url.appendingPathComponent("raiz"), dest, UnifierOptions(mode: .move))
        XCTAssertTrue(plan.notices.contains { $0.severity == .critical && $0.message.contains("maiúsculas") })
        let s = execute(plan)
        XCTAssertEqual(t.files(under: "destino/261108/VID_20261108_162608"), ["Origin.MP4"])
        XCTAssertEqual(try t.read("destino/261108/VID_20261108_162608/Origin.MP4"), "AAAA")
        XCTAssertTrue(t.exists("raiz/c2/VID_20261108_162608/origin.mp4"), "o segundo nunca é apagado")
        XCTAssertEqual(s.keptInSource, 1)
    }

    func testCancellationLeavesOnlyPartialAndResumeCleansUp() throws {
        let t = try TempDir()
        let big = randomData(2_000_000, seed: 7)
        try t.file("raiz/c1/VID_20261108_162608/a_pequeno.mp4", "pequeno")
        try t.file("raiz/c2/VID_20261108_162608/b_grande.mp4", big)
        let root = t.url.appendingPathComponent("raiz")
        let dest = try t.dir("destino")
        let opts = UnifierOptions(allowFastPaths: false)

        let token = CancellationToken()
        let s1 = execute(try makePlan(root, dest, opts), chunkSize: 64 * 1024, token: token) { p in
            if p.currentFile == "b_grande.mp4" && p.currentFileDone >= 128 * 1024 { token.cancel() }
        }
        XCTAssertTrue(s1.cancelled)
        let folder = "destino/261108/VID_20261108_162608"
        XCTAssertEqual(t.files(under: folder), ["a_pequeno.mp4", "b_grande.mp4.partial"])
        XCTAssertFalse(t.exists("\(folder)/b_grande.mp4"), "arquivo final incompleto nunca deve existir")
        XCTAssertTrue(t.exists("raiz/c2/VID_20261108_162608/b_grande.mp4"))

        // Retomada.
        let s2 = execute(try makePlan(root, dest, opts))
        XCTAssertTrue(s2.succeeded, "\(s2.errors)")
        XCTAssertEqual(s2.partialsRemoved, 1)
        XCTAssertEqual(s2.alreadyPresent, 1, "o arquivo completo não é refeito")
        XCTAssertEqual(s2.copied, 1)
        XCTAssertEqual(t.files(under: folder), ["a_pequeno.mp4", "b_grande.mp4"])
        XCTAssertEqual(try Data(contentsOf: t.url.appendingPathComponent("\(folder)/b_grande.mp4")), big)
    }

    func testOrphanCleanupKeepsLegitimatePartialNamedFiles() throws {
        let t = try TempDir()
        try t.file("raiz/c1/VID_20261108_162608/legitimo.partial", "do usuário")
        let root = t.url.appendingPathComponent("raiz")
        let dest = try t.dir("destino")
        XCTAssertTrue(execute(try makePlan(root, dest)).succeeded)
        let s = execute(try makePlan(root, dest))
        XCTAssertEqual(s.partialsRemoved, 0)
        XCTAssertEqual(try t.read("destino/261108/VID_20261108_162608/legitimo.partial"), "do usuário")
    }

    func testMoveWithChecksumDeletesOnlyVerifiedSources() throws {
        let t = try TempDir()
        try t.file("raiz/c1/VID_20261108_162608/a.mp4", "conteudo A")
        try t.file("raiz/c1/VID_20261108_162608/dup.mp4", "IGUAL")
        try t.file("raiz/c2/VID_20261108_162608/dup.mp4", "IGUAL")        // idêntica → removida da origem
        try t.file("raiz/c3/VID_20261108_162608/dup.mp4", "IGUAX")        // mesmo tamanho, checksum diferente → fica
        try t.file("raiz/c4/VID_20261108_162608/dup.mp4", "MAIOR!!")      // tamanho diferente → fica
        let dest = try t.dir("destino")
        let plan = try makePlan(t.url.appendingPathComponent("raiz"), dest,
                                UnifierOptions(mode: .move, verifyChecksum: true, allowFastPaths: false))
        let s = execute(plan)
        XCTAssertTrue(s.errors.isEmpty, "\(s.errors)")
        XCTAssertEqual(s.moved, 2)
        XCTAssertEqual(s.keptInSource, 2)
        XCTAssertFalse(t.exists("raiz/c1/VID_20261108_162608/a.mp4"))
        XCTAssertFalse(t.exists("raiz/c1/VID_20261108_162608/dup.mp4"))
        XCTAssertFalse(t.exists("raiz/c2/VID_20261108_162608/dup.mp4"))
        XCTAssertEqual(try t.read("raiz/c3/VID_20261108_162608/dup.mp4"), "IGUAX")
        XCTAssertEqual(try t.read("raiz/c4/VID_20261108_162608/dup.mp4"), "MAIOR!!")
        XCTAssertEqual(try t.read("destino/261108/VID_20261108_162608/dup.mp4"), "IGUAL")
        XCTAssertTrue(s.notices.contains { $0.severity == .critical })
        // Pastas de origem não são apagadas nem renomeadas.
        XCTAssertTrue(FileOps.isAccessibleDirectory(t.url.appendingPathComponent("raiz/c1/VID_20261108_162608").path))
    }

    func testMoveSameVolumeUsesDirectRename() throws {
        let t = try TempDir()
        try t.file("raiz/c1/VID_20261108_162608/a.mp4", "A")
        try t.file("raiz/c2/VID_20261108_162608/b.mp4", "B")
        let dest = try t.dir("destino")
        let plan = try makePlan(t.url.appendingPathComponent("raiz"), dest, UnifierOptions(mode: .move))
        XCTAssertEqual(plan.groups[0].tasks.map(\.kind), [.transfer(.rename), .transfer(.rename)])
        XCTAssertEqual(plan.bytesNeeded, 0)
        let s = execute(plan)
        XCTAssertEqual(s.moved, 2)
        XCTAssertEqual(t.files(under: "raiz"), [])
        XCTAssertEqual(t.files(under: "destino"), ["261108/VID_20261108_162608/a.mp4", "261108/VID_20261108_162608/b.mp4"])
    }

    func testExistingDifferentFileInDestinationIsNeverOverwritten() throws {
        let t = try TempDir()
        try t.file("raiz/c1/VID_20261108_162608/a.mp4", "novo conteúdo")
        try t.file("destino/261108/VID_20261108_162608/a.mp4", "antigo")
        let dest = t.url.appendingPathComponent("destino")
        for mode in TransferMode.allCases {
            let plan = try makePlan(t.url.appendingPathComponent("raiz"), dest, UnifierOptions(mode: mode))
            XCTAssertTrue(plan.notices.contains { $0.message.contains("Conflito") })
            let s = execute(plan)
            XCTAssertEqual(s.conflicts, 1)
            XCTAssertEqual(try t.read("destino/261108/VID_20261108_162608/a.mp4"), "antigo")
            XCTAssertTrue(t.exists("raiz/c1/VID_20261108_162608/a.mp4"))
        }
    }

    func testCSVLogFormat() throws {
        let t = try TempDir()
        try t.file("raiz/c1/VID_20261108_162608/nome;com\"aspas.mp4", "x")
        let s = execute(try makePlan(t.url.appendingPathComponent("raiz"), try t.dir("destino")))
        let data = try Data(contentsOf: s.logURL!)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines[0], "origem;destino;ação;tamanho;resultado")
        XCTAssertEqual(lines.count, 2)
        // Campo inteiro entre aspas, aspas internas duplicadas (RFC 4180).
        XCTAssertTrue(lines[1].hasPrefix("\"/"), lines[1])
        XCTAssertTrue(lines[1].contains("/nome;com\"\"aspas.mp4\";"), lines[1])
        XCTAssertTrue(lines[1].contains(";copiado;1;"))
    }

    func testProgressReachesTotal() throws {
        let t = try TempDir()
        try t.file("raiz/c1/VID_20261108_162608/a.mp4", randomData(300_000))
        try t.file("raiz/c2/VID_20261108_162608/b.mp4", randomData(100_000, seed: 3))
        final class Box: @unchecked Sendable { var last = ExecutionProgress() }
        let box = Box()
        let s = execute(try makePlan(t.url.appendingPathComponent("raiz"), try t.dir("destino"),
                                     UnifierOptions(allowFastPaths: false))) { box.last = $0 }
        XCTAssertTrue(s.succeeded)
        XCTAssertEqual(box.last.totalWork, 800_000)  // cópia + verificação
        XCTAssertEqual(box.last.doneWork, box.last.totalWork)
        XCTAssertEqual(box.last.filesDone, 2)
        XCTAssertEqual(s.bytesWritten, 400_000)
    }
}
