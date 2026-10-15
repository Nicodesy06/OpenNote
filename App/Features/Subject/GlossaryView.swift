import PDFKit
import SwiftUI

/// Glossario della materia: grafie corrette di nomi e termini tecnici,
/// inviate come parole chiave al provider di trascrizione (nei limiti
/// supportati) e come riferimento per la rielaborazione.
struct GlossaryView: View {
    @Bindable var subject: Subject
    @Environment(AppServices.self) private var services
    @State private var newTerm = ""
    @State private var suggestions: [String] = []
    @State private var showingSuggestions = false

    private var terms: [String] { subject.glossary?.terms ?? [] }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Aggiungi un termine (es. Walter Gropius)", text: $newTerm)
                        .onSubmit(add)
                        .submitLabel(.done)
                    Button("Aggiungi", action: add)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("Usato per migliorare il riconoscimento di nomi, sigle e termini tecnici. Una correzione ortografica plausibile non rende verificabile un contenuto che l'audio non contiene.")
            }
            Section("Termini (\(terms.count))") {
                if terms.isEmpty {
                    Text("Nessun termine").foregroundStyle(.secondary)
                }
                ForEach(terms, id: \.self) { term in
                    Text(term)
                }
                .onDelete { offsets in
                    var updated = terms
                    updated.remove(atOffsets: offsets)
                    save(updated)
                }
            }
            if !subject.materials.isEmpty {
                Section {
                    Button("Suggerisci termini dai PDF della materia", systemImage: "wand.and.stars") {
                        suggestions = GlossarySuggester.suggest(from: subject.materials.map { services.fileStore.materialURL(fileName: $0.fileName) }, excluding: terms)
                        showingSuggestions = true
                    }
                } footer: {
                    Text("Analisi locale del testo dei PDF (nomi propri e termini ricorrenti). Scegli tu quali aggiungere.")
                }
            }
        }
        .sheet(isPresented: $showingSuggestions) {
            GlossarySuggestionsSheet(suggestions: suggestions) { selected in
                save(terms + selected)
            }
        }
    }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        guard !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else {
            newTerm = ""
            return
        }
        save(terms + [term])
        newTerm = ""
    }

    private func save(_ updated: [String]) {
        if subject.glossary == nil {
            let glossary = SubjectGlossary()
            glossary.subject = subject
            subject.glossary = glossary
        }
        var seen = Set<String>()
        subject.glossary?.terms = updated.filter { seen.insert($0.lowercased()).inserted }
        subject.glossary?.updatedAt = Date()
        services.content.save()
    }
}

struct GlossarySuggestionsSheet: View {
    let suggestions: [String]
    let onAdd: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()

    var body: some View {
        NavigationStack {
            List(suggestions, id: \.self, selection: $selected) { term in
                Text(term)
            }
            .environment(\.editMode, .constant(.active))
            .overlay {
                if suggestions.isEmpty {
                    EmptyStateView(title: "Nessun suggerimento", systemImage: "text.magnifyingglass", message: "Non sono stati trovati termini ricorrenti nei PDF.")
                }
            }
            .navigationTitle("Termini suggeriti")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aggiungi \(selected.count)") {
                        onAdd(suggestions.filter { selected.contains($0) })
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

/// Estrazione euristica locale di candidati per il glossario.
enum GlossarySuggester {
    static func suggest(from urls: [URL], excluding existing: [String], limit: Int = 60) -> [String] {
        var counts: [String: Int] = [:]
        let stopwords: Set<String> = ["Il", "La", "Lo", "Le", "Gli", "I", "Un", "Una", "In", "Per", "Con", "Del", "Della", "Dei", "Nel", "Nella", "Questo", "Questa", "Capitolo", "Figura", "Tabella", "Pagina", "Fonte", "The", "And", "Of"]
        for url in urls {
            guard let document = PDFDocument(url: url) else { continue }
            let pageLimit = min(document.pageCount, 300)
            for index in 0..<pageLimit {
                guard let text = document.page(at: index)?.string else { continue }
                let words = text.split(whereSeparator: { $0.isWhitespace || ",;:()[]\"«»“”".contains($0) }).map(String.init)
                var position = 0
                while position < words.count {
                    let word = words[position].trimmingCharacters(in: .punctuationCharacters)
                    guard let first = word.first, first.isUppercase, word.count > 2, !stopwords.contains(word) else {
                        position += 1
                        continue
                    }
                    // Sequenze di parole maiuscole (es. "Deutscher Werkbund").
                    var phrase = [word]
                    var next = position + 1
                    while next < words.count, phrase.count < 4 {
                        let candidate = words[next].trimmingCharacters(in: .punctuationCharacters)
                        guard let initial = candidate.first, initial.isUppercase, candidate.count > 1 else { break }
                        phrase.append(candidate)
                        next += 1
                    }
                    let key = phrase.joined(separator: " ")
                    counts[key, default: 0] += 1
                    position = next
                }
            }
        }
        let existingLower = Set(existing.map { $0.lowercased() })
        return counts
            .filter { $0.value >= 3 && !existingLower.contains($0.key.lowercased()) && $0.key.count <= 60 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }
}

/// Impostazioni AI specifiche della materia.
struct SubjectAISettingsView: View {
    @Bindable var subject: Subject
    @Environment(AppServices.self) private var services
    @State private var languagesText = ""

    var body: some View {
        Form {
            Section {
                TextField("Lingua dei documenti", text: $subject.documentLanguage)
            } header: {
                Text("Sbobinatura")
            } footer: {
                Text("Lingua in cui viene scritta la sbobinatura (predefinita: italiano).")
            }
            Section {
                TextField("Codici lingua, es. it, en", text: $languagesText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(saveLanguages)
            } header: {
                Text("Lingue parlate a lezione")
            } footer: {
                Text("Codici ISO 639-1 separati da virgola. Lascia vuoto per il rilevamento automatico. Indica più lingue se il docente alterna, ad esempio, italiano e inglese.")
            }
            Section {
                TextEditor(text: $subject.aiInstructions)
                    .frame(minHeight: 120)
            } header: {
                Text("Indicazioni per l'AI")
            } footer: {
                Text("Es.: «Mantieni le formule in notazione LaTeX», «Il docente usa spesso esempi di architettura viennese». Le indicazioni non possono autorizzare l'AI ad aggiungere contenuti non detti a lezione.")
            }
        }
        .onAppear { languagesText = subject.transcriptionLanguages.joined(separator: ", ") }
        .onDisappear {
            saveLanguages()
            services.content.save()
        }
    }

    private func saveLanguages() {
        subject.transcriptionLanguages = languagesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.count >= 2 && $0.count <= 3 && $0.allSatisfy(\.isLetter) }
        services.content.save()
    }
}
