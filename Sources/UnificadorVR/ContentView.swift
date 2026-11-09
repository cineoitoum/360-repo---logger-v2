#if canImport(SwiftUI)
import SwiftUI
import UnificadorCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                StepBox(number: 1, title: "Pasta raiz") {
                    FolderField(url: model.root,
                                placeholder: "Arraste aqui a pasta com o conteúdo dos cartões, ou clique em Escolher…",
                                choose: model.chooseRoot,
                                drop: { model.root = $0 })
                }
                StepBox(number: 2, title: "Pasta de destino") {
                    FolderField(url: model.destination,
                                placeholder: "Obrigatória. Arraste aqui ou clique em Escolher…",
                                choose: model.chooseDestination,
                                drop: { model.destination = $0 })
                }
                StepBox(number: 3, title: "Modo") { ModeSection() }
                StepBox(number: 4, title: "Pré-visualização") { PreviewSection() }
                StepBox(number: 5, title: "Execução") { ExecutionSection() }
                if let summary = model.summary {
                    StepBox(number: 6, title: "Resumo") { SummarySection(summary: summary) }
                }
            }
            .padding(20)
        }
        .alert("Não foi possível continuar",
               isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Confirmar execução", isPresented: $model.showConfirmation) {
            Button(model.mode == .move ? "Mover" : "Executar mesmo assim", role: .destructive) { model.execute() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(model.confirmationMessage)
        }
    }
}

// MARK: - Componentes

struct StepBox<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        } label: {
            Text("\(number). \(title)").font(.headline)
        }
    }
}

struct FolderField: View {
    @EnvironmentObject private var model: AppModel
    let url: URL?
    let placeholder: String
    let choose: () -> Void
    let drop: (URL) -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: url == nil ? "folder.badge.plus" : "folder.fill")
                .foregroundStyle(url == nil ? Color.secondary : Color.accentColor)
            Text(url?.path ?? placeholder)
                .foregroundStyle(url == nil ? Color.secondary : Color.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Escolher…", action: choose)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: url == nil ? [5] : []))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = AppModel.folderURL(from: urls) else { return false }
            drop(folder)
            return true
        } isTargeted: { targeted = $0 }
        .disabled(model.isBusy)
    }
}

struct ModeSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Modo", selection: $model.mode) {
                Text("Copiar (originais intocados)").tag(TransferMode.copy)
                Text("Mover").tag(TransferMode.move)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            Toggle("Verificar checksum (SHA-256) depois de copiar", isOn: $model.verifyChecksum)
            if model.mode == .move {
                Text(model.verifyChecksum
                     ? "Cada original só é apagado depois de tamanho e checksum conferirem. No mesmo volume, a movimentação é direta."
                     : "Atenção: sem checksum, o original é apagado depois de conferir só o tamanho.")
                    .font(.callout)
                    .foregroundStyle(model.verifyChecksum ? Color.secondary : Color.orange)
            }
            Stepper("Pastas esperadas por grupo: \(model.expectedFolders)", value: $model.expectedFolders, in: 1...30)
                .frame(maxWidth: 320, alignment: .leading)
        }
        .disabled(model.isBusy)
    }
}

struct PreviewSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack {
            Button {
                model.analyze()
            } label: {
                Label(model.plan == nil ? "Analisar" : "Analisar de novo", systemImage: "magnifyingglass")
            }
            .disabled(!model.canAnalyze)
            if model.phase == .analyzing {
                ProgressView().controlSize(.small)
                Text("Varrendo pastas…").foregroundStyle(.secondary)
            } else if model.root == nil || model.destination == nil {
                Text("Escolha a raiz e o destino para analisar.").foregroundStyle(.secondary)
            }
        }

        if let plan = model.plan {
            let expected = plan.options.expectedFoldersPerGroup
            Table(plan.groups) {
                TableColumn("Pasta") { g in Text(g.name).textSelection(.enabled) }
                    .width(min: 180, ideal: 210)
                TableColumn("Origens") { g in
                    HStack(spacing: 4) {
                        Text("\(g.sourceFolders.count)").monospacedDigit()
                        if g.sourceCountMismatch(expected: expected) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help("Esperado \(expected)")
                        }
                    }
                }
                .width(70)
                TableColumn("Arquivos") { g in Text("\(g.fileCount)").monospacedDigit() }
                    .width(70)
                TableColumn("Duplicatas") { g in
                    Text(g.duplicateCount == 0 ? "—" : "\(g.duplicateCount)")
                        .monospacedDigit()
                        .foregroundStyle(g.duplicateCount == 0 ? Color.secondary : Color.orange)
                }
                .width(80)
                TableColumn("Tamanho") { g in Text(ByteFormat.string(g.totalBytes)).monospacedDigit() }
                    .width(90)
                TableColumn("Destino") { g in
                    Text("\(g.destinationDateFolderName)/")
                        .foregroundStyle(g.dateFolder == nil ? Color.orange : Color.primary)
                }
                .width(min: 90, ideal: 100)
            }
            .frame(minHeight: 180, idealHeight: 260)

            HStack(spacing: 18) {
                Text("\(plan.groups.count) grupo(s) · \(plan.totalFiles) arquivo(s) · \(ByteFormat.string(plan.totalBytes))")
                if plan.totalDuplicates > 0 {
                    Text("\(plan.totalDuplicates) duplicata(s) serão puladas").foregroundStyle(.orange)
                }
                Spacer()
                SpaceLabel(plan: plan)
            }
            .font(.callout)

            if !plan.notices.isEmpty {
                NoticeList(notices: plan.notices, title: "Avisos da análise")
            }
        }
    }
}

struct SpaceLabel: View {
    let plan: Plan
    var body: some View {
        let free = plan.freeSpace.map(ByteFormat.string) ?? "desconhecido"
        if plan.insufficientSpace {
            Label("Espaço insuficiente: precisa \(ByteFormat.string(plan.bytesNeeded)), livre \(free)",
                  systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.red)
        } else {
            Text("Espaço necessário \(ByteFormat.string(plan.bytesNeeded)) · livre \(free)")
                .foregroundStyle(.secondary)
        }
    }
}

struct NoticeList: View {
    let notices: [Notice]
    let title: String

    var sorted: [Notice] { notices.sorted { $0.severity > $1.severity } }

    var body: some View {
        DisclosureGroup("\(title) (\(notices.count))") {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sorted) { n in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: icon(n.severity)).foregroundStyle(color(n.severity))
                            Text(n.message)
                                .fontWeight(n.severity == .critical ? .semibold : .regular)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
    }

    func icon(_ s: Severity) -> String {
        switch s {
        case .critical: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    func color(_ s: Severity) -> Color {
        switch s {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}

struct ExecutionSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack {
            Button {
                model.requestExecute()
            } label: {
                Label(model.mode == .move ? "Executar (mover)" : "Executar (copiar)", systemImage: "play.fill")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canExecute)
            if model.phase == .running {
                Button(role: .cancel) { model.cancel() } label: { Label("Cancelar", systemImage: "stop.fill") }
            }
            if !model.canExecute && model.phase != .running {
                Text(model.phase == .finished ? "Para executar de novo (ou retomar), analise novamente."
                                              : "Disponível depois da pré-visualização.")
                    .foregroundStyle(.secondary)
            }
        }

        if model.phase == .running {
            let p = model.progress
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: p.fraction) {
                    Text("Geral: \(Int(p.fraction * 100))% · \(p.filesDone) de \(p.filesTotal) arquivo(s)")
                }
                ProgressView(value: p.fileFraction) {
                    Text(p.currentFile.isEmpty ? "Preparando…" : "\(p.currentPhase.capitalized): \(p.currentFile)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 18) {
                    Text("\(ByteFormat.string(p.currentFileDone)) de \(ByteFormat.string(p.currentFileTotal))")
                    Text("Velocidade: \(p.bytesPerSecond > 0 ? ByteFormat.string(Int64(p.bytesPerSecond)) + "/s" : "—")")
                    Text("Restante: \(formatETA(p.etaSeconds))")
                }
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct SummarySection: View {
    @EnvironmentObject private var model: AppModel
    let summary: ExecutionSummary

    var body: some View {
        if let fatal = summary.fatalError {
            Label(fatal, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.headline)
        } else if summary.cancelled {
            Label("Cancelado. Nada foi corrompido: o arquivo em andamento ficou como .partial e será apagado ao executar de novo; os completos não serão refeitos.",
                  systemImage: "pause.circle.fill")
                .foregroundStyle(.orange)
        } else if summary.errors.isEmpty {
            Label("Concluído sem erros.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
        } else {
            Label("Concluído com \(summary.errors.count) erro(s).", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.headline)
        }

        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
            GridRow {
                Text("Copiados: \(summary.copied)")
                Text("Movidos: \(summary.moved)")
                Text("Duplicatas puladas: \(summary.skippedDuplicates)")
            }
            GridRow {
                Text("Já presentes (retomada): \(summary.alreadyPresent)")
                Text("Conflitos: \(summary.conflicts)").foregroundStyle(summary.conflicts > 0 ? Color.red : Color.primary)
                Text("Mantidos na origem: \(summary.keptInSource)")
                    .foregroundStyle(summary.keptInSource > 0 ? Color.orange : Color.primary)
            }
            GridRow {
                Text("Gravado: \(ByteFormat.string(summary.bytesWritten))")
                Text("Tempo: \(formatETA(summary.duration))")
                Text(".partial órfãos removidos: \(summary.partialsRemoved)")
            }
        }
        .monospacedDigit()

        let allNotices = model.lastPlanNotices + summary.notices
        if !allNotices.isEmpty {
            NoticeList(notices: allNotices, title: "Avisos")
        }
        if !summary.errors.isEmpty {
            NoticeList(notices: summary.errors.map { Notice(.critical, $0) }, title: "Erros")
        }

        HStack {
            Button("Abrir log") { model.openLog() }.disabled(summary.logURL == nil)
            Button("Mostrar log no Finder") { model.revealLog() }.disabled(summary.logURL == nil)
            Button("Abrir pasta de destino") { model.openDestination() }
        }
    }
}

func formatETA(_ seconds: Double?) -> String {
    guard let s = seconds, s.isFinite, s >= 0 else { return "—" }
    let total = Int(s.rounded())
    let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
#endif
