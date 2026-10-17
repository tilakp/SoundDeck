import SwiftUI

/// The Audio tab of the Settings window: the Monitor device and the microphone pass-through.
struct AudioSettings: View {
    var body: some View {
        if let engine = DeckCommands.shared?.engine {
            AudioRoutingForm(engine: engine)
        } else {
            SettingsPlaceholder(name: "Audio")
        }
    }
}

private struct AudioRoutingForm: View {
    @ObservedObject var engine: AudioEngine

    var body: some View {
        Form {
            Section {
                Picker("Monitor device", selection: Binding(
                    get: { engine.routing.monitorDeviceUID },
                    set: { engine.selectMonitorDevice(uid: $0) })) {
                    Text("None").tag(String?.none)
                    ForEach(engine.outputDevices.filter { $0.uid != nil }) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if let uid = engine.routing.monitorDeviceUID,
                       !engine.outputDevices.contains(where: { $0.uid == uid }) {
                        Text("Missing device").tag(Optional(uid))
                    }
                }
                LabeledContent("Monitor volume") {
                    Slider(value: Binding(
                        get: { engine.routing.monitorVolume },
                        set: { engine.setMonitorVolume($0) }), in: 0...1)
                }
                .disabled(engine.routing.monitorDeviceUID == nil)
                Text("Each pad also plays on this device, for example your headphones. The Output row of a pad selects Both, Live or Me only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Monitor")
            }

            Section {
                Toggle("Mix my microphone into the deck output", isOn: Binding(
                    get: { engine.routing.micEnabled },
                    set: { engine.setMicEnabled($0) }))
                Picker("Input device", selection: Binding(
                    get: { engine.routing.micDeviceUID },
                    set: { engine.selectMicDevice(uid: $0) })) {
                    Text("System Default").tag(String?.none)
                    ForEach(engine.inputDevices.filter { $0.uid != nil }) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .disabled(!engine.routing.micEnabled)
                LabeledContent("Microphone gain") {
                    HStack {
                        Slider(value: Binding(
                            get: { engine.routing.micGainDecibels },
                            set: { engine.setMicGain(decibels: $0.rounded()) }),
                               in: AudioRoutingSettings.micGainRange)
                        Text(String(format: "%+.0f dB", engine.routing.micGainDecibels))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                .disabled(!engine.routing.micEnabled)
                if let error = engine.micError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("The deck output then carries your voice and the pads. In the call app, select only the deck output, for example BlackHole, as the microphone. You do not need an aggregate device. Your voice does not go to the monitor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Microphone")
            }
        }
        .formStyle(.grouped)
        .onAppear { engine.refreshDevices() }
    }
}
