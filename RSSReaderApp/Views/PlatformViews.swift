import SwiftUI

struct iPadContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        // For iPad, embed ContentView in NavigationView for swipe gestures
        NavigationView {
            ContentView()
                .environmentObject(appState)
        }
#if os(iOS)
        .navigationViewStyle(StackNavigationViewStyle())
#endif
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
#if os(iOS)
        .navigationViewStyle(StackNavigationViewStyle())
#endif
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

// MARK: - Liquid Glass Implementation

struct LiquidGlassTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// Adaptive TextFieldStyle with material fallback
struct AdaptiveLiquidGlassTextFieldStyle: TextFieldStyle {
    let cornerRadius: CGFloat
    let tintColor: Color?
    
    init(cornerRadius: CGFloat = 12, tintColor: Color? = nil) {
        self.cornerRadius = cornerRadius
        self.tintColor = tintColor
    }
    
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                    )
            }
    }
}

// Adaptive ButtonStyle with material fallback
struct AdaptiveLiquidGlassButtonStyle: ButtonStyle {
    let tintColor: Color?
    
    init(tintColor: Color? = nil) {
        self.tintColor = tintColor
    }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// Custom Liquid Glass Button Style
struct LiquidGlassButtonStyle: ButtonStyle {
    var isProminent: Bool = false
    var isTranslucent: Bool = false
    var showsBorder: Bool = true
    var showsBackground: Bool = true
    
    @Environment(\.colorScheme) private var colorScheme
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .fontWeight(.medium)
            .symbolRenderingMode(.monochrome)
            .foregroundColor(foregroundColor)
            .tint(foregroundColor)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Group {
                    if showsBackground {
                        ZStack {
                            backgroundFill
                            
                            #if os(iOS)
                            if gradientOverlayIsNeeded {
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(isTranslucent ? 0.3 : 0.2),
                                        Color.clear,
                                        Color.black.opacity(isTranslucent ? 0.05 : 0.1)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .blendMode(.overlay)
                            }
                            #endif
                            
                            if showsBorder {
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(borderColor, lineWidth: 1.5)
                            }
                        }
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: showsBackground ? 20 : 0))
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
    
    @ViewBuilder
    private var backgroundFill: some View {
        if isProminent {
            if colorScheme == .light {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.92))
            } else {
                RoundedRectangle(cornerRadius: 20)
                    .fill(safeBackgroundMaterial())
            }
        } else {
            RoundedRectangle(cornerRadius: 20)
                .fill(safeBackgroundMaterial())
        }
    }
    
    private var borderColor: Color {
        if isProminent {
            return colorScheme == .light ? Color.black.opacity(0.08) : Color.white.opacity(0.9)
        }
        return Color.white.opacity(isTranslucent ? 0.7 : 0.5)
    }
    
    private func safeBackgroundMaterial() -> some ShapeStyle {
        #if os(iOS)
        return isTranslucent ? .ultraThinMaterial : .thickMaterial
        #else
        // Use simple colors on macOS to avoid Metal texture conflicts
        if #available(macOS 12.0, *) {
            return isTranslucent ? .ultraThinMaterial : .thickMaterial
        } else {
            return isTranslucent ? Color.gray.opacity(0.15) : Color.gray.opacity(0.25)
        }
        #endif
    }
    
    private var foregroundColor: Color {
        guard isProminent else { return Color.primary }
        return colorScheme == .light ? Color.black : Color.white
    }
    
    private var gradientOverlayIsNeeded: Bool {
        guard showsBackground else { return false }
        if !isProminent { return true }
        return colorScheme == .dark
    }
}


// Adaptive container with material fallback
struct AdaptiveGlassContainerView<Content: View>: View {
    let content: Content
    let tintColor: Color?
    let cornerRadius: CGFloat
    
    init(tintColor: Color? = nil, cornerRadius: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.tintColor = tintColor
        self.cornerRadius = cornerRadius
    }
    
    var body: some View {
        content
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                    )
            }
    }
}

// MARK: - Unified Glass Style Extensions
struct AdaptiveGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tintColor: Color?

    init(cornerRadius: CGFloat = 12, tintColor: Color? = nil) {
        self.cornerRadius = cornerRadius
        self.tintColor = tintColor
    }

    func body(content: Content) -> some View {
        if #available(iOS 15.0, macOS 12.0, *) {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(tintColor?.opacity(0.3) ?? Color.white.opacity(0.2), lineWidth: 1)
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(tintColor ?? Color.gray.opacity(0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(tintColor?.opacity(0.3) ?? Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
    }
}

extension View {
    func applyGlassStyle(cornerRadius: CGFloat = 12, tintColor: Color? = nil) -> some View {
        if #available(iOS 15.0, macOS 12.0, *) {
            return AnyView(
                self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(tintColor?.opacity(0.3) ?? Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
        } else {
            return AnyView(
                self.background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(tintColor?.opacity(0.2) ?? Color.gray.opacity(0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(tintColor?.opacity(0.3) ?? Color.gray.opacity(0.3), lineWidth: 1)
                )
            )
        }
    }

    func ttsActiveGlow(_ isActive: Bool, color: Color) -> some View {
        self
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(color.opacity(isActive ? 0.85 : 0.0), lineWidth: 1.8)
                    .shadow(color: color.opacity(isActive ? 0.75 : 0.0), radius: 8, x: 0, y: 0)
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.18), value: isActive)
    }
}
