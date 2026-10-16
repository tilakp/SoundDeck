import SwiftUI

/// The OSC tab of the Settings window.
struct OSCSettings: View {
    @ObservedObject private var server = OSCServer.shared
    @State private var portText = String(OSCServer.shared.port)
    @State private var addresses = OSCServer.localAddresses()

    private static let examples: [(String, String)] = [
        ("/sounddeck/play \"Gong\"", "Play a pad by name, key or id."),
        ("/sounddeck/play/Gong", "Play on 1 or no argument. Release on 0."),
        ("/sounddeck/release \"Gong\"", "Release a pad. A Hold pad stops."),
        ("/sounddeck/stop", "Stop all pads."),
        ("/sounddeck/stop \"Gong\"", "Stop one pad."),
        ("/sounddeck/deck \"Stream\"", "Make a deck active."),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Receive OSC messages", isOn: Binding(
                    get: { server.isEnabled },
                    set: { server.setEnabled($0) }))
                HStack {
                    TextField("UDP port", text: $portText)
                        .onSubmit(applyPort)
                    Button("Apply", action: applyPort)
                        .disabled(UInt16(portText) == nil || UInt16(portText) == server.port)
                }
                LabeledContent("State") {
                    Text(stateText)
                        .foregroundStyle(stateIsError ? Color.red : Color.secondary)
                }
                LabeledContent("This Mac") {
                    Text(addresses.isEmpty ? "No network" : addresses.joined(separator: ", "))
                        .textSelection(.enabled)
                }
            }
            Section("Addresses") {
                ForEach(Self.examples, id: \.0) { example in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(example.0).font(.system(.body, design: .monospaced))
                        Text(example.1).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { addresses = OSCServer.localAddresses() }
    }

    private func applyPort() {
        guard let port = UInt16(portText), port > 0 else {
            portText = String(server.port)
            return
        }
        server.setPort(port)
    }

    private var stateText: String {
        switch server.state {
        case .off: return "Off"
        case .starting: return "Starting"
        case .listening(let port): return "Listening on UDP port \(port)"
        case .failed(let message): return message
        }
    }

    private var stateIsError: Bool {
        if case .failed = server.state { return true }
        return false
    }
}
