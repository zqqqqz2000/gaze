import SwiftUI

struct ContentView: View {
    private enum Field: Hashable {
        case host
        case port
    }

    @ObservedObject var viewModel: GazeDemoViewModel
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    providerSection
                    streamingSection
                    latestSampleSection
                    logSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .navigationTitle("Gaze Demo")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(uiColor: .systemGroupedBackground))
            .contentShape(Rectangle())
            .onTapGesture {
                focusedField = nil
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
            .modifier(KeyboardDismissModifier())
        }
        .navigationViewStyle(.stack)
        .onAppear {
            viewModel.startAutomaticSessionIfNeeded()
        }
    }

    private var providerSection: some View {
        sectionCard("Provider") {
            statGrid([
                ("State", viewModel.stateText),
                ("Confidence", viewModel.confidenceText),
                ("Face Distance", viewModel.faceDistanceText),
                ("Samples", "\(viewModel.sampleCount)"),
            ])

            HStack(spacing: 12) {
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
    }

    private var streamingSection: some View {
        sectionCard("Streaming") {
            Picker("Transport", selection: $viewModel.transportMode) {
                ForEach(GazeDemoViewModel.StreamTransport.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.transportMode == .lan {
                VStack(spacing: 12) {
                    TextField("Host IP", text: $viewModel.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .host)

                    TextField("Port", text: $viewModel.port)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .port)
                }
            } else {
                statGrid([
                    ("USB Port", "\(viewModel.usbListenerPort)"),
                ])
                Text("Use GazeBeamHost USB bridge on the Mac, then keep streaming enabled here.")
                    .foregroundStyle(.secondary)
                    .font(.system(.footnote))
            }

            statGrid([
                ("Status", viewModel.streamStatusText),
            ])

            Toggle("Send Samples To Host", isOn: $viewModel.isStreaming)
                .onChange(of: viewModel.isStreaming) { enabled in
                    viewModel.setStreaming(enabled: enabled)
                }
        }
    }

    private var latestSampleSection: some View {
        sectionCard("Latest Sample") {
            statGrid([
                ("Origin", viewModel.originText),
                ("Direction", viewModel.directionText),
            ])
        }
    }

    private var logSection: some View {
        sectionCard("Log") {
            if viewModel.logLines.isEmpty {
                Text("No events yet.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private func statGrid(_ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                keyValueRow(item.0, value: item.1)
            }
        }
    }

    private func keyValueRow(_ key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: GazeDemoViewModel())
    }
}

private struct KeyboardDismissModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollDismissesKeyboard(.interactively)
        } else {
            content
        }
    }
}
