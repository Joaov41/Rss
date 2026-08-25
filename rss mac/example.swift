//
//  FullScreenImageView.swift
//  RedditApp
//
//  Created by YourName on 2025-01-01.
//

import SwiftUI
import Kingfisher

// MARK: - FullScreenImageView
struct FullScreenImageView: View {
    let imageURL: URL
    @Binding var isPresented: Bool

    @State private var zoomScale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    let minZoom: CGFloat = 0.5
    let maxZoom: CGFloat = 5.0

    var body: some View {
        ZStack {
            Color.black
                .edgesIgnoringSafeArea(.all)

            GeometryReader { geometry in
                VStack {
                    HStack {
                        Spacer()
                        Button(action: { isPresented = false }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundColor(.white)
                        }
                        .padding()
                    }

                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        KFImage(imageURL)
                            .resizable()
                            .placeholder {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            }
                            .cancelOnDisappear(true)
                            .scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height) // Set frame explicitly
                            .scaleEffect(zoomScale)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        let newScale = lastScale * value
                                        zoomScale = min(max(newScale, minZoom), maxZoom)
                                    }
                                    .onEnded { value in
                                        lastScale = zoomScale
                                    }
                            )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity) // ScrollView fills the space
                }
            }
        }
    }
}
