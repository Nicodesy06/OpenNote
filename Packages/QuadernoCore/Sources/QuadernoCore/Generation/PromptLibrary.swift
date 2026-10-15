import Foundation

/// Prompt interni versionati, caricati dalle risorse del pacchetto. Gli
/// stessi file sono letti dal backend, così app e server condividono le
/// stesse istruzioni. L'utente può sovrascrivere il prompt di sistema dalle
/// impostazioni; il documento registra sempre la versione usata.
public struct PromptLibrary: Sendable {
    public enum Template: String, CaseIterable, Sendable {
        case system
        case outline
        case sectionIntegrale = "section_integrale"
        case sectionPulita = "section_pulita"
        case sectionRiassunto = "section_riassunto"
        case verify
        case repair
    }

    public let version: String
    private let templates: [Template: String]
    public var systemOverride: String?

    public init(version: String, templates: [Template: String], systemOverride: String? = nil) {
        self.version = version
        self.templates = templates
        self.systemOverride = systemOverride
    }

    public enum LoadError: Error, Equatable {
        case missingResource(String)
    }

    /// Carica i prompt dalle risorse del pacchetto (o da una cartella
    /// esplicita, utile per sperimentare con versioni alternative).
    public static func load(from directory: URL? = nil) throws -> PromptLibrary {
        let base: URL
        if let directory {
            base = directory
        } else if let url = Bundle.module.url(forResource: "prompts", withExtension: nil) {
            base = url
        } else {
            throw LoadError.missingResource("prompts")
        }
        var templates: [Template: String] = [:]
        for template in Template.allCases {
            let url = base.appendingPathComponent(template.rawValue + ".md")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw LoadError.missingResource(template.rawValue)
            }
            templates[template] = text
        }
        let version = (try? String(contentsOf: base.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "sconosciuta"
        return PromptLibrary(version: version, templates: templates)
    }

    public func raw(_ template: Template) -> String {
        if template == .system, let override = systemOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        return templates[template] ?? ""
    }

    /// Versione effettiva, che distingue un prompt di sistema personalizzato.
    public var effectiveVersion: String {
        if let override = systemOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return version + "+custom-" + String(format: "%08x", StableHash.fnv1a32(override))
        }
        return version
    }

    public func render(_ template: Template, _ values: [String: String]) -> String {
        Self.fill(raw(template), values)
    }

    /// Sostituisce i segnaposto `{{CHIAVE}}` in un solo passaggio: il testo
    /// inserito (ad esempio la trascrizione) non viene mai rielaborato, anche
    /// se contiene a sua volta parentesi graffe.
    public static func fill(_ template: String, _ values: [String: String]) -> String {
        var output = ""
        output.reserveCapacity(template.count + values.values.reduce(0) { $0 + $1.count })
        var index = template.startIndex
        while index < template.endIndex {
            if template[index...].hasPrefix("{{"),
               let close = template.range(of: "}}", range: template.index(index, offsetBy: 2)..<template.endIndex) {
                let key = String(template[template.index(index, offsetBy: 2)..<close.lowerBound])
                if key.allSatisfy({ $0.isUppercase || $0 == "_" }), !key.isEmpty {
                    output += values[key] ?? ""
                    index = close.upperBound
                    continue
                }
            }
            output.append(template[index])
            index = template.index(after: index)
        }
        return output
    }
}
