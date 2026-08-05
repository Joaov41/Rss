import SwiftUI

// AppColors is defined in ContentView.swift

// Helper for separator color
private func separatorColor() -> Color {
    #if os(iOS)
    return Color(UIColor.separator)
    #else
    return Color(NSColor.separatorColor)
    #endif
}

// GlassSidebarButton is now defined in ContentView.swift

// MARK: - Glass Navigation Bar
struct GlassNavigationBar: View {
    let title: String
    let showBackButton: Bool
    let backAction: () -> Void
    
    var body: some View {
        HStack {
            if showBackButton {
                Button(action: backAction) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .medium))
                        Text("Back")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .glassEffectCompat(in: Capsule())
                .shadow(radius: 2)
            } else {
                Button(action: {
                    // Toggle sidebar action will be passed in
                }) {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                }
                .background(.ultraThinMaterial, in: Circle())
                .shadow(radius: 2)
            }
            
            Spacer()
            
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
            
            Spacer()
            
            // Placeholder for balance
            Color.clear
                .frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                                 .foregroundColor(separatorColor.opacity(0.3)),
            alignment: .bottom
        )
    }
}

// MARK: - Glass Effect View Modifier (Fallback for older iOS)
struct GlassEffectModifier: ViewModifier {
    let isInteractive: Bool
    let shape: any Shape
    
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // This would use the new .glassEffect modifier
            // For now, we'll use a fallback
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                )
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.25),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                )
        }
    }
}

// glassEffectCompat extension is now defined in ContentView.swift