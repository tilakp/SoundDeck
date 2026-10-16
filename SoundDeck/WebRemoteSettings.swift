import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The Web remote tab of the Settings window.
struct WebRemoteSettings: View {
    @ObservedObject private var server = WebRemoteServer.shared
    @State private var portText = String(WebRemoteServer.shared.port)
    @State private var addresses = WebRemoteServer.localAddresses()

    private var urls: [String] {
        addresses.map { "http://\($0):\(server.port)/" }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Web remote", isOn: Binding(get: { server.isEnabled }, set: server.setEnabled))
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", text: $portText)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onSubmit(applyPort)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Pairing code") {
                            Text(server.pairingCode)
                                .font(.system(.title3, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Button("New code", action: server.makeNewCode)
                        if urls.isEmpty {
                            Text("No network connection.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(urls, id: \.self) { url in
                            Text(url)
                                .textSelection(.enabled)
                        }
                        Text("Open the address on a phone on the same network, or scan the code. A new code disconnects all browsers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let url = urls.first, let image = Self.qrCode(for: "\(url)#code=\(server.pairingCode)") {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 120, height: 120)
                            .accessibilityLabel("QR code of the web remote address")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { addresses = WebRemoteServer.localAddresses() }
    }

    private var statusText: String {
        switch server.status {
        case .stopped: return "The web remote is off."
        case .starting: return "The web remote starts."
        case .running: return "The web remote is on."
        case .failed(let message): return "The web remote cannot start: \(message)"
        }
    }

    private func applyPort() {
        guard let value = Int(portText), WebRemoteServer.isValidPort(value) else {
            portText = String(server.port)
            return
        }
        server.setPort(value)
    }

    /// A QR code of `text`, without smoothing. The QR code includes the pairing code in the URL fragment.
    static func qrCode(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
