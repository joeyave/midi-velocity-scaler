import SwiftUI

@main
struct MIDIVelocityScalerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {} // Required to keep app running
    }
}
