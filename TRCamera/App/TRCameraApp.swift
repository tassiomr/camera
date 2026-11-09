import SwiftUI
import TRDesignSystem

@main
struct TRCameraApp: App {
    @State private var model = CameraViewModel()

    var body: some Scene {
        WindowGroup {
            CameraScreen(model: model)
                .trTheme(.app)
        }
    }
}
