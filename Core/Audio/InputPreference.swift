import Foundation

/// Picks the input a recording should run on when macOS has handed the default to Bluetooth.
public enum InputPreference {
    /// USB first, then a Continuity microphone, then whatever is built into the machine.
    ///
    /// The order is by how deliberate the choice behind the device is: a USB microphone was
    /// plugged in on purpose, an iPhone merely happens to be on the desk, and a built-in
    /// microphone — which a Mac mini does not have at all — is the last resort.
    static let order: [InputTransport] = [.usb, .continuity, .builtIn]

    /// - Returns: the best full-band input among `devices`, or nil when there is none — in which
    ///   case the recording goes ahead on whatever the system chose, with the narrowband warning
    ///   the panel already shows.
    public static func replacement(among devices: [AudioInputDevice]) -> AudioInputDevice? {
        for transport in order {
            if let match = devices.first(where: {
                $0.transport == transport && !$0.uid.isEmpty && !$0.isNarrowband
            }) {
                return match
            }
        }
        return nil
    }
}
