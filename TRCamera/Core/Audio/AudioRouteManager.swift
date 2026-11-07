import AVFoundation

/// Owns the app's AVAudioSession. The capture session is told not to configure
/// audio automatically so that the user's input choice (USB interface, external
/// mic) and gain are respected.
final class AudioRouteManager {
    static let shared = AudioRouteManager()

    struct Input: Identifiable, Hashable {
        var id: String
        var name: String
        var kind: String
        var channels: Int
    }

    private let session = AVAudioSession.sharedInstance()

    func configureSession() {
        do {
            try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)
        } catch {
            Log.audio.error("Audio session: \(error.localizedDescription)")
        }
    }

    func availableInputs() -> [Input] {
        (session.availableInputs ?? []).map { port in
            Input(id: port.uid, name: port.portName, kind: Self.label(port.portType), channels: port.channels?.count ?? 0)
        }
    }

    var currentInputID: String? { session.currentRoute.inputs.first?.uid }

    func select(inputID: String) throws {
        guard let port = session.availableInputs?.first(where: { $0.uid == inputID }) else { return }
        try session.setPreferredInput(port)
    }

    /// Not every route allows gain control (many USB devices handle gain in hardware).
    var isGainSettable: Bool { session.isInputGainSettable }
    var gain: Float { session.inputGain }

    func setGain(_ value: Float) throws {
        guard session.isInputGainSettable else { return }
        try session.setInputGain(min(max(value, 0), 1))
    }

    static func label(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .builtInMic: "Interno"
        case .headsetMic: "Headset"
        case .usbAudio: "USB"
        case .bluetoothHFP: "Bluetooth"
        case .lineIn: "Line In"
        case .carAudio: "Carro"
        default: type.rawValue
        }
    }
}
