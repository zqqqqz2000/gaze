import SwiftUI

@main
struct GazeBeamHostApp: App {
    @StateObject private var viewModel = BeamHostViewModel()

    var body: some Scene {
        WindowGroup("Gaze Beam Host") {
            BeamHostControlView(viewModel: viewModel)
                .frame(minWidth: 420, minHeight: 620)
                .onAppear {
                    viewModel.startIfNeeded()
                }
        }
    }
}
