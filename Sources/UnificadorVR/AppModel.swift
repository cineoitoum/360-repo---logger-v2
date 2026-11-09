#if canImport(SwiftUI)
import AppKit
import Foundation
import SwiftUI
import UnificadorCore

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case idle, analyzing, previewReady, running, finished }

    @Published var root: URL? { didSet { invalidate() } }
    @Published var destination: URL? { didSet { invalidate() } }
    @Published var mode: TransferMode = .copy { didSet { invalidate() } }
    @Published var verifyChecksum = true { didSet { invalidate() } }
    @Published var expectedFolders = 7 { didSet { invalidate() } }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var plan: Plan?
    @Published private(set) var progress = ExecutionProgress()
    @Published private(set) var summary: ExecutionSummary?
    /// Avisos da pré-visualização que geraram a última execução (mostrados no resumo).
    @Published private(set) var lastPlanNotices: [Notice] = []
    @Published var errorMessage: String?
    @Published var showConfirmation = false

    private var token: CancellationToken?
    private var generation = 0

    var options: UnifierOptions {
        UnifierOptions(mode: mode, verifyChecksum: verifyChecksum, expectedFoldersPerGroup: expectedFolders)
    }

    var isBusy: Bool { phase == .analyzing || phase == .running }
    var canAnalyze: Bool { root != nil && destination != nil && !isBusy }
    var canExecute: Bool { phase == .previewReady && plan.map { $0.totalFiles > 0 } == true }

    var confirmationMessage: String {
        var parts: [String] = []
        if mode == .move {
            parts.append("No modo Mover, cada original é apagado da origem depois que a cópia for confirmada"
                + (verifyChecksum ? " por tamanho e checksum." : " por tamanho (checksum desligado)."))
        }
        if let plan, plan.insufficientSpace {
            parts.append("O destino parece não ter espaço suficiente (necessário \(ByteFormat.string(plan.bytesNeeded)), livre \(ByteFormat.string(plan.freeSpace ?? 0))). A cópia vai parar quando o disco encher.")
        }
        return parts.joined(separator: "\n\n")
    }

    private func invalidate() {
        guard phase != .running else { return }
        generation += 1
        plan = nil
        summary = nil
        phase = .idle
    }

    // MARK: - Seleção de pastas

    func chooseRoot() {
        if let u = pickFolder(message: "Escolha a pasta raiz com o conteúdo dos cartões") { root = u }
    }

    func chooseDestination() {
        if let u = pickFolder(message: "Escolha a pasta de destino") { destination = u }
    }

    private func pickFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = "Escolher"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Aceita só pastas vindas de arrastar e soltar.
    static func folderURL(from urls: [URL]) -> URL? {
        guard let u = urls.first else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return u
    }

    // MARK: - Pré-visualização

    func analyze() {
        guard let root, let destination, !isBusy else { return }
        let opts = options
        generation += 1
        let gen = generation
        phase = .analyzing
        plan = nil
        summary = nil
        errorMessage = nil
        Task {
            let result: Result<Plan, Error> = await Task.detached(priority: .userInitiated) {
                Result(catching: { try Planner.makePlan(root: root, destination: destination, options: opts) })
            }.value
            guard gen == self.generation else { return }  // entradas mudaram durante a análise
            switch result {
            case let .success(p):
                self.plan = p
                self.phase = .previewReady
            case let .failure(e):
                self.errorMessage = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
                self.phase = .idle
            }
        }
    }

    // MARK: - Execução

    func requestExecute() {
        guard canExecute else { return }
        if mode == .move || plan?.insufficientSpace == true {
            showConfirmation = true
        } else {
            execute()
        }
    }

    func execute() {
        guard let plan, canExecute else { return }
        let token = CancellationToken()
        self.token = token
        lastPlanNotices = plan.notices
        progress = ExecutionProgress()
        summary = nil
        phase = .running
        Task {
            let result = await Executor().run(plan: plan, token: token) { p in
                Task { @MainActor [weak self] in
                    guard let self, self.phase == .running else { return }
                    self.progress = p
                }
            }
            self.summary = result
            self.phase = .finished
            self.plan = nil  // nova execução (ou retomada) exige nova pré-visualização
            self.token = nil
        }
    }

    func cancel() {
        token?.cancel()
    }

    // MARK: - Finder

    func openLog() {
        if let u = summary?.logURL { NSWorkspace.shared.open(u) }
    }

    func revealLog() {
        if let u = summary?.logURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    func openDestination() {
        if let d = destination { NSWorkspace.shared.open(d) }
    }
}
#endif
