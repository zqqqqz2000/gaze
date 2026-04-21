import SwiftUI

struct BeamHostControlView: View {
    @ObservedObject var viewModel: BeamHostViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Connection") {
                VStack(alignment: .leading, spacing: 10) {
                    keyValueRow("LAN Listener", value: "\(viewModel.serverStatus) on \(viewModel.listenerPort)")
                    keyValueRow("LAN Client", value: viewModel.connectionStatus)
                    keyValueRow("USB Bridge", value: viewModel.usbBridgeStatus)
                    keyValueRow("USB Client", value: viewModel.usbClientStatus)
                    keyValueRow("Samples", value: "\(viewModel.sampleCount)")
                    keyValueRow("Confidence", value: viewModel.confidenceText)
                    keyValueRow("Last Point", value: viewModel.pointText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Beam") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show Overlay", isOn: $viewModel.overlayEnabled)

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
                    Text("LAN: set Host IP to one of these addresses and Port to \(viewModel.listenerPort).")
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

                    Divider()

                    Text("USB: connect the iPhone by cable, tap USB in the iPhone demo, then start the bridge here.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(viewModel.isUSBBridgeRunning ? "Restart USB Bridge" : "Start USB Bridge") {
                            viewModel.startUSBBridge()
                        }
                        .disabled(!viewModel.canStartUSBBridge)

                        Button("Stop USB Bridge") {
                            viewModel.stopUSBBridge()
                        }
                        .disabled(!viewModel.isUSBBridgeRunning)
                    }
                    Text("Requires `iproxy` from libimobiledevice. The host forwards localhost:\(viewModel.usbForwardedLocalPort) to device port \(viewModel.usbDevicePort).")
                        .foregroundStyle(.secondary)
                        .font(.system(.footnote))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Log") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(viewModel.logFilePath)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
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
