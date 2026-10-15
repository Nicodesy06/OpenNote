import SwiftUI
import UIKit

/// Condivisione di file tramite Share Sheet di sistema.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// File esportato pronto per la condivisione.
struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Etichetta di stato compatta e riutilizzabile.
struct StatusBadge: View {
    let text: String
    var systemImage: String?
    var color: Color = .secondary

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// Icona della materia con il suo colore.
struct SubjectIcon: View {
    let subject: Subject?
    var size: CGFloat = 28

    var body: some View {
        let color = Color(hex: subject?.colorHex ?? "#6E7B8B")
        Image(systemName: subject?.iconName ?? "tray")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Stato vuoto coerente in tutta l'app.
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
