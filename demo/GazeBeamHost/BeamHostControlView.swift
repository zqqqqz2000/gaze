import SwiftUI

struct BeamHostControlView: View {
    @ObservedObject var viewModel: BeamHostViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Connection") {
                VStack(alignment: .leading, spacing: 10) {
                    keyValueRow("Listener", value: "\(viewModel.serverStatus) on \(viewModel.listenerPort)")
                    keyValueRow("Client", value: viewModel.connectionStatus)
                    keyValueRow("Samples", value: "\(viewModel.sampleCount)")
                    keyValueRow("Confidence", value: viewModel.confidenceText)
                    keyValueRow("Last Point", value: viewModel.pointText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Beam") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show Overlay", isOn: $viewModel.overlayEnabled)
                    Toggle("Preview Motion", isOn: $viewModel.previewEnabled)

                    HStack {
                        Text("Size")
                        Slider(value: $viewModel.beamSize, in: 40...180, step: 1)
                        Text("\(Int(viewModel.beamSize)) px")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }

            GroupBox("Calibration") {
                VStack(alignment: .leading, spacing: 10) {
                    keyValueRow("Status", value: viewModel.calibrationStatus)
                    Text(viewModel.calibrationDetail)
                        .foregroundStyle(.secondary)
                        .font(.system(.footnote))
                    HStack {
                        Button(viewModel.isCalibrating ? "Calibrating..." : "Start Calibration") {
                            viewModel.startCalibration()
                        }
                        .disabled(viewModel.isCalibrating)

                        Button("Clear Calibration") {
                            viewModel.clearCalibration()
                        }
                        .disabled(!viewModel.hasCalibration && !viewModel.isCalibrating)
                    }
                }
            }

            GroupBox("Connect iPhone") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On the iPhone demo, set Host IP to one of these addresses and Port to \(viewModel.listenerPort).")
                        .foregroundStyle(.secondary)
                    if viewModel.localAddresses.isEmpty {
                        Text("No local IPv4 address detected.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.localAddresses, id: \.self) { address in
                            Text("\(address):\(viewModel.listenerPort)")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Log") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(18)
    }

    private func keyValueRow(_ key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
