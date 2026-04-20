import SwiftUI

@main
struct GazeDemoApp: App {
    @StateObject private var viewModel = GazeDemoViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }
}
