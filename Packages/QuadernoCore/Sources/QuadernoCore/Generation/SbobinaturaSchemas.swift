import Foundation

/// Schemi JSON per gli output strutturati (scaletta e verifica). Rispettano
/// sia le regole Anthropic sia la modalità strict di OpenAI: ogni oggetto ha
/// `additionalProperties: false` e tutti i campi sono obbligatori.
enum SbobinaturaSchemas {
    static let keyItemKinds: [JSONValue] = ["definizione", "esempio", "nome", "data", "numero", "riferimento", "concetto", "domanda", "correzione", "avviso"]

    static let outline = JSONSchemaSpec(name: "lesson_outline", schema: [
        "type": "object",
        "additionalProperties": false,
        "required": ["lessonTitle", "sections"],
        "properties": [
            "lessonTitle": ["type": "string"],
            "sections": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["title", "firstSegment", "lastSegment", "summary", "keyItems"],
                    "properties": [
                        "title": ["type": "string"],
                        "firstSegment": ["type": "integer"],
                        "lastSegment": ["type": "integer"],
                        "summary": ["type": "string"],
                        "keyItems": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "additionalProperties": false,
                                "required": ["kind", "text"],
                                "properties": [
                                    "kind": ["type": "string", "enum": .array(keyItemKinds)],
                                    "text": ["type": "string"]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    ])

    static let verification = JSONSchemaSpec(name: "section_verification", schema: [
        "type": "object",
        "additionalProperties": false,
        "required": ["issues", "unverifiable"],
        "properties": [
            "issues": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["type", "severity", "description", "sourceSegments", "excerpt"],
                    "properties": [
                        "type": ["type": "string", "enum": ["omission", "altered_value", "date_changed", "name_changed", "unsupported_claim", "wrong_correction", "other"]],
                        "severity": ["type": "string", "enum": ["high", "medium", "low"]],
                        "description": ["type": "string"],
                        "sourceSegments": ["type": "array", "items": ["type": "integer"]],
                        "excerpt": ["type": "string"]
                    ]
                ]
            ],
            "unverifiable": ["type": "array", "items": ["type": "string"]]
        ]
    ])

    /// Estrae l'oggetto JSON dal testo del modello, tollerando recinti
    /// ``` o testo accessorio.
    static func extractJSONObject(_ text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return Data(text[start...end].utf8)
    }

    struct OutlinePayload: Decodable {
        var lessonTitle: String
        var sections: [OutlineSection]
    }

    struct VerificationPayload: Decodable {
        struct Issue: Decodable {
            var type: String
            var severity: String
            var description: String
            var sourceSegments: [Int]
            var excerpt: String
        }
        var issues: [Issue]
        var unverifiable: [String]
    }

    static func decodeOutline(_ text: String) throws -> OutlinePayload {
        guard let data = extractJSONObject(text) else { throw AIServiceError.decoding("Scaletta non in formato JSON") }
        do {
            return try JSONDecoder().decode(OutlinePayload.self, from: data)
        } catch {
            throw AIServiceError.decoding("Scaletta JSON non conforme: \(error)")
        }
    }

    static func decodeVerification(_ text: String) throws -> VerificationPayload {
        guard let data = extractJSONObject(text) else { throw AIServiceError.decoding("Verifica non in formato JSON") }
        do {
            return try JSONDecoder().decode(VerificationPayload.self, from: data)
        } catch {
            throw AIServiceError.decoding("Verifica JSON non conforme: \(error)")
        }
    }
}
