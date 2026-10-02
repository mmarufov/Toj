import SwiftUI

struct ContentView: View {
    @State private var appearance = TojAppearancePreferences.shared

    var body: some View {
        Group {
            if ProcessInfo.processInfo.environment["TOJ_USE_M1_SKELETON"] == "1" {
                SkeletonView()
            } else {
                CloudRootView()
            }
        }
        .preferredColorScheme(.dark)
        .tint(appearance.accent.color)
        .environment(appearance)
        .environment(\.locale, appearance.language.locale)
        .environment(\.dynamicTypeSize, appearance.textSize.dynamicTypeSize)
    }
}

#Preview {
    ContentView()
}
