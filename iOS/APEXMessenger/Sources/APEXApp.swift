import SwiftUI

@main
struct APEXApp: App {
    @StateObject private var appVM = AppViewModel()

    var body: some Scene {
        WindowGroup {
            if appVM.identity == nil {
                IdentitySetupView()
                    .environmentObject(appVM)
            } else {
                ConversationListView()
                    .environmentObject(appVM)
            }
        }
    }
}
