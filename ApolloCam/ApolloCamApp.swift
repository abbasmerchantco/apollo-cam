import SwiftUI

@main
struct ApolloCamApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            CameraScreen()
                .tabItem { Label("Camera", systemImage: "camera.fill") }
            GalleryView()
                .tabItem { Label("Gallery", systemImage: "photo.on.rectangle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(Color(red: 0.98, green: 0.75, blue: 0.24))
    }
}
