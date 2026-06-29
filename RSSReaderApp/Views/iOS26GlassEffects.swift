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
            if !showBackButton {
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
            } else {
                Color.clear
                    .frame(width: 40, height: 40)
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
                .foregroundColor(separatorColor().opacity(0.3)),
            alignment: .bottom
        )
    }
}

// MARK: - Glass Effect View Modifier (Fallback for older iOS)
struct GlassEffectModifier<S: InsettableShape>: ViewModifier {
    let isInteractive: Bool
    let shape: S

    func body(content: Content) -> some View {
        let borderColors: [Color]
        if #available(iOS 26.0, *) {
            borderColors = [
                Color.white.opacity(0.3),
                Color.white.opacity(0.1)
            ]
        } else {
            borderColors = [
                Color.white.opacity(0.25),
                Color.white.opacity(0.05)
            ]
        }

        return content
            .background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: borderColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
            )
            .allowsHitTesting(isInteractive)
    }
}

// glassEffectCompat extension is now defined in ContentView.swift
