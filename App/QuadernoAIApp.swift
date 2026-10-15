import BackgroundTasks
import SwiftUI
import UIKit

@main
struct QuadernoAIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var services: AppServices
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let services = AppServices()
        AppServices.shared = services
        _services = State(initialValue: services)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services)
                .environment(services.recording)
                .environment(services.playback)
                .environment(services.jobs)
                .environment(services.network)
                .environmentObject(services.settings)
                .modelContainer(services.modelContainer)
                .task { await services.startup() }
                .onOpenURL { url in services.handleIncoming(url: url) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                services.jobs.processQueue()
            }
            if phase == .background {
                services.drawingStore.flush()
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: JobRunner.backgroundTaskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                guard let services = AppServices.shared else {
                    task.setTaskCompleted(success: false)
                    return
                }
                services.jobs.handleBackgroundProcessing(task)
            }
        }
        BackgroundUploadTransport.shared.reconnect()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        BackgroundUploadTransport.shared.setBackgroundCompletionHandler(completionHandler)
    }
}
