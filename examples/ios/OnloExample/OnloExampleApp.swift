import SwiftUI

@main
struct OnloExampleApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "questionmark.bubble")
                Text("Embed SupportView in your merchant app")
                Text("Pass your public SDK key and an authenticated backend callback.")
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
