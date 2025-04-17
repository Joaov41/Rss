import SwiftUI

struct iPadContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        // For iPad, simply show ContentView in a large layout
        ContentView()
            .environmentObject(appState)
    }
}

struct iPhoneContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        // For iPhone, embed ContentView in a NavigationView if desired
        ContentView()
            .environmentObject(appState)
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
