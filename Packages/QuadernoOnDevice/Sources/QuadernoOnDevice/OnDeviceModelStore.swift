import Foundation
import Observation
import QuadernoCore

/// Posizione e stato dei file dei modelli sul disco.
public enum OnDeviceModelFiles {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("OnDeviceModels", isDirectory: true)
    }

    /// Un modello è pronto solo dopo download **e** primo caricamento
    /// riusciti; il marcatore distingue un download interrotto da uno
    /// completo.
    static func readyMarker(_ model: OnDeviceModel) -> URL {
        root.appendingPathComponent("ready/\(model.id)", isDirectory: false)
    }

    static func directories(_ model: OnDeviceModel) -> [URL] {
        switch model.engine {
        case .fluidAudio:
            return FluidAudioEngine.directory(engineModel: model.engineModel).map { [$0] } ?? []
        case .whisperKit:
            return [WhisperKitEngine.modelFolder(variant: model.engineModel)]
        case .appleSpeech:
            return []
        }
    }

    public static func isInstalled(_ model: OnDeviceModel) -> Bool {
        guard model.requiresDownload else { return true }
        guard FileManager.default.fileExists(atPath: readyMarker(model).path) else { return false }
        switch model.engine {
        case .fluidAudio: return FluidAudioEngine.isDownloaded(engineModel: model.engineModel)
        case .whisperKit: return WhisperKitEngine.isDownloaded(variant: model.engineModel)
        case .appleSpeech: return true
        }
    }

    public static func diskUsage(_ model: OnDeviceModel) -> Int64 {
        directories(model).reduce(0) { $0 + size(of: $1) }
    }

    static func size(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// I modelli si possono riscaricare: non vanno nel backup di iCloud.
    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}

/// Download, preparazione ed eliminazione dei modelli sul dispositivo.
@MainActor
@Observable
public final class OnDeviceModelStore {
    public enum State: Equatable {
        case notInstalled
        case downloading(OnDeviceProgress)
        case installed(bytes: Int64)
        case failed(String)
    }

    public private(set) var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    public init() {
        refresh()
    }

    public func state(for model: OnDeviceModel) -> State {
        states[model.id] ?? .notInstalled
    }

    public func isInstalled(_ model: OnDeviceModel) -> Bool {
        if case .installed = state(for: model) { return true }
        return !model.requiresDownload
    }

    public var totalBytes: Int64 {
        states.values.reduce(0) { total, state in
            if case .installed(let bytes) = state { return total + bytes }
            return total
        }
    }

    /// Rilegge lo stato dal disco (all'avvio e dopo ogni operazione).
    public func refresh() {
        for model in OnDeviceModelCatalog.all where model.requiresDownload {
            if tasks[model.id] != nil { continue }
            if OnDeviceModelFiles.isInstalled(model) {
                states[model.id] = .installed(bytes: OnDeviceModelFiles.diskUsage(model))
            } else if case .failed = states[model.id] {
                continue
            } else {
                states[model.id] = .notInstalled
            }
        }
    }

    public func download(_ model: OnDeviceModel) {
        guard model.requiresDownload, tasks[model.id] == nil else { return }
        states[model.id] = .downloading(OnDeviceProgress(fraction: 0, phase: .downloading))
        let id = model.id
        tasks[id] = Task { [weak self] in
            let report: OnDeviceProgressHandler = { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.tasks[id] != nil else { return }
                    self.states[id] = .downloading(progress)
                }
            }
            do {
                try FileManager.default.createDirectory(at: OnDeviceModelFiles.readyMarker(model).deletingLastPathComponent(), withIntermediateDirectories: true)
                let directory: URL
                switch model.engine {
                case .fluidAudio:
                    directory = try await FluidAudioEngine.shared.download(engineModel: model.engineModel, progress: report)
                case .whisperKit:
                    directory = try await WhisperKitEngine.shared.download(variant: model.engineModel, progress: report)
                case .appleSpeech:
                    return
                }
                try Task.checkCancellation()
                OnDeviceModelFiles.excludeFromBackup(directory)
                OnDeviceModelFiles.excludeFromBackup(OnDeviceModelFiles.root)
                let marker = Data("\(model.id)\n\(Date().timeIntervalSince1970)\n".utf8)
                try marker.write(to: OnDeviceModelFiles.readyMarker(model), options: .atomic)
                self?.finish(id: id, state: nil)
            } catch is CancellationError {
                self?.finish(id: id, state: .notInstalled)
            } catch {
                self?.finish(id: id, state: .failed(Self.describe(error)))
            }
        }
    }

    public func cancelDownload(_ model: OnDeviceModel) {
        tasks[model.id]?.cancel()
    }

    public func delete(_ model: OnDeviceModel) async {
        tasks[model.id]?.cancel()
        // Il modello caricato va rilasciato prima di cancellarne i file.
        switch model.engine {
        case .fluidAudio: await FluidAudioEngine.shared.unload()
        case .whisperKit: await WhisperKitEngine.shared.unload()
        case .appleSpeech: return
        }
        try? FileManager.default.removeItem(at: OnDeviceModelFiles.readyMarker(model))
        for directory in OnDeviceModelFiles.directories(model) {
            try? FileManager.default.removeItem(at: directory)
        }
        states[model.id] = .notInstalled
        refresh()
    }

    /// Libera la memoria dei modelli caricati (es. su avviso di memoria).
    public func unloadAll() async {
        await FluidAudioEngine.shared.unload()
        await WhisperKitEngine.shared.unload()
    }

    private func finish(id: String, state: State?) {
        tasks[id] = nil
        if let state {
            states[id] = state
        } else {
            states[id] = nil
        }
        refresh()
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost: return "Connessione assente: il download riprenderà dai file già scaricati."
            case .timedOut: return "Il server non risponde. Riprova più tardi."
            default: break
            }
        }
        if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSFileWriteOutOfSpaceError {
            return "Spazio insufficiente sull'iPad."
        }
        return error.localizedDescription
    }
}
