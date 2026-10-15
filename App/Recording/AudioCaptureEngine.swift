import AVFoundation
import Accelerate
import os

/// Acquisizione audio con AVAudioEngine: un solo tap sull'ingresso, downmix
/// in mono, guadagno opzionale, misura dei livelli e consegna dei buffer al
/// writer su una coda seriale dedicata. È indipendente dall'interfaccia e
/// dall'editor PencilKit: continua a funzionare a schermo bloccato grazie
/// alla modalità audio in background, senza timer né task di UI.
final class AudioCaptureEngine: @unchecked Sendable {
    enum CaptureError: Error, LocalizedError {
        case noInputAvailable
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInputAvailable: return "Nessun microfono disponibile."
            case .engineStartFailed(let message): return "Avvio dell'acquisizione non riuscito: \(message)"
            }
        }
    }

    private(set) var engine = AVAudioEngine()
    let analyzer = SignalAnalyzer()
    let writerQueue = DispatchQueue(label: "it.quadernoai.audio-writer", qos: .userInitiated)
    private let logger = Logger(subsystem: "QuadernoAI", category: "AudioCaptureEngine")

    /// Accesso solo da `writerQueue`.
    private var writer: SegmentedAudioWriter?
    private let stateLock = NSLock()
    private var acceptingBuffers = false
    private var gainLinear: Float = 1
    private var writeFailed = false

    /// Errore di scrittura (es. spazio esaurito): chiamato sulla coda del writer.
    var onWriteError: ((Error) -> Void)?

    // MARK: - Ciclo di vita

    func attach(writer: SegmentedAudioWriter) {
        writerQueue.sync { self.writer = writer }
    }

    func setGain(decibels: Double) {
        stateLock.lock()
        gainLinear = Float(pow(10, decibels / 20))
        stateLock.unlock()
    }

    /// Installa il tap con il formato corrente dell'hardware e avvia il motore.
    func start(voiceProcessing: Bool) throws {
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(voiceProcessing)
            } catch {
                logger.error("Voice processing non configurabile: \(error.localizedDescription, privacy: .public)")
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputAvailable }
        input.removeTap(onBus: 0)
        // Buffer di 4096 frame (~85-93 ms): pochi risvegli al secondo.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        setAccepting(true)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            setAccepting(false)
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
    }

    /// Ferma il motore e chiude (finalizza) il segmento corrente.
    func stopAndCloseSegment() {
        setAccepting(false)
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        writerQueue.sync {
            self.writer?.closeCurrentSegment()
        }
    }

    /// Ricrea il motore (dopo un reset dei servizi audio di sistema).
    func rebuildEngine() {
        setAccepting(false)
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        engine = AVAudioEngine()
    }

    /// Restituisce i segmenti finali; da chiamare dopo `stopAndCloseSegment`.
    func finishedSegments() -> [SegmentedAudioWriter.Segment] {
        writerQueue.sync { writer?.segments ?? [] }
    }

    func detachWriter() {
        writerQueue.sync { writer = nil }
    }

    var isRunning: Bool { engine.isRunning }

    var inputFormatDescription: String {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return String(format: "%.0f Hz, %d canali", format.sampleRate, format.channelCount)
    }

    // MARK: - Tap

    private func setAccepting(_ value: Bool) {
        stateLock.lock()
        acceptingBuffers = value
        stateLock.unlock()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let accepting = acceptingBuffers && !writeFailed
        let gain = gainLinear
        stateLock.unlock()
        guard accepting, let mono = Self.makeMono(buffer, gain: gain) else { return }
        analyzer.process(mono)
        writerQueue.async { [weak self] in
            guard let self, let writer = self.writer else { return }
            do {
                try writer.write(mono)
            } catch {
                self.stateLock.lock()
                self.writeFailed = true
                self.stateLock.unlock()
                self.logger.error("Errore di scrittura audio: \(error.localizedDescription, privacy: .public)")
                self.onWriteError?(error)
            }
        }
    }

    func resetWriteFailure() {
        stateLock.lock()
        writeFailed = false
        stateLock.unlock()
    }

    /// Converte il buffer di ingresso in un nuovo buffer mono float32 (copia
    /// propria: il buffer del tap può essere riutilizzato dal sistema).
    static func makeMono(_ buffer: AVAudioPCMBuffer, gain: Float) -> AVAudioPCMBuffer? {
        let frames = buffer.frameLength
        guard frames > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames),
              let destination = output.floatChannelData?[0] else { return nil }
        output.frameLength = frames
        let channels = Int(buffer.format.channelCount)
        let count = vDSP_Length(frames)

        if let source = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                // Dati interlacciati nel primo puntatore: media con passo.
                let interleaved = source[0]
                vDSP_mmov(interleaved, destination, 1, count, vDSP_Length(channels), 1)
                if channels > 1 {
                    for channel in 1..<channels {
                        vDSP_vadd(destination, 1, interleaved.advanced(by: channel), vDSP_Stride(channels), destination, 1, count)
                    }
                }
            } else {
                destination.update(from: source[0], count: Int(frames))
                if channels > 1 {
                    for channel in 1..<channels {
                        vDSP_vadd(destination, 1, source[channel], 1, destination, 1, count)
                    }
                }
            }
            var scale = gain / Float(max(1, channels))
            if scale != 1 {
                vDSP_vsmul(destination, 1, &scale, destination, 1, count)
            }
        } else if let source = buffer.int16ChannelData {
            // Ingressi interi a 16 bit (raro): conversione in float.
            vDSP_vflt16(source[0], 1, destination, 1, count)
            var scale = gain / 32768
            vDSP_vsmul(destination, 1, &scale, destination, 1, count)
        } else {
            return nil
        }
        if gain > 1 {
            var low: Float = -1
            var high: Float = 1
            vDSP_vclip(destination, 1, &low, &high, destination, 1, count)
        }
        return output
    }
}
