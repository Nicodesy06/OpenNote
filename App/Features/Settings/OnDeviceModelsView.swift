import SwiftUI
import QuadernoCore
import QuadernoOnDevice

/// Scelta e download dei modelli di trascrizione sul dispositivo.
struct OnDeviceModelsView: View {
    @Environment(AppServices.self) private var services
    @EnvironmentObject private var settings: AppSettings
    @State private var pendingDelete: OnDeviceModel?

    private var store: OnDeviceModelStore { services.onDeviceModels }
    private var recommendedID: String { DeviceProfile.recommendedOnDeviceModel.id }

    var body: some View {
        List {
            Section {
                ForEach(OnDeviceModelCatalog.all) { model in
                    OnDeviceModelRow(
                        model: model,
                        state: model.requiresDownload ? store.state(for: model) : .installed(bytes: 0),
                        isSelected: settings.onDeviceModelID == model.id,
                        isRecommended: model.id == recommendedID,
                        unavailableReason: unavailableReason(model),
                        select: { settings.onDeviceModelID = model.id },
                        download: { store.download(model) },
                        cancel: { store.cancelDownload(model) },
                        delete: { pendingDelete = model }
                    )
                }
            } header: {
                Text("Modelli")
            } footer: {
                Text("I modelli vengono scaricati una sola volta da Hugging Face (repository CoreML di FluidInference e Argmax) e poi funzionano senza rete. Il punteggio di accuratezza è indicativo: dipende molto dalla qualità dell'audio e dal lessico della materia.")
            }

            Section {
                LabeledContent("Spazio occupato", value: Format.bytes(store.totalBytes))
                LabeledContent("Questo iPad", value: "iPadOS \(DeviceProfile.osMajor) · \(DeviceProfile.ramGB) GB di RAM")
            } footer: {
                Text("I modelli sono esclusi dal backup di iCloud: dopo un ripristino si possono riscaricare. Durante la trascrizione resta in memoria un solo modello alla volta.")
            }
        }
        .navigationTitle("Modelli di trascrizione")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.refresh() }
        .confirmationDialog(
            "Eliminare \(pendingDelete?.displayName ?? "il modello")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Elimina", role: .destructive) {
                if let model = pendingDelete {
                    Task { await store.delete(model) }
                }
                pendingDelete = nil
            }
            Button("Annulla", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Le trascrizioni già fatte restano. Per usarlo di nuovo andrà riscaricato.")
        }
    }

    private func unavailableReason(_ model: OnDeviceModel) -> String? {
        if model.minimumOSMajor > DeviceProfile.osMajor {
            return "Richiede iPadOS \(model.minimumOSMajor) o successivo."
        }
        if model.minimumRAMGB > DeviceProfile.ramGB {
            return "Richiede almeno \(model.minimumRAMGB) GB di RAM: su questo iPad sarebbe lento o verrebbe interrotto dal sistema."
        }
        return nil
    }
}

private struct OnDeviceModelRow: View {
    let model: OnDeviceModel
    let state: OnDeviceModelStore.State
    let isSelected: Bool
    let isRecommended: Bool
    let unavailableReason: String?
    let select: () -> Void
    let download: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    private var isAvailable: Bool { unavailableReason == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: select) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!isAvailable)
            .accessibilityLabel(isSelected ? "Selezionato" : "Seleziona \(model.displayName)")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.displayName).font(.headline)
                    if isRecommended { ModelBadge(text: "Consigliato", color: .green) }
                    if !model.requiresDownload { ModelBadge(text: "Di sistema", color: .blue) }
                }
                Text(model.summary).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Label(model.languageSummary, systemImage: "globe")
                    if model.requiresDownload {
                        Text("·")
                        Text(Format.bytes(Int64(model.approximateSizeMB) * 1_000_000))
                    }
                    if model.timestamps == .none {
                        Text("·")
                        Text("tempi approssimati")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !model.supports(languages: ["it"]) {
                    Text("Non trascrive l'italiano: utile solo per lezioni nelle lingue indicate.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let unavailableReason {
                    Text(unavailableReason).font(.caption).foregroundStyle(.orange)
                }
                if case .failed(let message) = state {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if isAvailable { select() } }

            trailing
        }
        .padding(.vertical, 4)
        .opacity(isAvailable ? 1 : 0.6)
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .installed(let bytes):
            if model.requiresDownload {
                Menu {
                    Button("Elimina (\(Format.bytes(bytes)))", systemImage: "trash", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "checkmark.seal.fill").font(.title3).foregroundStyle(.green)
                }
                .accessibilityLabel("Scaricato, opzioni")
            }
        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 4) {
                if progress.phase == .preparing {
                    ProgressView().controlSize(.small)
                    Text("Preparazione…").font(.caption2).foregroundStyle(.secondary)
                } else {
                    ProgressView(value: progress.fraction).frame(width: 80)
                    Text("\(Int(progress.fraction * 100))%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                Button("Annulla", action: cancel).font(.caption).buttonStyle(.borderless)
            }
        case .notInstalled, .failed:
            Button(action: download) {
                Label("Scarica", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .disabled(!isAvailable)
        }
    }
}

private struct ModelBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
