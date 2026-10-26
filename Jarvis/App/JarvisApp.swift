import SwiftUI

@main
struct JarvisApp: App {
    @State private var jarvis = JarvisAssistant()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(jarvis)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}
