import SwiftUI

// Platform Detection Examples for RSS Reader App

// Method 1: Using ProcessInfo to detect iOS app on Mac
struct PlatformDetectionExample {
    
    static var isRunningOnMac: Bool {
        #if os(macOS)
        // Native macOS app
        return true
        #else
        // Check if iOS/iPadOS app is running on Mac
        if #available(iOS 14.0, *) {
            return ProcessInfo.processInfo.isiOSAppOnMac
        } else {
            return false
        }
        #endif
    }
    
    static var platformDescription: String {
        #if os(macOS)
        return "Native macOS App"
        #elseif targetEnvironment(macCatalyst)
        return "Mac Catalyst App"
        #else
        if #available(iOS 14.0, *) {
            if ProcessInfo.processInfo.isiOSAppOnMac {
                return "iOS App running on Mac (Designed for iPad)"
            } else if UIDevice.current.userInterfaceIdiom == .pad {
                return "Native iPad App"
            } else {
                return "Native iPhone App"
            }
        } else {
            if UIDevice.current.userInterfaceIdiom == .pad {
                return "Native iPad App"
            } else {
                return "Native iPhone App"
            }
        }
        #endif
    }
}

// Usage in SwiftUI View
struct PlatformAwareView: View {
    var body: some View {
        VStack {
            Text("Platform: \(PlatformDetectionExample.platformDescription)")
                .font(.headline)
            
            #if !os(macOS)
            if #available(iOS 14.0, *) {
                if ProcessInfo.processInfo.isiOSAppOnMac {
                    Text("This iPad app is running on Mac!")
                        .foregroundColor(.blue)
                    Text("You may want to adjust UI for Mac conventions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            #endif
        }
        .padding()
    }
}

// Integration Example for RSSReaderApp
extension RSSReaderApp {
    var adjustedBody: some Scene {
        #if os(macOS)
        // Native macOS code path
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1000, minHeight: 600)
        }
        #else
        WindowGroup {
            if #available(iOS 14.0, *), ProcessInfo.processInfo.isiOSAppOnMac {
                // iOS app running on Mac - use iPad-style layout
                iPadContentView()
                    .environmentObject(appState)
                    .frame(minWidth: 1000, minHeight: 600)
            } else if UIDevice.current.userInterfaceIdiom == .pad {
                // Native iPad
                iPadContentView()
                    .environmentObject(appState)
            } else {
                // iPhone
                iPhoneContentView()
                    .environmentObject(appState)
            }
        }
        #endif
    }
}

// Platform-specific adjustments
struct PlatformSpecificModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if !os(macOS)
        if #available(iOS 14.0, *), ProcessInfo.processInfo.isiOSAppOnMac {
            // Adjustments for iOS app on Mac
            content
                .navigationViewStyle(StackNavigationViewStyle()) // Better for Mac
                .frame(minWidth: 800, minHeight: 600) // Ensure minimum window size
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    func adaptForPlatform() -> some View {
        self.modifier(PlatformSpecificModifier())
    }
}