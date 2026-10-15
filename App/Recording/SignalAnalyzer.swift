import AVFoundation
import Accelerate

/// Misura del livello del segnale a costo minimo: RMS e picco per buffer con
/// vDSP (poche decine di operazioni vettoriali ogni ~90 ms). Nessuna
/// elaborazione spettrale o AI durante la registrazione.
final class SignalAnalyzer: @unchecked Sendable {
    struct Snapshot: Equatable {
        var rmsDB: Float
        var peakDB: Float
        var quality: SignalQuality
        var capturedDuration: TimeInterval
    }

    enum SignalQuality: Equatable {
        case unknown
        case good
        case low
        case clipping

        var message: String? {
            switch self {
            case .unknown, .good: return nil
            case .low: return "Segnale molto basso: avvicina l'iPad o usa un microfono esterno."
            case .clipping: return "Segnale distorto: allontana il microfono o riduci il guadagno."
            }
        }
    }

    private let lock = NSLock()
    private var lastRMS: Float = -160
    private var lastPeak: Float = -160
    private var history: [Float] = []
    private var historyIndex = 0
    private var clipTimes: [TimeInterval] = []
    private var captured: TimeInterval = 0
    private let historyCapacity = 120 // ~10-12 s di buffer

    func reset() {
        lock.lock()
        lastRMS = -160
        lastPeak = -160
        history.removeAll(keepingCapacity: true)
        historyIndex = 0
        clipTimes.removeAll()
        captured = 0
        lock.unlock()
    }

    /// Imposta la durata già acquisita (ripresa dopo pausa o recupero).
    func setCapturedDuration(_ value: TimeInterval) {
        lock.lock()
        captured = value
        lock.unlock()
    }

    /// Chiamato dal thread del tap audio con un buffer mono float.
    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = vDSP_Length(buffer.frameLength)
        guard count > 0 else { return }
        var rms: Float = 0
        var peak: Float = 0
        vDSP_rmsqv(data, 1, &rms, count)
        vDSP_maxmgv(data, 1, &peak, count)
        let rmsDB = 20 * log10(max(rms, 1e-8))
        let peakDB = 20 * log10(max(peak, 1e-8))
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate

        lock.lock()
        lastRMS = rmsDB
        lastPeak = peakDB
        captured += seconds
        if history.count < historyCapacity {
            history.append(rmsDB)
        } else {
            history[historyIndex] = rmsDB
            historyIndex = (historyIndex + 1) % historyCapacity
        }
        if peakDB > -0.3 {
            clipTimes.append(captured)
        }
        if let first = clipTimes.first, captured - first > 10 {
            clipTimes.removeAll { captured - $0 > 10 }
        }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let rms = lastRMS
        let peak = lastPeak
        let values = history
        let clips = clipTimes.count
        let duration = captured
        lock.unlock()
        return Snapshot(rmsDB: rms, peakDB: peak, quality: Self.evaluate(history: values, recentClips: clips, capacity: historyCapacity), capturedDuration: duration)
    }

    /// Valuta la qualità sul 90° percentile dei livelli recenti (stima del
    /// livello del parlato, insensibile alle pause).
    static func evaluate(history: [Float], recentClips: Int, capacity: Int) -> SignalQuality {
        guard history.count >= capacity * 2 / 3 else { return .unknown }
        if recentClips >= 3 { return .clipping }
        let sorted = history.sorted()
        let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        if p90 < -52 { return .low }
        return .good
    }
}
