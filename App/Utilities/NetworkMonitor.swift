import Foundation
import Network
import Observation

/// Stato della connessione, per mettere in attesa i lavori cloud senza rete
/// e riprenderli automaticamente al ritorno della connessione.
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isConnected = true
    private(set) var isExpensive = false
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored var onReconnect: (() -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected = connected
                self.isExpensive = expensive
                if connected && !wasConnected { self.onReconnect?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "it.quadernoai.network", qos: .utility))
    }
}
