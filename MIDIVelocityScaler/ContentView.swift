//
//  ContentView.swift
//  MIDIVelocityScaler
//
//  Created by Joseph Aveltsev on 13.05.2025.
//

import CoreMIDI
import SwiftUI

class AppState: ObservableObject {
    static let shared = AppState()

    struct Device: Hashable, Identifiable {
        var id: MIDIUniqueID
        let name: String
    }

    @Published var availableInputDevices: [Device] = [] {
        didSet { print("🔄 availableInputDevices →", availableInputDevices) }
    }
    @Published var selectedInputDevice: Set<Device> = [] {
        didSet {
            print("🔄 selectedInputDevice →", selectedInputDevice)
            // Determine added and removed devices
            let added = selectedInputDevice.subtracting(oldValue)
            let removed = oldValue.subtracting(selectedInputDevice)
            // Connect newly selected sources
            for dev in added {
                if let src = endpointRef(for: dev.id, isSource: true) {
                    MIDIPortConnectSource(inputPort, src, nil)
                }
            }
            // Disconnect deselected sources
            for dev in removed {
                if let src = endpointRef(for: dev.id, isSource: true) {
                    MIDIPortDisconnectSource(inputPort, src)
                }
            }
        }
    }
    @Published var availableOutputDevices: [Device] = [] {
        didSet { print("🔄 availableOutputDevices →", availableOutputDevices) }
    }
    @Published var selectedOutputDevice: Device? = nil {
        didSet {
            print("🔄 selectedOutputDevice →", selectedOutputDevice as Any)
            // Update the MIDI endpoint for the newly selected output device
            if let outDev = selectedOutputDevice {
                selectedOutputEndpoint = endpointRef(
                    for: outDev.id,
                    isSource: false
                )
            } else {
                selectedOutputEndpoint = nil
            }
        }
    }

    @Published var velocityScalePercent: Int = 83

    private var midiClient = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var selectedOutputEndpoint: MIDIEndpointRef?

    // MIDI read callback for incoming packets
    private static let midiReadProc: MIDIReadProc = {
        packetListPtr,
        refCon,
        srcConnRefCon in
        let state = Unmanaged<AppState>.fromOpaque(refCon!)
            .takeUnretainedValue()
        state.handlePacketList(packetListPtr.pointee)
    }

    private init() {
        // Create CoreMIDI client with a notify handler
        MIDIClientCreate(
            "ScalerClient" as CFString,
            AppState.notifyCallback,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &midiClient
        )
        // create input & output ports
        MIDIInputPortCreate(
            midiClient,
            "InputPort" as CFString,
            AppState.midiReadProc,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &inputPort
        )
        MIDIOutputPortCreate(
            midiClient,
            "OutputPort" as CFString,
            &outputPort
        )
        // Initial driver list
        updateOutputDevices()
        updateInputDevices()
        // wire existing selections
        if let outDev = selectedOutputDevice {
            selectedOutputEndpoint = endpointRef(
                for: outDev.id,
                isSource: false
            )
        }
        // connect any selected input devices
        for dev in selectedInputDevice {
            if let src = endpointRef(for: dev.id, isSource: true) {
                MIDIPortConnectSource(inputPort, src, nil)
            }
        }
    }

    private func updateOutputDevices() {
        var drivers: [Device] = []
        let count = MIDIGetNumberOfDestinations()
        for i in 0..<count {
            let endpoint = MIDIGetDestination(i)

            // Display name
            var cfDisplayName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(
                endpoint,
                kMIDIPropertyDisplayName,
                &cfDisplayName
            )
            let displayName =
                cfDisplayName?.takeRetainedValue() as String? ?? "Unknown"

            // Model property
            var cfModel: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyModel, &cfModel)
            let model = cfModel?.takeRetainedValue() as String? ?? ""
            // Only include IAC Driver endpoints (model == "IAC Driver")
            if model != "IAC Driver" {
                continue
            }

            // Unique ID
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(
                endpoint,
                kMIDIPropertyUniqueID,
                &uid
            )

            drivers.append(Device(id: uid, name: displayName))
        }
        DispatchQueue.main.async {
            self.availableOutputDevices = drivers
            if self.selectedOutputDevice == nil, let first = drivers.first {
                self.selectedOutputDevice = first
            }
            if let sel = self.selectedOutputDevice {
                self.selectedOutputEndpoint = self.endpointRef(
                    for: sel.id,
                    isSource: false
                )
            }
        }
    }

    private var hasInitializedInputs = false
    private func updateInputDevices() {
        var inputs: [Device] = []
        let count = MIDIGetNumberOfSources()
        for i in 0..<count {
            let endpoint = MIDIGetSource(i)

            // Display name
            var cfDisplayName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(
                endpoint,
                kMIDIPropertyDisplayName,
                &cfDisplayName
            )
            let displayName =
                cfDisplayName?.takeRetainedValue() as String? ?? "Unknown"

            // Model property
            var cfModel: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyModel, &cfModel)
            let model = cfModel?.takeRetainedValue() as String? ?? ""
            // Skip IAC Driver virtual buses
            if model == "IAC Driver" {
                continue
            }
            // Unique ID
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(
                endpoint,
                kMIDIPropertyUniqueID,
                &uid
            )

            inputs.append(Device(id: uid, name: displayName))
        }
        DispatchQueue.main.async {
            self.availableInputDevices = inputs
            // On first scan, select all inputs; on subsequent scans, add newly connected
            if !self.hasInitializedInputs {
                // First launch: select all inputs
                self.selectedInputDevice = Set(inputs)
                self.hasInitializedInputs = true
            } else {
                // On subsequent scans: enable any newly connected inputs by default
                let newlyConnected = Set(inputs).subtracting(
                    self.selectedInputDevice
                )
                self.selectedInputDevice.formUnion(newlyConnected)
            }
            // reconnect only selected inputs
            for dev in self.selectedInputDevice {
                if let src = self.endpointRef(for: dev.id, isSource: true) {
                    MIDIPortConnectSource(self.inputPort, src, nil)
                }
            }
        }
    }

    private func endpointRef(for uid: MIDIUniqueID, isSource: Bool)
        -> MIDIEndpointRef?
    {
        let count =
            isSource ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
        for i in 0..<count {
            let ep = isSource ? MIDIGetSource(i) : MIDIGetDestination(i)
            var propUID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(ep, kMIDIPropertyUniqueID, &propUID)
            if propUID == uid { return ep }
        }
        return nil
    }

    private func handlePacketList(_ packetList: MIDIPacketList) {
        var scaledList = MIDIPacketList()
        let mtu = 1024
        var writer = MIDIPacketListInit(&scaledList)
        var packetPtr = packetList.packet
        for _ in 0..<packetList.numPackets {
            let status = packetPtr.data.0 & 0xF0
            var data = packetPtr.data
            // Only process Note On messages (0x90)
            if status == 0x90 {
                let note = data.1
                // semitones 1,3,6,8,10 are black keys
                if [1, 3, 6, 8, 10].contains(Int(note % 12)) {
                    let vel = Int(data.2)
                    let newVel = UInt8(
                        max(1, min(127, vel * velocityScalePercent / 100))
                    )
                    data.2 = newVel
                }
            }
            writer = MIDIPacketListAdd(
                &scaledList,
                mtu,
                writer,
                packetPtr.timeStamp,
                Int(packetPtr.length),
                &data
            )
            packetPtr = MIDIPacketNext(&packetPtr).pointee
        }
        if let dest = selectedOutputEndpoint {
            MIDISend(outputPort, dest, &scaledList)
        }
    }

    private static let notifyCallback: MIDINotifyProc = {
        notificationPtr,
        refCon in
        guard let refCon = refCon else { return }
        let state = Unmanaged<AppState>.fromOpaque(refCon).takeUnretainedValue()
        state.updateOutputDevices()
        state.updateInputDevices()
    }
}

struct ContentView: View {
    // Formatter to ensure integer input
    private let numberFormatter: NumberFormatter = {
        let fmt = NumberFormatter()
        fmt.numberStyle = .none
        fmt.minimum = 1
        fmt.maximum = 100
        return fmt
    }()
    @StateObject private var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading) {
            Text("MIDI Output Driver")
                .font(.headline)

            if state.availableOutputDevices.isEmpty {
                Text(
                    "No IAC drivers enabled. Enable IAC Driver in Audio MIDI Setup → Window → Show MIDI Studio, then activate it."
                )
                .foregroundColor(.red)
                .font(.subheadline)
            } else {
                Picker(
                    "MIDI Output Driver",
                    selection: Binding(
                        get: { state.selectedOutputDevice },
                        set: { state.selectedOutputDevice = $0 }
                    )
                ) {
                    ForEach(state.availableOutputDevices) { driver in
                        Text(driver.name)
                            .tag(driver)
                    }
                }
                .pickerStyle(MenuPickerStyle())
            }

            Text("MIDI Input Devices")
                .font(.headline)
            List {
                ForEach(state.availableInputDevices) { device in
                    Toggle(
                        isOn: Binding(
                            get: { state.selectedInputDevice.contains(device) },
                            set: { isSelected in
                                if isSelected {
                                    state.selectedInputDevice.insert(device)
                                } else {
                                    state.selectedInputDevice.remove(device)
                                }
                            }
                        )
                    ) {
                        Text(device.name)
                    }
                }
            }
            .frame(height: 200)

            HStack {
                Text("Velocity Scale:")
                TextField(
                    "",
                    value: $state.velocityScalePercent,
                    formatter: numberFormatter
                )
                .frame(width: 50)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                Text("%")
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 300, minHeight: 350)
    }
}

#Preview {
    ContentView()
}
