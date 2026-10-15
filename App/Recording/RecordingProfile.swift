import AVFoundation

/// Profili di acquisizione. Le modalità di AVAudioSession NON sono
/// equivalenti: `.default` applica l'elaborazione standard di sistema
/// (incluso il controllo automatico del guadagno sui microfoni integrati),
/// `.measurement` la disattiva, il voice processing aggiunge cancellazione
/// dell'eco e soppressione del rumore. Nessun profilo può recuperare parole
/// che il microfono non ha acquisito: per aule grandi un microfono esterno
/// vicino al docente resta la soluzione migliore.
enum RecordingProfileID: String, CaseIterable, Identifiable, Codable {
    case classroom
    case classroomRaw
    case closeVoice

    var id: String { rawValue }
}

struct RecordingProfile: Equatable {
    let id: RecordingProfileID
    let displayName: String
    let summary: String
    let sessionMode: AVAudioSession.Mode
    let voiceProcessing: Bool
    let appliesSoftwareGain: Bool
    let isExperimental: Bool

    static func profile(for id: RecordingProfileID) -> RecordingProfile {
        switch id {
        case .classroom:
            return RecordingProfile(
                id: .classroom,
                displayName: "Aula (consigliato)",
                summary: "Elaborazione standard di iPadOS con controllo automatico del guadagno: alza le voci lontane senza soppressione aggressiva del rumore.",
                sessionMode: .default,
                voiceProcessing: false,
                appliesSoftwareGain: false,
                isExperimental: false)
        case .classroomRaw:
            return RecordingProfile(
                id: .classroomRaw,
                displayName: "Aula — segnale grezzo (sperimentale)",
                summary: "Disattiva l'elaborazione di sistema (modalità misurazione) e applica un guadagno digitale configurabile. Segnale più fedele, utile con microfoni esterni di qualità; verificalo con una registrazione di prova.",
                sessionMode: .measurement,
                voiceProcessing: false,
                appliesSoftwareGain: true,
                isExperimental: true)
        case .closeVoice:
            return RecordingProfile(
                id: .closeVoice,
                displayName: "Voce vicina, ambiente rumoroso",
                summary: "Riduzione del rumore e cancellazione dell'eco di sistema. Può attenuare o cancellare voci lontane: sconsigliato per le lezioni in aula.",
                sessionMode: .default,
                voiceProcessing: true,
                appliesSoftwareGain: false,
                isExperimental: false)
        }
    }
}

/// Parametri di codifica: AAC in M4A, mono, bitrate configurabile.
struct EncodingSettings: Equatable, Codable {
    var bitrate: Int
    var segmentDuration: TimeInterval

    static let allowedBitrates = [48_000, 64_000, 96_000]

    func fileSettings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitrate
        ]
    }

    /// Byte stimati per ora di registrazione.
    var bytesPerHour: Int64 { Int64(bitrate / 8) * 3600 }
}
