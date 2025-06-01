import SwiftUI

struct iPadContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        // For iPad, embed ContentView in NavigationView for swipe gestures
        NavigationView {
            ContentView()
                .environmentObject(appState)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct iPhoneContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        // For iPhone, embed ContentView in a NavigationView to enable swipe back
        NavigationView {
            ContentView()
                .environmentObject(appState)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct PlatformViews_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            iPadContentView().environmentObject(AppState())
            iPhoneContentView().environmentObject(AppState())
        }
    }
}
