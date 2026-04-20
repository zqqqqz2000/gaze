import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: GazeDemoViewModel

    var body: some View {
        NavigationView {
            Form {
                Section("Provider") {
                    keyValueRow("State", value: viewModel.stateText)
                    keyValueRow("Confidence", value: viewModel.confidenceText)
                    keyValueRow("Face Distance", value: viewModel.faceDistanceText)
                    keyValueRow("Samples", value: "\(viewModel.sampleCount)")

                    HStack {
                        Button("Start Tracking") {
                            viewModel.startTracking()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Stop") {
                            viewModel.stopTracking()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("Streaming") {
                    TextField("Host IP", text: $viewModel.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.decimalPad)

                    TextField("Port", text: $viewModel.port)
                        .keyboardType(.numberPad)

                    Toggle("Send Samples To Host", isOn: $viewModel.isStreaming)
                        .onChange(of: viewModel.isStreaming) { enabled in
                            viewModel.setStreaming(enabled: enabled)
                        }
                }

                Section("Latest Sample") {
                    keyValueRow("Origin", value: viewModel.originText)
                    keyValueRow("Direction", value: viewModel.directionText)
                }

                Section("Log") {
                    if viewModel.logLines.isEmpty {
                        Text("No events yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.footnote, design: .monospaced))
                        }
                    }
                }
            }
            .navigationTitle("Gaze Demo")
        }
        .navigationViewStyle(.stack)
        .onAppear {
            guard viewModel.shouldAutoStart, viewModel.stateText == "idle" else {
                return
            }
            viewModel.startTracking()
        }
    }

    private func keyValueRow(_ key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: GazeDemoViewModel())
    }
}
