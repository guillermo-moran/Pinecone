import SwiftUI

@main
struct MobileOSHostApp: App {
    @StateObject private var model = MobileOSHostModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task {
                    await model.boot()
                }
        }
    }
}
