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

    private let defaults = UserDefaults.standard
    private let kInputDevicesKey = "selectedInputDeviceIDs"
    private let kOutputDeviceKey = "selectedOutputDeviceID"
    private let kVelocityKey = "velocityScalePercent"

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
            let ids = selectedInputDevice.map { $0.id }
            defaults.set(ids, forKey: kInputDevicesKey)
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
                defaults.set(outDev.id, forKey: kOutputDeviceKey)
            } else {
                selectedOutputEndpoint = nil
                defaults.removeObject(forKey: kOutputDeviceKey)
            }
        }
    }

    @Published var velocityScalePercent: Int = 83 {
        didSet { defaults.set(velocityScalePercent, forKey: kVelocityKey) }
    }

    private var midiClient = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var selectedOutputEndpoint: MIDIEndpointRef?
    private var hasInitializedInputs = false
    private var knownInputDeviceIDs: Set<MIDIUniqueID> = []

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
        // Load saved velocity
        if let storedVel = defaults.object(forKey: kVelocityKey) as? Int {
            velocityScalePercent = storedVel
        }
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
            if let storedID = self.defaults.object(
                forKey: self.kOutputDeviceKey
            ) as? MIDIUniqueID,
                let stored = drivers.first(where: { $0.id == storedID })
            {
                self.selectedOutputDevice = stored
            } else if self.selectedOutputDevice == nil,
                let first = drivers.first
            {
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
            let currentIDs = Set(inputs.map { $0.id })
            // On first scan, restore or select all; thereafter only add truly new devices
            if !self.hasInitializedInputs {
                if let stored = self.defaults.object(
                    forKey: self.kInputDevicesKey
                ) as? [MIDIUniqueID] {
                    self.selectedInputDevice = Set(
                        inputs.filter { stored.contains($0.id) }
                    )
                } else {
                    self.selectedInputDevice = Set(inputs)
                }
                self.hasInitializedInputs = true
                // Initialize known IDs
                self.knownInputDeviceIDs = currentIDs
            } else {
                // Only auto-select devices never seen before
                let brandNew = currentIDs.subtracting(self.knownInputDeviceIDs)
                let newDevices = inputs.filter { brandNew.contains($0.id) }
                self.selectedInputDevice.formUnion(newDevices)
                self.knownInputDeviceIDs.formUnion(currentIDs)
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

    /// Restore all settings back to app defaults
    func restoreDefaults() {
        // Clear saved settings
        defaults.removeObject(forKey: kVelocityKey)
        defaults.removeObject(forKey: kInputDevicesKey)
        defaults.removeObject(forKey: kOutputDeviceKey)
        // Reset in-memory flags
        hasInitializedInputs = false
        knownInputDeviceIDs.removeAll()
        // Reset values to initial defaults
        velocityScalePercent = 83
        selectedOutputDevice = nil
        // Re-scan and reapply defaults
        updateOutputDevices()
        updateInputDevices()
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
    @State private var showIACAlert = false

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
                .lineLimit(nil)  // remove the single‐line cap
                .fixedSize(horizontal: false, vertical: true)  // let it take as many lines as it needs
            } else {
                Picker(
                    "IAC Driver",
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

            Button("Restore Defaults") {
                state.restoreDefaults()
            }
            .padding(.top)

            Spacer()
        }
        .onAppear {
            if state.availableOutputDevices.isEmpty {
                showIACAlert = true
            }
        }
        .padding()
        .frame(minWidth: 300, minHeight: 350)
        .alert("No IAC Driver Detected",
               isPresented: $showIACAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please enable the IAC Driver in Audio MIDI Setup → Window → Show MIDI Studio, then activate it.")
        }
    }
}

#Preview {
    ContentView()
}