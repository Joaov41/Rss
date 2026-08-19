//
//  YouTubePlayerView.swift
//  RSSReaderApp
//
//  Uses YouTube's supported iframe player. The app does not extract or stream
//  YouTube media URLs directly.
//

import SwiftUI
import WebKit

#if os(iOS)
struct YouTubePlayerView: UIViewRepresentable {
    let videoID: String
    var onError: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onError: onError) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = [.audio, .video]
        configuration.userContentController.add(context.coordinator, name: "youtubePlayer")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.loadedVideoID = videoID
        load(videoID: videoID, into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onError = onError
        guard context.coordinator.loadedVideoID != videoID else { return }
        context.coordinator.loadedVideoID = videoID
        load(videoID: videoID, into: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.evaluateJavaScript("if (window.player && player.pauseVideo) { player.pauseVideo(); }")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "youtubePlayer")
        webView.stopLoading()
    }

    private func load(videoID: String, into webView: WKWebView) {
        let safeVideoID = videoID.replacingOccurrences(of: "'", with: "")
        let appIdentifier = (Bundle.main.bundleIdentifier ?? "com.joaovalente.rssreaderapp").lowercased()
        guard let clientIdentityURL = URL(string: "https://\(appIdentifier)") else {
            onError("YouTube could not identify this app for embedded playback.")
            return
        }
        let clientOrigin = clientIdentityURL.absoluteString
        let html = """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body,#player{margin:0;width:100%;height:100%;background:#000;overflow:hidden}</style>
        </head><body><div id="player"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
          var player;
          function onYouTubeIframeAPIReady() {
            player = new YT.Player('player', {
              videoId: '\(safeVideoID)',
              playerVars: { playsinline: 1, controls: 1, rel: 0, origin: '\(clientOrigin)' },
              events: { onError: function(e) { window.webkit.messageHandlers.youtubePlayer.postMessage(String(e.data)); } }
            });
          }
        </script></body></html>
        """
        webView.loadHTMLString(html, baseURL: clientIdentityURL)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onError: (String) -> Void
        var loadedVideoID: String?

        init(onError: @escaping (String) -> Void) { self.onError = onError }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let code = String(describing: message.body)
            let explanation: String
            switch code {
            case "2": explanation = "YouTube rejected this video identifier."
            case "5": explanation = "This video cannot be played in the embedded HTML player."
            case "100": explanation = "This video is private, deleted, or unavailable."
            case "101", "150": explanation = "The video owner does not allow embedded playback."
            case "153": explanation = "YouTube could not verify the embedded player request."
            default: explanation = "YouTube playback failed (error \(code))."
            }
            DispatchQueue.main.async { self.onError(explanation) }
        }
    }
}
#elseif os(macOS)
private final class YouTubeScrollForwardingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        // The embedded YouTube iframe consumes wheel/trackpad events even
        // though its document is not scrollable. Forward vertical scrolling
        // to the surrounding article while leaving clicks and player controls
        // handled by the web view.
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
           let articleScrollView = enclosingScrollView {
            articleScrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

struct YouTubePlayerView: NSViewRepresentable {
    let videoID: String
    var onError: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onError: onError) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = [.audio, .video]
        configuration.userContentController.add(context.coordinator, name: "youtubePlayer")

        let webView = YouTubeScrollForwardingWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.loadedVideoID = videoID
        load(videoID: videoID, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onError = onError
        guard context.coordinator.loadedVideoID != videoID else { return }
        context.coordinator.loadedVideoID = videoID
        load(videoID: videoID, into: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.evaluateJavaScript("if (window.player && player.pauseVideo) { player.pauseVideo(); }")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "youtubePlayer")
        webView.stopLoading()
    }

    private func load(videoID: String, into webView: WKWebView) {
        let safeVideoID = videoID.replacingOccurrences(of: "'", with: "")
        let appIdentifier = (Bundle.main.bundleIdentifier ?? "com.joaovalente.rssreaderapp").lowercased()
        guard let clientIdentityURL = URL(string: "https://\(appIdentifier)") else {
            onError("YouTube could not identify this app for embedded playback.")
            return
        }
        let clientOrigin = clientIdentityURL.absoluteString
        let html = """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body,#player{margin:0;width:100%;height:100%;background:#000;overflow:hidden}</style>
        </head><body><div id="player"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
          var player;
          function onYouTubeIframeAPIReady() {
            player = new YT.Player('player', {
              videoId: '\(safeVideoID)',
              playerVars: { playsinline: 1, controls: 1, rel: 0, origin: '\(clientOrigin)' },
              events: { onError: function(e) { window.webkit.messageHandlers.youtubePlayer.postMessage(String(e.data)); } }
            });
          }
        </script></body></html>
        """
        webView.loadHTMLString(html, baseURL: clientIdentityURL)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onError: (String) -> Void
        var loadedVideoID: String?

        init(onError: @escaping (String) -> Void) { self.onError = onError }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let code = String(describing: message.body)
            let explanation: String
            switch code {
            case "2": explanation = "YouTube rejected this video identifier."
            case "5": explanation = "This video cannot be played in the embedded HTML player."
            case "100": explanation = "This video is private, deleted, or unavailable."
            case "101", "150": explanation = "The video owner does not allow embedded playback."
            case "153": explanation = "YouTube could not verify the embedded player request."
            default: explanation = "YouTube playback failed (error \(code))."
            }
            DispatchQueue.main.async { self.onError(explanation) }
        }
    }
}
#endif
