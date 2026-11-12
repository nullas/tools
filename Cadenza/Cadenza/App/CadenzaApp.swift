import SwiftUI

@main
struct CadenzaApp: App {
    @State private var library = Library()
    @State private var progress = ProgressStore()
    @State private var input = InputManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(progress)
                .environment(input)
                .tint(Theme.accent)
                .task { input.start() }
        }
    }
}
