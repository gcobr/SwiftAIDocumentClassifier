import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            PreviewZoomCommands()
        }
    }
}
