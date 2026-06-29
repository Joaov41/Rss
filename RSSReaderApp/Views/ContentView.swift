import SwiftUI
@preconcurrency import WebKit
import Combine
import SwiftSoup
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Reader Mode Service (Mozilla Readability.js)
// Provides intelligent article extraction using the same algorithm as Safari Reader, Firefox, and Pocket

enum ReaderModeService {
    /// JavaScript that loads Readability.js and extracts the article content.
    /// Returns a clean HTML document with just the article content.
    static func toggleScript(useCompactTitle: Bool) -> String {
        let readability = loadReadabilitySource()
        let titleFontSize = useCompactTitle ? 28 : 30
        let readerScript = """
        (function() {
          try {
            // If reader mode is already active, reload the original page
            if (window.__rssReaderModeActive) {
              window.__rssReaderModeActive = false;
              var url = window.__rssReaderOriginalURL || location.href;
              if (url) { location.href = url; }
              return false;
            }

            // Check if Readability is available
            if (typeof Readability === 'undefined') { return false; }

            // Clone the document and parse with Readability
            var clone = document.cloneNode(true);
            var article = new Readability(clone).parse();
            if (!article || !article.content) { return false; }

            // Escape HTML for safe display
            function escapeHtml(text) {
              return (text || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
            }

            // Clean up promotional/ad content from the extracted article
            function cleanContent(html) {
              var div = document.createElement('div');
              div.innerHTML = html;

              // Affiliate link URL patterns
              var affiliateURLPatterns = [
                'amazon.com', 'amzn.to', 'amzn.com',
                'news.google.com', 'google.com/publisher',
                'nordvpn', 'affiliate', 'partner',
                'apple.com/shop', 'tkqlhce.com', 'anrdoezrs.net',
                'shareasale', 'commission', 'ref='
              ];

              // Text patterns for promotional content
              var promoPatterns = [
                'preferred source on google', 'add as a preferred',
                'follow us on', 'subscribe to', 'sign up for',
                'newsletter', 'sponsored', 'advertisement', 'promoted content',
                'official apple store', 'apple store on amazon',
                'carplay adapter', 'wireless carplay',
                'nordvpn', 'vpn with no logs',
                'iphone air cases', 'iphone cases', 'cases and bumpers',
                'magsafe battery', 'magsafe charger',
                'official iphone', 'iphone 17', 'iphone air',
                'photo by', 'on unsplash', 'on amazon',
                'pro max', 'buy now', 'shop now', 'get it here',
                'disclosure', 'affiliate link', 'we may earn'
              ];

              // Section headers that indicate non-article content
              var sectionHeaders = [
                'popular stories', 'related articles', 'related stories',
                'more stories', 'top stories', 'trending', 'recommended',
                'you might also like', 'read more', 'see also',
                'more from', 'latest news', 'recent posts', 'most read',
                'editor picks', 'featured', 'don\\'t miss', 'also read',
                'top rated comments', 'reader comments', 'leave a comment'
              ];

              // Aggressively find and remove sections with these headers
              var allElements = div.querySelectorAll('*');
              var elementsToRemove = [];

              allElements.forEach(function(el) {
                var text = (el.textContent || '').toLowerCase().trim();
                var directText = '';
                for (var i = 0; i < el.childNodes.length; i++) {
                  if (el.childNodes[i].nodeType === 3) {
                    directText += el.childNodes[i].textContent;
                  }
                }
                directText = directText.toLowerCase().trim();

                var isHeaderElement = sectionHeaders.some(function(p) {
                  return directText === p || (directText.indexOf(p) !== -1 && directText.length < 50);
                });

                if (isHeaderElement) {
                  console.log('Reader: Found section header to remove:', directText);
                  var container = el;
                  while (container.parentElement &&
                         container.parentElement.tagName !== 'BODY' &&
                         container.parentElement.tagName !== 'ARTICLE' &&
                         container.parentElement.tagName !== 'DIV') {
                    container = container.parentElement;
                  }
                  var current = container;
                  while (current) {
                    var next = current.nextElementSibling;
                    elementsToRemove.push(current);
                    current = next;
                  }
                }
              });

              elementsToRemove.forEach(function(el) {
                if (el.parentElement) {
                  el.parentElement.removeChild(el);
                }
              });

              var remaining = div.querySelectorAll('h1, h2, h3, h4, h5, h6, strong, b, header, section, aside');
              remaining.forEach(function(el) {
                var text = (el.textContent || '').toLowerCase().trim();
                var isSection = sectionHeaders.some(function(p) { return text === p || (text.indexOf(p) !== -1 && text.length < 100); });
                if (isSection && el.parentElement) {
                  console.log('Reader: Removing section element:', text.substring(0, 50));
                  el.parentElement.removeChild(el);
                }
              });

              // Remove Google News promotional links and their containers
              var googlePromoLinks = div.querySelectorAll('a[href*="news.google.com"], a[href*="google.com/publisher"], a[href*="google.com/s/notification"], a[href*="google.com/alerts"]');
              googlePromoLinks.forEach(function(link) {
                var container = link.closest('figure') || link.closest('aside') || link.closest('div');
                if (container && container.parentElement) {
                  container.parentElement.removeChild(container);
                } else if (link.parentElement) {
                  link.parentElement.removeChild(link);
                }
              });

              // Remove any links to google.com that contain images (likely promotional badges)
              var allGoogleLinks = div.querySelectorAll('a[href*="google.com"]');
              allGoogleLinks.forEach(function(link) {
                var hasImg = link.querySelector('img') || link.querySelector('svg');
                var linkText = (link.textContent || '').toLowerCase();
                if (hasImg || linkText.indexOf('preferred') !== -1 || linkText.indexOf('follow') !== -1) {
                  var container = link.closest('figure') || link.closest('aside') || link.closest('div');
                  if (container && container.parentElement && container.textContent.length < 150) {
                    container.parentElement.removeChild(container);
                  } else if (link.parentElement) {
                    link.parentElement.removeChild(link);
                  }
                }
              });

              // Remove images with Google-related alt text or src
              var allImages = div.querySelectorAll('img');
              allImages.forEach(function(img) {
                var alt = (img.alt || '').toLowerCase();
                var src = (img.src || '').toLowerCase();
                var title = (img.title || '').toLowerCase();
                if (alt.indexOf('google') !== -1 || alt.indexOf('preferred') !== -1 ||
                    src.indexOf('gstatic.com') !== -1 || src.indexOf('google.com') !== -1 ||
                    title.indexOf('google') !== -1 || title.indexOf('preferred') !== -1) {
                  var container = img.closest('figure') || img.closest('a') || img.closest('div');
                  if (container && container.parentElement && container.textContent.length < 100) {
                    container.parentElement.removeChild(container);
                  } else if (img.parentElement) {
                    img.parentElement.removeChild(img);
                  }
                }
              });

              var allContainers = div.querySelectorAll('figure, aside, div');
              allContainers.forEach(function(el) {
                var text = (el.textContent || '').toLowerCase().trim();
                if (text.length < 100 && text.length > 5) {
                  if (text.indexOf('preferred source') !== -1 ||
                      text.indexOf('add as a preferred') !== -1 ||
                      text.indexOf('follow us on google') !== -1 ||
                      text.indexOf('follow on google news') !== -1) {
                    el.parentElement && el.parentElement.removeChild(el);
                  }
                }
              });

              var lists = div.querySelectorAll('ul');
              lists.forEach(function(ul) {
                var links = ul.querySelectorAll('a');
                var affiliateCount = 0;
                links.forEach(function(a) {
                  var href = (a.href || '').toLowerCase();
                  if (affiliateURLPatterns.some(function(p) { return href.indexOf(p) !== -1; })) {
                    affiliateCount++;
                  }
                });
                if (links.length > 0 && affiliateCount >= links.length / 2) {
                  ul.parentElement && ul.parentElement.removeChild(ul);
                }
              });

              var affiliateLinks = div.querySelectorAll('a');
              affiliateLinks.forEach(function(el) {
                var href = (el.href || '').toLowerCase();
                var isAffiliate = affiliateURLPatterns.some(function(p) { return href.indexOf(p) !== -1; });
                if (isAffiliate) {
                  var parent = el.closest('li');
                  if (parent) {
                    parent.parentElement && parent.parentElement.removeChild(parent);
                  } else {
                    el.parentElement && el.parentElement.removeChild(el);
                  }
                }
              });

              var elements = div.querySelectorAll('li, figure, div, p, a, span');
              elements.forEach(function(el) {
                var text = (el.textContent || '').toLowerCase();
                var isPromo = promoPatterns.some(function(p) { return text.indexOf(p) !== -1; });
                if (isPromo && text.length < 400) {
                  el.parentElement && el.parentElement.removeChild(el);
                }
              });

              for (var i = 0; i < 3; i++) {
                var empties = div.querySelectorAll('p:empty, div:empty, figure:empty, ul:empty, li:empty, span:empty, a:empty');
                empties.forEach(function(el) { el.parentElement && el.parentElement.removeChild(el); });
              }

              return div.innerHTML;
            }

            var cleanedContent = cleanContent(article.content);
            var title = article.title || document.title || '';
            var byline = article.byline || '';
            var bylineHtml = byline ? '<div class="reader-byline">' + escapeHtml(byline) + '</div>' : '';
            var baseHref = document.baseURI || location.href;
            var dirAttr = article.dir ? ' dir="' + article.dir + '"' : '';

            var html = '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
              '<base href="' + baseHref + '">' +
              '<title>' + escapeHtml(title) + '</title>' +
              '<style>' +
              ':root { --bg-color: #f6f4ef; --text-color: #1e1e1e; --secondary-color: #6b6b6b; --link-color: #007AFF; }' +
              '@media (prefers-color-scheme: dark) { :root { --bg-color: #000000; --text-color: #f2f2f2; --secondary-color: #a5a5a5; --link-color: #5AC8FA; } }' +
              'body { margin: 0; background: var(--bg-color); color: var(--text-color); }' +
              '.reader-shell { max-width: 860px; margin: 0 auto; padding: 32px 20px 60px; }' +
              '.reader-title { font-size: \(titleFontSize)px; line-height: 1.2; margin: 0 0 16px; font-weight: 700; }' +
              '.reader-byline { font-size: 14px; color: var(--secondary-color); margin-bottom: 20px; }' +
              '.reader-article { font-size: 18px; line-height: 1.7; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif; }' +
              '.reader-article img { max-width: 100%; height: auto; border-radius: 8px; margin: 24px 0; }' +
              '.reader-article a { color: var(--link-color); text-decoration: underline; }' +
              '.reader-article figure { margin: 24px 0; }' +
              '.reader-article figcaption { font-size: 14px; color: var(--secondary-color); text-align: center; margin-top: 8px; }' +
              '.reader-article pre { white-space: pre-wrap; background: rgba(128,128,128,0.1); padding: 16px; border-radius: 8px; overflow-x: auto; }' +
              '.reader-article code { font-family: "SF Mono", Monaco, "Courier New", monospace; font-size: 0.9em; background: rgba(128,128,128,0.1); padding: 2px 6px; border-radius: 4px; }' +
              '.reader-article blockquote { border-left: 4px solid var(--link-color); margin: 16px 0; padding: 12px 16px; color: var(--secondary-color); font-style: italic; background: rgba(128,128,128,0.05); border-radius: 0 8px 8px 0; }' +
              '.reader-article h1, .reader-article h2, .reader-article h3, .reader-article h4 { margin: 24px 0 12px; font-weight: 600; line-height: 1.3; }' +
              '.reader-article p { margin: 16px 0; }' +
              '.reader-article ul, .reader-article ol { padding-left: 24px; margin: 16px 0; }' +
              '.reader-article li { margin: 8px 0; }' +
              '.reader-article table { border-collapse: collapse; width: 100%; margin: 16px 0; }' +
              '.reader-article th, .reader-article td { border: 1px solid rgba(128,128,128,0.3); padding: 8px 12px; text-align: left; }' +
              '.reader-article th { background: rgba(128,128,128,0.1); font-weight: 600; }' +
              '</style>' +
              '</head><body><div class="reader-shell"' + dirAttr + '><h1 class="reader-title">' + escapeHtml(title) + '</h1>' + bylineHtml + '<article class="reader-article">' + cleanedContent + '</article></div></body></html>';

            window.__rssReaderOriginalURL = location.href;
            document.open();
            document.write(html);
            document.close();
            window.__rssReaderModeActive = true;
            return true;
          } catch (e) {
            console.error('Reader mode error:', e);
            return false;
          }
        })();
        """

        guard !readability.isEmpty else {
            return readerScript
        }

        return readability + "\n;" + readerScript
    }

    /// Attempts to load Readability.js from the app bundle
    private static func loadReadabilitySource() -> String {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: "Readability", withExtension: "js"),
            bundle.url(forResource: "readability", withExtension: "js"),
            bundle.bundleURL.appendingPathComponent("Readability.js"),
            bundle.bundleURL.appendingPathComponent("readability.js")
        ]

        for url in candidates {
            guard let url else { continue }
            if let source = try? String(contentsOf: url) {
                return source
            }
        }

        // Fallback: return empty string if not found
        print("⚠️ ReaderModeService: Readability.js not found in bundle")
        return ""
    }
}

private func ensureBackgroundTTSReady() {}

// MARK: - Glass Effect Compatibility Extension
extension View {
    func glassEffectCompat<S: Shape>(_ isInteractive: Bool = true, in shape: S) -> some View {
        self.background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.stroke(
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
    
    // Navigation gesture extensions
    func navigationGestures() -> some View {
        self.modifier(NavigationGestureModifier())
    }
    
    func navigationFeedback() -> some View {
        self.overlay(NavigationFeedbackOverlay())
    }
}

// MARK: - Navigation Gesture Support
struct NavigationGestureModifier: ViewModifier {
    @EnvironmentObject var appState: AppState

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .background(
                MacNavigationSwipeView(
                    onBack: { performTrackpadBackNavigation() },
                    onForward: { performForwardNavigation() }
                )
            )
            .onKeyPress(.leftArrow, action: handleBackKeyPress)
            .onKeyPress(.rightArrow, action: handleForwardKeyPress)
        #else
        content
            .gesture(primaryNavigationGesture)
            #if os(iOS)
            .simultaneousGesture(trackpadGesture)
            #endif
            .onKeyPress(.leftArrow, action: handleBackKeyPress)
            .onKeyPress(.rightArrow, action: handleForwardKeyPress)
        #endif
    }

    // Primary gesture for touch and general interaction
    private var primaryNavigationGesture: some Gesture {
        DragGesture(minimumDistance: 50, coordinateSpace: .local)
            .onEnded { value in
                let horizontalAmount = value.translation.width
                let verticalAmount = value.translation.height

                // Ensure horizontal swipe is dominant (at least 2:1 ratio)
                guard abs(horizontalAmount) > abs(verticalAmount) * 2 else { return }

                if horizontalAmount > 0 && appState.canGoBack {
                    // Swipe right - go back
                    withAnimation(.easeInOut(duration: 0.3)) {
                        appState.navigateBackInHistory()
                    }
                }
            }
    }

    #if os(iOS)
    // Trackpad gesture for iPad and Mac
    private var trackpadGesture: some Gesture {
        // Use a more sensitive gesture for trackpad
        DragGesture(minimumDistance: 30, coordinateSpace: .local)
            .onEnded { value in
                let horizontalAmount = value.translation.width
                let verticalAmount = value.translation.height

                // Different sensitivity for trackpad gestures
                guard abs(horizontalAmount) > abs(verticalAmount) * 1.5 else { return }
                guard abs(horizontalAmount) > 30 else { return }

                if horizontalAmount > 0 {
                    performTrackpadBackNavigation(duration: 0.2)
                }
            }
    }
    #endif

    private func performTrackpadBackNavigation(duration: Double = 0.2) {
        withAnimation(.easeInOut(duration: duration)) {
            appState.navigateBack()
        }
    }

    private func performForwardNavigation(duration: Double = 0.2) {
        guard appState.canGoForward else { return }
        withAnimation(.easeInOut(duration: duration)) {
            appState.navigateForwardInHistory()
        }
    }

    private func handleBackKeyPress() -> KeyPress.Result {
        if appState.canGoBack {
            withAnimation(.easeInOut(duration: 0.3)) {
                appState.navigateBackInHistory()
            }
            return .handled
        }
        return .ignored
    }

    private func handleForwardKeyPress() -> KeyPress.Result {
        if appState.canGoForward {
            performForwardNavigation(duration: 0.3)
            return .handled
        }
        return .ignored
    }
}

#if os(macOS)
private struct MacNavigationSwipeView: NSViewRepresentable {
    let onBack: () -> Void
    let onForward: () -> Void

    func makeNSView(context: Context) -> SwipeCaptureView {
        let view = SwipeCaptureView()
        view.onBack = onBack
        view.onForward = onForward
        return view
    }

    func updateNSView(_ nsView: SwipeCaptureView, context: Context) {
        nsView.onBack = onBack
        nsView.onForward = onForward
    }

    final class SwipeCaptureView: NSView {
        var onBack: () -> Void = {}
        var onForward: () -> Void = {}

        private var eventMonitor: Any?
        private var accumulatedTranslation: CGFloat = 0
        private var accumulatedVerticalTranslation: CGFloat = 0
        private var gestureTriggered = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configure()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configure()
        }

        private func configure() {
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            refreshEventMonitor()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Do not block interactions with the underlying SwiftUI content.
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshEventMonitor()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeEventMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            guard let superview = superview else { return }
            frame = superview.bounds
            autoresizingMask = [.width, .height]
        }

        deinit {
            removeEventMonitor()
        }

        private func refreshEventMonitor() {
            removeEventMonitor()
            guard window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                self?.handleScroll(event)
                return event
            }
        }

        private func removeEventMonitor() {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }

        private func handleScroll(_ event: NSEvent) {
            // Only consider indirect (trackpad) horizontal scrolling
            guard event.subtype == .tabletPoint || event.subtype.rawValue == 0 else { return }

            if event.phase == .began || event.momentumPhase == .began {
                accumulatedTranslation = 0
                accumulatedVerticalTranslation = 0
                gestureTriggered = false
            }

            let horizontal = event.scrollingDeltaX
            let vertical = event.scrollingDeltaY

            // macOS provides inverted deltas when "natural scrolling" is enabled.
            let adjustedHorizontal = event.isDirectionInvertedFromDevice ? -horizontal : horizontal

            accumulatedTranslation += adjustedHorizontal
            accumulatedVerticalTranslation += vertical

            if !gestureTriggered {
                let horizontalMagnitude = abs(accumulatedTranslation)
                let verticalMagnitude = abs(accumulatedVerticalTranslation)
                let meetsDirectionality = horizontalMagnitude > verticalMagnitude * 1.2
                let meetsDistance = horizontalMagnitude > 40

                if meetsDirectionality && meetsDistance {
                    gestureTriggered = true
                    if accumulatedTranslation < 0 {
                        onBack()
                    }
                }
            }

            let stateEnded = event.phase == .ended || event.phase == .cancelled ||
                event.momentumPhase == .ended || event.momentumPhase == .cancelled

            if stateEnded {
                accumulatedTranslation = 0
                accumulatedVerticalTranslation = 0
                gestureTriggered = false
            }
        }
    }
}
#endif

// Navigation feedback overlay to show visual feedback during navigation
struct NavigationFeedbackOverlay: View {
    @EnvironmentObject var appState: AppState
    @State private var showBackIndicator = false
    @State private var showForwardIndicator = false
    @State private var lastHistoryIndex = -1
    
    var body: some View {
        ZStack {
            // Back indicator
            if showBackIndicator {
                HStack {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.blue.opacity(0.8))
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 60, height: 60)
                        )
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity),
                            removal: .opacity
                        ))
                    Spacer()
                }
                .padding(.horizontal, 30)
            }
            
            // Forward indicator
            if showForwardIndicator {
                HStack {
                    Spacer()
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.blue.opacity(0.8))
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 60, height: 60)
                        )
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity),
                            removal: .opacity
                        ))
                }
                .padding(.horizontal, 30)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: appState.canGoBack) { oldValue, newValue in
            updateIndicators()
        }
        .onChange(of: appState.canGoForward) { oldValue, newValue in
            updateIndicators()
        }
    }
    
    private func updateIndicators() {
        // This is a simple way to detect navigation direction
        // In a real implementation, you might want to track this more precisely
        
        // Show back indicator briefly
        if !showBackIndicator && appState.canGoBack {
            showBackIndicator = true
            withAnimation(.easeOut(duration: 0.6)) {
                showBackIndicator = false
            }
        }
        
        // Show forward indicator briefly
        if !showForwardIndicator && appState.canGoForward {
            showForwardIndicator = true
            withAnimation(.easeOut(duration: 0.6)) {
                showForwardIndicator = false
            }
        }
    }
}

// MARK: - Glass Sidebar Button
struct GlassSidebarButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
        }
        .glassEffectCompat(in: Circle())
        .shadow(radius: 2)
    }
}

// MARK: - App Color Definitions (matching code2 example)
struct AppColors {
    static var background: Color {
        #if os(iOS)
        return Color(UIColor.systemBackground)
        #else
        return macDynamicColor(light: rgb(248, 248, 250), dark: rgb(28, 28, 30))
        #endif
    }

    static var systemGray5: Color {
        #if os(iOS)
        return Color(UIColor.systemGray5)
        #else
        return macDynamicColor(light: rgb(229, 229, 234), dark: rgb(44, 44, 46))
        #endif
    }

    static var systemGray6: Color {
        #if os(iOS)
        return Color(UIColor.systemGray6)
        #else
        return macDynamicColor(light: rgb(242, 242, 247), dark: rgb(28, 28, 30))
        #endif
    }

    static var neutralGray: Color {
        #if os(iOS)
        return Color(UIColor.systemGray)
        #else
        return macDynamicColor(light: rgb(142, 142, 147), dark: rgb(174, 174, 178))
        #endif
    }
    
    static var separatorColor: Color {
        #if os(iOS)
        return Color(UIColor.separator)
        #else
        return Color(NSColor.separatorColor)
        #endif
    }

    static var secondaryBackground: Color {
        #if os(iOS)
        return Color(UIColor.secondarySystemBackground)
        #else
        return macDynamicColor(light: rgb(255, 255, 255), dark: rgb(44, 44, 46))
        #endif
    }

    static func redditBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .black : background
    }

    static func redditCardFill(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            return Color(red: 0.035, green: 0.035, blue: 0.04)
        }
        return Color.orange.opacity(0.05)
    }

    static func redditCardBorder(for colorScheme: ColorScheme) -> LinearGradient {
        return LinearGradient(
            colors: [
                Color(red: 0.82, green: 0.26, blue: 0.14),
                Color.orange,
                Color(red: 0.96, green: 0.78, blue: 0.28)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    #if os(macOS)
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
        NSColor(calibratedRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: 1.0)
    }

    private static func macDynamicColor(light: NSColor, dark: NSColor) -> Color {
        if #available(macOS 10.14, *) {
            let dynamic = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }
            return Color(nsColor: dynamic)
        } else {
            return Color(nsColor: light)
        }
    }
    #endif
}

// MARK: - Cross-Platform Clipboard Helpers
private func copyToClipboard(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

private func copyURLToClipboard(_ url: URL) {
    #if os(iOS)
    UIPasteboard.general.url = url
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
    #endif
}

private func currentPlatformScreenHeight() -> CGFloat {
    #if os(iOS)
    return UIScreen.main.bounds.height
    #elseif os(macOS)
    return NSScreen.main?.visibleFrame.height ?? 900
    #else
    return 900
    #endif
}

private let articleChromeContinuityAnimation = Animation.spring(response: 0.34, dampingFraction: 0.88, blendDuration: 0.12)

#if os(macOS)
private struct MacArticleScrollWheelActivityMonitor: NSViewRepresentable {
    let onScrollActivity: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onScrollActivity = onScrollActivity
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onScrollActivity = onScrollActivity
    }

    final class MonitorView: NSView {
        var onScrollActivity: (() -> Void)?
        private var eventMonitor: Any?
        private var lastActivityTime: TimeInterval = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configure()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configure()
        }

        private func configure() {
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            refreshEventMonitor()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshEventMonitor()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeEventMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            guard let superview else { return }
            frame = superview.bounds
            autoresizingMask = [.width, .height]
        }

        deinit {
            removeEventMonitor()
        }

        private func refreshEventMonitor() {
            removeEventMonitor()
            guard window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                self?.handleScroll(event)
                return event
            }
        }

        private func removeEventMonitor() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }

        private func handleScroll(_ event: NSEvent) {
            guard let window, event.window === window else { return }

            let location = convert(event.locationInWindow, from: nil)
            guard bounds.contains(location) else { return }

            let vertical = abs(event.scrollingDeltaY)
            let horizontal = abs(event.scrollingDeltaX)
            guard vertical > 0, vertical >= horizontal else { return }

            let now = Date().timeIntervalSinceReferenceDate
            guard now - lastActivityTime > 0.035 else { return }
            lastActivityTime = now

            onScrollActivity?()
        }
    }
}

private struct MacArticleScrollActivityObserver: NSViewRepresentable {
    let onScrollActivity: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onScrollActivity = onScrollActivity
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onScrollActivity = onScrollActivity
        nsView.attachToEnclosingScrollViewIfNeeded()
    }

    final class ObserverView: NSView {
        var onScrollActivity: (() -> Void)?
        private weak var observedScrollView: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachToEnclosingScrollViewIfNeeded()
        }

        deinit {
            if let observedScrollView {
                NotificationCenter.default.removeObserver(self, name: NSScrollView.didLiveScrollNotification, object: observedScrollView)
            }
        }

        func attachToEnclosingScrollViewIfNeeded() {
            guard let scrollView = enclosingScrollView else {
                DispatchQueue.main.async { [weak self] in
                    self?.attachToEnclosingScrollViewIfNeeded()
                }
                return
            }

            guard observedScrollView !== scrollView else { return }

            if let observedScrollView {
                NotificationCenter.default.removeObserver(self, name: NSScrollView.didLiveScrollNotification, object: observedScrollView)
            }

            observedScrollView = scrollView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleLiveScroll),
                name: NSScrollView.didLiveScrollNotification,
                object: scrollView
            )
        }

        @objc private func handleLiveScroll() {
            onScrollActivity?()
        }
    }
}
#endif

private struct ArticleChromeContinuityModifier: ViewModifier {
    let isVisible: Bool
    let edge: Edge

    private var verticalOffset: CGFloat {
        guard !isVisible else { return 0 }
        return edge == .top ? -12 : 12
    }

    private var anchor: UnitPoint {
        edge == .top ? .top : .bottom
    }

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .blur(radius: isVisible ? 0 : 2.5)
            .scaleEffect(isVisible ? 1 : 0.985, anchor: anchor)
            .offset(y: verticalOffset)
    }
}

private extension AnyTransition {
    static func articleChromeContinuity(edge: Edge) -> AnyTransition {
        .modifier(
            active: ArticleChromeContinuityModifier(isVisible: false, edge: edge),
            identity: ArticleChromeContinuityModifier(isVisible: true, edge: edge)
        )
    }
}

// Extension to enable enhanced swipe back navigation
extension View {
#if os(macOS)
    /// macOS: disable legacy press-drag "ship" gesture entirely.
    /// Navigation gestures on Mac are provided via an NSPanGestureRecognizer capturing two-finger swipes.
    func onSwipeGesture(perform action: @escaping () -> Void) -> some View { self }

    func enhancedSwipeBack(perform action: @escaping () -> Void) -> some View { self }
#else
    /// iOS/iPadOS: keep the lightweight drag helper as-is.
    func onSwipeGesture(perform action: @escaping () -> Void) -> some View {
        self.background(
            GeometryReader { _ in
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                if abs(dx) > abs(dy), dx > 0 {
                                    action()
                                }
                            }
                    )
            }
        )
    }

    func enhancedSwipeBack(perform action: @escaping () -> Void) -> some View {
        self.gesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .local)
                .onEnded { value in
                    // Enhanced swipe detection with stricter horizontal requirements
                    let horizontalDistance = value.translation.width
                    let verticalDistance = value.translation.height
                    let velocity = value.velocity.width
                    
                    // Much stricter requirements for swipe back
                    let isHorizontalSwipe = abs(horizontalDistance) > abs(verticalDistance) * 2.5 // Horizontal must be 2.5x larger than vertical
                    let isRightSwipe = horizontalDistance > 0
                    let hasGoodVelocity = abs(velocity) > 300 // Higher velocity requirement
                    let hasGoodDistance = abs(horizontalDistance) > 120 // Larger distance requirement
                    let verticalNotTooLarge = abs(verticalDistance) < 50 // Limit vertical movement
                    
                    if isHorizontalSwipe && isRightSwipe && (hasGoodVelocity || hasGoodDistance) && verticalNotTooLarge {
                        // Add haptic feedback on iOS
                        #if os(iOS)
                        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                        impactFeedback.impactOccurred()
                        #endif
                        
                        // Perform the back action with animation
                        withAnimation(.easeOut(duration: 0.3)) {
                            action()
                        }
                    }
                }
        )
    }
#endif
}

// Add this class at the top of the file, before ContentView
class ArticleQAState: ObservableObject {
    @Published var showQAInterface = false
    @Published var questionText = ""
    @Published var answerText = "Ask a question about this article..."
    @Published var isProcessingQuestion = false
    @Published var previousQuestionText: String? = nil

    static let shared = ArticleQAState()

    func resetState() {
        showQAInterface = false
        questionText = ""
        answerText = "Ask a question about this article..."
        isProcessingQuestion = false
        previousQuestionText = nil
    }

    func toggleQAInterface() {
        showQAInterface.toggle()
    }
}

// Activity presenter anchored to its own view (works on iOS, iPad, and iPad-on-Mac)
#if os(iOS)
struct ActivityViewPresenter: UIViewRepresentable {
    @Binding var isPresented: Bool
    var items: [Any]

    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }

    func updateUIView(_ view: UIView, context: Context) {
        guard isPresented else { return }
        DispatchQueue.main.async {
            // Check if running on Mac (iPad app on Mac) - if so, just dismiss to avoid crash
            let isRunningOnMac: Bool = {
                #if targetEnvironment(macCatalyst)
                return true
                #else
                if #available(iOS 14.0, *) {
                    return ProcessInfo.processInfo.isiOSAppOnMac
                }
                return false
                #endif
            }()
            
            if isRunningOnMac {
                // On Mac, use native sharing without UIActivityViewController
                self.presentMacShare(items: items, from: view)
                self.isPresented = false
                return
            }
            
            // Bridge items to UIKit-friendly types
            let bridged: [Any] = items.compactMap { item in
                if let url = item as? URL { return url }
                if let str = item as? String { return str }
                if let nsurl = item as? NSURL { return nsurl as URL }
                if let nsstr = item as? NSString { return nsstr as String }
                return nil
            }
            guard !bridged.isEmpty else {
                self.isPresented = false
                return
            }
            
            // Standard iOS sharing
            let controller = UIActivityViewController(activityItems: bridged, applicationActivities: nil)
            controller.modalPresentationStyle = .automatic

            if let pop = controller.popoverPresentationController {
                pop.sourceView = view
                // Ensure a non-zero rect
                let rect = view.bounds.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1) : view.bounds
                pop.sourceRect = rect
                pop.permittedArrowDirections = .any
            }

            // Find top-most UIViewController to present from
            let rootVC: UIViewController? = {
                if let rvc = sequence(first: view.next, next: { $0?.next }).first(where: { $0 is UIViewController }) as? UIViewController {
                    return rvc
                }
                for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                    if let win = scene.windows.first(where: { $0.isKeyWindow }), let root = win.rootViewController {
                        return root
                    }
                }
                return UIApplication.shared.windows.first?.rootViewController
            }()

            func topMost(from vc: UIViewController?) -> UIViewController? {
                guard var top = vc else { return nil }
                while let presented = top.presentedViewController { top = presented }
                if let nav = top as? UINavigationController { return topMost(from: nav.visibleViewController) }
                if let tab = top as? UITabBarController { return topMost(from: tab.selectedViewController) }
                return top
            }

            if let presenter = topMost(from: rootVC) {
                presenter.present(controller, animated: true) {
                    self.isPresented = false
                }
            } else {
                self.isPresented = false
            }
        }
    }
    
    private func presentMacShare(items: [Any], from view: UIView) {
        // Use action sheet for Mac instead of UIActivityViewController
        guard let firstItem = items.first else { return }
        
        let alert = UIAlertController(title: "Share", message: nil, preferredStyle: .actionSheet)
        
        // Copy Link action
        alert.addAction(UIAlertAction(title: "Copy Link", style: .default) { _ in
            if let url = firstItem as? URL {
                copyURLToClipboard(url)
            } else if let string = firstItem as? String {
                copyToClipboard(string)
            }
        })
        
        // Open in Browser action (for URLs)
        if let url = firstItem as? URL {
            alert.addAction(UIAlertAction(title: "Open in Browser", style: .default) { _ in
                UIApplication.shared.open(url)
            })
        }
        
        // Cancel action
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        // Configure for Mac presentation
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            let rect = view.bounds.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1) : view.bounds
            popover.sourceRect = rect
        }
        
        // Present from top view controller
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first(where: { $0.isKeyWindow }),
           let rootVC = window.rootViewController {
            
            func topMost(from vc: UIViewController) -> UIViewController {
                if let presented = vc.presentedViewController {
                    return topMost(from: presented)
                }
                if let nav = vc as? UINavigationController, let visible = nav.visibleViewController {
                    return topMost(from: visible)
                }
                if let tab = vc as? UITabBarController, let selected = tab.selectedViewController {
                    return topMost(from: selected)
                }
                return vc
            }
            
            let presenter = topMost(from: rootVC)
            presenter.present(alert, animated: true)
        }
    }
    
}
#endif


// (macOS helper added inside ContentView below)

// Wrapper for RedditDetailView that accepts a post directly
struct RedditDetailViewWrapper: View {
    let post: RedditPost
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        RedditDetailView()
            .environmentObject(appState)
            .onAppear {
                // Ensure the post is selected
                appState.selectedRedditPost = post
                appState.markRedditPostAsRead(post)
            }
    }
}

private struct RedditSortPicker: View {
    @Binding var selection: RedditService.SortOption

    var body: some View {
        Picker("Sort", selection: $selection) {
            ForEach(RedditService.SortOption.allCases) { option in
                Text(option.displayName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(height: 34)
        .accessibilityElement(children: .contain)
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    // Programmatic pop for NavigationStack on iPhone
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    // Existing properties
    @State private var showAddSubscription = false
    @State private var selectedCategory: FeedCategory = .all
    @State private var showSettings = false
    @State private var currentlyVisibleSubscription: String?
    @State private var isSidebarProgrammaticRestoreInFlight = false
    @State private var programmaticRestoreInFlightKeys: Set<String> = []
    @State private var showRedditSummaryScopePicker = false
    @State private var redditSummaryScopeSubreddit: String?
    @State private var isArticleReadingChromeHidden = false
    #if os(iOS)
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    #endif
    
    private var isRunningOnMac: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        if #available(iOS 14.0, *) {
            return ProcessInfo.processInfo.isiOSAppOnMac
        }
        return false
        #endif
    }

    private func articleListID(for article: Article) -> String {
        article.id
    }

    private var sidebarSelectionAccent: Color {
        Color.blue
    }

    private var sidebarSurfaceBackground: some View {
        Group {
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color(red: 0.055, green: 0.058, blue: 0.095),
                        Color(red: 0.025, green: 0.026, blue: 0.047)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.035),
                            Color(red: 0.35, green: 0.18, blue: 0.75).opacity(0.08),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.985, green: 0.988, blue: 1.0),
                        Color(red: 0.925, green: 0.940, blue: 0.975)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.55),
                            Color.blue.opacity(0.045),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        }
    }

    private var sidebarHeaderTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.45) : Color.black.opacity(0.46)
    }

    private var sidebarDividerColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.10)
    }

    private func sidebarSelectionRailColor(for accentColor: Color) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.75) : accentColor.opacity(0.95)
    }

    private func sidebarSelectionGradient(for accentColor: Color) -> LinearGradient {
        LinearGradient(
            colors: [
                accentColor.opacity(colorScheme == .dark ? 0.82 : 0.90),
                accentColor.opacity(colorScheme == .dark ? 0.46 : 0.68)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func sidebarSelectionStrokeColor(for accentColor: Color) -> Color {
        accentColor.opacity(colorScheme == .dark ? 0.52 : 0.62)
    }

    private var sidebarUnselectedTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.88) : Color.black.opacity(0.78)
    }

    private var sidebarSelectedTextColor: Color {
        Color.white.opacity(0.98)
    }

    private var sidebarCountPillTextColor: Color {
        colorScheme == .dark
            ? Color(red: 0.74, green: 0.78, blue: 1.0).opacity(0.9)
            : Color(red: 0.24, green: 0.31, blue: 0.63)
    }

    private var sidebarCountPillBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.11, blue: 0.20).opacity(0.92)
            : Color(red: 0.86, green: 0.89, blue: 0.98).opacity(0.95)
    }

    private var sidebarSelectedCountPillTextColor: Color {
        Color.white.opacity(0.95)
    }

    private var sidebarSelectedCountPillBackground: Color {
        Color.white.opacity(colorScheme == .dark ? 0.16 : 0.22)
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(sidebarHeaderTextColor)
            .textCase(nil)
            .tracking(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sidebarSystemIcon(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
    }

    private func sidebarRedditIcon(size: CGFloat = 26) -> some View {
        Image("RedditLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private func sidebarSubscriptionIcon(for subscription: Subscription, isSelected: Bool = false) -> some View {
        if subscription.type == .rss {
            if let url = URL(string: subscription.url), let host = url.host {
                DomainIconView(domain: host, size: 18)
                    .frame(width: 28, height: 28)
            } else {
                sidebarSystemIcon("rss", tint: Color(red: 0.56, green: 0.67, blue: 1.0))
            }
        } else {
            sidebarRedditIcon()
        }
    }

    private func sidebarMenuRow<Icon: View>(
        title: String,
        unreadCount: Int? = nil,
        isSelected: Bool = false,
        accentColor: Color = Color(red: 0.56, green: 0.67, blue: 1.0),
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        SidebarMenuRow(
            title: title,
            unreadCount: unreadCount,
            isSelected: isSelected,
            accentColor: accentColor,
            selectedTextColor: sidebarSelectedTextColor,
            unselectedTextColor: sidebarUnselectedTextColor,
            selectionGradient: sidebarSelectionGradient(for: accentColor),
            selectionStrokeColor: sidebarSelectionStrokeColor(for: accentColor),
            selectionRailColor: sidebarSelectionRailColor(for: accentColor),
            countPillTextColor: sidebarCountPillTextColor,
            countPillBackground: sidebarCountPillBackground,
            selectedCountPillTextColor: sidebarSelectedCountPillTextColor,
            selectedCountPillBackground: sidebarSelectedCountPillBackground,
            icon: icon
        )
    }

    private func isLibraryCategorySelected(_ category: FeedCategory) -> Bool {
        appState.activeSubscriptionURL == nil && appState.lastSelectedCategory == category
    }

    private func redditPostListID(for post: RedditPost) -> String {
        post.id
    }

    private var shouldShowExplicitWebAIControls: Bool {
        appState.settings.selectedSummaryProvider != .webAI
    }
    
    var body: some View {
        // FIX: Use a stack-based navigation approach instead
        ZStack {
            // Dynamic background that adapts to color scheme
            (colorScheme == .dark ? Color.black : AppColors.background)
                .edgesIgnoringSafeArea(.all)
            
            // Main content
                        #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                // iPhone navigation
                if let post = appState.selectedRedditPost {
                    RedditDetailView()
                        .transition(.move(edge: .trailing))
                        .zIndex(1)
                        .enhancedSwipeBack {
                            appState.navigateBack()
                        }
                } else if let article = appState.selectedArticle {
                    ArticleDetailView(isReadingChromeHidden: $isArticleReadingChromeHidden)
                        .transition(.move(edge: .trailing))
                        .zIndex(1)
                        .enhancedSwipeBack {
                            appState.navigateBack()
                        }
                } else if let activeURL = appState.activeSubscriptionURL, let subscription = appState.subscriptions.first(where: { $0.url == activeURL }) {
                    // Show the subscription list we were in
                    subscriptionView(for: subscription)
                } else {
                    // Root view with sidebar only (allows navigating back to main UI)
                    NavigationView {
                        sidebar
                    }
                    .navigationViewStyle(StackNavigationViewStyle())
                    .background(colorScheme == .dark ? Color.black : AppColors.background)
                }
            } else {
                // iPad: Keep NavigationView alive and overlay detail views.
                ZStack {
                    NavigationView {
                        sidebar
                        restoreNavigationState()
                    }
                    .navigationViewStyle(DoubleColumnNavigationViewStyle())
                    .background(colorScheme == .dark ? Color.black : AppColors.background)

                    if let post = appState.selectedRedditPost {
                        RedditDetailView()
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                            .enhancedSwipeBack {
                                appState.navigateBack()
                            }
                    } else if let article = appState.selectedArticle {
                        ArticleDetailView(isReadingChromeHidden: $isArticleReadingChromeHidden)
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                            .enhancedSwipeBack {
                                appState.navigateBack()
                            }
                    }
                }
            }
            #else
            // macOS: Keep NavigationView alive and overlay detail views.
            ZStack {
                NavigationView {
                    sidebar
                    // Restore the appropriate view based on what was active
                    restoreNavigationState()
                }
                .navigationViewStyle(DoubleColumnNavigationViewStyle())
                .background(colorScheme == .dark ? Color.black : AppColors.redditBackground(for: colorScheme))
                .zIndex(0)
                .onAppear {
                    // Sync local state with app state when navigation view appears
                    self.selectedCategory = appState.lastSelectedCategory
                }

                if let post = appState.selectedRedditPost {
                    RedditDetailView()
                        .transition(.move(edge: .trailing))
                        .zIndex(1)
                        .enhancedSwipeBack {
                            appState.navigateBack()
                        }
                } else if let article = appState.selectedArticle {
                    ArticleDetailView(isReadingChromeHidden: $isArticleReadingChromeHidden)
                        .transition(.move(edge: .trailing))
                        .zIndex(1)
                        .enhancedSwipeBack {
                            appState.navigateBack()
                        }
                }
            }
            #endif
        }
        // Add keyboard shortcuts
        .background(
            Group {
                if appState.selectedArticle != nil || appState.selectedRedditPost != nil {
                    Button("") {
                        appState.navigateBack()
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .hidden()
                }
            }
        )
        // Add a navigation bar overlay when in detail view (only for articles, not Reddit posts)
        .overlay(alignment: .top) {
            if appState.selectedArticle != nil && !isArticleReadingChromeHidden {
                ZStack(alignment: .top) {
                    // Glass background for navigation bar
                    if colorScheme == .dark {
                        Color.black
                            .ignoresSafeArea(edges: .horizontal)
                    } else {
                        Color.clear
                            .background(.ultraThinMaterial)
                            .glassEffectCompat(in: Rectangle())
                            .ignoresSafeArea(edges: .horizontal)
                    }

                    VStack(spacing: 0) {
                        HStack {
                            Spacer()

                            // Action buttons
                            HStack(spacing: 12) {
                                // Summary button
                                if let article = appState.selectedArticle {
                                    Button(action: {
                                        appState.requestSummary(for: article)
                                    }) {
                                        #if os(iOS)
                                        if UIDevice.current.userInterfaceIdiom == .phone {
                                            Image(systemName: "text.quote")
                                                .font(.subheadline)
                                        } else {
                                            Label("Summarize", systemImage: "text.quote")
                                                .font(.subheadline)
                                        }
                                        #else
                                        Label("Summarize", systemImage: "text.quote")
                                            .font(.subheadline)
                                        #endif
                                    }
                                    .buttonStyle(LiquidGlassButtonStyle())

                                    if shouldShowExplicitWebAIControls {
                                        Button(action: {
                                            appState.requestWebSummary(for: article)
                                        }) {
                                            Label(appState.settings.selectedWebAIProvider.displayName, systemImage: "globe")
                                                .font(.subheadline)
                                        }
                                        .buttonStyle(LiquidGlassButtonStyle())
                                    }
                                }

                                // Favorite button
                                if let article = appState.selectedArticle {
                                    Button(action: {
                                        appState.toggleArticleFavorite(article)
                                    }) {
                                        #if os(iOS)
                                        if UIDevice.current.userInterfaceIdiom == .phone {
                                            Image(systemName: article.isFavorite ? "star.fill" : "star")
                                                .font(.subheadline)
                                                .foregroundColor(article.isFavorite ? .yellow : .primary)
                                        } else {
                                            Label("Favorite", systemImage: article.isFavorite ? "star.fill" : "star")
                                                .font(.subheadline)
                                                .foregroundColor(article.isFavorite ? .yellow : .primary)
                                        }
                                        #else
                                        Label("Favorite", systemImage: article.isFavorite ? "star.fill" : "star")
                                            .font(.subheadline)
                                            .foregroundColor(article.isFavorite ? .yellow : .primary)
                                        #endif
                                    }
                                    .buttonStyle(LiquidGlassButtonStyle())
                                }

                                // Ask about article button
                                if let _ = appState.selectedArticle {
                                    Button(action: {
                                        // Toggle Q&A interface for articles
                                        ArticleQAState.shared.toggleQAInterface()
                                    }) {
                                        #if os(iOS)
                                        if UIDevice.current.userInterfaceIdiom == .phone {
                                            Image(systemName: "questionmark.circle")
                                                .font(.subheadline)
                                        } else {
                                            Label("Ask about this article", systemImage: "questionmark.circle")
                                                .font(.subheadline)
                                        }
                                        #else
                                        Label("Ask about this article", systemImage: "questionmark.circle")
                                            .font(.subheadline)
                                        #endif
                                    }
                                    .buttonStyle(LiquidGlassButtonStyle())
                                }

                                // Share button (iOS)
                                #if os(iOS)
                                if let article = appState.selectedArticle {
                                    Button(action: {
                                        if let url = article.url {
                                            shareItems = [url]
                                        } else {
                                            shareItems = [article.title]
                                        }
                                        showShareSheet = true
                                    }) {
                                        if UIDevice.current.userInterfaceIdiom == .phone {
                                            Image(systemName: "square.and.arrow.up")
                                                .font(.subheadline)
                                        } else {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                                .font(.subheadline)
                                        }
                                    }
                                    .buttonStyle(LiquidGlassButtonStyle())
                                }
                                #endif
                                #if os(iOS)
                                // Invisible anchor that presents UIActivityViewController when toggled
                                ActivityViewPresenter(isPresented: $showShareSheet, items: shareItems)
                                    .frame(width: 0, height: 0)
                                #endif
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .frame(height: 60)
                .offset(y: isRunningOnMac ? -20 : 0)
                .transition(.articleChromeContinuity(edge: .top))
            }
        }
        .animation(articleChromeContinuityAnimation, value: isArticleReadingChromeHidden)
        // Sheet for adding subscription
        .sheet(isPresented: $showAddSubscription) {
            AddSubscriptionView()
                .environmentObject(appState)
        }
        // Sheet for Settings
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(appState)
                #if os(macOS)
                .frame(minWidth: 760, idealWidth: 860, minHeight: 640, idealHeight: 760)
                #endif
                #if os(iOS)
                .presentationDetents([.large])
                .presentationCornerRadius(40) // Balanced radius to prevent clipping
                .presentationBackground(.ultraThinMaterial) // Use thin material for iOS 26
                .presentationBackgroundInteraction(.enabled)
                #endif
        }
        .confirmationDialog(
            "Local request is too large",
            isPresented: Binding(
                get: { appState.pendingLocalReroute?.presentationScope == .global },
                set: {
                    if !$0, appState.pendingLocalReroute?.presentationScope == .global {
                        appState.dismissPendingLocalReroute()
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: appState.pendingLocalReroute
        ) { _ in
            ForEach(LocalRerouteProvider.allCases) { provider in
                Button(provider.displayName) {
                    appState.reroutePendingLocalRequest(to: provider)
                }
            }
            Button("Cancel", role: .cancel) {
                appState.dismissPendingLocalReroute()
            }
        } message: { request in
            Text(request.message)
        }
        // Global Summary JSON sheet
        // Commented out sheet - replaced with overlay
        // .sheet(
        //     isPresented: Binding(
        //         get: { appState.showGlobalSummary },
        //         set: { appState.showGlobalSummary = $0 }
        //     )
        // ) {
        //     GlobalSummaryResultView(
        //         json: appState.globalSummaryJSON,
        //         error: appState.lastGlobalSummaryError
        //     )
        //     .environmentObject(appState)
        // }
        // Global Summary Draggable Overlay and Floating Button
        .overlay(
            ZStack {
                let hidesGlobalSummaryWhileWebAIIsMinimized = 
                    (appState.isLoading || appState.isWebAIBatchHandoffInProgress) &&
                    appState.isWebAIHandoffMinimized

                // Draggable summary view
                if appState.showGlobalSummary && !hidesGlobalSummaryWhileWebAIIsMinimized {
                    DraggableGlobalSummaryView(
                        json: appState.globalSummaryJSON,
                        error: appState.lastGlobalSummaryError
                    )
                    .environmentObject(appState)
                    .allowsHitTesting(true)
                }
                
                // Floating button to re-show summary (bottom-right corner)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if appState.hasCachedSummary && !appState.showGlobalSummary {
                            Button {
                                appState.showGlobalSummary = true
                            } label: {
                                Image(systemName: "list.bullet.rectangle")
                                    .font(.title2)
                                    .foregroundColor(.white)
                                    .frame(width: 50, height: 50)
                                    .background(
                                        Circle()
                                            .fill(Color.blue)
                                            .shadow(radius: 4)
                                    )
                            }
                            .padding()
                        }
                    }
                }
            }
        )
        // (iOS share presented via ActivityViewPresenter background anchor near the button)
        // Fallback notification overlay - high priority
        .overlay(
            VStack {
                Spacer()
                if appState.showFallbackNotification {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.orange)
                            .font(.subheadline)
                        Text(appState.fallbackNotification)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: appState.showFallbackNotification)
                }
            }
        )
        .zIndex(1000) // High z-index to ensure it's above other content
        .background(MacWindowChromeBackgroundView(isDark: colorScheme == .dark))
        .onAppear {
            NotificationCenter.default.addObserver(
                forName: Notification.Name("ShowAddSubscription"),
                object: nil,
                queue: .main
            ) { _ in
                showAddSubscription = true
            }
        }
        .background(
            // System-adaptive background color
            (colorScheme == .dark ? Color.black : AppColors.background)
                .ignoresSafeArea()
        )
        .navigationGestures()
        .navigationFeedback()
    }

    // presentMacShare function removed - using ShareLink instead
    
    // MARK: - Sidebar
    var sidebar: some View {
#if os(iOS)
        ScrollViewReader { scrollProxy in
            sidebarList(scrollProxy: scrollProxy)
                .ignoresSafeArea()
        }
#else
        ScrollViewReader { scrollProxy in
            sidebarList(scrollProxy: scrollProxy)
                .toolbar {
                    ToolbarItem {
                        Button(action: {
                            NSApp.keyWindow?.firstResponder?.tryToPerform(
                                #selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
                        }) {
                            Image(systemName: "sidebar.left")
                        }
                    }
                }
        }
#endif
    }

// MARK: - Category Feed List
    var categoryFeedList: some View {
        Group {
            switch appState.lastSelectedCategory {
            case .all:
                allView
            case .unread:
                unreadView
            case .favorites:
                favoritesView
            case .today:
                todayView
            case .reddit:
                redditView
            }
        }
        // Force update on selection change to ensure navigation state is properly updated
        .id("categoryList-\(appState.selectedArticleId ?? "none")-\(appState.selectedRedditPostId ?? "none")")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { appState.manualCloudRefresh() }) {
                    Image(systemName: toolbarSyncIconName)
                }
                .disabled(appState.manualCloudSyncState == .syncing)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showAddSubscription = true }) {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape.fill")
                }
            }
        }
    }

    private var toolbarSyncIconName: String {
        switch appState.manualCloudSyncState {
        case .idle:
            return "arrow.clockwise"
        case .syncing:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .completed:
            return "checkmark.circle.fill"
        }
    }
    
    // MARK: - Feed Views
    var allView: some View {
        ScrollViewReader { scrollProxy in
            List {
                ForEach(appState.feeds.flatMap { $0.articles }
                    .sorted(by: { $0.publishDate > $1.publishDate })) { article in
                        
                    // Use a button for navigation instead of NavigationLink
                    Button(action: {
                        // Set article and navigate
                        appState.selectedArticle = article
                        // Save scroll position for "all" category
                        appState.saveScrollPosition(for: "all_category", itemID: article.id)
                        if !article.isRead {
                            appState.markArticleAsRead(article)
                        }
                    }) {
                        ArticleRow(article: article)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .id(articleListID(for: article)) // Set ID for scroll position tracking
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(colorScheme == .dark ? Color.black : AppColors.background)
            .onAppear {
                #if os(iOS)
                // Update navigation state for iPhone
                if UIDevice.current.userInterfaceIdiom == .phone {
                    selectedCategory = .all
                    appState.lastSelectedCategory = .all
                    appState.activeSubscriptionURL = nil
                }
                #endif
                // Restore scroll position when view appears
                restoreScrollPosition(for: "all_category", using: scrollProxy)
            }
            .onChange(of: appState.selectedArticleId) { newValue in
                guard newValue == nil else { return }
                restoreScrollPosition(for: "all_category", using: scrollProxy)
            }
            .navigationTitle("All Articles")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        // Validate collection briefly before LLM
                        let count = appState.feeds.flatMap { $0.articles }.count
                        print("Validation: All Articles visible count=\(count)")
                        appState.summarizeTodayArticlesGlobally()
                    }) {
                        Label("Summarize Articles", systemImage: "text.append")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                }
            }
        }
    }
    
    var unreadView: some View {
        ScrollViewReader { scrollProxy in
            List {
                Section(header: Text("RSS Articles")) {
                    let unreadArticles = appState.feeds.flatMap { $0.articles }
                        .filter { !$0.isRead }
                        .sorted(by: { $0.publishDate > $1.publishDate })
                    
                    if unreadArticles.isEmpty {
                        Text("No unread articles")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(unreadArticles) { article in
                            Button(action: {
                                // Record that we're in the Unread category before navigating
                                appState.activeSubscriptionURL = nil
                                appState.lastSelectedCategory = .unread
                                
                                // Set article and navigate
                                appState.selectedArticle = article
                                // Save scroll position for "unread" category
                                appState.saveScrollPosition(for: "unread_category", itemID: article.id)
                                appState.markArticleAsRead(article)
                            }) {
                                ArticleRow(article: article)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            .id(articleListID(for: article)) // Set ID for scroll position tracking
                        }
                    }
                }
                
                Section(header: Text("Reddit Posts")) {
                    let unreadPosts = appState.redditFeeds.flatMap { $0.posts }
                        .filter { !$0.isRead }
                        .sorted(by: { $0.publishDate > $1.publishDate })
                    
                    if unreadPosts.isEmpty {
                        Text("No unread posts")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(unreadPosts) { post in
                            Button(action: {
                                // Record that we're in the Unread category before navigating
                                appState.activeSubscriptionURL = nil
                                appState.lastSelectedCategory = .unread
                                
                                // Set post and navigate
                                appState.selectedRedditPost = post
                                // Save scroll position for "unread" category
                                appState.saveScrollPosition(for: "unread_category", itemID: post.id)
                                appState.markRedditPostAsRead(post)
                            }) {
                                RedditPostRow(post: post)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            .id(redditPostListID(for: post)) // Set ID for scroll position tracking
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(colorScheme == .dark ? Color.black : AppColors.background)
            .onAppear {
                // Update the last selected category when this view appears
                appState.lastSelectedCategory = .unread
                selectedCategory = .unread
                
                #if os(iOS)
                // Clear activeSubscriptionURL for iPhone
                if UIDevice.current.userInterfaceIdiom == .phone {
                    appState.activeSubscriptionURL = nil
                }
                #endif
                
                // Restore scroll position when view appears
                restoreScrollPosition(for: "unread_category", using: scrollProxy)
            }
            .onChange(of: appState.selectedArticleId) { newValue in
                guard newValue == nil else { return }
                restoreScrollPosition(for: "unread_category", using: scrollProxy)
            }
            .onChange(of: appState.selectedRedditPostId) { newValue in
                guard newValue == nil else { return }
                restoreScrollPosition(for: "unread_category", using: scrollProxy)
            }
            .navigationTitle("Unread")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    let hasUnreadItems = !(appState.feeds.flatMap { $0.articles }.filter { !$0.isRead }.isEmpty && 
                                          appState.redditFeeds.flatMap { $0.posts }.filter { !$0.isRead }.isEmpty)
                    
                    Button(action: {
                        appState.markAllUnreadAsRead()
                    }) {
                        Label("Mark All as Read", systemImage: "checkmark.circle")
                    }
                    .disabled(!hasUnreadItems)
                }
            }
        }
    }
    
    var favoritesView: some View {
        List {
            Section(header: Text("RSS Articles")) {
                let favoriteArticles = appState.feeds.flatMap { $0.articles }
                    .filter { $0.isFavorite }
                    .sorted(by: { $0.publishDate > $1.publishDate })
                
                if favoriteArticles.isEmpty {
                    Text("No favorite articles")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(favoriteArticles) { article in
                        Button(action: {
                            // Set article and navigate
                            appState.selectedArticle = article
                            if !article.isRead {
                                appState.markArticleAsRead(article)
                            }
                        }) {
                            ArticleRow(article: article)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .swipeActions {
                            Button(role: .destructive) {
                                appState.toggleArticleFavorite(article)
                            } label: {
                                Label("Remove", systemImage: "star.slash")
                            }
                        }
                    }
                }
            }
            
            Section(header: Text("Reddit Posts")) {
                let favoritePosts = appState.redditFeeds.flatMap { $0.posts }
                    .filter { $0.isFavorite }
                    .sorted(by: { $0.publishDate > $1.publishDate })
                
                if favoritePosts.isEmpty {
                    Text("No favorite posts")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(favoritePosts) { post in
                        Button(action: {
                            // Set post and navigate
                            appState.selectedRedditPost = post
                            if !post.isRead {
                                appState.markRedditPostAsRead(post)
                            }
                        }) {
                            RedditPostRow(post: post)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .swipeActions {
                            Button(role: .destructive) {
                                appState.toggleRedditPostFavorite(post)
                            } label: {
                                Label("Remove", systemImage: "star.slash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .onAppear {
            #if os(iOS)
            // Update navigation state for iPhone
            if UIDevice.current.userInterfaceIdiom == .phone {
                selectedCategory = .favorites
                appState.lastSelectedCategory = .favorites
                appState.activeSubscriptionURL = nil
            }
            #endif
        }
        .navigationTitle("Favorites")
    }
    
    // PRE-FILTER data to prevent expensive computations during view updates
    private var filteredTodayArticles: [Article] {
        let calendar = Calendar.current
        return Array(
            appState.feeds.flatMap { $0.articles }
                .filter { calendar.isDateInToday($0.publishDate) }
                .sorted(by: { $0.publishDate > $1.publishDate })
                .prefix(50) // Limit to prevent memory issues
        )
    }

    private var filteredTodayRedditPosts: [RedditPost] {
        let calendar = Calendar.current
        return Array(
            appState.redditFeeds.flatMap { $0.posts }
                .filter { calendar.isDateInToday($0.publishDate) }
                .sorted(by: { $0.publishDate > $1.publishDate })
                .prefix(50) // Limit to prevent memory issues
        )
    }

    var todayView: some View {
        ScrollViewReader { scrollProxy in
            List {
                let todayArticles = filteredTodayArticles
                let todayRedditPosts = filteredTodayRedditPosts

                // Today's Topics Overview Section - Only show if user has actively generated summary
                if appState.isGeneratingTodaySummary {
                    Section(header: Text("Today's Topics Overview")) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Generating summary...")
                                    .foregroundColor(.secondary)
                            }
                            if let info = appState.todaySummaryInfo {
                                Text(info)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } else if appState.todaySummaryResult != nil {
                    // Only show results section if there's an active result from user's action
                    Section(header: Text("Today's Topics Overview")) {
                        VStack(alignment: .leading, spacing: 12) {
                            ArticleGlassySummary(summary: appState.todaySummaryResult!)
                            HStack(spacing: 12) {
                                Button(action: {
                                    if let summary = appState.todaySummaryResult {
                                        copyToClipboard(summary)
                                    }
                                }) {
                                    Label("Copy Summary", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(LiquidGlassButtonStyle())
                                .disabled(appState.todaySummaryResult?.isEmpty ?? true)

                                Button(role: .cancel) {
                                    appState.clearTodaySummary()
                                } label: {
                                    Label("Dismiss", systemImage: "xmark.circle")
                                }
                                .buttonStyle(LiquidGlassButtonStyle())
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } else if appState.todaySummaryError != nil {
                    // Only show error if it resulted from user's action
                    Section(header: Text("Today's Topics Overview")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(appState.todaySummaryError!)
                                .font(.body)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button(role: .cancel) {
                                appState.clearTodaySummary()
                            } label: {
                                Label("Dismiss", systemImage: "xmark.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // Today's RSS articles
                if !todayArticles.isEmpty {
                    Section(header: Text("RSS Articles")) {
                        ForEach(todayArticles) { article in
                            Button(action: {
                                // Record that we're in the Today category before navigating
                                appState.activeSubscriptionURL = nil
                                appState.lastSelectedCategory = .today
                                
                                // Set article and navigate
                                appState.selectedArticle = article
                                // Save scroll position for "today" category
                                appState.saveScrollPosition(for: "today_category", itemID: article.id)
                                if !article.isRead {
                                    appState.markArticleAsRead(article)
                                }
                            }) {
                                ArticleRow(article: article)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            .id(articleListID(for: article)) // Set ID for scroll position tracking
                        }
                    }
                }
                
                // Today's Reddit posts
                
                if !todayRedditPosts.isEmpty {
                    Section(header: Text("Reddit Posts")) {
                        ForEach(todayRedditPosts) { post in
                            Button(action: {
                                // Record that we're in the Today category before navigating
                                appState.activeSubscriptionURL = nil
                                appState.lastSelectedCategory = .today
                                
                                // Set post and navigate
                                appState.selectedRedditPost = post
                                // Save scroll position for "today" category
                                appState.saveScrollPosition(for: "today_category", itemID: post.id)
                                if !post.isRead {
                                    appState.markRedditPostAsRead(post)
                                }
                            }) {
                                RedditPostRow(post: post)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            .id(redditPostListID(for: post)) // Set ID for scroll position tracking
                        }
                    }
                }
                
                if todayArticles.isEmpty && todayRedditPosts.isEmpty {
                    Text("No content from today")
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(colorScheme == .dark ? Color.black : AppColors.background)
            .onAppear {
                // Update the last selected category when this view appears
                if appState.lastSelectedCategory != .today {
                    appState.lastSelectedCategory = .today
                }
                if selectedCategory != .today {
                    selectedCategory = .today
                }

                #if os(iOS)
                // Clear activeSubscriptionURL for iPhone only when needed
                if UIDevice.current.userInterfaceIdiom == .phone,
                   appState.activeSubscriptionURL != nil {
                    appState.activeSubscriptionURL = nil
                }
                #endif

                // Clear any cached today summary state to prevent memory issues
                if appState.isGeneratingTodaySummary ||
                    appState.todaySummaryResult != nil ||
                    appState.todaySummaryError != nil ||
                    appState.todaySummaryInfo != nil {
                    DispatchQueue.main.async {
                        appState.clearTodaySummary()
                    }
                }

                // Restore scroll position when view appears
                restoreScrollPosition(for: "today_category", using: scrollProxy)
            }
            .onChange(of: appState.selectedArticleId) { newValue in
                guard newValue == nil else { return }
                restoreScrollPosition(for: "today_category", using: scrollProxy)
            }
            .onChange(of: appState.selectedRedditPostId) { newValue in
                guard newValue == nil else { return }
                restoreScrollPosition(for: "today_category", using: scrollProxy)
            }
            .navigationTitle("Today")
                            .toolbar {
                                ToolbarItemGroup(placement: .primaryAction) {
                                    Button(action: {
                                        appState.summarizeTodayTopics()
                                    }) {
                                        #if os(iOS)
                                        if UIDevice.current.userInterfaceIdiom == .phone {
                                            Image(systemName: "sparkles")
                                        } else {
                                            Label("Summarize Today's Content", systemImage: "sparkles")
                                        }
                                        #else
                                        Label("Summarize Today's Content", systemImage: "sparkles")
                                        #endif
                                    }
                                    .disabled(appState.isGeneratingTodaySummary)
                                    #if os(macOS)
                                    .help("Summarize today's articles and Reddit posts by subject")
                                    #endif

                                    Button(action: {
                                        appState.markAllUnreadAsRead()
                                    }) {
                                        #if os(iOS)
                                        if UIDevice.current.userInterfaceIdiom == .phone {
                                            Image(systemName: "checkmark.circle")
                                        } else {
                                            Label("Mark All Seen", systemImage: "checkmark.circle")
                                        }
                                        #else
                                        Label("Mark All Seen", systemImage: "checkmark.circle")
                                        #endif
                                    }
                                    .disabled(!(
                                        appState.feeds.contains { feed in
                                            feed.articles.contains { !$0.isRead }
                                        } || appState.redditFeeds.contains { feed in
                                            feed.posts.contains { !$0.isRead }
                                        }
                                    ))
                                    #if os(macOS)
                                    .help("Mark every article and Reddit post as seen")
                                    #endif
                                }
                            }
        }
    }
    
    var redditView: some View {
        VStack {
            RedditSortPicker(selection: $appState.redditSortOption)
                .padding(.horizontal)
                .onChange(of: appState.redditSortOption) { newOption in
                    print("📱 ContentView: Reddit sort option changed to \(newOption.rawValue) for r/\(appState.activeSubscriptionURL ?? "")")
                    // Provide feedback that we're loading
                    appState.isLoading = true
                    DispatchQueue.main.async {
                        // Only refresh the current subreddit feed instead of all feeds
                        appState.refreshRedditFeeds(specificSubreddit: appState.activeSubscriptionURL)
                    }
                }
            
            if let status = appState.aggregatedRedditStatusMessage {
                RedditRateLimitBanner(status: status)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }
            
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(appState.redditFeeds.flatMap { $0.posts }
                            .sorted(by: { $0.publishDate > $1.publishDate })) { post in
                                Button(action: {
                                    // Record that we're in the Reddit category before navigating
                                    appState.activeSubscriptionURL = nil
                                    appState.lastSelectedCategory = .reddit
                                    
                                    // Save scroll position for "reddit" category
                                    appState.saveScrollPosition(for: "reddit_category", itemID: post.id)
                                    // First set the post selection
                                    appState.selectedRedditPost = post
                                    appState.markRedditPostAsRead(post)
                                }) {
                                    RedditPostRow(post: post)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(redditPostListID(for: post)) // Set ID for scroll position tracking
                        }
                }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                }
                .background(colorScheme == .dark ? Color.black : AppColors.redditBackground(for: colorScheme))
                .onAppear {
                    // Update the last selected category when this view appears
                    appState.lastSelectedCategory = .reddit
                    selectedCategory = .reddit
                    
                    #if os(iOS)
                    // Clear activeSubscriptionURL for iPhone
                    if UIDevice.current.userInterfaceIdiom == .phone {
                        appState.activeSubscriptionURL = nil
                    }
                    #endif
                    
                    // Restore scroll position when view appears
                    restoreScrollPosition(for: "reddit_category", using: scrollProxy)
                }
                .onChange(of: appState.selectedRedditPostId) { newValue in
                    guard newValue == nil else { return }
                    restoreScrollPosition(for: "reddit_category", using: scrollProxy)
                }
            }
        }
        .onAppear {
            appState.ensureAllRedditFeedsMatchCurrentSort()
        }
        .navigationTitle("Reddit")
        .background((colorScheme == .dark ? Color.black : AppColors.redditBackground(for: colorScheme)).ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    // Validate collection briefly before LLM
                    let count = appState.redditFeeds.flatMap { $0.posts }.count
                    print("Validation: Reddit posts visible count=\(count)")
                    appState.summarizeAllRedditGlobally(topComments: 10)
                }) {
                    #if os(iOS)
                    if UIDevice.current.userInterfaceIdiom == .phone {
                        Image(systemName: "sparkles")
                    } else {
                        Label("Summarize Reddit", systemImage: "sparkles")
                    }
                    #else
                    Label("Summarize Reddit", systemImage: "sparkles")
                    #endif
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .disabled(appState.aggregatedRedditStatusMessage?.statusCode == 429)
                #if os(macOS)
                .help(appState.aggregatedRedditStatusMessage?.statusCode == 429 ? "Reddit rate limit in effect. Please wait for reset before summarizing." : "Summarize all Reddit posts.")
                #endif
            }
        }
    }
    
    func subscriptionView(for subscription: Subscription) -> some View {
        Group {
            if subscription.type == .rss {
                if let feed = appState.feeds.first(where: { $0.url == subscription.url }) {
                    feedSubscriptionView(feed: feed, subscription: subscription)
                } else {
                    Text("Loading feed...")
                        .navigationTitle(subscription.title)
                }
            } else {
                if let feed = appState.redditFeeds.first(where: { $0.subreddit == subscription.url }) {
                    redditSubscriptionView(feed: feed, subscription: subscription)
                } else {
                    Text("Loading subreddit...")
                        .navigationTitle(subscription.title)
                }
            }
        }
        .overlay(
            Group {
                #if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .phone {
                    VStack {
                        ZStack {
                            // Glass background for navigation bar
                            Color.clear
                                .background(.ultraThinMaterial)
                                .glassEffectCompat(in: Rectangle())
                                .ignoresSafeArea(edges: .horizontal)
                            
                            HStack {
                                Spacer()
                            }
                            .padding()
                        }
                        .frame(height: 60)
                        
                        Spacer()
                    }
                }
                #endif
            }
        )
        .onAppear {
            // Set the active subscription URL when view appears
            appState.activeSubscriptionURL = subscription.url
        }
    }

    @ViewBuilder
    private func feedSubscriptionView(feed: Feed, subscription: Subscription) -> some View {
        ScrollViewReader { scrollProxy in
            feedArticlesList(feed: feed, subscription: subscription, scrollProxy: scrollProxy)
        }
    }

    private func feedArticlesList(feed: Feed, subscription: Subscription, scrollProxy: ScrollViewProxy) -> some View {
        let articles = displayArticles(for: feed)
        let listSpaceName = "subscriptionFeedList-\(subscription.id.uuidString)"
        #if os(iOS)
        let shouldManageSubscriptionScroll = UIDevice.current.userInterfaceIdiom == .phone
        #else
        let shouldManageSubscriptionScroll = false
        #endif

        return List {
            ForEach(articles) { article in
                Button(action: {
                    appState.rememberCurrentSubscription(url: subscription.url)
                    appState.selectedArticle = article
                    appState.lastSelectedCategory = article.isFavorite ? .favorites : .all
                    if !article.isRead {
                        appState.markArticleAsRead(article)
                    }
                }) {
                    ArticleRow(article: article)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .id(articleListID(for: article))
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SubscriptionRowOffsetPreferenceKey.self,
                            value: shouldManageSubscriptionScroll
                                ? [article.id: proxy.frame(in: .named(listSpaceName)).minY]
                                : [:]
                        )
                    }
                )
            }
        }
        .listStyle(.plain)
        .coordinateSpace(name: listSpaceName)
        .scrollContentBackground(.hidden)
        .background(colorScheme == .dark ? Color.black : AppColors.background)
        .navigationTitle(feed.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(UIDevice.current.userInterfaceIdiom == .phone)
        .padding(.top, UIDevice.current.userInterfaceIdiom == .phone ? 60 : 0)
        #endif
        .onPreferenceChange(SubscriptionRowOffsetPreferenceKey.self) { offsets in
            guard shouldManageSubscriptionScroll,
                  !programmaticRestoreInFlightKeys.contains(subscription.url),
                  !offsets.isEmpty else { return }
            if let nearestToTop = offsets.min(by: { abs($0.value) < abs($1.value) })?.key {
                appState.saveScrollPosition(for: subscription.url, itemID: nearestToTop)
            }
        }
        .onAppear {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                appState.activeSubscriptionURL = subscription.url
            }
            #endif
            guard shouldManageSubscriptionScroll else { return }
            restoreScrollPosition(for: subscription.url, using: scrollProxy, animated: false)
        }
        .onChange(of: appState.selectedArticleId) { newValue in
            guard shouldManageSubscriptionScroll, newValue == nil else { return }
            restoreScrollPosition(for: subscription.url, using: scrollProxy, animated: false)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                summarizeFeedButton(feed: feed, subscription: subscription)
                feedScrollToTopButton(scrollProxy: scrollProxy, firstArticleId: articles.first?.id)
                feedMarkAllButton(feed: feed, subscription: subscription)
            }
        }
    }

    @ViewBuilder
    private func redditSubscriptionView(feed: RedditFeed, subscription: Subscription) -> some View {
        ScrollViewReader { scrollProxy in
            #if os(iOS)
            let shouldManageSubscriptionScroll = UIDevice.current.userInterfaceIdiom == .phone
            #else
            let shouldManageSubscriptionScroll = false
            #endif
            VStack(spacing: 0) {
                // Sort control
                RedditSortPicker(selection: $appState.redditSortOption)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .onChange(of: appState.redditSortOption) { newOption in
                        print("📱 ContentView: Reddit sort option changed to \(newOption.rawValue) for r/\(subscription.url)")
                        appState.isLoading = true
                        DispatchQueue.main.async {
                            appState.refreshRedditFeeds(specificSubreddit: subscription.url)
                        }
                    }

                if let status = appState.redditStatusMessages[subscription.url] {
                    RedditRateLimitBanner(status: status)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
                
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(feed.posts) { post in
                            Button(action: {
                                appState.rememberCurrentSubscription(url: subscription.url)
                                appState.selectedRedditPost = post
                                appState.lastSelectedCategory = .reddit
                                if !post.isRead {
                                    appState.markRedditPostAsRead(post)
                                }
                            }) {
                                RedditPostRow(post: post)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(redditPostListID(for: post))
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: SubscriptionRowOffsetPreferenceKey.self,
                                        value: shouldManageSubscriptionScroll
                                            ? [post.id: proxy.frame(in: .named("subscriptionRedditList-\(subscription.id.uuidString)")).minY]
                                            : [:]
                                    )
                                }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                    #if os(iOS)
                    .padding(.top, UIDevice.current.userInterfaceIdiom == .phone ? 60 : 0)
                    #endif
                }
                .coordinateSpace(name: "subscriptionRedditList-\(subscription.id.uuidString)")
                .background(colorScheme == .dark ? Color.black : AppColors.redditBackground(for: colorScheme))
            }
            .background((colorScheme == .dark ? Color.black : AppColors.redditBackground(for: colorScheme)).ignoresSafeArea())
            .onPreferenceChange(SubscriptionRowOffsetPreferenceKey.self) { offsets in
                guard shouldManageSubscriptionScroll,
                      !programmaticRestoreInFlightKeys.contains(subscription.url),
                      !offsets.isEmpty else { return }
                if let nearestToTop = offsets.min(by: { abs($0.value) < abs($1.value) })?.key {
                    appState.saveScrollPosition(for: subscription.url, itemID: nearestToTop)
                }
            }
            .onAppear {
                #if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .phone {
                    appState.activeSubscriptionURL = subscription.url
                }
                #endif
                guard shouldManageSubscriptionScroll else { return }
                restoreScrollPosition(for: subscription.url, using: scrollProxy, animated: false)
            }
            .onChange(of: appState.selectedRedditPostId) { newValue in
                guard shouldManageSubscriptionScroll, newValue == nil else { return }
                restoreScrollPosition(for: subscription.url, using: scrollProxy, animated: false)
            }
            .navigationTitle("r/\(feed.subreddit)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(UIDevice.current.userInterfaceIdiom == .phone)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    summarizeRedditButton(feed: feed, subscription: subscription)
                    redditScrollToTopButton(scrollProxy: scrollProxy, firstPostId: feed.posts.first?.id, subscription: subscription)
                    redditMarkAllButton(feed: feed, subscription: subscription)
                }
            }
            .overlay {
                if showRedditSummaryScopePicker && redditSummaryScopeSubreddit == subscription.url {
                    redditSummaryScopePickerOverlay(feed: feed, subscription: subscription)
                }
            }
        }
        .onAppear {
            appState.ensureRedditFeedMatchesCurrentSort(for: subscription.url)
        }
    }

    private func displayArticles(for feed: Feed) -> [Article] {
        if feed.url.contains("9to5mac.com") {
            return feed.articles.sorted { first, second in
                let delta = abs(first.publishDate.timeIntervalSince(second.publishDate))
                if delta < 60 {
                    return first.id > second.id
                }
                return first.publishDate > second.publishDate
            }
        }
        return feed.articles
    }

    // MARK: - Toolbar Helpers

    @ViewBuilder
    private func summarizeFeedButton(feed: Feed, subscription: Subscription) -> some View {
        Button(action: {
            let count = feed.articles.count
            print("Validation: Feed \(subscription.title) articles count=\(count)")
            appState.summarizeFeedArticlesGlobally(feedURL: subscription.url)
        }) {
            Image(systemName: "sparkles")
        }
        .accessibilityLabel("Summarize Articles")
        #if os(macOS)
        .help("Summarize this feed's articles")
        #endif
    }

    @ViewBuilder
    private func feedScrollToTopButton(scrollProxy: ScrollViewProxy, firstArticleId: Article.ID?) -> some View {
        Button(action: {
            guard let target = firstArticleId else { return }
            withAnimation(.easeInOut) {
                scrollProxy.scrollTo(target, anchor: .top)
            }
        }) {
            Image(systemName: "arrow.up.circle")
        }
        .disabled(firstArticleId == nil)
        .accessibilityLabel("Scroll to first article")
        #if os(macOS)
        .help("Scroll to the first article")
        #endif
    }

    @ViewBuilder
    private func feedMarkAllButton(feed: Feed, subscription: Subscription) -> some View {
        let hasUnread = feed.articles.contains { !$0.isRead }
        Button(action: {
            appState.markAllArticlesAsRead(for: subscription.url)
            appState.navigateToNextSubscription(after: subscription.url)
        }) {
            Image(systemName: "checkmark.circle")
        }
        .disabled(!hasUnread)
        .accessibilityLabel("Mark all articles as read")
        #if os(macOS)
        .help("Mark all articles in this feed as read")
        #endif
    }

    @ViewBuilder
    private func summarizeRedditButton(feed: RedditFeed, subscription: Subscription) -> some View {
        Button {
            redditSummaryScopeSubreddit = subscription.url
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                showRedditSummaryScopePicker = true
            }
        } label: {
            Image(systemName: "text.bubble")
        }
        .accessibilityLabel("Summarize subreddit posts")
        #if os(macOS)
        .help("Summarize this subreddit")
        #endif
    }

    private func dismissRedditSummaryScopePicker() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            showRedditSummaryScopePicker = false
            redditSummaryScopeSubreddit = nil
        }
    }

    @ViewBuilder
    private func redditSummaryScopePickerOverlay(feed: RedditFeed, subscription: Subscription) -> some View {
        ZStack {
            Color.black
                .opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { dismissRedditSummaryScopePicker() }

            VStack(spacing: 12) {
                Text("Summary Overview")
                    .font(.headline)

                let unreadCount = feed.posts.filter { !$0.isRead }.count
                Text("New: \(unreadCount) unread • Ranked: up to 50 posts")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Button("New") {
                            dismissRedditSummaryScopePicker()
                            appState.summarizeSubredditPostsGlobally(subreddit: subscription.url, topComments: 10)
                        }
                        .buttonStyle(LiquidGlassButtonStyle())

                        Button("Hot") {
                            dismissRedditSummaryScopePicker()
                            appState.summarizeSubredditHotPostsGlobally(subreddit: subscription.url, topComments: 10)
                        }
                        .buttonStyle(LiquidGlassButtonStyle())
                    }

                    HStack(spacing: 12) {
                        Button("Top Day") {
                            dismissRedditSummaryScopePicker()
                            appState.summarizeSubredditTopDayPostsGlobally(subreddit: subscription.url, topComments: 10)
                        }
                        .buttonStyle(LiquidGlassButtonStyle())

                        Button("Top Week") {
                            dismissRedditSummaryScopePicker()
                            appState.summarizeSubredditTopWeekPostsGlobally(subreddit: subscription.url, topComments: 10)
                        }
                        .buttonStyle(LiquidGlassButtonStyle())
                    }
                }

                Button("Cancel") {
                    dismissRedditSummaryScopePicker()
                }
                .buttonStyle(LiquidGlassButtonStyle(isTranslucent: true))
            }
            .padding(16)
            .glassEffectCompat(in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
    }

    @ViewBuilder
    private func redditScrollToTopButton(scrollProxy: ScrollViewProxy, firstPostId: RedditPost.ID?, subscription: Subscription) -> some View {
        Button(action: {
            guard let target = firstPostId else { return }
            withAnimation(.easeInOut) {
                scrollProxy.scrollTo(target, anchor: .top)
            }
            appState.isLoading = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                appState.refreshRedditFeeds(specificSubreddit: subscription.url)
            }
        }) {
            Image(systemName: "arrow.up.circle")
        }
        .disabled(firstPostId == nil)
        .accessibilityLabel("Scroll to first post")
        #if os(macOS)
        .help("Scroll to the first post")
        #endif
    }

    @ViewBuilder
    private func redditMarkAllButton(feed: RedditFeed, subscription: Subscription) -> some View {
        let hasUnreadPosts = feed.posts.contains { !$0.isRead }
        Button(action: {
            appState.markAllRedditPostsAsRead(for: subscription.url)
            appState.navigateToNextSubscription(after: subscription.url)
        }) {
            Image(systemName: "checkmark.circle")
        }
        .disabled(!hasUnreadPosts)
        .accessibilityLabel("Mark all Reddit posts as read")
        #if os(macOS)
        .help("Mark all posts in this subreddit as read")
        #endif
    }

        // MARK: - Detail View
    var detailView: some View {
        Group {
            if appState.selectedArticle != nil {
                ArticleDetailView(isReadingChromeHidden: $isArticleReadingChromeHidden)
            } else if let selectedRedditPost = appState.selectedRedditPost {
                RedditDetailView()
                    .id("post-\(selectedRedditPost.id)") // Force view recreation with unique ID
            } else {
                // Instead of showing "Select an article or post to read", 
                // restore the appropriate view based on navigation state
                if let activeURL = appState.activeSubscriptionURL {
                    // If we have an active subscription URL, navigate to it
                    let subscription = appState.subscriptions.first(where: { $0.url == activeURL })
                    if let subscription = subscription {
                        subscriptionView(for: subscription)
                    } else {
                        // Fallback to category if subscription not found
                        categoryFeedList
                    }
                } else {
                    // Otherwise show the category feed list based on lastSelectedCategory
                    categoryFeedList
                }
            }
        }
    }
    
    // MARK: - Helper Functions
    private func restoreScrollPosition(for key: String, using proxy: ScrollViewProxy, animated: Bool = true) {
        guard let rawID = appState.getSavedScrollPosition(for: key) else { return }
        let scrollAction: () -> Void
        let isSidebarKey = key == "sidebar_subscriptions"
        let centerAnchorKeys: Set<String> = ["all_category", "unread_category", "today_category", "reddit_category"]
        let shouldUseTopAnchor = isSidebarKey || !centerAnchorKeys.contains(key)
        programmaticRestoreInFlightKeys.insert(key)
        if isSidebarKey {
            isSidebarProgrammaticRestoreInFlight = true
        }
        if let uuid = UUID(uuidString: rawID) {
            if shouldUseTopAnchor {
                scrollAction = { proxy.scrollTo(uuid, anchor: .top) }
            } else {
                scrollAction = { proxy.scrollTo(uuid, anchor: .center) }
            }
        } else {
            if shouldUseTopAnchor {
                scrollAction = { proxy.scrollTo(rawID, anchor: .top) }
            } else {
                scrollAction = { proxy.scrollTo(rawID, anchor: .center) }
            }
        }
        DispatchQueue.main.async {
            if animated {
                withAnimation {
                    scrollAction()
                }
            } else {
                scrollAction()
            }

            guard isSidebarKey else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isSidebarProgrammaticRestoreInFlight = false
                programmaticRestoreInFlightKeys.remove(key)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            programmaticRestoreInFlightKeys.remove(key)
        }
    }

    private func restoreNavigationState() -> some View {
        // Set the selected category to match what's in AppState
        self.selectedCategory = appState.lastSelectedCategory
        
        return Group {
            if let activeURL = appState.activeSubscriptionURL {
                // If we have an active subscription URL, navigate to it
                let subscription = appState.subscriptions.first(where: { $0.url == activeURL })
                if let subscription = subscription {
                    subscriptionView(for: subscription)
                } else {
                    // Fallback to category if subscription not found
                    categoryFeedList
                }
            } else {
                // Otherwise show the category feed list based on lastSelectedCategory
                categoryFeedList
            }
        }
    }
}

// MARK: - Sidebar Helpers
private struct SidebarRowOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SubscriptionRowOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension ContentView {
    @ViewBuilder
    func sidebarList(scrollProxy: ScrollViewProxy?) -> some View {
        #if os(iOS)
        let shouldAutoRestoreSidebarOnSelectionChange = UIDevice.current.userInterfaceIdiom == .phone
        #else
        let shouldAutoRestoreSidebarOnSelectionChange = false
        #endif

        List {
            feedSection()
            subscriptionsSection(scrollProxy: scrollProxy)
            sidebarSettingsSection()
        }
        .listStyle(.plain)
#if os(macOS)
        .background(MacListSelectionClearView())
#endif
        .coordinateSpace(name: "sidebarListSpace")
        .scrollContentBackground(.hidden)
        .frame(minWidth: 200)
        .background(sidebarSurfaceBackground.ignoresSafeArea(edges: .top))
        .transaction { tx in tx.animation = nil }
        .animation(nil, value: appState.subscriptions.count)
        .onPreferenceChange(SidebarRowOffsetPreferenceKey.self) { offsets in
            guard !isSidebarProgrammaticRestoreInFlight, !offsets.isEmpty else { return }
            if let nearestToTop = offsets.min(by: { abs($0.value) < abs($1.value) })?.key {
                appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: nearestToTop)
            }
        }
        .onAppear {
            guard let scrollProxy = scrollProxy else { return }
            restoreScrollPosition(for: "sidebar_subscriptions", using: scrollProxy, animated: false)
        }
        .onChange(of: appState.selectedArticleId) { newValue in
            guard shouldAutoRestoreSidebarOnSelectionChange,
                  newValue == nil,
                  let scrollProxy = scrollProxy else { return }
            restoreScrollPosition(for: "sidebar_subscriptions", using: scrollProxy, animated: false)
        }
        .onChange(of: appState.selectedRedditPostId) { newValue in
            guard shouldAutoRestoreSidebarOnSelectionChange,
                  newValue == nil,
                  let scrollProxy = scrollProxy else { return }
            restoreScrollPosition(for: "sidebar_subscriptions", using: scrollProxy, animated: false)
        }
        .onChange(of: appState.activeSubscriptionURL) { newValue in
            guard shouldAutoRestoreSidebarOnSelectionChange,
                  newValue == nil,
                  let scrollProxy = scrollProxy else { return }
            restoreScrollPosition(for: "sidebar_subscriptions", using: scrollProxy, animated: false)
        }
    }

    @ViewBuilder
    func feedSection() -> some View {
        Section(header:
            sidebarSectionHeader("LIBRARY")
        ) {
            NavigationLink(destination: allView) {
                let unreadAllArticles = appState.unreadAllArticlesCount()

                sidebarMenuRow(
                    title: FeedCategory.all.rawValue,
                    unreadCount: unreadAllArticles,
                    isSelected: isLibraryCategorySelected(.all)
                ) {
                    sidebarSystemIcon(FeedCategory.all.systemImageName, tint: Color(red: 0.64, green: 0.68, blue: 1.0))
                }
            }
            #if os(iOS)
            .simultaneousGesture(
                UIDevice.current.userInterfaceIdiom == .pad ?
                TapGesture().onEnded {
                    selectedCategory = .all
                    appState.lastSelectedCategory = .all
                    appState.activeSubscriptionURL = nil
                } : nil
            )
            #else
            .simultaneousGesture(TapGesture().onEnded {
                DispatchQueue.main.async {
                    selectedCategory = .all
                    appState.lastSelectedCategory = .all
                    appState.activeSubscriptionURL = nil
                }
            })
            #endif
            .buttonStyle(.plain)
            .sidebarSelectionBorder(selectedCategory == .all && appState.activeSubscriptionURL == nil)

            NavigationLink(destination: unreadView) {
                sidebarMenuRow(
                    title: FeedCategory.unread.rawValue,
                    isSelected: isLibraryCategorySelected(.unread)
                ) {
                    sidebarSystemIcon(FeedCategory.unread.systemImageName, tint: Color(red: 0.52, green: 0.65, blue: 1.0))
                }
            }
            #if os(iOS)
            .simultaneousGesture(
                UIDevice.current.userInterfaceIdiom == .pad ?
                TapGesture().onEnded {
                    selectedCategory = .unread
                    appState.lastSelectedCategory = .unread
                    appState.activeSubscriptionURL = nil
                } : nil
            )
            #else
            .simultaneousGesture(TapGesture().onEnded {
                DispatchQueue.main.async {
                    selectedCategory = .unread
                    appState.lastSelectedCategory = .unread
                    appState.activeSubscriptionURL = nil
                }
            })
            #endif
            .buttonStyle(.plain)
            .sidebarSelectionBorder(selectedCategory == .unread && appState.activeSubscriptionURL == nil)

            NavigationLink(destination: favoritesView) {
                sidebarMenuRow(
                    title: FeedCategory.favorites.rawValue,
                    isSelected: isLibraryCategorySelected(.favorites)
                ) {
                    sidebarSystemIcon(FeedCategory.favorites.systemImageName, tint: Color(red: 0.60, green: 0.67, blue: 1.0))
                }
            }
            #if os(iOS)
            .simultaneousGesture(
                UIDevice.current.userInterfaceIdiom == .pad ?
                TapGesture().onEnded {
                    selectedCategory = .favorites
                    appState.lastSelectedCategory = .favorites
                    appState.activeSubscriptionURL = nil
                } : nil
            )
            #else
            .simultaneousGesture(TapGesture().onEnded {
                DispatchQueue.main.async {
                    selectedCategory = .favorites
                    appState.lastSelectedCategory = .favorites
                    appState.activeSubscriptionURL = nil
                }
            })
            #endif
            .buttonStyle(.plain)
            .sidebarSelectionBorder(selectedCategory == .favorites && appState.activeSubscriptionURL == nil)

            NavigationLink(destination: todayView) {
                let todayArticlesCount = filteredTodayArticles.count
                let todayRedditCount = filteredTodayRedditPosts.count
                let totalTodayItems = todayArticlesCount + todayRedditCount

                sidebarMenuRow(
                    title: FeedCategory.today.rawValue,
                    unreadCount: totalTodayItems,
                    isSelected: isLibraryCategorySelected(.today)
                ) {
                    sidebarSystemIcon(FeedCategory.today.systemImageName, tint: Color(red: 0.58, green: 0.65, blue: 1.0))
                }
            }
            #if os(iOS)
            .simultaneousGesture(
                UIDevice.current.userInterfaceIdiom == .pad ?
                TapGesture().onEnded {
                    selectedCategory = .today
                    appState.lastSelectedCategory = .today
                    appState.activeSubscriptionURL = nil
                } : nil
            )
            #else
            .simultaneousGesture(TapGesture().onEnded {
                DispatchQueue.main.async {
                    selectedCategory = .today
                    appState.lastSelectedCategory = .today
                    appState.activeSubscriptionURL = nil
                }
            })
            #endif
            .buttonStyle(.plain)
            .sidebarSelectionBorder(selectedCategory == .today && appState.activeSubscriptionURL == nil)
        }
    }

    @ViewBuilder
    func subscriptionsSection(scrollProxy: ScrollViewProxy?) -> some View {
        Section(header:
            sidebarSectionHeader("SUBSCRIPTIONS")
        ) {
            ForEach(appState.subscriptions) { subscription in
                subscriptionSidebarRow(for: subscription)
                .id(subscription.id)
                .buttonStyle(.plain)
                .sidebarSubscriptionGlass(isSelected: appState.activeSubscriptionURL == subscription.url)
                .onAppear {
                    currentlyVisibleSubscription = subscription.id.uuidString
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SidebarRowOffsetPreferenceKey.self,
                            value: [subscription.id.uuidString: proxy.frame(in: .named("sidebarListSpace")).minY]
                        )
                    }
                )
            }
            .onDelete { indexSet in
                appState.removeSubscription(at: indexSet)
            }

            Button(action: { showAddSubscription = true }) {
                sidebarMenuRow(title: "Add Subscription", accentColor: Color(red: 0.42, green: 0.72, blue: 1.0)) {
                    sidebarSystemIcon("plus.circle.fill", tint: Color(red: 0.42, green: 0.72, blue: 1.0))
                }
            }
            .buttonStyle(.plain)
            .sidebarRowChrome()
        }
    }

    @ViewBuilder
    func sidebarSettingsSection() -> some View {
        Section {
            Button(action: { showSettings = true }) {
                sidebarMenuRow(title: "Settings", accentColor: Color(red: 0.76, green: 0.78, blue: 0.88)) {
                    sidebarSystemIcon("gearshape", tint: Color(red: 0.78, green: 0.80, blue: 0.90))
                }
            }
            .buttonStyle(.plain)
            .sidebarRowChrome()
        }
    }

    @ViewBuilder
    func subscriptionSidebarRow(for subscription: Subscription) -> some View {
        #if os(macOS)
        Button {
            appState.selectedArticle = nil
            appState.selectedRedditPost = nil
            appState.activeSubscriptionURL = subscription.url
            appState.lastSelectedCategory = subscription.type == .reddit ? .reddit : .all
            appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.id.uuidString)
        } label: {
            subscriptionRowContent(for: subscription)
        }
        #else
        Button {
            appState.activeSubscriptionURL = subscription.url
        } label: {
            subscriptionRowContent(for: subscription)
        }
        #endif
    }

    @ViewBuilder
    func subscriptionRowContent(for subscription: Subscription) -> some View {
        let isSelected = appState.activeSubscriptionURL == subscription.url
        let selectionColor: Color = subscription.type == .reddit
            ? Color(red: 1.0, green: 0.28, blue: 0.10)
            : sidebarSelectionAccent
        let unreadCount = appState.unreadCount(for: subscription)

        sidebarMenuRow(
            title: subscription.title,
            unreadCount: unreadCount,
            isSelected: isSelected,
            accentColor: selectionColor
        ) {
            sidebarSubscriptionIcon(for: subscription, isSelected: isSelected)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Reddit Rate Limit Banner
struct RedditRateLimitBanner: View {
    let status: RedditStatusMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "tortoise.fill")
                .font(.title3)
                .foregroundColor(.orange)
                .accessibilityHidden(true)

            Text(status.text)
                .font(.footnote)
                .foregroundColor(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            }
        )
    }
}

// MARK: - Domain Icon View
struct DomainIconView: View {
    let domain: String?
    let size: CGFloat
    
    var body: some View {
        Group {
            if let domain = domain {
                // Create a Google favicon URL
                if let googleFaviconURL = URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=64") {
                    AsyncImage(url: googleFaviconURL) { image in
                        image
                            .resizable()
                            .scaledToFit()
                    } placeholder: {
                        // While loading, show a placeholder with the domain's first letter
                        DomainLetterView(domain: domain, size: size)
                    }
                    .frame(width: size, height: size)
                } else {
                    // If URL creation failed, use a placeholder
                    DomainLetterView(domain: domain, size: size)
                }
            } else {
                // Fallback generic icon
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundColor(.gray)
            }
        }
        .frame(width: size, height: size)
    }
}

// Placeholder view with first letter of domain
struct DomainLetterView: View {
    let domain: String
    let size: CGFloat
    
    var body: some View {
        ZStack {
            Circle()
                .fill(colorForDomain(domain))
            Text(String(domain.prefix(1).uppercased()))
                .font(.system(size: size * 0.6, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
    
    // Deterministic color based on domain name
    private func colorForDomain(_ domain: String) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .red]
        let index = abs(domain.hashValue) % colors.count
        return colors[index]
    }
}

// MARK: - String Extension for Image URL Extraction
extension String {
    func extractImageUrl() -> String {
        // Look for URLs in img tags first
        let imgTagPattern = "<img[^>]+src\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>"
        if let regex = try? NSRegularExpression(pattern: imgTagPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: self, options: [], range: NSRange(self.startIndex..., in: self)),
           let captureRange = Range(match.range(at: 1), in: self) {
            return String(self[captureRange])
        }
        
        // Then try for URLs with common image extensions
        let pattern = "https?://[^\\s]+\\.(jpg|jpeg|png|gif|webp)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: self, options: [], range: NSRange(self.startIndex..., in: self)),
           let range = Range(match.range, in: self) {
            return String(self[range])
        }
        
        // Fallback - just find any URL
        let urlPattern = "https?://[^\\s]+"
        if let regex = try? NSRegularExpression(pattern: urlPattern, options: []),
           let match = regex.firstMatch(in: self, options: [], range: NSRange(self.startIndex..., in: self)),
           let range = Range(match.range, in: self) {
            return String(self[range])
        }
        
        return ""
    }
}

// MARK: - Article Row
struct ArticleRow: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let article: Article
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top row: Domain and date
            HStack {
                // Publication source
                HStack(spacing: 4) {
                    if let url = article.url, let host = url.host {
                        DomainIconView(domain: host, size: 14)
                    }
                    
                            Text(article.feedTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                // Date
                Text(formatDate(article.publishDate))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            // Article title with clean typography
            Text(article.title)
                .font(.system(size: 17, weight: .semibold))
                // Use primary color that adapts to color scheme
                .foregroundColor(.primary)
                .lineLimit(3)
                .padding(.bottom, 2)
            
            // Content layout - horizontal on larger screens
            HStack(alignment: .top, spacing: 12) {
                // Text preview
                if !article.content.isEmpty {
                    Text(cleanContentPreview(article.content))
                        .font(.system(size: 14))
                        // Use secondary color that adapts to color scheme
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // Image if available
                if let imageURL = article.imageURL {
                    AsyncImage(url: imageURL, transaction: Transaction(animation: .none)) { phase in
                        ZStack {
                            Rectangle()
                                .fill(AppColors.systemGray5)

                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            case .failure:
                                Image(systemName: "photo")
                                    .foregroundColor(.secondary)
                            case .empty:
                                ProgressView()
                            @unknown default:
                                EmptyView()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            
            // Status indicators
            HStack(spacing: 12) {
                // Replace "New" badge with "Seen" badge
                if article.isRead { // Check if IS read
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle") // Checkmark icon
                            .font(.system(size: 10))
                        Text("Seen") // "Seen" text
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2)) // Grey background
                    .foregroundColor(Color.gray.opacity(0.9)) // Grey foreground
                    .cornerRadius(4)
                }
                
                if article.summary != nil {
                    Text("Summary")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(Color.green.opacity(0.9))
                        .cornerRadius(4)
                }
                
                if article.isFavorite {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                        Text("Favorite")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.2))
                    .foregroundColor(Color.yellow)
                    .cornerRadius(4)
                }
                
                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(colorScheme == .dark ? Color.black : AppColors.systemGray6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            colorScheme == .dark ? Color.blue : Color.clear,
                            lineWidth: colorScheme == .dark ? 1.2 : 0
                        )
                )
                .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
        )
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }
    
    // Format date in a clean readable format
    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        
        // If today, show time only
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        
        // If within a week, show day name
        let now = Date()
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE"
            return formatter.string(from: date)
        }
        
        // Otherwise show compact date
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
    
    // Clean up content for preview
    private func cleanContentPreview(_ content: String) -> String {
        var cleaned = content
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&[^;]+;", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Limit preview length
        if cleaned.count > 140 {
            cleaned = String(cleaned.prefix(140)) + "..."
        }
        
        return cleaned
    }
}

// MARK: - Reddit Post Row
struct RedditPostRow: View {
    let post: RedditPost
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 12)
                .fill(AppColors.redditCardFill(for: colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            AppColors.redditCardBorder(for: colorScheme),
                            lineWidth: colorScheme == .dark ? 1.2 : 1
                        )
                )
            
            HStack(alignment: .top, spacing: 12) {
                // Left side: content
                VStack(alignment: .leading, spacing: 8) {
                    // Header with Reddit info
                    HStack(alignment: .center) {
                        // Upvote/score/downvote column
                        HStack(spacing: 0) {
                            VStack(spacing: 2) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                                Text("\(post.score)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.gray)
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                            }
                            .frame(width: 24)
                            .padding(.trailing, 8)
                        }
                        
                        // Subreddit info
                        HStack(spacing: 4) {
                            Image("RedditLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                                .foregroundColor(.orange)
                            
                            Text("r/\(post.subreddit)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // Post metadata
                        HStack {
                            Text("u/\(post.author)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.gray)
                            
                            Text(post.publishDate, style: .relative)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    
                    // Post title
                    Text(post.title)
                        .font(.headline)
                        .lineLimit(3)
                        // Revert color change - always use primary color
                        .foregroundColor(.primary)
                    
                    // Post content preview
                    if !post.content.isEmpty {
                        Text(post.content)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    
                    // Comments and other metadata
                    HStack(spacing: 16) {
                        if post.isStickied {
                            HStack(spacing: 4) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 10))
                                Text("Sticky")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(Color.orange.opacity(0.9))
                            .cornerRadius(4)
                        }
                        
                        // Comments
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 12))
                            Text("\(post.commentCount)")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(.secondary)
                        
                        // Add "Seen" badge if read
                        if post.isRead {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 10))
                                Text("Seen")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.2))
                            .foregroundColor(Color.gray.opacity(0.9))
                            .cornerRadius(4)
                        }
                        
                        Spacer()
                    }
                    .padding(.top, 4)
                }
                
                // Right side: image
                if let imageURL = post.bestImageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .empty:
                            ZStack {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.15))
                                ProgressView()
                            }
                            .frame(width: 100, height: 100)
                            .cornerRadius(8)
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 100, height: 100)
                                .clipped()
                                .cornerRadius(8)
                        case .failure:
                            ZStack {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.15))
                                Image(systemName: "photo")
                                    .foregroundColor(.gray)
                            }
                            .frame(width: 100, height: 100)
                            .cornerRadius(8)
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Article Detail View
struct ArticleDetailView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var qaState = ArticleQAState.shared
    @Binding var isReadingChromeHidden: Bool
    @State private var cancellables = Set<AnyCancellable>()
    @State private var articleViewMode: ArticleContentRenderer.ViewMode = .reader
    @Environment(\.colorScheme) var colorScheme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    
    // TTS state variables for Q&A
    @State private var isSynthesizingSpeechQA: Bool = false
    @State private var isSpeakingLocallyQA: Bool = false
    @State private var speechSynthesisErrorQA: String? = nil
    @State private var showSelectionAskAIResponse = false
    @State private var isSelectionAskAIInFlight = false
    @State private var selectionAskAIResponse: String?
    @State private var selectionAskAIError: String?
    @State private var selectionAskAITask: Task<Void, Never>?
    @State private var articleChromeRestoreWorkItem: DispatchWorkItem?
#if os(iOS)
    @State private var audioPlayerQA: AVAudioPlayer?
    @State private var localSpeechSynthQA: AVSpeechSynthesizer?
    @StateObject private var soundDelegateQA = SoundDelegate()
    // Holds queued audio for fast-start split
    @State private var nextAudioChunkQA: Data? = nil
    @State private var ttsCanceledQA: Bool = false
    @State private var localTTSTaskQA: Task<Void, Never>? = nil
#elseif os(macOS)
    @State private var audioPlayerQA: NSSound?
    @State private var localSpeechSynthQA: NSSpeechSynthesizer?
    @StateObject private var soundDelegateQA = SoundDelegate()
    // Holds queued audio for fast-start split
    @State private var nextAudioChunkQA: Data? = nil
    @State private var ttsCanceledQA: Bool = false
    #endif
    
#if os(iOS)
// iPhone-only: bottom action bar visibility controller.
@State private var showActionBar: Bool = true
@State private var actionBarRestoreWorkItem: DispatchWorkItem?
@State private var lastActionBarScrollOffset: CGFloat?
#endif
    @State private var articleReaderScrollToTopTrigger: Int = 0
    private let articleTopAnchor = "articleDetailTopAnchor"
    private let articleQAAnchor = "articleDetailQAAnchor"
    #if os(iOS)
    private let articleScrollCoordinateSpace = "articleDetailScrollCoordinateSpace"
    private let actionBarRestoreDelay: TimeInterval = 0.75
    #endif

    init(isReadingChromeHidden: Binding<Bool> = .constant(false)) {
        self._isReadingChromeHidden = isReadingChromeHidden
    }

    private var detailBackground: Color {
        colorScheme == .dark ? Color(red: 0.02, green: 0.025, blue: 0.04) : AppColors.background
    }

    private var articleDetailTitleSize: CGFloat {
        #if os(iOS)
        return horizontalSizeClass == .compact ? 28 : 34
        #else
        return 34
        #endif
    }

    private var usesCompactTitleSizing: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    private var usesPhoneArticleLayout: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    private var shouldShowArticleLanguageChip: Bool {
        #if os(iOS)
        return !usesPhoneArticleLayout
        #else
        return false
        #endif
    }

    private var articleHeaderHorizontalPadding: CGFloat {
        #if os(iOS)
        return usesPhoneArticleLayout ? 18 : 32
        #else
        return 32
        #endif
    }

    private var articleContentHorizontalPadding: CGFloat {
        #if os(iOS)
        return usesPhoneArticleLayout ? 12 : 28
        #else
        return 28
        #endif
    }

    private var articleCardOuterHorizontalPadding: CGFloat {
        #if os(iOS)
        return usesPhoneArticleLayout ? 0 : 16
        #else
        return 16
        #endif
    }

    private var articleTopSpacerHeight: CGFloat {
        #if os(iOS)
        return usesPhoneArticleLayout ? 56 : 104
        #else
        return 58
        #endif
    }

    private var articleReaderChromeHeightEstimate: CGFloat {
        #if os(iOS)
        return usesPhoneArticleLayout ? 176 : 244
        #else
        return isReadingChromeHidden ? 24 : 186
        #endif
    }

    private var shouldShowExplicitWebAIControls: Bool {
        appState.settings.selectedSummaryProvider != .webAI
    }
    
    /// Process content to remove the first image if a header image was already displayed.
    private var contentToRender: String {
        guard let article = appState.selectedArticle else { return "" }

        // DON'T remove images - just return the original content
        // The removeFirstImage function seems to be corrupting the HTML
        return article.content
    }
    
    var body: some View {
        if let article = appState.selectedArticle {
            selectedArticleView(article: article)
        } else {
            emptyArticlePlaceholder
        }
    }

    private func selectedArticleView(article: Article) -> some View {
        ScrollViewReader { proxy in
            articleScene(article: article, proxy: proxy)
                .onAppear {
                    configureArticleDetailAppearance(for: article)
                }
                .onChange(of: article.id) { _ in
                    resetArticleReadingChrome()
                }
                .onDisappear {
                    resetArticleReadingChrome()
                }
        }
    }

    private func articleScene(article: Article, proxy: ScrollViewProxy) -> some View {
        ZStack {
            articleDetailBackground
                .ignoresSafeArea()

            articleScrollContent(article: article)
                #if os(iOS)
                .edgesIgnoringSafeArea(.all)
                #endif
                #if !os(iOS)
                .enhancedSwipeBack {
                    appState.navigateBack()
                }
                #endif

            VStack {
                Spacer()
            }
        }
        #if os(iOS)
        .safeAreaInset(edge: .bottom) {
            if usesPhoneArticleLayout && !isReadingChromeHidden {
                phoneBottomActionBar(proxy: proxy)
                    .transition(.articleChromeContinuity(edge: .bottom))
                    .zIndex(10_000)
            }
        }
        #endif
        .overlay { phoneFloatingStatusOverlay() }
        .overlay(alignment: .bottomTrailing) {
            if !isReadingChromeHidden {
                scrollToTopOverlay(proxy: proxy)
                    .transition(.articleChromeContinuity(edge: .bottom))
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                revealArticleReadingChrome()
            }
        )
        .onChange(of: qaState.showQAInterface) { isVisible in
            scrollToArticleQAIfNeeded(isVisible: isVisible, proxy: proxy)
        }
        .sheet(isPresented: $showSelectionAskAIResponse) {
            AskAIResponseSheet(
                isLoading: isSelectionAskAIInFlight,
                response: selectionAskAIResponse,
                errorMessage: selectionAskAIError,
                onClose: { showSelectionAskAIResponse = false },
                onCopy: copySelectionAskAIResponse
            )
        }
    }

    private var articleDetailBackground: some View {
        ZStack {
            detailBackground
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.05 : 0.35),
                    Color.clear,
                    Color.black.opacity(colorScheme == .dark ? 0.18 : 0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func scrollToArticleQAIfNeeded(isVisible: Bool, proxy: ScrollViewProxy) {
        guard isVisible else { return }

        DispatchQueue.main.async {
            withAnimation(.easeInOut) {
                proxy.scrollTo(articleQAAnchor, anchor: UnitPoint(x: 0.5, y: 0.35))
            }
        }
    }

    private func scrollArticleToTop(proxy: ScrollViewProxy) {
        print("⬆️ Article bottom toolbar scroll-to-top tapped")
        #if os(iOS)
        if usesPhoneArticleLayout {
            articleReaderScrollToTopTrigger += 1
            NotificationCenter.default.post(name: .articleReaderScrollToTopRequested, object: nil)
            ArticleScrollToTopController.shared.scrollToTop()
            resetPhoneActionBarVisibility()
        }
        #endif

        withAnimation(.easeInOut) {
            proxy.scrollTo(articleTopAnchor, anchor: .top)
        }
    }

    private func noteArticleTextScrollActivity() {
        articleChromeRestoreWorkItem?.cancel()

        if !isReadingChromeHidden {
            isReadingChromeHidden = true
        }

        let restoreWorkItem = DispatchWorkItem {
            withAnimation(articleChromeContinuityAnimation) {
                isReadingChromeHidden = false
            }
        }
        articleChromeRestoreWorkItem = restoreWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: restoreWorkItem)
    }

    private func revealArticleReadingChrome() {
        guard isReadingChromeHidden else { return }

        articleChromeRestoreWorkItem?.cancel()
        articleChromeRestoreWorkItem = nil

        withAnimation(articleChromeContinuityAnimation) {
            isReadingChromeHidden = false
        }
    }

    private func resetArticleReadingChrome() {
        articleChromeRestoreWorkItem?.cancel()
        articleChromeRestoreWorkItem = nil
        isReadingChromeHidden = false
        #if os(iOS)
        resetPhoneActionBarVisibility()
        #endif
    }

    #if os(iOS)
    private func handlePhoneArticleScrollOffsetChange(_ offset: CGFloat) {
        guard usesPhoneArticleLayout else { return }

        guard let previousOffset = lastActionBarScrollOffset else {
            lastActionBarScrollOffset = offset
            return
        }

        guard abs(offset - previousOffset) > 0.5 else { return }
        lastActionBarScrollOffset = offset
        notePhoneActionBarScrollActivity()
    }

    private func notePhoneActionBarScrollActivity() {
        guard usesPhoneArticleLayout else { return }

        actionBarRestoreWorkItem?.cancel()

        if showActionBar {
            withAnimation(.easeOut(duration: 0.12)) {
                showActionBar = false
            }
        }

        let restoreWorkItem = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.2)) {
                showActionBar = true
            }
        }

        actionBarRestoreWorkItem = restoreWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + actionBarRestoreDelay, execute: restoreWorkItem)
    }

    private func resetPhoneActionBarVisibility() {
        actionBarRestoreWorkItem?.cancel()
        actionBarRestoreWorkItem = nil
        lastActionBarScrollOffset = nil
        showActionBar = true
    }

    private var phoneArticleScrollOffsetReader: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: ArticleDetailScrollOffsetPreferenceKey.self,
                value: geometry.frame(in: .named(articleScrollCoordinateSpace)).minY
            )
        }
    }
    #else
    private func notePhoneActionBarScrollActivity() {}
    #endif

    private var emptyArticlePlaceholder: some View {
        Text("Select an article to read")
            .font(.title)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func scrollToTopOverlay(proxy: ScrollViewProxy) -> some View {
        #if os(iOS)
        if !usesPhoneArticleLayout {
            Button(action: {
                withAnimation(.easeInOut) {
                    proxy.scrollTo(articleTopAnchor, anchor: .top)
                }
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2.weight(.semibold))
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .padding(.trailing, 24)
            .padding(.bottom, 24)
        }
        #else
        EmptyView()
        #endif
    }

    private func configureArticleDetailAppearance(for article: Article) {
        resetArticleReadingChrome()
        articleViewMode = .reader
        if appState.selectedArticleId != article.id || appState.selectedArticle?.id != article.id {
            appState.setSelectedArticle(article)
        }

        qaState.resetState()
        print("📱 ArticleDetailView: Reset Q&A state for article: \(article.title)")

        soundDelegateQA.onPlaybackFinished = { [self] in
            DispatchQueue.main.async {
                if let next = self.nextAudioChunkQA {
                    self.nextAudioChunkQA = nil
                    self.playAudioQA(data: next)
                } else {
                    self.isSynthesizingSpeechQA = false
                }
            }
        }

        soundDelegateQA.onSpeechFinished = { [self] in
            DispatchQueue.main.async {
                self.isSpeakingLocallyQA = false
            }
        }
    }

    private func articleScrollContent(article: Article) -> some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: usesPhoneArticleLayout ? 1 : 0)
                        .id(articleTopAnchor)
                        #if os(iOS)
                        .background(phoneArticleScrollOffsetReader)
                        #endif

                    Spacer()
                        .frame(height: isReadingChromeHidden ? 0 : articleTopSpacerHeight)

                    if !isReadingChromeHidden {
                        VStack(alignment: .leading, spacing: 0) {
                            articleHeader(article: article)
                            articleSummaryAndQASection(article: article)
                        }
                        .transition(.articleChromeContinuity(edge: .top))
                    }

                    ArticleContentRenderer(
                        content: contentToRender,
                        baseURL: article.url,
                        prefersCompactTitleSizing: usesCompactTitleSizing,
                        viewMode: $articleViewMode,
                        isReadingChromeHidden: isReadingChromeHidden,
                        readerViewportHeight: articleReaderViewportHeight(containerHeight: geometry.size.height),
                        scrollToTopTrigger: articleReaderScrollToTopTrigger,
                        onPhoneScrollActivity: notePhoneActionBarScrollActivity,
                        onArticleTextScroll: noteArticleTextScrollActivity,
                        onArticleTextTap: revealArticleReadingChrome
                    )
                    .padding(.top, articleViewMode == .reader ? 4 : 8)
                    .padding(.horizontal, articleContentHorizontalPadding)

                    Spacer()
                        .frame(height: articleViewMode == .reader ? 12 : 40)

                    if !isReadingChromeHidden && articleViewMode == .rss {
                        articleFooter(article: article)
                            .transition(.articleChromeContinuity(edge: .bottom))
                    }
                }
                .animation(articleChromeContinuityAnimation, value: isReadingChromeHidden)
                #if os(iOS)
                .padding(.horizontal, articleCardOuterHorizontalPadding)
                .padding(.bottom, 20)
                #else
                .modifier(ArticleCardGlassModifier())
                .padding(.horizontal, articleCardOuterHorizontalPadding)
                .padding(.bottom, 16)
                #endif
            }
            #if os(iOS)
            .coordinateSpace(name: articleScrollCoordinateSpace)
            .background(ArticleOuterScrollViewResolver().frame(width: 0, height: 0))
            .onPreferenceChange(ArticleDetailScrollOffsetPreferenceKey.self, perform: handlePhoneArticleScrollOffsetChange)
            #endif
        }
    }

    private func articleReaderViewportHeight(containerHeight: CGFloat) -> CGFloat? {
        guard articleViewMode == .reader else { return nil }
        return max(360, containerHeight - articleReaderChromeHeightEstimate)
    }

    private func articleHeader(article: Article) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            articleMetadataCard(article: article)
            if articleViewMode == .rss {
                Text(article.title)
                    .font(.system(size: articleDetailTitleSize, weight: .bold))
                    .lineSpacing(0)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 36)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(articlePanelBackground(cornerRadius: 24))
            }
        }
        .padding(.horizontal, articleHeaderHorizontalPadding)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private func articleMetadataCard(article: Article) -> some View {
        VStack(alignment: .leading, spacing: usesPhoneArticleLayout ? 0 : 10) {
            if usesPhoneArticleLayout {
                HStack(alignment: .top, spacing: 0) {
                    articleMetadataCompactItem(
                        icon: "clock.fill",
                        title: article.feedTitle,
                        subtitle: "Source",
                        accent: .blue
                    )

                    articleMetadataCompactItem(
                        icon: "person",
                        title: normalizedArticleAuthor(article),
                        subtitle: "Author",
                        accent: .secondary
                    )

                    articleMetadataCompactItem(
                        icon: "calendar",
                        title: formattedDate(article.publishDate),
                        subtitle: "Published",
                        accent: .secondary
                    )
                }
            } else {
                HStack(spacing: 0) {
                    articleMetadataItem(
                        icon: "clock.fill",
                        title: article.feedTitle,
                        subtitle: "Source",
                        accent: .blue
                    )

                    articleMetadataDivider()

                    articleMetadataItem(
                        icon: "person",
                        title: normalizedArticleAuthor(article),
                        subtitle: "Author",
                        accent: .secondary
                    )

                    articleMetadataDivider()

                    articleMetadataItem(
                        icon: "calendar",
                        title: formattedDate(article.publishDate),
                        subtitle: "Published",
                        accent: .secondary
                    )
                }
            }

            if shouldShowArticleLanguageChip {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.caption.weight(.semibold))
                    Text("English")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(articleSoftFill, in: Capsule())
            }
        }
        .padding(.horizontal, usesPhoneArticleLayout ? 16 : 20)
        .padding(.vertical, usesPhoneArticleLayout ? 14 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(articlePanelBackground(cornerRadius: 18))
    }

    private func articleMetadataCompactItem(icon: String, title: String, subtitle: String, accent: Color) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 36, height: 36)
                .background(articleSoftFill, in: Circle())

            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func articleMetadataItem(icon: String, title: String, subtitle: String, accent: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(articleSoftFill, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func articleMetadataDivider() -> some View {
        Rectangle()
            .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.24))
            .frame(width: 1, height: 38)
            .padding(.horizontal, 16)
    }

    private func normalizedArticleAuthor(_ article: Article) -> String {
        let trimmed = article.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    private func articlePanelBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(articlePanelFill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.35), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 10, x: 0, y: 6)
    }

    private var articlePanelFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.095) : Color.white.opacity(0.72)
    }

    private var articleSoftFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }

    private func articleSummaryAndQASection(article: Article) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            summarySection(article: article)
            qaSection(article: article)
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func summarySection(article: Article) -> some View {
        if appState.isLoading && article.summary == nil {
            VStack(spacing: 16) {
                HStack {
                    Text("Summary")
                        .font(.headline)
                    Spacer()
                }
                let streamText = appState.mlxStreamingText
                if (appState.settings.selectedSummaryProvider == .appleLocal || appState.settings.selectedSummaryProvider == .mlxLocal || appState.settings.selectedSummaryProvider == .coreAIMLXLocal) && !streamText.isEmpty {
                    ScrollView {
                        Text(streamText)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .frame(maxHeight: 200)
                    .background(AppColors.systemGray6)
                    .cornerRadius(10)
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Summarizing article...")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(AppColors.systemGray6)
                    .cornerRadius(10)
                }
            }
            .padding(.bottom, 16)
        } else if appState.isWaitingForAppleIntelligence && article.summary == nil {
            VStack(spacing: 16) {
                HStack {
                    Text("Summary")
                        .font(.headline)
                    Spacer()
                }
                VStack(spacing: 8) {
                    ProgressView()
                    Text(appState.appleIntelligenceWaitProgress)
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(AppColors.systemGray6)
                .cornerRadius(10)
            }
            .padding(.bottom, 16)
        } else if let summary = article.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Summary")
                        .font(.headline)
                    Spacer()
                }
                ArticleGlassySummary(
                    summary: summary,
                    onAskAI: { selectedText in
                        handleAskAISelection(selectedText: selectedText, context: summary)
                    },
                    onAskAIWeb: { selectedText in
                        handleAskAIWebSelection(selectedText: selectedText, context: summary)
                    }
                )
                HStack(spacing: 12) {
                    Button(action: {
                        copyToClipboard(summary)
                    }) {
                        Label("Copy Summary", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    .disabled(summary.isEmpty)
                }
                .padding(.top, 5)
            }
            .padding(.bottom, 16)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func qaSection(article: Article) -> some View {
        if qaState.showQAInterface {
            VStack(alignment: .leading, spacing: 18) {
                qaSectionHeader(article: article)
                qaPromptField(article: article)
                    .id(articleQAAnchor)
                qaAnswerContent()
                if !qaAnswerUnavailable {
                    qaUtilityButtons()
                }
                qaStatusIndicators()
            }
            .padding(24)
            .background(qaCardBackground)
            .padding(.bottom, 16)
        }
    }

    private func qaSectionHeader(article: Article) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.blue.opacity(0.92),
                                Color.blue.opacity(0.46)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.blue.opacity(0.36), radius: 12, x: 0, y: 0)

                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text("Ask a question about this article")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Get quick answers based on the article's content.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if shouldShowExplicitWebAIControls {
                    qaHeaderActionButton(
                        systemName: "globe",
                        accessibilityLabel: appState.settings.selectedWebAIProvider.displayName,
                        isDisabled: qaState.questionText.isEmpty || qaState.isProcessingQuestion
                    ) {
                        askWebQuestion(article: article)
                    }
                }

                qaHeaderActionButton(systemName: "xmark", accessibilityLabel: "Cancel") {
                    qaState.showQAInterface = false
                    qaState.questionText = ""
                    qaState.answerText = "Ask a question about this article..."
                    print("📱 ArticleDetailView: Q&A interface canceled by user")
                }
            }
        }
    }

    private func qaPromptField(article: Article) -> some View {
        HStack(spacing: 12) {
            qaInputField(article: article)

            Button(action: {
                if !qaState.questionText.isEmpty {
                    askQuestion(article: article)
                }
            }) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.blue))
                    .shadow(color: Color.blue.opacity(0.45), radius: 10, x: 0, y: 0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ask")
            .disabled(qaState.questionText.isEmpty || qaState.isProcessingQuestion)
            .opacity(qaState.questionText.isEmpty || qaState.isProcessingQuestion ? 0.45 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.blue.opacity(0.88), lineWidth: 1.2)
        )
        .shadow(color: Color.blue.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 10, x: 0, y: 0)
    }

    private func qaInputField(article: Article) -> some View {
        TextField("Type your question...", text: $qaState.questionText)
            .textFieldStyle(PlainTextFieldStyle())
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(.primary)
            .submitLabel(.send)
            .disabled(qaState.isProcessingQuestion)
            .onSubmit {
                if !qaState.questionText.isEmpty && !qaState.isProcessingQuestion {
                    askQuestion(article: article)
                }
            }
            .onAppear {
                print("📱 ArticleDetailView: Q&A interface appeared")
            }
    }

    private func qaHeaderActionButton(
        systemName: String,
        accessibilityLabel: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isDisabled ? Color.secondary : Color.blue)
                .frame(width: 40, height: 34)
                .background(
                    Capsule(style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.035))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.blue.opacity(isDisabled ? 0.16 : 0.32), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }

    private var qaCardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(articlePanelFill)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.blue.opacity(colorScheme == .dark ? 0.28 : 0.24), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 12, x: 0, y: 8)
    }

    private func qaActionRow(article: Article) -> some View {
        HStack {
            Button(action: {
                if !qaState.questionText.isEmpty {
                    askQuestion(article: article)
                }
            }) {
                Image(systemName: "questionmark.circle")
                    .font(.subheadline)
            }
            .accessibilityLabel("Ask")
            .buttonStyle(LiquidGlassButtonStyle())
            .disabled(qaState.questionText.isEmpty || qaState.isProcessingQuestion)

            if shouldShowExplicitWebAIControls {
                Button(action: {
                    askWebQuestion(article: article)
                }) {
                    Image(systemName: "globe")
                        .font(.subheadline)
                }
                .accessibilityLabel(appState.settings.selectedWebAIProvider.displayName)
                .buttonStyle(LiquidGlassButtonStyle())
                .disabled(qaState.questionText.isEmpty || qaState.isProcessingQuestion)
            }

            Button(action: {
                qaState.showQAInterface = false
                qaState.questionText = ""
                qaState.answerText = "Ask a question about this article..."
                print("📱 ArticleDetailView: Q&A interface canceled by user")
            }) {
                Image(systemName: "xmark.circle")
                    .font(.subheadline)
            }
            .accessibilityLabel("Cancel")
            .buttonStyle(LiquidGlassButtonStyle())

            Spacer()
        }
    }

    @ViewBuilder
    private func qaAnswerContent() -> some View {
        if qaState.isProcessingQuestion {
            let qaStreamText = appState.mlxStreamingText
            if (appState.settings.selectedSummaryProvider == .appleLocal || appState.settings.selectedSummaryProvider == .mlxLocal || appState.settings.selectedSummaryProvider == .coreAIMLXLocal) && !qaStreamText.isEmpty {
                Text(qaStreamText)
                    .font(.body)
                    .foregroundColor(.primary)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Processing your question...")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(AppColors.systemGray6)
                .cornerRadius(8)
            }
        } else if appState.isWaitingForArticleQA {
            VStack(spacing: 8) {
                ProgressView()
                Text(appState.articleQAWaitProgress)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(AppColors.systemGray6)
            .cornerRadius(8)
        } else if !qaAnswerUnavailable {
            SelectableText(qaState.answerText)
            .onAskAI { selectedText in
                handleAskAISelection(selectedText: selectedText, context: qaState.answerText)
            }
            .onAskAIWeb { selectedText in
                handleAskAIWebSelection(selectedText: selectedText, context: qaState.answerText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func qaUtilityButtons() -> some View {
        HStack(spacing: 12) {
            Button {
                speakAnswerQA(qaState.answerText)
            } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.subheadline)
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .ttsActiveGlow(isSynthesizingSpeechQA, color: .blue)
            .help("Read aloud (Cloud)")
            .disabled(isSynthesizingSpeechQA || isSpeakingLocallyQA || qaAnswerUnavailable)

            Button {
                stopQASpeech()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.subheadline)
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .help("Stop speech")

            Button {
                speakAnswerLocallyQA(qaState.answerText)
            } label: {
                Image(systemName: "speaker.wave.2.circle")
                    .font(.subheadline)
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .ttsActiveGlow(isSpeakingLocallyQA, color: .green)
            .help("Read aloud (Local)")
            .disabled(isSynthesizingSpeechQA || qaAnswerUnavailable)

            Button(action: {
                copyToClipboard(qaState.answerText)
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.subheadline)
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .help("Copy answer")
            .disabled(qaAnswerUnavailable)
        }
        .padding(.top, 5)
    }

    @ViewBuilder
    private func qaStatusIndicators() -> some View {
        if isSynthesizingSpeechQA {
            HStack {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.trailing, 5)
                Text("Reading answer...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)
        } else if isSpeakingLocallyQA {
            HStack {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.trailing, 5)
                Text("Reading with local TTS...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)
        }

        if let error = speechSynthesisErrorQA {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
                .padding(.top, 4)
        }

        let qaProvider = appState.settings.selectedSummaryProvider
        if (qaProvider == .mlxLocal || qaProvider == .coreAIMLXLocal || qaProvider == .appleLocal || qaProvider == .applePCCGateway || qaProvider == .summarizeDaemon),
           !appState.mlxLastQAThroughput.isEmpty,
           !qaState.isProcessingQuestion,
           !qaAnswerUnavailable {
            HStack(spacing: 4) {
                Image(systemName: "cpu").font(.caption2)
                Text(appState.mlxLastQAThroughput).font(.caption2).monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }

    private var qaAnswerUnavailable: Bool {
        qaState.answerText.isEmpty || qaState.answerText == "Ask a question about this article..."
    }

    private func handleAskAISelection(selectedText: String, context: String) {
        guard let article = appState.selectedArticle else { return }
        askAIFromArticleSelection(selectedText, article: article, action: .standard)
    }

    private func handleAskAIWebSelection(selectedText: String, context: String) {
        guard let article = appState.selectedArticle else { return }
        askAIFromArticleSelection(selectedText, article: article, action: .web)
    }

    private func askAIFromArticleSelection(_ selection: String, article: Article, action: AskAISelectionAction) {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        selectionAskAITask?.cancel()
        isSelectionAskAIInFlight = true
        selectionAskAIResponse = nil
        selectionAskAIError = nil
        showSelectionAskAIResponse = true

        let prompt = appState.articleQAPrompt(
            article: article,
            question: "What is said about \(trimmed)?"
        )

        selectionAskAITask = Task {
            let answer = await withCheckedContinuation { continuation in
                switch action {
                case .standard:
                    appState.askQuestionAboutSelection(prompt: prompt) { response in
                        continuation.resume(returning: response)
                    }
                case .web:
                    appState.askWebQuestionAboutSelection(prompt: prompt, title: "Article Ask AI Web") { response in
                        continuation.resume(returning: response)
                    }
                }
            }

            await MainActor.run {
                self.selectionAskAIResponse = formatAskAIResponseForDisplay(answer)
                self.isSelectionAskAIInFlight = false
            }
        }
    }

    private func copySelectionAskAIResponse() {
        guard let selectionAskAIResponse, !selectionAskAIResponse.isEmpty else { return }
        copyToClipboard(selectionAskAIResponse)
    }

    @ViewBuilder
    private func articleFooter(article: Article) -> some View {
        if let url = article.url {
            Divider()
                .padding(.horizontal, articleHeaderHorizontalPadding)

            Link(destination: url) {
                HStack {
                    Text("Read full article on")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)

                    if let host = url.host {
                        Text(host)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.blue)
                    }

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12))
                        .foregroundColor(.blue)
                }
                .padding(.horizontal, articleHeaderHorizontalPadding)
                .padding(.vertical, 16)
            }
        }
    }

    @ViewBuilder
    private func phoneBottomActionBar(proxy: ScrollViewProxy) -> some View {
        #if os(iOS)
        if usesPhoneArticleLayout {
            HStack(spacing: 16) {
                Button {
                    scrollArticleToTop(proxy: proxy)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 52)
                }
                .buttonStyle(.plain)
                .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.46), lineWidth: 1)
                )
                .accessibilityLabel("Scroll to top")

                Button(action: {
                    if let article = appState.selectedArticle {
                        appState.requestSummary(for: article)
                    }
                }) {
                    Image(systemName: "text.quote")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(LiquidGlassButtonStyle())

                if let article = appState.selectedArticle {
                    Button(action: {
                        appState.toggleArticleFavorite(article)
                    }) {
                        Image(systemName: article.isFavorite ? "star.fill" : "star")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(article.isFavorite ? .yellow : .primary)
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                }

                Button(action: {
                    ArticleQAState.shared.toggleQAInterface()
                }) {
                    Image(systemName: "questionmark.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(LiquidGlassButtonStyle())

                if let url = appState.selectedArticle?.url {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 6)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity)
            .opacity(showActionBar ? 1 : 0)
            .allowsHitTesting(showActionBar)
            .accessibilityHidden(!showActionBar)
            .animation(.easeInOut(duration: 0.2), value: showActionBar)
        }
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder
    private func phoneFloatingStatusOverlay() -> some View {
        #if os(iOS)
        if usesPhoneArticleLayout {
            ZStack {
                if let article = appState.selectedArticle,
                   appState.isSummarizingArticle(article),
                   article.summary == nil {
                    floatingStatusPill(text: "Summarizing article...")
                }

                if qaState.isProcessingQuestion {
                    floatingStatusPill(text: "Processing question...")
                }
            }
        }
        #else
        EmptyView()
        #endif
    }

    private func floatingStatusPill(text: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Text(text)
                    .foregroundColor(.white)
                    .font(.subheadline)
            }
            .padding()
            .background(.black.opacity(0.8))
            .cornerRadius(10)
            .padding(.bottom, 100)
        }
    }
    
    // MARK: - Private Methods
    
    private func askQuestion(article: Article) {
        guard !qaState.questionText.isEmpty else { return }

        print("📱 ArticleDetailView: Asking question: \"\(qaState.questionText)\"")

        // Set loading state
        qaState.isProcessingQuestion = true
        qaState.answerText = "Thinking..."

        // Use AppState's askQuestionAboutArticle which handles both Gemini and Apple Intelligence
        appState.askQuestionAboutArticle(article: article, question: qaState.questionText) { answer in
            self.qaState.answerText = formatAskAIResponseForDisplay(answer)
            self.qaState.isProcessingQuestion = false
            // Update previous question for next time
            self.qaState.previousQuestionText = self.qaState.questionText
            print("📱 ArticleDetailView: Got answer, updating UI")
        }
    }

    private func askWebQuestion(article: Article) {
        guard !qaState.questionText.isEmpty else { return }

        print("📱 ArticleDetailView: Asking WebAI question: \"\(qaState.questionText)\"")

        qaState.isProcessingQuestion = true
        qaState.answerText = "Thinking..."

        appState.askWebQuestionAboutArticle(article: article, question: qaState.questionText) { answer in
            self.qaState.answerText = formatAskAIResponseForDisplay(answer)
            self.qaState.isProcessingQuestion = false
            self.qaState.previousQuestionText = self.qaState.questionText
            print("📱 ArticleDetailView: Got WebAI answer, updating UI")
        }
    }
    
    // Format date in a clean readable format
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "'Today at' h:mm a"
        } else if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }
        
        return formatter.string(from: date)
    }

    private func markdownSummaryText(_ string: String) -> Text {
        if #available(macOS 12.0, iOS 15.0, *) {
            if let attributed = try? AttributedString(
                markdown: string,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            ) {
                return Text(attributed)
            }
        }
        return Text(string)
    }

    // Extract image caption if available
    private func extractImageCaption(_ article: Article) -> String? {
        if let imageURL = article.imageURL?.absoluteString {
            // Try to extract caption from title if it contains image reference
            if article.title.contains("Image:") || article.title.contains("image:") {
                let components = article.title.components(separatedBy: "|")
                if components.count > 1 {
                    return components.last?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            
            // Default caption with attribution
            return "\(article.feedTitle) | Image: \(article.url?.host ?? "Source")"
        }
        return nil
    }

    /// Helper to remove the first <img> tag from HTML using SwiftSoup.
    private func removeFirstImage(fromHTML html: String) -> String {
        // DEBUG: Let's see what's happening
        print("🔍 REMOVE FIRST IMAGE - Input HTML contains images: \(html.contains("<img"))")
        
        do {
            let document: Document = try SwiftSoup.parseBodyFragment(html)
                let allImages = try document.select("img")
            print("🔍 SwiftSoup found \(allImages.count) images")
            
            if let firstImg = try document.select("img").first() {
                try firstImg.remove()
                print("🔍 Removed first image")
            }
            
            let result = try document.body()?.html() ?? html
            print("🔍 REMOVE FIRST IMAGE - Output HTML contains images: \(result.contains("<img"))")
            return result
        } catch {
            print("SwiftSoup error removing first image: \(error)")
            return html // Return original HTML in case of error
        }
    }
    
    // MARK: - TTS Methods for Q&A
    
    private func speakAnswerQA(_ text: String) {
        // Reset cancellation flag
        ttsCanceledQA = false
        guard !text.isEmpty && text != "Ask a question about this article..." else {
            speechSynthesisErrorQA = "No answer available to read."
            return
        }
        
        // Stop any currently playing sounds before starting a new one
        #if os(iOS)
        audioPlayerQA?.stop()
        audioPlayerQA = nil
        // Also stop any local speech if playing
        localSpeechSynthQA?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayerQA?.stop()
        audioPlayerQA = nil
        // Also stop any local speech if playing
        localSpeechSynthQA?.stopSpeaking()
        #endif
        
        isSynthesizingSpeechQA = true
        isSpeakingLocallyQA = false
        speechSynthesisErrorQA = nil
        
        Task {
            await appState.summaryService.synthesizeSpeechFastStartSplit(
                text: text,
                onFirstChunk: { data in
                    DispatchQueue.main.async {
                        if !self.ttsCanceledQA { self.playAudioQA(data: data) }
                    }
                },
                onRemainingReady: { data in
                    DispatchQueue.main.async {
                        if self.ttsCanceledQA { return }
                        if let player = self.audioPlayerQA, player.isPlaying {
                            self.nextAudioChunkQA = data
                        } else {
                            self.playAudioQA(data: data)
                        }
                    }
                },
                onComplete: {
                    // handled by delegate chain
                },
                onError: { error in
                    DispatchQueue.main.async {
                        self.speechSynthesisErrorQA = "Speech synthesis failed: \(error.localizedDescription)"
                        self.isSynthesizingSpeechQA = false
                        self.nextAudioChunkQA = nil
                    }
                }
            )
        }
    }
    
    private func stopQASpeech() {
        ttsCanceledQA = true
        #if os(iOS)
        stopAnyKokoroPlaybackNow()
        localTTSTaskQA?.cancel()
        localTTSTaskQA = nil
        KokoroTTSService.shared.cancelPlayback()
        audioPlayerQA?.stop()
        audioPlayerQA = nil
        localSpeechSynthQA?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayerQA?.stop()
        audioPlayerQA = nil
        localSpeechSynthQA?.stopSpeaking()
        #endif
        nextAudioChunkQA = nil
        isSynthesizingSpeechQA = false
        isSpeakingLocallyQA = false
    }

    private func playAudioQA(data: Data) {
        #if os(iOS)
        // Stop any existing playback
        audioPlayerQA?.stop()
        
        // Detect format and handle accordingly
        let audioData: Data
        if isMP3Data(data) || isAACData(data) {
            // OpenAI returns MP3 or AAC directly
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        do {
            audioPlayerQA = try AVAudioPlayer(data: audioData)
            if let player = audioPlayerQA {
                player.prepareToPlay()
                player.delegate = soundDelegateQA
                if player.play() {
                    // isSynthesizingSpeechQA remains true until playback finishes or fails
                } else {
                    speechSynthesisErrorQA = "Failed to start audio playback."
                    isSynthesizingSpeechQA = false // Playback failed to start
                }
            }
        } catch {
            speechSynthesisErrorQA = "Failed to initialize audio player: \(error.localizedDescription)"
            isSynthesizingSpeechQA = false // Player initialization failed
        }
        #elseif os(macOS)
        // Stop any existing playback
        audioPlayerQA?.stop()
        
        // Detect format and handle accordingly
        let audioData: Data
        if isMP3Data(data) || isAACData(data) {
            // OpenAI returns MP3 or AAC directly
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        audioPlayerQA = NSSound(data: audioData)
        if let player = audioPlayerQA {
            player.delegate = soundDelegateQA
            if player.play() {
                // isSynthesizingSpeechQA remains true until playback finishes or fails
            } else {
                speechSynthesisErrorQA = "Failed to start audio playback."
                isSynthesizingSpeechQA = false // Playback failed to start
            }
        } else {
            speechSynthesisErrorQA = "Failed to initialize audio player with data."
            isSynthesizingSpeechQA = false // Player initialization failed
        }
        #endif
    }
    
    
    private func speakAnswerLocallyQA(_ text: String) {
        #if os(iOS)
        // Toggle off if already speaking
        if isSpeakingLocallyQA {
            stopAnyKokoroPlaybackNow()
            localTTSTaskQA?.cancel()
            localTTSTaskQA = nil
            KokoroTTSService.shared.cancelPlayback()
            localSpeechSynthQA?.stopSpeaking(at: .immediate)
            isSpeakingLocallyQA = false
            return
        }
        
        guard !text.isEmpty && text != "Ask a question about this article..." else {
            speechSynthesisErrorQA = "No answer available to read."
            return
        }
        
        // Stop any other audio playing
        audioPlayerQA?.stop()
        localSpeechSynthQA?.stopSpeaking(at: .immediate)
        
        // Configure audio session for high-quality speech (stays active while locked)
        ensureBackgroundTTSReady()

        let localEngine = appState.summaryService.getLocalTTSEngine()
        if localEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                speechSynthesisErrorQA = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            isSpeakingLocallyQA = true
            isSynthesizingSpeechQA = false
            speechSynthesisErrorQA = nil
            let allowCaching = appState.summaryService.isKokoroPrecacheEnabled()
            startKokoroPlayback(
                text: text,
                voice: appState.summaryService.getKokoroVoice(),
                speed: appState.summaryService.getKokoroSpeed(),
                allowCaching: allowCaching,
                precacheEnabled: allowCaching,
                setAudioPlayer: { [self] player in audioPlayerQA = player },
                soundDelegate: soundDelegateQA,
                taskStore: &localTTSTaskQA,
                onCompleted: {
                    self.isSpeakingLocallyQA = false
                    self.localTTSTaskQA = nil
                },
                onError: { message in
                    self.speechSynthesisErrorQA = message
                    self.isSpeakingLocallyQA = false
                }
            )
            return
        }

        // Check if running on Mac as iPad app - use Shortcuts instead
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // Toggle off if already speaking (can't really stop shortcuts)
            if isSpeakingLocallyQA {
                ShortcutsTTS.shared.stopSpeaking()
                isSpeakingLocallyQA = false
                return
            }

            // Start speaking via Shortcuts
            isSpeakingLocallyQA = true
            isSynthesizingSpeechQA = false

            let success = ShortcutsTTS.shared.speakText(text) {
                // Completion handler - called when speech ends (estimated)
                DispatchQueue.main.async {
                    self.isSpeakingLocallyQA = false
                }
            }

            if !success {
                isSpeakingLocallyQA = false
                speechSynthesisErrorQA = "Failed to start Shortcuts TTS"
            }

            return
        }
        
        // Initialize speech synthesizer
        if localSpeechSynthQA == nil {
            localSpeechSynthQA = AVSpeechSynthesizer()
            localSpeechSynthQA?.delegate = soundDelegateQA
        }
        
        let utterance = AVSpeechUtterance(string: text)
        // Optimize speech parameters for quality
        utterance.rate = 0.52  // Slightly slower than default (0.5) for better clarity
        utterance.pitchMultiplier = 1.0  // Natural pitch
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.0
        utterance.postUtteranceDelay = 0.0

        // iOS-on-Mac has TERRIBLE TTS support - trying to find ANY decent voice
        
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        print("🔊 [LocalTTS] ========================================")
        print("🔊 [LocalTTS] DEBUGGING: ALL AVAILABLE VOICES:")
        
        // Log ALL voices grouped by type to understand what we have
        let ttsbundleVoices = allVoices.filter { $0.identifier.contains("com.apple.ttsbundle") }
        let speechVoices = allVoices.filter { $0.identifier.contains("com.apple.speech") }
        let voiceVoices = allVoices.filter { $0.identifier.contains("com.apple.voice") }
        let eloquenceVoices = allVoices.filter { $0.identifier.contains("com.apple.eloquence") }
        let otherVoices = allVoices.filter { voice in
            !voice.identifier.contains("com.apple.ttsbundle") &&
            !voice.identifier.contains("com.apple.speech") &&
            !voice.identifier.contains("com.apple.voice") &&
            !voice.identifier.contains("com.apple.eloquence")
        }
        
        print("🔊 [LocalTTS] TTSBundle voices (\(ttsbundleVoices.count)):")
        for v in ttsbundleVoices {
            print("🔊 [LocalTTS]   - \(v.name) [\(v.identifier)] quality=\(v.quality.rawValue) lang=\(v.language)")
        }
        
        print("🔊 [LocalTTS] Speech voices (\(speechVoices.count)):")
        for v in speechVoices {
            print("🔊 [LocalTTS]   - \(v.name) [\(v.identifier)] quality=\(v.quality.rawValue) lang=\(v.language)")
        }
        
        print("🔊 [LocalTTS] Voice voices (\(voiceVoices.count)) - THESE DON'T WORK:")
        for v in voiceVoices.prefix(3) {
            print("🔊 [LocalTTS]   - \(v.name) [\(v.identifier)] quality=\(v.quality.rawValue)")
        }
        
        print("🔊 [LocalTTS] Eloquence voices (\(eloquenceVoices.count)):")
        for v in eloquenceVoices.prefix(3) {
            print("🔊 [LocalTTS]   - \(v.name) [\(v.identifier)] quality=\(v.quality.rawValue)")
        }
        
        print("🔊 [LocalTTS] Other voices (\(otherVoices.count)):")
        for v in otherVoices {
            print("🔊 [LocalTTS]   - \(v.name) [\(v.identifier)] quality=\(v.quality.rawValue)")
        }
        
        print("🔊 [LocalTTS] ========================================")
        
        // Simple voice selection: Check for user's saved choice, then premium, then enhanced, then default
        var selectedVoice: AVSpeechSynthesisVoice?
        
        // First check if user has selected a specific voice in settings
        if let savedVoiceID = UserDefaults.standard.string(forKey: "LocalTTS.iOSOnMac.SelectedVoiceID"),
           !savedVoiceID.isEmpty,
           let savedVoice = AVSpeechSynthesisVoice(identifier: savedVoiceID) {
            // On Mac, skip com.apple.voice identifiers as they don't work
            if ProcessInfo.processInfo.isiOSAppOnMac && savedVoice.identifier.contains("com.apple.voice") {
                print("🔊 [LocalTTS Q&A] Skipping com.apple.voice on Mac")
            } else {
                selectedVoice = savedVoice
                let qualityStr = savedVoice.quality == .premium ? "PREMIUM" : 
                                savedVoice.quality == .enhanced ? "Enhanced" : "Default"
                print("🔊 [LocalTTS Q&A] Using saved voice: \(savedVoice.name) [\(qualityStr)]")
                print("🔊 [LocalTTS Q&A] Voice ID: \(savedVoice.identifier)")
            }
        } else {
            print("🔊 [LocalTTS Q&A] No saved voice found, will auto-select")
        }
        
        // If no saved voice, find the best available voice automatically
        if selectedVoice == nil {
            let currentLang = AVSpeechSynthesisVoice.currentLanguageCode()
            let allVoices = AVSpeechSynthesisVoice.speechVoices()
            
            // Filter for current language voices (and exclude com.apple.voice on Mac)
            let availableVoices: [AVSpeechSynthesisVoice]
            if ProcessInfo.processInfo.isiOSAppOnMac {
                availableVoices = allVoices.filter { 
                    $0.language == currentLang && !$0.identifier.contains("com.apple.voice")
                }
            } else {
                availableVoices = allVoices.filter { $0.language == currentLang }
            }
            
            // Try to find premium voices first (quality == .premium)
            let premiumVoices = availableVoices.filter { $0.quality == .premium }
            if let premium = premiumVoices.first {
                selectedVoice = premium
                print("🔊 [LocalTTS] Using PREMIUM voice: \(premium.name)")
            }
            
            // If no premium, try enhanced voices (quality == .enhanced)
            if selectedVoice == nil {
                let enhancedVoices = availableVoices.filter { $0.quality == .enhanced }
                if let enhanced = enhancedVoices.first {
                    selectedVoice = enhanced
                    print("🔊 [LocalTTS] Using Enhanced voice: \(enhanced.name)")
                }
            }
            
            // Fall back to default voice for the language
            if selectedVoice == nil {
                selectedVoice = AVSpeechSynthesisVoice(language: currentLang)
                if let v = selectedVoice {
                    print("🔊 [LocalTTS] Using default voice: \(v.name)")
                }
            }
        }
        
        // FALLBACK: If no voice selected yet, try ttsbundle voices (for iOS-on-Mac compatibility)
        if selectedVoice == nil && !ttsbundleVoices.isEmpty {
            print("🔊 [LocalTTS] No premium/enhanced voice found, trying ttsbundle...")
            // Sort ttsbundle voices by quality
            let sortedBundle = ttsbundleVoices.sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                if a.language == "en-US" && b.language != "en-US" { return true }
                if a.language != "en-US" && b.language == "en-US" { return false }
                return a.name < b.name
            }
            selectedVoice = sortedBundle.first
        }
        // SECOND: Try eloquence (might be better than speech.synthesis)
        else if selectedVoice == nil && !eloquenceVoices.isEmpty && eloquenceVoices.first?.name != "Eddy" {
            print("🔊 [LocalTTS] No ttsbundle, trying eloquence...")
            selectedVoice = eloquenceVoices.first { v in
                v.language == "en-US" && v.name != "Eddy"
            }
            ?? eloquenceVoices.first
        }
        // THIRD: Try speech.synthesis but avoid Albert!
        else if selectedVoice == nil && !speechVoices.isEmpty {
            print("🔊 [LocalTTS] No ttsbundle/eloquence, trying speech.synthesis...")
            selectedVoice = speechVoices.first { v in
                v.language == "en-US" && !v.name.contains("Albert")
            }
            ?? speechVoices.first { v in
                !v.name.contains("Albert")
            }
            ?? speechVoices.first
        }
        // LAST RESORT
        else if selectedVoice == nil {
            print("🔊 [LocalTTS] NO GOOD VOICES FOUND! Using language default...")
            selectedVoice = AVSpeechSynthesisVoice(language: "en-US")
        }

        // Safety: avoid com.apple.voice identifiers ONLY on iOS-on-Mac (they don't work there)
        if ProcessInfo.processInfo.isiOSAppOnMac,
           let v = selectedVoice, 
           v.identifier.contains("com.apple.voice") {
            print("🔊 [LocalTTS] Avoiding com.apple.voice on Mac, finding alternative...")
            let english = allVoices.filter { 
                $0.language.lowercased().hasPrefix("en") && !$0.identifier.contains("com.apple.voice") 
            }
            let sorted = english.sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
            selectedVoice = sorted.first ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.voice = selectedVoice
        if let v = utterance.voice {
            print("🔊 [LocalTTS] ========================================")
            print("🔊 [LocalTTS] SELECTED: \(v.name)")
            print("🔊 [LocalTTS]   ID: \(v.identifier)")
            print("🔊 [LocalTTS]   Quality: \(v.quality.rawValue) (0=default, 1=enhanced, 2=premium)")
            print("🔊 [LocalTTS]   Language: \(v.language)")
            print("🔊 [LocalTTS] ========================================")
            
            if v.name.contains("Albert") {
                print("🔊 [LocalTTS] WARNING: Had to use Albert - no better voices available!")
                print("🔊 [LocalTTS] This is a known iOS-on-Mac limitation.")
            }
        }
        
        isSpeakingLocallyQA = true
        isSynthesizingSpeechQA = false
        if let synth = localSpeechSynthQA {
            DispatchQueue.main.async { synth.speak(utterance) }
        } else {
            isSpeakingLocallyQA = false
            speechSynthesisErrorQA = "Failed to initialize speech synthesizer."
        }
        #elseif os(macOS)
        // Toggle off if already speaking
        if isSpeakingLocallyQA {
            localSpeechSynthQA?.stopSpeaking()
            isSpeakingLocallyQA = false
            return
        }
        
        guard !text.isEmpty && text != "Ask a question about this article..." else {
            speechSynthesisErrorQA = "No answer available to read."
            return
        }
        
        // Stop all other audio
        audioPlayerQA?.stop()
        
        let synth = NSSpeechSynthesizer()
        let overrideQA = UserDefaults.standard.string(forKey: "LocalTTS.Mac.SelectedVoiceID") ?? ""
        if !overrideQA.isEmpty {
            _ = setMacSpeechVoice(synth, identifier: overrideQA)
        } else if let voiceID = preferredMacVoiceIdentifier() {
            _ = setMacSpeechVoice(synth, identifier: voiceID)
        }
        synth.delegate = soundDelegateQA
        
        isSpeakingLocallyQA = true
        isSynthesizingSpeechQA = false
        if !synth.startSpeaking(text) {
            isSpeakingLocallyQA = false
            speechSynthesisErrorQA = "Failed to start local speech synthesis."
        } else {
            localSpeechSynthQA = synth
        }
        #endif
    }
}

// MARK: - Article Content Renderer
// Content element for reader mode
enum ReaderContentElement {
    case text(String)
    case image(String)
}

private struct ArticleReaderPanelModifier: ViewModifier {
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .background(colorScheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.74))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.36), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 10, x: 0, y: 6)
    }
}

private extension View {
    func articleReaderPanel(colorScheme: ColorScheme) -> some View {
        modifier(ArticleReaderPanelModifier(colorScheme: colorScheme))
    }
}

struct ArticleContentRenderer: View {
    let content: String
    let baseURL: URL?
    let prefersCompactTitleSizing: Bool
    @Binding var viewMode: ViewMode
    let isReadingChromeHidden: Bool
    let readerViewportHeight: CGFloat?
    let scrollToTopTrigger: Int
    let onPhoneScrollActivity: () -> Void
    let onArticleTextScroll: () -> Void
    let onArticleTextTap: () -> Void

    enum ViewMode: String, CaseIterable {
        case reader = "Reader"
        case rss = "RSS"
    }

    @State private var contentHeight: CGFloat = 100
    @State private var isLoadingReader: Bool = false
    @State private var readerModeAvailable: Bool = true
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var usesPhoneArticleLayout: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    /// Check if we have a valid article URL to load in reader mode
    private var hasArticleURL: Bool {
        guard let url = baseURL else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isReadingChromeHidden {
                articleModeControl
                    .padding(.bottom, usesPhoneArticleLayout ? 12 : 20)
                .transition(.articleChromeContinuity(edge: .top))
            }

            articleContentPanel
        }
        .animation(articleChromeContinuityAnimation, value: isReadingChromeHidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: content) { _ in
            if viewMode == .rss {
                contentHeight = 100
            }
        }
        .onAppear {
            // If no valid URL, default to RSS mode
            if !hasArticleURL {
                viewMode = .rss
            }
        }
    }

    private var articleModeControl: some View {
        HStack {
            Spacer(minLength: 0)

            HStack(spacing: 0) {
                articleModeButton(.reader, icon: "doc.plaintext")
                    .disabled(!hasArticleURL)
                    .opacity(hasArticleURL ? 1.0 : 0.45)

                articleModeButton(.rss, icon: "dot.radiowaves.left.and.right")
            }
            .padding(4)
            .frame(maxWidth: 420)
            .background(
                Capsule(style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.28), lineWidth: 1)
                    )
            )

            if !usesPhoneArticleLayout {
                Color.clear
                    .frame(width: 28, height: 1)
            }

            Spacer(minLength: 0)
        }
    }

    private func articleModeButton(_ mode: ViewMode, icon: String) -> some View {
        let isActive = viewMode == mode

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewMode = mode
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(mode.rawValue)
                    .font(.system(size: 14, weight: isActive ? .semibold : .medium))
            }
            .foregroundStyle(isActive ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                if isActive {
                    Capsule(style: .continuous)
                        .fill(Color.blue.opacity(0.72))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.blue.opacity(0.95), lineWidth: 1)
                        )
                        .shadow(color: Color.blue.opacity(0.50), radius: 12, x: 0, y: 0)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var articleContentPanel: some View {
        if viewMode == .reader && hasArticleURL {
            ArticleReaderWebView(
                articleURL: baseURL!,
                isLoading: $isLoadingReader,
                readerModeAvailable: $readerModeAvailable,
                useCompactTitleSizing: prefersCompactTitleSizing,
                scrollToTopTrigger: scrollToTopTrigger,
                onScrollActivity: onPhoneScrollActivity
            )
            .frame(maxWidth: .infinity)
            .frame(height: readerViewportHeight ?? (isReadingChromeHidden ? currentPlatformScreenHeight() : currentPlatformScreenHeight() - 200))
            .animation(articleChromeContinuityAnimation, value: isReadingChromeHidden)
        } else {
            HTMLWebView(htmlContent: enhanceHTML(content), baseURL: baseURL, contentHeight: $contentHeight)
                .frame(maxWidth: .infinity)
                .frame(height: max(contentHeight, 200))
                .articleReaderPanel(colorScheme: colorScheme)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in
                            onArticleTextScroll()
                        }
                )
                .simultaneousGesture(
                    TapGesture().onEnded {
                        onArticleTextTap()
                    }
                )
        }
    }

    private func buttonTextColor(isActive: Bool) -> Color {
        if colorScheme == .light {
            return isActive ? Color.black : Color.primary
        } else {
            return isActive ? Color.white : Color.primary
        }
    }
    
    // Enhance HTML with better styling
    private func enhanceHTML(_ html: String) -> String {
        let sanitizedHTML = sanitizeHTMLContent(html)
        let baseHTML = sanitizedHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? html : sanitizedHTML
        
        // Don't process if it's already well-formed HTML with our custom wrapper
        if baseHTML.contains("<html") && baseHTML.contains("<body") && baseHTML.contains("RSSReaderApp-processed") {
            return baseHTML
        }
        
        if sanitizedHTML != html {
            print("🧹 Sanitized HTML: removed suspected advertising blocks.")
        }
        
        var processedHTML = baseHTML
        
        // DEBUG: Log the raw HTML to see what we're working with
        print("🔍 RAW HTML CONTENT (first 500 chars):")
        print(String(baseHTML.prefix(500)))
        print("🔍 Contains <img tags: \(baseHTML.contains("<img"))")
        print("🔍 Contains IMAGE: \(baseHTML.contains("IMAGE:"))")
        print("---")
        
        // Fix common encoding issues
        let replacements: [(String, String)] = [
            ("&acirc;&#128;&#148;", "—"),  // em dash
            ("&acirc;&#128;&#153;", "'"),  // right single quote
            ("&acirc;&#128;&#156;", "\""),  // left double quote
            ("&acirc;&#128;&#157;", "\""),  // right double quote
            ("&acirc;&#128;&#147;", "–"),  // en dash
            ("&acirc;&#128;&#152;", "'"),  // left single quote
            ("&#8217;", "'"),             // apostrophe
            ("&#8220;", "\""),            // open double quote
            ("&#8221;", "\""),            // close double quote
            ("&nbsp;", " "),              // non-breaking space
            ("&amp;", "&"),               // ampersand
            ("&lt;", "<"),                // less than
            ("&gt;", ">")                 // greater than
        ]
        
        for (pattern, replacement) in replacements {
            processedHTML = processedHTML.replacingOccurrences(of: pattern, with: replacement)
        }
        
        // Convert any legacy [IMAGE:url] placeholders to proper <img> tags
        let imageTagPattern = "\\[IMAGE:([^\\]]+)\\]"
        processedHTML = processedHTML.replacingOccurrences(
            of: imageTagPattern,
            with: "<img src=\"$1\" alt=\"Article image\" style=\"max-width:100%;height:auto;display:block;margin:24px auto;\">",
            options: .regularExpression
        )
        
        // Also handle IMAGE:url without brackets
        let noBracketPattern = "IMAGE:(https?://\\S+)"
        processedHTML = processedHTML.replacingOccurrences(
            of: noBracketPattern,
            with: "<img src=\"$1\" alt=\"Article image\" style=\"max-width:100%;height:auto;display:block;margin:24px auto;\">",
            options: .regularExpression
        )
        
        // NO STYLE STRIPPING IN THE ORIGINAL CODE!
        
        // If the content doesn't seem to be HTML, wrap it in paragraph tags
        if !processedHTML.contains("<") {
            processedHTML = "<p>\(processedHTML)</p>"
        }
        
        // DEBUG: Log processed HTML
        print("🔍 PROCESSED HTML (first 500 chars):")
        print(String(processedHTML.prefix(500)))
        print("🔍 After processing - Contains <img tags: \(processedHTML.contains("<img"))")
        print("---")
        
        // Wrap in proper HTML document with viewport and styling
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    font-size: 17px;
                    line-height: 1.65;
                    color: #333;
                    padding: 0px;
                    margin: 0;
                    max-width: none;
                    word-wrap: break-word;
                    overflow-wrap: break-word;
                    background-color: transparent;
                }
                img {
                    max-width: 100%;
                    max-height: 400px;
                    height: auto;
                    display: block;
                    margin: 16px auto;
                    border-radius: 12px;
                    box-shadow: 0 4px 16px rgba(0,0,0,0.08);
                    object-fit: contain;
                    transition: transform 0.2s ease, box-shadow 0.2s ease;
                }
                img:hover {
                    transform: scale(1.02);
                    box-shadow: 0 6px 20px rgba(0,0,0,0.12);
                }
                a {
                    color: #007AFF;
                    text-decoration: none;
                    word-break: break-word;
                }
                a:hover {
                    text-decoration: underline;
                }
                p {
                    margin: 10px 0;
                    text-align: justify;
                    text-justify: inter-word;
                }
                p:first-child {
                    margin-top: 0;
                }
                pre {
                    overflow-x: auto;
                    background: #f8f9fa;
                    padding: 16px;
                    border-radius: 8px;
                    margin: 12px 0;
                    font-size: 14px;
                    border: 1px solid #e9ecef;
                }
                code {
                    background: #f8f9fa;
                    padding: 2px 6px;
                    border-radius: 4px;
                    font-family: 'SF Mono', Monaco, 'Courier New', monospace;
                    font-size: 0.9em;
                    color: #d73a49;
                }
                blockquote {
                    border-left: 4px solid #007AFF;
                    margin: 12px 0;
                    padding: 12px 16px;
                    color: #555;
                    font-style: italic;
                    background: #f8f9fa;
                    border-radius: 0 8px 8px 0;
                }
                h1, h2, h3, h4, h5, h6 {
                    margin: 18px 0 10px 0;
                    font-weight: 600;
                    line-height: 1.3;
                }
                h1 { font-size: 28px; }
                h2 { font-size: 24px; }
                h3 { font-size: 20px; }
                h4 { font-size: 18px; }
                ul, ol {
                    padding-left: 28px;
                    margin: 10px 0;
                }
                li {
                    margin: 4px 0;
                }
                table {
                    border-collapse: collapse;
                    width: 100%;
                    margin: 12px 0;
                    font-size: 15px;
                }
                th, td {
                    border: 1px solid #ddd;
                    padding: 8px 12px;
                    text-align: left;
                }
                th {
                    background-color: #f5f5f5;
                    font-weight: 600;
                }
                hr {
                    border: none;
                    border-top: 1px solid #e0e0e0;
                    margin: 20px 0;
                }
                @media (prefers-color-scheme: dark) {
                    body {
                        color: #e8e8e8;
                        background-color: transparent;
                    }
                    a {
                        color: #5AC8FA;
                    }
                    a:hover {
                        color: #7AD4FF;
                    }
                    pre {
                        background: rgba(255,255,255,0.05);
                        border: 1px solid rgba(255,255,255,0.1);
                    }
                    code {
                        background: rgba(255,255,255,0.08);
                        color: #e8e8e8;
                    }
                    blockquote {
                        border-left-color: #5AC8FA;
                        color: #b8b8b8;
                        background: rgba(90,200,250,0.05);
                        padding: 12px 16px;
                        border-radius: 0 8px 8px 0;
                    }
                    th {
                        background-color: rgba(255,255,255,0.05);
                    }
                    th, td {
                        border-color: rgba(255,255,255,0.1);
                    }
                    hr {
                        border-top-color: rgba(255,255,255,0.1);
                    }
                    img {
                        box-shadow: 0 4px 12px rgba(0,0,0,0.4);
                    }
                }
            </style>
        </head>
        <body class="RSSReaderApp-processed">
            \(processedHTML)
        </body>
        </html>
        """
    }

    private func parseContentForReader(_ html: String) -> [ReaderContentElement] {
        var elements: [ReaderContentElement] = []
        let sanitizedHTML = sanitizeHTMLContent(html)
        var workingHTML = sanitizedHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? html : sanitizedHTML

        let imgPattern = "<img[^>]*src\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>"
        var imageURLs: [String] = []

        if let regex = try? NSRegularExpression(pattern: imgPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: workingHTML, options: [], range: NSRange(workingHTML.startIndex..., in: workingHTML))

            for match in matches.reversed() {
                if let urlRange = Range(match.range(at: 1), in: workingHTML) {
                    let imageURL = String(workingHTML[urlRange])
                    imageURLs.insert(imageURL, at: 0)

                    if let fullRange = Range(match.range, in: workingHTML) {
                        workingHTML.replaceSubrange(fullRange, with: "[[IMAGE_PLACEHOLDER_\(imageURLs.count - 1)]]")
                    }
                }
            }
        }

        let textWithPlaceholders = cleanTextFromHTML(workingHTML)

        let placeholderPattern = "\\[\\[IMAGE_PLACEHOLDER_(\\d+)\\]\\]"
        if let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern, options: []) {
            var lastIndex = textWithPlaceholders.startIndex
            let matches = placeholderRegex.matches(in: textWithPlaceholders, options: [], range: NSRange(textWithPlaceholders.startIndex..., in: textWithPlaceholders))

            for match in matches {
                if let range = Range(match.range, in: textWithPlaceholders),
                   let indexRange = Range(match.range(at: 1), in: textWithPlaceholders),
                   let imageIndex = Int(textWithPlaceholders[indexRange]) {
                    let textBefore = String(textWithPlaceholders[lastIndex..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !textBefore.isEmpty && !isLikelyAdLabel(textBefore) {
                        elements.append(.text(textBefore))
                    }

                    if imageIndex < imageURLs.count {
                        let imageURL = imageURLs[imageIndex]
                        if !isLikelyAdResource(imageURL) {
                            elements.append(.image(imageURL))
                        }
                    }

                    lastIndex = range.upperBound
                }
            }

            let remainingText = String(textWithPlaceholders[lastIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainingText.isEmpty && !isLikelyAdLabel(remainingText) {
                elements.append(.text(remainingText))
            }
        } else {
            if !textWithPlaceholders.isEmpty && !isLikelyAdLabel(textWithPlaceholders) {
                elements.append(.text(textWithPlaceholders))
            }
        }

        if elements.isEmpty {
            let cleanedText = cleanTextFromHTML(workingHTML)
            if !cleanedText.isEmpty && !isLikelyAdLabel(cleanedText) {
                elements.append(.text(cleanedText))
            }
        }

        return elements
    }

    private func sanitizeHTMLContent(_ html: String) -> String {
        guard html.contains("<") else { return html }

        do {
            let treatAsFullDocument = html.contains("<html")
            let document: SwiftSoup.Document = treatAsFullDocument ? try SwiftSoup.parse(html) : try SwiftSoup.parseBodyFragment(html)

            try stripAdElements(in: document)

            if treatAsFullDocument {
                return try document.html()
            } else {
                return try document.body()?.html() ?? ""
            }
        } catch {
            print("⚠️ sanitizeHTMLContent error: \(error)")
            return html
        }
    }

    private func stripAdElements(in document: SwiftSoup.Document) throws {
        try document.select("script, style, iframe, ins, noscript, object, embed, form").remove()

        let attributeSelectors = [
            "[data-ad]",
            "[data-ad-client]",
            "[data-ad-slot]",
            "[data-ad-unit]",
            "[data-ads]",
            "[data-dfp]",
            "[data-google-query-id]",
            "[data-taboola]",
            "[data-outbrain]",
            "[data-ad-name]",
            "[data-ad-type]",
            "[data-advertisement]",
            "[aria-label*=\"Advert\"]",
            "[aria-label*=\"advert\"]",
            "[role=\"advertisement\"]"
        ]

        for selector in attributeSelectors {
            try document.select(selector).remove()
        }

        let elements = try document.select("*")
        for element in elements {
            if try shouldStripElement(element) {
                try element.remove()
            }
        }

        let wrappers = try document.select("div, section, aside")
        for wrapper in wrappers {
            let text = (try? wrapper.text().trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            let mediaElements = try wrapper.select("img, video, picture, iframe, object, canvas")
            let hasMedia = !mediaElements.isEmpty()

            if text.isEmpty && !hasMedia {
                try wrapper.remove()
            }
        }
    }

    private func shouldStripElement(_ element: SwiftSoup.Element) throws -> Bool {
        let tag = element.tagName().lowercased()

        if ["script", "style", "iframe", "ins", "noscript", "object", "embed", "form"].contains(tag) {
            return true
        }

        let adAttributePrefixes = ["data-ad", "data-dfp", "data-gpt", "data-ads", "data-slot", "data-revive", "data-taboola", "data-outbrain", "data-sponsored"]
        for prefix in adAttributePrefixes {
            if element.hasAttr(prefix) {
                return true
            }
        }

        if let role = try? element.attr("role").lowercased(), role == "advertisement" {
            return true
        }

        if let ariaLabel = try? element.attr("aria-label"), isLikelyAdLabel(ariaLabel) {
            return true
        }

        if let classNames = try? element.classNames() {
            for className in classNames {
                if containsAdKeyword(in: className) {
                    return true
                }
            }
        }

        if let idValue = try? element.attr("id"), containsAdKeyword(in: idValue) {
            return true
        }

        if let attributes = element.getAttributes()?.asList() {
            for attribute in attributes {
                let key = attribute.getKey().lowercased()
                let value = attribute.getValue().lowercased()

                if key.hasPrefix("data-") && containsAdKeyword(in: key) {
                    return true
                }

                if containsAdKeyword(in: value) && (key.contains("slot") || key.contains("unit") || key.contains("module") || key.contains("campaign") || key.contains("source")) {
                    return true
                }

            }
        }

        if tag == "img" {
            let src = (try? element.attr("src").lowercased()) ?? ""
            let dataSrc = (try? element.attr("data-src").lowercased()) ?? ""
            let dataLazySrc = (try? element.attr("data-lazy-src").lowercased()) ?? ""
            let alt = (try? element.attr("alt").lowercased()) ?? ""
            let title = (try? element.attr("title").lowercased()) ?? ""

            if isLikelyAdResource(src) || isLikelyAdResource(dataSrc) || isLikelyAdResource(dataLazySrc) || isLikelyAdResource(alt) || isLikelyAdResource(title) {
                return true
            }
        }

        if tag == "a" {
            let href = (try? element.attr("href").lowercased()) ?? ""
            if isLikelyAdResource(href) {
                return true
            }
        }

        if ["p", "span", "div", "section", "aside", "figure", "small", "strong"].contains(tag) {
            let text = (try? element.text().trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            if isLikelyAdLabel(text) {
                return true
            }
        }

        return false
    }

    private func containsAdKeyword(in value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let lower = value.lowercased()

        let tokenKeywords: Set<String> = [
            "ad",
            "ads",
            "adslot",
            "adslots",
            "adunit",
            "adunits",
            "adcontainer",
            "adwrapper",
            "adwrap",
            "adbanner",
            "adleaderboard",
            "adbox",
            "admodule",
            "adplaceholder",
            "adplacement",
            "adchoices",
            "advert",
            "advertisement",
            "advertisements",
            "advertorial",
            "adsense",
            "adsbygoogle",
            "googleads",
            "doubleclick",
            "dfp",
            "gpt",
            "taboola",
            "outbrain",
            "sponsored",
            "sponsor",
            "sponsorship",
            "promo",
            "promoted",
            "promotion",
            "promotions",
            "brandpost",
            "brandstudio",
            "nativead",
            "native-ad",
            "adrail",
            "adbreak",
            "adwidget",
            "prebid",
            "adunitwrapper",
            "mpu"
        ]

        if tokenKeywords.contains(lower) {
            return true
        }

        let delimiters = "-_ .:/"
        let tokens = lower.split { delimiters.contains($0) }
        for tokenSub in tokens {
            let token = String(tokenSub)
            if tokenKeywords.contains(token) {
                return true
            }
        }

        let broadMatches = [
            "sponsor",
            "taboola",
            "outbrain",
            "doubleclick",
            "googlesyndication",
            "googletagservices",
            "googletagmanager",
            "adservice",
            "adsystem",
            "adnxs",
            "adthrive",
            "adform",
            "adfox",
            "adzerk",
            "moatads",
            "criteo",
            "sharethrough",
            "mediavoice",
            "nativead",
            "prebid"
        ]

        if broadMatches.contains(where: { lower.contains($0) }) {
            return true
        }

        if lower.hasPrefix("ad") {
            let suffix = lower.dropFirst(2)
            let adSuffixes = [
                "slot",
                "slots",
                "unit",
                "units",
                "container",
                "wrapper",
                "banner",
                "break",
                "choice",
                "choices",
                "module",
                "widget",
                "tag",
                "link",
                "placeholder"
            ]

            for suffixKeyword in adSuffixes {
                if suffix.hasPrefix(suffixKeyword) {
                    return true
                }
            }
        }

        return false
    }

    private func isLikelyAdResource(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let lower = value.lowercased()

        let hostIndicators = [
            "doubleclick",
            "googlesyndication",
            "googletagservices",
            "googletagmanager",
            "adservice",
            "adsystem",
            "adnxs",
            "adform",
            "adfox",
            "adthrive",
            "adsrvr",
            "moatads",
            "taboola",
            "outbrain",
            "zedo",
            "teads",
            "criteo",
            "adroll",
            "pubmatic",
            "openx",
            "rubiconproject",
            "sharethrough",
            "mediavoice",
            "sascdn",
            "brandstudio",
            "sponsor",
            "sponsored"
        ]

        if hostIndicators.contains(where: { lower.contains($0) }) {
            return true
        }

        let pathIndicators = [
            "/ads/",
            "/ads-",
            "/ad/",
            "/ad-",
            "/advert",
            "/sponsor",
            "/sponsored",
            "/promotions",
            "/promo/",
            "/promo-",
            "/banners",
            "/banner",
            "/affiliate",
            "/affiliates",
            "adunit",
            "adslot",
            "adbanner",
            "/dfp/",
            "/gpt/"
        ]

        if pathIndicators.contains(where: { lower.contains($0) }) {
            return true
        }

        let queryIndicators = [
            "?ad=",
            "&ad=",
            "?ads=",
            "&ads=",
            "adid=",
            "adslot=",
            "adunit=",
            "advertiser=",
            "utm_campaign=sponsored",
            "utm_medium=sponsored",
            "utm_source=sponsored",
            "utm_campaign=promo",
            "utm_source=promo",
            "utm_medium=promo"
        ]

        if queryIndicators.contains(where: { lower.contains($0) }) {
            return true
        }

        return false
    }

    private func isLikelyAdLabel(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return false }

        let exactMatches: Set<String> = [
            "advertisement",
            "advertisements",
            "ad",
            "ads",
            "sponsored",
            "sponsored content",
            "sponsored story",
            "sponsored stories",
            "sponsored post",
            "paid content",
            "paid post",
            "promotion",
            "promoted",
            "promoted content",
            "partner content",
            "partner offer",
            "from our partners",
            "from our partner",
            "from our sponsors",
            "from our sponsor",
            "presented by",
            "commercial break"
        ]

        if exactMatches.contains(normalized) {
            return true
        }

        let prefixMatches = [
            "advertisement:",
            "advertisement -",
            "advertisement —",
            "advertisement –",
            "advertisement •",
            "advertisement |",
            "advertisement (",
            "advertisement continue",
            "advertisement continue reading",
            "advertisement continue reading below",
            "advertisement ·",
            "advertisement →",
            "sponsored:",
            "sponsored by",
            "sponsored —",
            "paid content:",
            "promotion:",
            "promoted by",
            "presented by",
            "partner content:",
            "partner offer:"
        ]

        for prefix in prefixMatches {
            if normalized.hasPrefix(prefix) {
                return true
            }
        }

        return false
    }

    private func cleanTextFromHTML(_ html: String) -> String {
        let pattern = "<[^>]+>"
        let stripped = html.replacingOccurrences(of: pattern, with: "", options: .regularExpression, range: nil)

        let decoded = stripped
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&rsquo;", with: "'")
            .replacingOccurrences(of: "&lsquo;", with: "'")
            .replacingOccurrences(of: "&rdquo;", with: "\"")
            .replacingOccurrences(of: "&ldquo;", with: "\"")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&hellip;", with: "...")
            .replacingOccurrences(of: "&#8217;", with: "'")
            .replacingOccurrences(of: "&#8220;", with: "\"")
            .replacingOccurrences(of: "&#8221;", with: "\"")

        let lines = decoded.components(separatedBy: .newlines)
        let cleanedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return cleanedLines.joined(separator: "\n\n")
    }
}

// MARK: - Article Reader WebView (Readability.js-based)
// WebView that loads the article URL and applies Readability.js for clean content extraction

#if os(macOS)
struct ArticleReaderWebView: NSViewRepresentable {
    let articleURL: URL
    @Binding var isLoading: Bool
    @Binding var readerModeAvailable: Bool
    let useCompactTitleSizing: Bool
    let scrollToTopTrigger: Int
    let onScrollActivity: () -> Void

    private static func conceal(_ webView: WKWebView) {
        webView.alphaValue = 1
    }

    private static func reveal(_ webView: WKWebView) {
        guard webView.alphaValue != 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            webView.animator().alphaValue = 1
        }
    }

    private static func scrollToTop(_ webView: WKWebView) {
        webView.evaluateJavaScript("window.scrollTo({ top: 0, left: 0, behavior: 'smooth' });", completionHandler: nil)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        Self.conceal(webView)

        // Set User-Agent to avoid being blocked
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        print("📖 ArticleReaderWebView: Created WebView for \(articleURL)")
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self

        if context.coordinator.currentURL != articleURL || context.coordinator.currentUseCompactTitleSizing != useCompactTitleSizing {
            context.coordinator.currentURL = articleURL
            context.coordinator.currentUseCompactTitleSizing = useCompactTitleSizing
            context.coordinator.resetReaderModeState()

            DispatchQueue.main.async {
                self.isLoading = true
            }

            Self.conceal(nsView)
            var request = URLRequest(url: articleURL)
            request.cachePolicy = .returnCacheDataElseLoad
            print("📖 ArticleReaderWebView: Loading URL \(articleURL)")
            nsView.load(request)
        }

        if context.coordinator.currentScrollToTopTrigger != scrollToTopTrigger {
            context.coordinator.currentScrollToTopTrigger = scrollToTopTrigger
            if scrollToTopTrigger > 0 {
                Self.scrollToTop(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ArticleReaderWebView
        var currentURL: URL?
        var currentUseCompactTitleSizing: Bool?
        var hasAppliedReaderMode: Bool = false
        var pageLoaded: Bool = false
        var readerModeAttempt: Int = 0
        var pendingReaderModeRetry: DispatchWorkItem?
        var currentScrollToTopTrigger: Int = 0

        init(_ parent: ArticleReaderWebView) {
            self.parent = parent
        }

        func resetReaderModeState() {
            pendingReaderModeRetry?.cancel()
            pendingReaderModeRetry = nil
            hasAppliedReaderMode = false
            pageLoaded = false
            readerModeAttempt = 0
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if !pageLoaded {
                decisionHandler(.allow)
                return
            }

            if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            print("📖 ArticleReaderWebView: Started loading...")
            DispatchQueue.main.async {
                self.parent.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("📖 ArticleReaderWebView: Page finished loading")
            pageLoaded = true

            guard !hasAppliedReaderMode else {
                print("📖 ArticleReaderWebView: Reader mode already applied, skipping")
                DispatchQueue.main.async {
                    self.parent.isLoading = false
                }
                return
            }

            applyReaderMode(on: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("📖 ArticleReaderWebView: Navigation failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.pendingReaderModeRetry?.cancel()
                self.pendingReaderModeRetry = nil
                self.parent.isLoading = false
                self.parent.readerModeAvailable = false
                ArticleReaderWebView.reveal(webView)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("📖 ArticleReaderWebView: Provisional navigation failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.pendingReaderModeRetry?.cancel()
                self.pendingReaderModeRetry = nil
                self.parent.isLoading = false
                self.parent.readerModeAvailable = false
                ArticleReaderWebView.reveal(webView)
            }
        }

        private func applyReaderMode(on webView: WKWebView) {
            guard !hasAppliedReaderMode else { return }

            pendingReaderModeRetry?.cancel()
            pendingReaderModeRetry = nil
            readerModeAttempt += 1

            let script = ReaderModeService.toggleScript(useCompactTitle: parent.useCompactTitleSizing)
            print("📖 ArticleReaderWebView: Applying Readability.js immediately (attempt \(readerModeAttempt), script length: \(script.count) chars)")

            webView.evaluateJavaScript(script) { [weak self] result, error in
                DispatchQueue.main.async {
                    self?.handleReaderModeEvaluation(result: result, error: error, webView: webView)
                }
            }
        }

        private func handleReaderModeEvaluation(result: Any?, error: Error?, webView: WKWebView) {
            if let error {
                print("📖 ArticleReaderWebView: JavaScript error on attempt \(readerModeAttempt): \(error.localizedDescription)")
                if scheduleReaderModeRetry(on: webView) { return }

                hasAppliedReaderMode = true
                parent.isLoading = false
                parent.readerModeAvailable = false
                ArticleReaderWebView.reveal(webView)
                return
            }

            if let success = result as? Bool {
                print("📖 ArticleReaderWebView: Readability.js result on attempt \(readerModeAttempt): \(success)")
                if success {
                    hasAppliedReaderMode = true
                    parent.isLoading = false
                    parent.readerModeAvailable = true
                    ArticleReaderWebView.reveal(webView)
                    return
                }

                if scheduleReaderModeRetry(on: webView) { return }

                hasAppliedReaderMode = true
                parent.isLoading = false
                parent.readerModeAvailable = false
                ArticleReaderWebView.reveal(webView)
                return
            }

            print("📖 ArticleReaderWebView: Unexpected result type on attempt \(readerModeAttempt): \(String(describing: result))")
            if scheduleReaderModeRetry(on: webView) { return }

            hasAppliedReaderMode = true
            parent.isLoading = false
            parent.readerModeAvailable = false
            ArticleReaderWebView.reveal(webView)
        }

        private func scheduleReaderModeRetry(on webView: WKWebView) -> Bool {
            let maxAttempts = 4
            guard readerModeAttempt < maxAttempts else { return false }

            let delay = 0.15 * Double(readerModeAttempt)
            let workItem = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.applyReaderMode(on: webView)
            }

            pendingReaderModeRetry?.cancel()
            pendingReaderModeRetry = workItem
            print("📖 ArticleReaderWebView: Scheduling reader retry in \(String(format: "%.2f", delay))s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return true
        }
    }
}
#else
struct ArticleReaderWebView: UIViewRepresentable {
    let articleURL: URL
    @Binding var isLoading: Bool
    @Binding var readerModeAvailable: Bool
    let useCompactTitleSizing: Bool
    let scrollToTopTrigger: Int
    let onScrollActivity: () -> Void

    private static func conceal(_ webView: WKWebView) {
        webView.alpha = 1
    }

    private static func reveal(_ webView: WKWebView) {
        guard webView.alpha != 1 else { return }
        UIView.animate(withDuration: 0.15) {
            webView.alpha = 1
        }
    }

    private static func scrollToTop(_ webView: WKWebView) {
        let topOffset = CGPoint(x: 0, y: -webView.scrollView.adjustedContentInset.top)
        webView.scrollView.setContentOffset(topOffset, animated: true)
        webView.evaluateJavaScript(
            "document.scrollingElement.scrollTo({ top: 0, left: 0, behavior: 'smooth' }); window.scrollTo({ top: 0, left: 0, behavior: 'smooth' });",
            completionHandler: nil
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.delegate = context.coordinator
        context.coordinator.attachScrollToTopObserver(to: webView)
        ArticleScrollToTopController.shared.registerReaderWebView(webView)
        webView.allowsBackForwardNavigationGestures = false

        // Important: Don't make it transparent - let the page render normally
        webView.isOpaque = true
        let detailBackgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .black : .systemBackground
        }
        webView.backgroundColor = detailBackgroundColor
        webView.scrollView.backgroundColor = detailBackgroundColor
        Self.conceal(webView)

        // Set a proper User-Agent to avoid being blocked
        webView.customUserAgent = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        print("📖 ArticleReaderWebView: Created WebView for \(articleURL)")
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attachScrollToTopObserver(to: uiView)
        ArticleScrollToTopController.shared.registerReaderWebView(uiView)

        if context.coordinator.currentURL != articleURL || context.coordinator.currentUseCompactTitleSizing != useCompactTitleSizing {
            context.coordinator.currentURL = articleURL
            context.coordinator.currentUseCompactTitleSizing = useCompactTitleSizing
            context.coordinator.resetReaderModeState()

            DispatchQueue.main.async {
                self.isLoading = true
            }

            Self.conceal(uiView)
            var request = URLRequest(url: articleURL)
            request.cachePolicy = .returnCacheDataElseLoad
            print("📖 ArticleReaderWebView: Loading URL \(articleURL)")
            uiView.load(request)
        }

        if context.coordinator.currentScrollToTopTrigger != scrollToTopTrigger {
            context.coordinator.currentScrollToTopTrigger = scrollToTopTrigger
            if scrollToTopTrigger > 0 {
                Self.scrollToTop(uiView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        var parent: ArticleReaderWebView
        var currentURL: URL?
        var currentUseCompactTitleSizing: Bool?
        var hasAppliedReaderMode: Bool = false
        var pageLoaded: Bool = false
        var readerModeAttempt: Int = 0
        var pendingReaderModeRetry: DispatchWorkItem?
        var currentScrollToTopTrigger: Int = 0
        private weak var webView: WKWebView?
        private var scrollToTopObserver: NSObjectProtocol?

        init(_ parent: ArticleReaderWebView) {
            self.parent = parent
        }

        deinit {
            if let scrollToTopObserver {
                NotificationCenter.default.removeObserver(scrollToTopObserver)
            }
        }

        func attachScrollToTopObserver(to webView: WKWebView) {
            self.webView = webView
            guard scrollToTopObserver == nil else { return }

            scrollToTopObserver = NotificationCenter.default.addObserver(
                forName: .articleReaderScrollToTopRequested,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let webView = self?.webView else { return }
                ArticleReaderWebView.scrollToTop(webView)
            }
        }

        func resetReaderModeState() {
            pendingReaderModeRetry?.cancel()
            pendingReaderModeRetry = nil
            hasAppliedReaderMode = false
            pageLoaded = false
            readerModeAttempt = 0
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow all navigation types for the initial load
            if !pageLoaded {
                decisionHandler(.allow)
                return
            }

            // After initial load, open clicked links externally
            if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            print("📖 ArticleReaderWebView: Started loading...")
            DispatchQueue.main.async {
                self.parent.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("📖 ArticleReaderWebView: Page finished loading")
            pageLoaded = true

            // Don't apply reader mode if we've already done it (prevents loops)
            guard !hasAppliedReaderMode else {
                print("📖 ArticleReaderWebView: Reader mode already applied, skipping")
                DispatchQueue.main.async {
                    self.parent.isLoading = false
                }
                return
            }

            applyReaderMode(on: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("📖 ArticleReaderWebView: Navigation failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.pendingReaderModeRetry?.cancel()
                self.pendingReaderModeRetry = nil
                self.parent.isLoading = false
                self.parent.readerModeAvailable = false
                ArticleReaderWebView.reveal(webView)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("📖 ArticleReaderWebView: Provisional navigation failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.pendingReaderModeRetry?.cancel()
                self.pendingReaderModeRetry = nil
                self.parent.isLoading = false
                self.parent.readerModeAvailable = false
                ArticleReaderWebView.reveal(webView)
            }
        }

        private func applyReaderMode(on webView: WKWebView) {
            guard !hasAppliedReaderMode else { return }

            pendingReaderModeRetry?.cancel()
            pendingReaderModeRetry = nil
            readerModeAttempt += 1

            let script = ReaderModeService.toggleScript(useCompactTitle: parent.useCompactTitleSizing)
            print("📖 ArticleReaderWebView: Applying Readability.js immediately (attempt \(readerModeAttempt), script length: \(script.count) chars)")

            webView.evaluateJavaScript(script) { [weak self] result, error in
                DispatchQueue.main.async {
                    self?.handleReaderModeEvaluation(result: result, error: error, webView: webView)
                }
            }
        }

        private func handleReaderModeEvaluation(result: Any?, error: Error?, webView: WKWebView) {
            if let error {
                print("📖 ArticleReaderWebView: JavaScript error on attempt \(readerModeAttempt): \(error.localizedDescription)")
                if scheduleReaderModeRetry(on: webView) { return }

                hasAppliedReaderMode = true
                parent.isLoading = false
                parent.readerModeAvailable = false
                ArticleReaderWebView.reveal(webView)
                return
            }

            if let success = result as? Bool {
                print("📖 ArticleReaderWebView: Readability.js result on attempt \(readerModeAttempt): \(success)")
                if success {
                    hasAppliedReaderMode = true
                    parent.isLoading = false
                    parent.readerModeAvailable = true
                    ArticleReaderWebView.reveal(webView)
                    return
                }

                if scheduleReaderModeRetry(on: webView) { return }

                hasAppliedReaderMode = true
                parent.isLoading = false
                parent.readerModeAvailable = false
                print("📖 ArticleReaderWebView: Reader mode failed after retries - showing original page")
                ArticleReaderWebView.reveal(webView)
                return
            }

            print("📖 ArticleReaderWebView: Unexpected result type on attempt \(readerModeAttempt): \(String(describing: result))")
            if scheduleReaderModeRetry(on: webView) { return }

            hasAppliedReaderMode = true
            parent.isLoading = false
            parent.readerModeAvailable = false
            ArticleReaderWebView.reveal(webView)
        }

        private func scheduleReaderModeRetry(on webView: WKWebView) -> Bool {
            let maxAttempts = 4
            guard readerModeAttempt < maxAttempts else { return false }

            let delay = 0.15 * Double(readerModeAttempt)
            let workItem = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.applyReaderMode(on: webView)
            }

            pendingReaderModeRetry?.cancel()
            pendingReaderModeRetry = workItem
            print("📖 ArticleReaderWebView: Scheduling reader retry in \(String(format: "%.2f", delay))s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return true
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking else { return }
            parent.onScrollActivity()
        }
    }
}
#endif

// WebView wrapper for displaying HTML content
#if os(macOS)
struct HTMLWebView: NSViewRepresentable {
    let htmlContent: String
    let baseURL: URL?
    @Binding var contentHeight: CGFloat
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let preferences = WKPreferences()
        preferences.javaScriptEnabled = true
        config.preferences = preferences
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        
        // Configure the web view
        webView.setValue(false, forKey: "drawsBackground")
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Load the HTML content
        nsView.loadHTMLString(htmlContent, baseURL: baseURL)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLWebView
        
        init(_ parent: HTMLWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow the initial HTML load
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }
            
            // Open external links in browser
            if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            
            decisionHandler(.allow)
        }
    }
}
#else
struct HTMLWebView: UIViewRepresentable {
    let htmlContent: String
    let baseURL: URL?
    @Binding var contentHeight: CGFloat
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let preferences = WKPreferences()
        preferences.javaScriptEnabled = true
        config.preferences = preferences
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        // Avoid nested scrolling conflicts – ScrollView handles scrolling
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Load the HTML content
        uiView.loadHTMLString(htmlContent, baseURL: baseURL)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLWebView
        
        init(_ parent: HTMLWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow the initial HTML load
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }
            
            // Open external links in browser
            if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            
            decisionHandler(.allow)
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Evaluate JavaScript to get the content height and push it to SwiftUI
            webView.evaluateJavaScript("document.readyState") { (complete, error) in
                if complete != nil {
                    webView.evaluateJavaScript("document.body.scrollHeight") { (height, error) in
                        if let h = height as? CGFloat {
                            DispatchQueue.main.async {
                                self.parent.contentHeight = h
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif

// MARK: - Add Subscription View
struct AddSubscriptionView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.presentationMode) var presentationMode
    @State private var title = ""
    @State private var url = ""
    @State private var type: SubscriptionType = .rss
    @State private var errorMessage: String?
    
    @ViewBuilder
    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var iosBody: some View {
        NavigationView {
            ZStack {
                iosAddSheetBackground
                    .ignoresSafeArea()

                Form {
                    Section(header: Text("Subscription Details")) {
                        TextField("Title", text: $title)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        urlEntryField
                        Picker("Type", selection: $type) {
                            Text("RSS Feed").tag(SubscriptionType.rss)
                            Text("Reddit").tag(SubscriptionType.reddit)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }

                    if let errorMessage = errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundColor(.red)
                        }
                    }

                    Section {
                        Button("Add Subscription") {
                            addSubscription()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(title.isEmpty || url.isEmpty)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add Subscription")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
    #endif

    @ViewBuilder
    private var urlEntryField: some View {
        #if os(iOS)
        TextField(type == .rss ? "Feed URL" : "Subreddit Name", text: $url)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .autocapitalization(.none)
            .disableAutocorrection(true)
        #else
        TextField(type == .rss ? "Feed URL" : "Subreddit Name", text: $url)
            .textFieldStyle(RoundedBorderTextFieldStyle())
        #endif
    }

    #if os(macOS)
    private var macBody: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            HStack {
                Text("Add Subscription")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Title")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Subscription Title", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(type == .rss ? "Feed URL" : "Subreddit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(type == .rss ? "https://example.com/feed" : "technology", text: $url)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Type")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Type", selection: $type) {
                        Text("RSS Feed").tag(SubscriptionType.rss)
                        Text("Reddit").tag(SubscriptionType.reddit)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.large)
                }

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .padding(.top, 4)
                }
            }

            HStack {
                Spacer()
                Button("Add Subscription") {
                    addSubscription()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(title.isEmpty || url.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 440)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
    #endif

    #if os(iOS)
    private var iosAddSheetBackground: Color {
        Color(UIColor.systemGroupedBackground)
    }
    #endif
    
    private func addSubscription() {
        if type == .rss && !url.lowercased().starts(with: "http") {
            errorMessage = "Please enter a valid URL starting with http:// or https://"
            return
        }
        let finalUrl = type == .rss ? url : url.replacingOccurrences(of: "r/", with: "")
        presentationMode.wrappedValue.dismiss()
        DispatchQueue.main.async {
            appState.addSubscription(title: title, url: finalUrl, type: type)
        }
    }
}

enum SummaryCardBorderStyle {
    case article
    case reddit
}

// Replace the ArticleGlassyBackgroundModifier with this enhanced version
struct ArticleGlassyBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let borderStyle: SummaryCardBorderStyle?

    init(borderStyle: SummaryCardBorderStyle? = nil) {
        self.borderStyle = borderStyle
    }
    
    func body(content: Content) -> some View {
        if #available(iOS 15.0, macOS 12.0, *) {
            content
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(borderOverlay)
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
        } else {
            // Fallback for older OS versions
            content
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(AppColors.systemGray6)
                )
                .overlay(borderOverlay)
                .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 3)
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        switch borderStyle {
        case .article:
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1)
        case .reddit:
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(AppColors.redditCardBorder(for: colorScheme), lineWidth: 1)
        case .none:
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.4),
                            Color.white.opacity(0.1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }
}



// Also update the ArticleGlassySummary with enhanced styling and TTS
struct ArticleGlassySummary: View {
    let summary: String
    var borderStyle: SummaryCardBorderStyle? = nil
    var onAskAI: ((String) -> Void)? = nil
    var onAskAIWeb: ((String) -> Void)? = nil
    @EnvironmentObject var appState: AppState
    
    // TTS state variables
    @State private var isSynthesizingSpeech: Bool = false
    @State private var isSpeakingLocally: Bool = false
    @State private var speechSynthesisError: String? = nil
    #if os(iOS)
    @State private var audioPlayer: AVAudioPlayer?
    @State private var localSpeechSynth: AVSpeechSynthesizer?
    @StateObject private var soundDelegate = SoundDelegate()
    @State private var nextAudioChunk: Data? = nil
    @State private var ttsCanceled: Bool = false
    @State private var localTTSTask: Task<Void, Never>? = nil
    #elseif os(macOS)
    @State private var audioPlayer: NSSound?
    @State private var localSpeechSynth: NSSpeechSynthesizer?
    @StateObject private var soundDelegate = SoundDelegate()
    @State private var nextAudioChunk: Data? = nil
    @State private var ttsCanceled: Bool = false
    @State private var localTTSTask: Task<Void, Never>? = nil
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // TTS controls at the top
            HStack(spacing: 12) {
                Spacer()

                // Cloud TTS button
                Button {
                    speakSummary()
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.subheadline)
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .ttsActiveGlow(isSynthesizingSpeech, color: .blue)
                .help("Read aloud (Cloud)")
                .disabled(isSynthesizingSpeech || isSpeakingLocally || summary.isEmpty)
                
                // Stop speech
                Button {
                    stopArticleSummarySpeech()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.subheadline)
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .help("Stop speech")
                
                // Local TTS button
                Button {
                    speakSummaryLocally()
                } label: {
                    Image(systemName: "speaker.wave.2.circle")
                        .font(.subheadline)
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .ttsActiveGlow(isSpeakingLocally, color: .green)
                .help("Read aloud (Local)")
                .disabled(isSynthesizingSpeech || summary.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            
            // Summary text
            SelectableText(.init(summary))
                .font(.body)
                .foregroundColor(.primary)
                .onAskAI(onAskAI)
                .onAskAIWeb(onAskAIWeb)
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // TTS status indicators
            if isSynthesizingSpeech {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 5)
                    Text("Reading summary...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            } else if isSpeakingLocally {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 5)
                    Text("Reading with local TTS...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            
            // Throughput badge for on-device providers
            let _summaryProvider = appState.settings.selectedSummaryProvider
            if (_summaryProvider == .mlxLocal || _summaryProvider == .coreAIMLXLocal || _summaryProvider == .appleLocal || _summaryProvider == .applePCCGateway || _summaryProvider == .summarizeDaemon),
               !appState.mlxLastThroughput.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "cpu").font(.caption2)
                    Text(appState.mlxLastThroughput).font(.caption2).monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            }

            if let error = speechSynthesisError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .modifier(ArticleGlassyBackgroundModifier(borderStyle: borderStyle))
        .onAppear {
            // Set up sound delegate callbacks
            #if os(iOS)
            soundDelegate.onPlaybackFinished = {
                DispatchQueue.main.async {
                    if let next = self.nextAudioChunk {
                        self.nextAudioChunk = nil
                        self.playAudio(data: next)
                    } else {
                        self.isSynthesizingSpeech = false
                    }
                }
            }
            soundDelegate.onSpeechFinished = {
                DispatchQueue.main.async {
                    self.isSpeakingLocally = false
                }
            }
            #elseif os(macOS)
            soundDelegate.onPlaybackFinished = {
                DispatchQueue.main.async {
                    if let next = self.nextAudioChunk {
                        self.nextAudioChunk = nil
                        self.playAudio(data: next)
                    } else {
                        self.isSynthesizingSpeech = false
                    }
                }
            }
            soundDelegate.onSpeechFinished = {
                DispatchQueue.main.async {
                    self.isSpeakingLocally = false
                }
            }
            #endif
        }
    }
    
    // MARK: - TTS Methods
    
    private func speakSummary() {
        ttsCanceled = false
        guard !summary.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }
        
        // Stop any currently playing sounds before starting a new one
        #if os(iOS)
        audioPlayer?.stop()
        audioPlayer = nil
        // Also stop any local speech if playing
        localSpeechSynth?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayer?.stop()
        audioPlayer = nil
        // Also stop any local speech if playing
        localSpeechSynth?.stopSpeaking()
        #endif
        
        isSynthesizingSpeech = true
        isSpeakingLocally = false
        speechSynthesisError = nil
        
        Task {
            await appState.summaryService.synthesizeSpeechFastStartSplit(
                text: summary,
                onFirstChunk: { data in
                    DispatchQueue.main.async {
                        if !self.ttsCanceled { self.playAudio(data: data) }
                    }
                },
                onRemainingReady: { data in
                    DispatchQueue.main.async {
                        if self.ttsCanceled { return }
                        if let player = self.audioPlayer, player.isPlaying {
                            self.nextAudioChunk = data
                        } else {
                            self.playAudio(data: data)
                        }
                    }
                },
                onComplete: {
                    // handled by delegate chain
                },
                onError: { error in
                    DispatchQueue.main.async {
                        self.speechSynthesisError = "Speech synthesis failed: \(error.localizedDescription)"
                        self.isSynthesizingSpeech = false
                        self.nextAudioChunk = nil
                    }
                }
            )
        }
    }
    
    private func stopArticleSummarySpeech() {
        ttsCanceled = true
        #if os(iOS)
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayer?.stop()
        audioPlayer = nil
        ShortcutsTTS.shared.stopSpeaking()
        localSpeechSynth?.stopSpeaking()
        #endif
        nextAudioChunk = nil
        isSynthesizingSpeech = false
        isSpeakingLocally = false
    }
    
    private func playAudio(data: Data) {
        #if os(iOS)
        // Stop any existing playback
        audioPlayer?.stop()
        
        // Detect format and handle accordingly
        let audioData: Data
        if isMP3Data(data) || isAACData(data) {
            // OpenAI returns MP3 or AAC directly - both are supported by AVAudioPlayer
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        do {
            audioPlayer = try AVAudioPlayer(data: audioData)
            if let player = audioPlayer {
                player.prepareToPlay()
                player.delegate = soundDelegate
                soundDelegate.onPlaybackFinished = {
                    DispatchQueue.main.async {
                        if let next = self.nextAudioChunk {
                            self.nextAudioChunk = nil
                            self.playAudio(data: next)
                        } else {
                            self.isSynthesizingSpeech = false
                        }
                    }
                }
                if player.play() {
                    // isSynthesizingSpeech remains true until playback finishes or fails
                } else {
                    speechSynthesisError = "Failed to start audio playback."
                    isSynthesizingSpeech = false // Playback failed to start
                }
            }
        } catch {
            speechSynthesisError = "Failed to initialize audio player: \(error.localizedDescription)"
            isSynthesizingSpeech = false // Player initialization failed
        }
        #elseif os(macOS)
        // Stop any existing playback
        audioPlayer?.stop()
        
        // Detect format and handle accordingly
        let audioData: Data
        if isMP3Data(data) || isAACData(data) {
            // OpenAI returns MP3 or AAC directly - both are supported by NSSound
            audioData = data
        } else {
            // Gemini returns PCM that needs WAV conversion
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }
        
        audioPlayer = NSSound(data: audioData)
        if let player = audioPlayer {
            player.delegate = soundDelegate
            soundDelegate.onPlaybackFinished = {
                DispatchQueue.main.async {
                    if let next = self.nextAudioChunk {
                        self.nextAudioChunk = nil
                        self.playAudio(data: next)
                    } else {
                        self.isSynthesizingSpeech = false
                    }
                }
            }
            if player.play() {
                // isSynthesizingSpeech remains true until playback finishes or fails
            } else {
                speechSynthesisError = "Failed to start audio playback."
                isSynthesizingSpeech = false // Playback failed to start
            }
        } else {
            speechSynthesisError = "Failed to initialize audio player with data."
            isSynthesizingSpeech = false // Player initialization failed
        }
        #endif
    }
    
    private func speakSummaryLocally() {
        #if os(iOS)
        // Check if Kokoro engine is selected
        let settings = PersistenceManager.shared.loadSettings()
        if settings.localTTSEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                isSpeakingLocally = false
                speechSynthesisError = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            if isSpeakingLocally {
                localTTSTask?.cancel()
                localTTSTask = nil
                audioPlayer?.stop()
                localSpeechSynth?.stopSpeaking(at: .immediate)
                isSpeakingLocally = false
                return
            }
            guard !summary.isEmpty else {
                speechSynthesisError = "No summary available to read."
                return
            }
            audioPlayer?.stop()
            isSpeakingLocally = true
            isSynthesizingSpeech = false
            startKokoroPlaybackSummary(
                text: summary,
                voice: settings.kokoroVoice,
                speed: settings.kokoroSpeed,
                setAudioPlayer: { player in audioPlayer = player },
                soundDelegate: soundDelegate,
                taskStore: &localTTSTask,
                onCompleted: {
                    isSpeakingLocally = false
                    localTTSTask = nil
                },
                onError: { message in
                    speechSynthesisError = message
                    isSpeakingLocally = false
                }
            )
            return
        }

        // Check if running on Mac as iPad app - use Shortcuts instead
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // Toggle off if already speaking (can't really stop shortcuts)
            if isSpeakingLocally {
                ShortcutsTTS.shared.stopSpeaking()
                isSpeakingLocally = false
                return
            }

            guard !summary.isEmpty else {
                speechSynthesisError = "No summary available to read."
                return
            }

            // Stop any other audio playing
            audioPlayer?.stop()

            // Start speaking via Shortcuts
            isSpeakingLocally = true
            isSynthesizingSpeech = false

            let success = ShortcutsTTS.shared.speakText(summary) {
                // Completion handler - called when speech ends (estimated)
                DispatchQueue.main.async {
                    self.isSpeakingLocally = false
                }
            }
            
            if !success {
                isSpeakingLocally = false
                speechSynthesisError = "Failed to start Shortcuts TTS"
            }
            
            return
        }
        
        // Original iOS code for real devices
        // Toggle off if already speaking
        if isSpeakingLocally {
            localSpeechSynth?.stopSpeaking(at: .immediate)
            isSpeakingLocally = false
            return
        }
        
        guard !summary.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }
        
        // Stop any other audio playing
        audioPlayer?.stop()
        
        // Configure audio session for high-quality speech
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP])
            try audioSession.setActive(true)
        } catch {
            print("🔊 [LocalTTS] Failed to configure audio session: \(error)")
        }
        
        // Initialize speech synthesizer
        if localSpeechSynth == nil {
            localSpeechSynth = AVSpeechSynthesizer()
            localSpeechSynth?.delegate = soundDelegate
        }
        
        let utterance = AVSpeechUtterance(string: summary)
        // Optimize speech parameters for quality
        utterance.rate = 0.52  // Slightly slower than default (0.5) for better clarity
        utterance.pitchMultiplier = 1.0  // Natural pitch
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.0
        utterance.postUtteranceDelay = 0.0

        // Prefer Ava (Enhanced/Premium) when iOS app runs on Mac
        // Try to use saved voice first, then fall back to default (like the example)
        let savedVoiceID = UserDefaults.standard.string(forKey: "LocalTTS.iOSOnMac.SelectedVoiceID") ?? ""
        
        if !savedVoiceID.isEmpty {
            // Try to use the saved voice
            if let voice = AVSpeechSynthesisVoice(identifier: savedVoiceID) {
                // Only skip com.apple.voice on Mac (they don't work there)
                if ProcessInfo.processInfo.isiOSAppOnMac && voice.identifier.contains("com.apple.voice") {
                    print("🔊 [LocalTTS] Skipping com.apple.voice on Mac")
                } else {
                    utterance.voice = voice
                    let qualityStr = voice.quality == .premium ? "PREMIUM" : 
                                    voice.quality == .enhanced ? "Enhanced" : "Default"
                    print("🔊 [LocalTTS] Using saved voice: \(voice.name) [\(qualityStr)]")
                }
            } else {
                // Saved voice doesn't exist, clear it
                UserDefaults.standard.removeObject(forKey: "LocalTTS.iOSOnMac.SelectedVoiceID")
                print("🔊 [LocalTTS] Saved voice not found (\(savedVoiceID)), cleared preference")
            }
        }
        
        // If no voice set yet, select the best available voice (Premium > Enhanced > Default)
        if utterance.voice == nil {
            let currentLang = AVSpeechSynthesisVoice.currentLanguageCode()
            let allVoices = AVSpeechSynthesisVoice.speechVoices()
            
            // Filter for current language (and exclude com.apple.voice on Mac)
            let availableVoices: [AVSpeechSynthesisVoice]
            if ProcessInfo.processInfo.isiOSAppOnMac {
                availableVoices = allVoices.filter { 
                    $0.language == currentLang && !$0.identifier.contains("com.apple.voice")
                }
            } else {
                availableVoices = allVoices.filter { $0.language == currentLang }
            }
            
            // Simple priority: Premium > Enhanced > Default
            let premiumVoices = availableVoices.filter { $0.quality == .premium }
            let enhancedVoices = availableVoices.filter { $0.quality == .enhanced }
            
            if let premium = premiumVoices.first {
                utterance.voice = premium
                print("🔊 [LocalTTS] Using PREMIUM voice: \(premium.name)")
            } else if let enhanced = enhancedVoices.first {
                utterance.voice = enhanced
                print("🔊 [LocalTTS] Using Enhanced voice: \(enhanced.name)")
            } else {
                // Fall back to default voice for the language
                utterance.voice = AVSpeechSynthesisVoice(language: currentLang)
                if let v = utterance.voice {
                    print("🔊 [LocalTTS] Using default voice: \(v.name)")
                }
            }
        }
        
        isSpeakingLocally = true
        isSynthesizingSpeech = false
        if let synth = localSpeechSynth {
            DispatchQueue.main.async { synth.speak(utterance) }
        } else {
            isSpeakingLocally = false
            speechSynthesisError = "Failed to initialize speech synthesizer."
        }
        #elseif os(macOS)
        // Check if Kokoro engine is selected
        let settings = PersistenceManager.shared.loadSettings()
        if settings.localTTSEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                isSpeakingLocally = false
                speechSynthesisError = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            if isSpeakingLocally {
                localTTSTask?.cancel()
                localTTSTask = nil
                audioPlayer?.stop()
                isSpeakingLocally = false
                return
            }
            guard !summary.isEmpty else {
                speechSynthesisError = "No summary available to read."
                return
            }
            audioPlayer?.stop()
            isSpeakingLocally = true
            isSynthesizingSpeech = false
            startKokoroPlaybackSummary(
                text: summary,
                voice: settings.kokoroVoice,
                speed: settings.kokoroSpeed,
                setAudioPlayer: { player in audioPlayer = player },
                soundDelegate: soundDelegate,
                taskStore: &localTTSTask,
                onCompleted: {
                    isSpeakingLocally = false
                    localTTSTask = nil
                },
                onError: { message in
                    speechSynthesisError = message
                    isSpeakingLocally = false
                }
            )
            return
        }

        // Toggle off if already speaking (CLI shortcut cannot truly stop mid-stream)
        if isSpeakingLocally {
            ShortcutsTTS.shared.stopSpeaking()
            isSpeakingLocally = false
            return
        }

        guard !summary.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }

        // Stop all other audio
        audioPlayer?.stop()

        isSpeakingLocally = true
        isSynthesizingSpeech = false

        let success = ShortcutsTTS.shared.speakText(summary) {
            DispatchQueue.main.async {
                self.isSpeakingLocally = false
            }
        }

        if !success {
            isSpeakingLocally = false
            speechSynthesisError = "Failed to start Shortcuts TTS on macOS."
        }
        #endif
    }

    private func startKokoroPlaybackSummary(
        text: String,
        voice: String,
        speed: Double,
        setAudioPlayer: @escaping (NSSound?) -> Void,
        soundDelegate: SoundDelegate,
        taskStore: inout Task<Void, Never>?,
        onCompleted: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        _ = soundDelegate
        taskStore?.cancel()
        taskStore = Task {
            defer {
                if !PersistenceManager.shared.loadSettings().kokoroPrecacheEnabled {
                    KokoroTTSService.shared.unloadIfAllowed()
                }
                Task { @MainActor in onCompleted() }
            }
            do {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                func makeKokoroChunks(from input: String) -> [String] {
                    let firstSize = min(240, input.count)
                    let firstChunk = String(input.prefix(firstSize))
                    let remaining = String(input.dropFirst(firstSize)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !remaining.isEmpty else { return [firstChunk] }
                    var chunks: [String] = [firstChunk]
                    let sentences = remaining.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                    var current = ""
                    let maxChunkSize = 420
                    for sentence in sentences {
                        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmedSentence.isEmpty { continue }
                        let sentenceWithPunctuation = trimmedSentence + "."
                        if current.count + sentenceWithPunctuation.count <= maxChunkSize {
                            current += (current.isEmpty ? "" : " ") + sentenceWithPunctuation
                        } else {
                            if !current.isEmpty { chunks.append(current) }
                            current = sentenceWithPunctuation
                        }
                    }
                    if !current.isEmpty { chunks.append(current) }
                    return chunks
                }

                let chunks = makeKokoroChunks(from: trimmed)
                guard let firstChunk = chunks.first else { return }

                func playChunk(_ data: Data) async throws -> TimeInterval {
                    try await MainActor.run {
                        #if os(iOS)
                        do {
                            let player = try AVAudioPlayer(data: data)
                            player.delegate = nil
                            player.prepareToPlay()
                            setAudioPlayer(player)
                            if player.play() == false {
                                onError("Failed to start audio playback.")
                                throw NSError(domain: "KokoroPlayback", code: -1)
                            }
                            return player.duration
                        } catch {
                            onError("Failed to initialize audio player: \(error.localizedDescription)")
                            throw error
                        }
                        #elseif os(macOS)
                        guard let player = NSSound(data: data) else {
                            onError("Failed to initialize audio player.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        setAudioPlayer(player)
                        if player.play() == false {
                            onError("Failed to start audio playback.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        return player.duration
                        #endif
                    }
                }

                enum KokoroPlaybackError: Error { case timeout }

                func synthesizeWithTimeout(_ text: String) async throws -> Data {
                    try await withThrowingTaskGroup(of: Data.self) { group in
                        group.addTask {
                            try await KokoroTTSService.shared.synthesize(text: text, voice: voice, speed: Float(speed))
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 20_000_000_000)
                            throw KokoroPlaybackError.timeout
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                }

                let firstData = try await synthesizeWithTimeout(firstChunk)
                if Task.isCancelled { return }
                var currentDuration = try await playChunk(firstData)
                if chunks.count == 1 { return }

                var nextIndex = 1
                var nextTask: Task<Data, Error>? = Task { try await synthesizeWithTimeout(chunks[nextIndex]) }
                defer { nextTask?.cancel() }

                while nextIndex < chunks.count {
                    try await Task.sleep(nanoseconds: UInt64(currentDuration * 1_000_000_000))
                    if Task.isCancelled { return }
                    guard let task = nextTask else { return }
                    let data = try await task.value
                    nextIndex += 1
                    if nextIndex < chunks.count {
                        nextTask = Task { try await synthesizeWithTimeout(chunks[nextIndex]) }
                    } else {
                        nextTask = nil
                    }
                    currentDuration = try await playChunk(data)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    let message: String
                    if let kokoroError = error as? KokoroTTSServiceError, kokoroError == .notAvailable {
                        message = "MLX TTS is not available. Add the MLXAudio package and model access."
                    } else if String(describing: error).contains("timeout") {
                        message = "Kokoro is still loading models. Please wait a moment and try again."
                    } else {
                        message = "Kokoro TTS failed: \(error.localizedDescription)"
                    }
                    onError(message)
                }
            }
        }
    }
}

private struct SidebarMenuRow<Icon: View>: View {
    let title: String
    let unreadCount: Int?
    let isSelected: Bool
    let accentColor: Color
    let selectedTextColor: Color
    let unselectedTextColor: Color
    let selectionGradient: LinearGradient
    let selectionStrokeColor: Color
    let selectionRailColor: Color
    let countPillTextColor: Color
    let countPillBackground: Color
    let selectedCountPillTextColor: Color
    let selectedCountPillBackground: Color
    let icon: Icon

    init(
        title: String,
        unreadCount: Int?,
        isSelected: Bool,
        accentColor: Color,
        selectedTextColor: Color,
        unselectedTextColor: Color,
        selectionGradient: LinearGradient,
        selectionStrokeColor: Color,
        selectionRailColor: Color,
        countPillTextColor: Color,
        countPillBackground: Color,
        selectedCountPillTextColor: Color,
        selectedCountPillBackground: Color,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.unreadCount = unreadCount
        self.isSelected = isSelected
        self.accentColor = accentColor
        self.selectedTextColor = selectedTextColor
        self.unselectedTextColor = unselectedTextColor
        self.selectionGradient = selectionGradient
        self.selectionStrokeColor = selectionStrokeColor
        self.selectionRailColor = selectionRailColor
        self.countPillTextColor = countPillTextColor
        self.countPillBackground = countPillBackground
        self.selectedCountPillTextColor = selectedCountPillTextColor
        self.selectedCountPillBackground = selectedCountPillBackground
        self.icon = icon()
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 28, height: 28)

            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isSelected ? selectedTextColor : unselectedTextColor)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if let unreadCount, unreadCount > 0 {
                SidebarCountPill(
                    count: unreadCount,
                    isSelected: isSelected,
                    textColor: countPillTextColor,
                    backgroundColor: countPillBackground,
                    selectedTextColor: selectedCountPillTextColor,
                    selectedBackgroundColor: selectedCountPillBackground
                )
            }
        }
        .frame(minHeight: 40)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selectionGradient)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(selectionStrokeColor, lineWidth: 1)
                    }
            }
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule(style: .continuous)
                    .fill(selectionRailColor)
                    .frame(width: 3, height: 24)
                    .padding(.leading, 4)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SidebarCountPill: View {
    let count: Int
    let isSelected: Bool
    let textColor: Color
    let backgroundColor: Color
    let selectedTextColor: Color
    let selectedBackgroundColor: Color

    var body: some View {
        Text("\(count)")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isSelected ? selectedTextColor : textColor)
            .padding(.horizontal, 8)
            .frame(minWidth: 30, minHeight: 22)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? selectedBackgroundColor : backgroundColor)
            }
    }
}

// Glass row background modifier for sidebar
struct GlassRowBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

private struct SidebarRowChromeModifier: ViewModifier {
    let backgroundColor: Color

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 3, leading: 18, bottom: 3, trailing: 18))
            .listRowSeparator(.hidden)
            .listRowBackground(backgroundColor.opacity(0))
    }
}

private struct SidebarSelectionBorderModifier: ViewModifier {
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let borderColor: Color = isSelected
            ? Color.white.opacity(colorScheme == .dark ? 0.10 : 0.16)
            : Color.clear

        content
            .modifier(SidebarRowChromeModifier(backgroundColor: .clear))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(borderColor, lineWidth: isSelected ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}

// Glass-style container used for subscription rows: a translucent rounded
// rectangle with a subtle border, sitting behind the row's selection fill.
private struct SidebarSubscriptionGlassModifier: ViewModifier {
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                Color.white.opacity(colorScheme == .dark ? 0.08 : 0.14),
                                lineWidth: 1
                            )
                    }
                    .allowsHitTesting(false)
            }
    }
}

private extension View {
    func sidebarRowChrome(backgroundColor: Color = .clear) -> some View {
        modifier(SidebarRowChromeModifier(backgroundColor: backgroundColor))
    }

    func sidebarSelectionBorder(_ isSelected: Bool) -> some View {
        modifier(SidebarSelectionBorderModifier(isSelected: isSelected))
    }

    func sidebarSubscriptionGlass(isSelected: Bool) -> some View {
        modifier(SidebarSubscriptionGlassModifier(isSelected: isSelected))
    }
}

#if os(macOS)
private struct MacListSelectionClearView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let apply = {
            let tableView =
                nsView.firstSuperview(of: NSTableView.self) ??
                (nsView.firstSuperview(of: NSScrollView.self)?.documentView as? NSTableView) ??
                nsView.window?.contentView?.firstDescendant(of: NSTableView.self)
            guard let tableView else { return }
            let scrollView = tableView.enclosingScrollView
            tableView.selectionHighlightStyle = .none
            tableView.backgroundColor = .clear
            tableView.usesAlternatingRowBackgroundColors = false
            scrollView?.drawsBackground = false
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
}

private struct MacWindowChromeBackgroundView: NSViewRepresentable {
    let isDark: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            apply(to: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            apply(to: nsView)
        }
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        let chromeColor = isDark
            ? NSColor(calibratedRed: 0.055, green: 0.058, blue: 0.095, alpha: 1)
            : NSColor(calibratedRed: 0.985, green: 0.988, blue: 1.0, alpha: 1)

        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.toolbar?.showsBaselineSeparator = false
        window.backgroundColor = chromeColor
        window.isOpaque = true
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = chromeColor.cgColor
    }
}

private extension NSView {
    func firstSuperview<T: NSView>(of type: T.Type) -> T? {
        var current = superview
        while let view = current {
            if let match = view as? T {
                return match
            }
            current = view.superview
        }
        return nil
    }

    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        if let match = self as? T {
            return match
        }
        for child in subviews {
            if let match = child.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}
#endif

struct SidebarButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.callout)
            .fontWeight(.medium)
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.regularMaterial)
            }
    }
}

// iOS 26 Glass Button Style
extension View {
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(PlainButtonStyle())
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else {
            self
                .buttonStyle(PlainButtonStyle())
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                        )
                }
        }
    }
    
    @ViewBuilder
    func glassBackground() -> some View {
        if #available(iOS 26.0, *) {
            self
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        } else {
            self
                .padding()
                .background(AppColors.systemGray6, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

// Visual effect blur for macOS
#if os(macOS)
struct VisualEffectBlur: NSViewRepresentable {
    var blurStyle: NSVisualEffectView.Material = .sidebar
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = blurStyle
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = blurStyle
    }
}
#else
struct VisualEffectBlur: UIViewRepresentable {
    var blurStyle: UIBlurEffect.Style = .systemMaterial
    
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
    }
    
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: blurStyle)
    }
}
#endif


// Article card glass modifier
struct ArticleCardGlassModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if colorScheme == .dark {
            content
                .background(Color.black, in: RoundedRectangle(cornerRadius: 24))
                .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 8)
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 8)
        } else {
            if #available(iOS 15.0, macOS 12.0, *) {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.5),
                                        Color.white.opacity(0.1)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 8)
            } else {
                content
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(AppColors.secondaryBackground)
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
            }
        }
    }
}

// Question/Answer glass modifier
struct QuestionAnswerGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if #available(iOS 15.0, macOS 12.0, *) {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                )
        } else {
            content
                .background(Color.blue.opacity(0.1))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                )
        }
    }
}

// Navigation button glass modifier
struct NavigationButtonGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else if #available(iOS 15.0, macOS 12.0, *) {
            content
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else {
            content
                .background(Color.black.opacity(0.7))
                .cornerRadius(8)
        }
    }
}

// Draggable version of GlobalSummaryResultView
struct DraggableGlobalSummaryView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var offset = CGSize.zero
    @State private var isDragging = false
    
    // Q&A State Variables
    @State private var showQAInterface = false
    @State private var qaQuestionText: String = ""
    @State private var qaAnswerText: String = ""
    @State private var isProcessingQA = false
    @State private var qaInlineError: String?
    @State private var showAnswerSheet = false

    // Ask AI Selection State
    @State private var showSelectionAskAIResponse = false
    @State private var isSelectionAskAIInFlight = false
    @State private var selectionAskAIResponse: String?
    @State private var selectionAskAIError: String?
    @State private var selectionAskAITask: Task<Void, Never>?

    // Whiteboard State Variables
    @State private var showWhiteboard: Bool = false
    @State private var whiteboardContent: Data?
    @State private var isGeneratingWhiteboard: Bool = false
    @State private var whiteboardError: String?

    // Infographic State Variables
    @State private var showInfographic: Bool = false
    @State private var infographicContent: Data?
    @State private var isGeneratingInfographic: Bool = false
    @State private var infographicError: String?

    // TTS State Variables
    @State private var isSynthesizingSpeechDrag: Bool = false
    @State private var isSpeakingLocallyDrag: Bool = false
    @State private var speechSynthesisErrorDrag: String? = nil
    @State private var audioPlayerDrag: NSSound?
    @StateObject private var soundDelegateDrag = SoundDelegate()
    @State private var nextAudioChunkDrag: Data? = nil
    @State private var ttsCanceledDrag: Bool = false
    @State private var localTTSTaskDrag: Task<Void, Never>? = nil

    let json: String
    let error: String?

    private var shouldShowExplicitWebAIControls: Bool {
        appState.settings.selectedSummaryProvider != .webAI
    }
    
    private var parsedResult: GlobalSummaryResult? {
        guard let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(GlobalSummaryResult.self, from: data) else {
            return nil
        }
        return result
    }
    
    private var parsedSummaries: [GlobalSummaryItem] {
        return parsedResult?.summaries ?? []
    }
    
    private var isRedditContent: Bool {
        return parsedResult?.source == "reddit"
    }
    
    private var hasSummaryContent: Bool {
        !parsedSummaries.isEmpty || !(appState.aggregateSummaryText?.isEmpty ?? true)
    }

    private func summaryStableID(for item: GlobalSummaryItem, index: Int) -> String {
        if let referenceId = item.referenceId, !referenceId.isEmpty {
            return "ref-\(referenceId)-\(index)"
        }
        return "summary-\(item.subject)-\(index)"
    }

    private struct ParsedSummaryRow: Identifiable {
        let id: String
        let index: Int
        let item: GlobalSummaryItem
    }

    private var parsedSummaryRows: [ParsedSummaryRow] {
        parsedSummaries.enumerated().map { index, item in
            ParsedSummaryRow(
                id: summaryStableID(for: item, index: index),
                index: index,
                item: item
            )
        }
    }

    private var askAIHandler: (String) -> Void {
        { selection in
            askAIFromSummarySelection(selection, action: .standard)
        }
    }

    private var askAIWebHandler: (String) -> Void {
        { selection in
            askAIFromSummarySelection(selection, action: .web)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title bar with drag handle
            HStack {
                Image(systemName: "line.3.horizontal")
                    .foregroundColor(.secondary)
                Text("Summary Overview")
                    .font(.headline)
                Spacer()
                
                // Minimize button
                Button {
                    appState.showGlobalSummary = false
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.secondary)
                }
                
                // Close button
                Button {
                    appState.showGlobalSummary = false
                    appState.hasCachedSummary = false
                    appState.globalSummaryJSON = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.2),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .cornerRadius(12)
                    .blendMode(.overlay)
                }
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        offset = CGSize(
                            width: value.translation.width + value.startLocation.x - 200,
                            height: value.translation.height + value.startLocation.y - 100
                        )
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = error, !error.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.callout)
                                .foregroundColor(.primary)
                        }
                        .padding(10)
                        .background(.regularMaterial)
                        .cornerRadius(8)
                    }
                    
                    let hidesBatchSummaryProgressWhileWebAIIsMinimized =
                        (appState.isLoading || appState.isWebAIBatchHandoffInProgress) &&
                        appState.isWebAIHandoffMinimized

                    if appState.isLoading && appState.aggregateSummaryText == nil && !hidesBatchSummaryProgressWhileWebAIIsMinimized {
                        VStack(spacing: 20) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .progressViewStyle(CircularProgressViewStyle())
                            Text(isRedditContent ? "Summarizing Reddit posts..." : "Summarizing articles...")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    } else {
                        if appState.isLoading && appState.aggregateSummaryText != nil && !hidesBatchSummaryProgressWhileWebAIIsMinimized {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Refreshing source summaries...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal)
                        }

                        // Overall Summary at the top (before individual summaries)
                        if let aggregateText = appState.aggregateSummaryText {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkles")
                                        .foregroundColor(.blue)
                                    Text("Overall Summary")
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    if let providerName = appState.aggregateSummaryProviderName {
                                        Text(providerName)
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                    }
                                }
                                SelectableText(.init(aggregateText))
                                    .font(.body)
                                    .foregroundColor(.primary)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                ZStack {
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(.ultraThinMaterial)
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.15),
                                            Color.clear,
                                            Color.black.opacity(0.05)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    .cornerRadius(16)
                                    .blendMode(.overlay)
                                    if isRedditContent {
                                        RoundedRectangle(cornerRadius: 16)
                                            .strokeBorder(AppColors.redditCardBorder(for: colorScheme), lineWidth: 1)
                                    } else {
                                        RoundedRectangle(cornerRadius: 16)
                                            .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1)
                                    }
                                }
                            )
                        }

                        if appState.isGeneratingAggregateSummary {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Generating overall summary...")
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                        }

                        if let aggregateError = appState.aggregateSummaryError {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(aggregateError)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                        }

                        // Individual summaries
                        ForEach(parsedSummaryRows) { row in
                            let index = row.index
                            let item = row.item
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .center, spacing: 8) {
                                    Text("\(index + 1).")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(item.subject)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    if item.referenceId != nil {
                                        Button {
                                            openItem(item, isReddit: isRedditContent)
                                        } label: {
                                            Image(systemName: "arrow.up.right.square")
                                                .font(.system(size: 16, weight: .semibold))
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .help(isRedditContent ? "Open Reddit post" : "Open article")
                                    }
                                }

                                ArticleGlassySummary(
                                    summary: item.summary,
                                    borderStyle: isRedditContent ? .reddit : .article
                                )
                                    .environmentObject(appState)
                            }
                            .padding(.bottom, 4)
                        }
                    }
                }
                .padding()
                .environment(\.askAISelectionHandler, askAIHandler)
                .environment(\.askAIWebSelectionHandler, askAIWebHandler)
            }
            .frame(maxHeight: 400)

            // Q&A Interface
            if showQAInterface {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ask a question about these \(isRedditContent ? "Reddit discussions" : "articles")")
                        .font(.headline)
                    
                    TextField("Type your question...", text: $qaQuestionText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isProcessingQA || appState.isWaitingForGlobalQA)
                        .onSubmit {
                            askGlobalSummaryQuestion()
                        }
                    
                    HStack(spacing: 8) {
                        Button {
                            askGlobalSummaryQuestion()
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .font(.subheadline)
                        }
                        .accessibilityLabel("Ask")
                        .buttonStyle(LiquidGlassButtonStyle())
                        .disabled(qaQuestionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessingQA || appState.isWaitingForGlobalQA)

                        if shouldShowExplicitWebAIControls {
                            Button {
                                askGlobalSummaryWebQuestion()
                            } label: {
                                Image(systemName: "globe")
                                    .font(.subheadline)
                            }
                            .accessibilityLabel(appState.settings.selectedWebAIProvider.displayName)
                            .buttonStyle(LiquidGlassButtonStyle())
                            .disabled(qaQuestionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessingQA || appState.isWaitingForGlobalQA)
                        }
                        
                        Button {
                            resetQAState(keepInterface: true)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.subheadline)
                        }
                        .accessibilityLabel("Clear")
                        .buttonStyle(LiquidGlassButtonStyle())
                        .disabled(isProcessingQA || appState.isWaitingForGlobalQA)
                        
                        Spacer()
                    }
                    
                    if let inlineError = qaInlineError {
                        Text(inlineError)
                            .font(.caption)
                            .foregroundColor(.red)
                    } else if isProcessingQA || appState.isWaitingForGlobalQA {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(appState.globalQAWaitProgress.isEmpty ? "Thinking..." : appState.globalQAWaitProgress)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if !qaAnswerText.isEmpty {
                        HStack {
                            Button {
                                showAnswerSheet = true
                            } label: {
                                Label("Open Answer", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .font(.subheadline)
                            }
                            .buttonStyle(LiquidGlassButtonStyle())
                            
                            Button {
                                copyToClipboard(qaAnswerText)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .font(.subheadline)
                            }
                            .buttonStyle(LiquidGlassButtonStyle())
                            
                            Spacer()
                        }
                        .transition(.opacity.combined(with: .slide))
                    }
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
            }

            // TTS status indicators
            if isSynthesizingSpeechDrag {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 5)
                    Text("Reading overview (Cloud TTS)...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
            } else if isSpeakingLocallyDrag {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 5)
                    Text("Reading overview (Local TTS)...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
            }
            if let ttsError = speechSynthesisErrorDrag {
                Text(ttsError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    let formattedText = parsedSummaries.enumerated()
                        .map { index, item in "\(index + 1). **\(item.subject)**\n\(item.summary)" }
                        .joined(separator: "\n\n")
                    copyToClipboard(formattedText)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .help("Copy summaries")

                if appState.aggregateSummaryText == nil {
                    Button {
                        print("🎇 SPARKLES BUTTON PRESSED")
                        appState.generateCombinedGlobalSummary(force: false)
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    .help("Generate overall summary")
                    .disabled(
                        appState.isLoading ||
                        appState.isGeneratingAggregateSummary ||
                        appState.aggregatedRedditStatusMessage?.statusCode == 429
                    )
                }

                Button {
                    print("🔄 RELOAD BUTTON PRESSED - context exists: \(appState.lastGlobalSummaryContext != nil)")
                    DispatchQueue.main.async {
                        appState.retryLastGlobalSummary()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .help("Reload summary")
                .disabled(appState.lastGlobalSummaryContext == nil)
                .onAppear {
                    print("🔄 Reload button appeared - context: \(String(describing: appState.lastGlobalSummaryContext))")
                }

                // Cloud TTS button
                Button {
                    speakDragOverviewCloudTTS()
                } label: {
                    Image(systemName: "speaker.wave.2")
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .ttsActiveGlow(isSynthesizingSpeechDrag, color: .blue)
                .help("Read aloud (Cloud TTS)")
                .disabled(isSynthesizingSpeechDrag || isSpeakingLocallyDrag || !hasSummaryContent)

                // Local TTS button
                Button {
                    speakDragOverviewLocally()
                } label: {
                    Image(systemName: "speaker.wave.2.circle")
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .ttsActiveGlow(isSpeakingLocallyDrag, color: .green)
                .help("Read aloud (Local TTS / MLX)")
                .disabled(isSynthesizingSpeechDrag || !hasSummaryContent)

                // Stop TTS button
                if isSynthesizingSpeechDrag || isSpeakingLocallyDrag {
                    Button {
                        stopDragOverviewSpeech()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    .help("Stop speech")
                }

                Spacer()

                // C button - Copy to clipboard
                Button {
                    copySummaryToClipboard()
                } label: {
                    Image(systemName: "c.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!canCopySummary)
                .help("Copy summary to clipboard")

                // Q&A Toggle Button
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        if showQAInterface {
                            resetQAState()
                        } else {
                            showQAInterface = true
                        }
                    }
                } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundColor(showQAInterface ? .accentColor : .secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!hasSummaryContent)
                .help("Ask a question about this overview")

                // Whiteboard Button
                Button {
                    generateWhiteboard()
                } label: {
                    if isGeneratingWhiteboard {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "square.grid.3x3.fill")
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!hasSummaryContent || isGeneratingWhiteboard)
                .help("Generate whiteboard summary")

                // Infographic Button
                Button {
                    generateInfographic()
                } label: {
                    if isGeneratingInfographic {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "chart.bar.doc.horizontal.fill")
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!hasSummaryContent || isGeneratingInfographic)
                .help("Generate infographic summary")

                if shouldShowExplicitWebAIControls {
                    Menu {
                        Button("Generate Overall Summary with \(appState.settings.selectedWebAIProvider.displayName)") {
                            appState.requestWebCombinedGlobalSummary(force: true)
                        }
                        .disabled(!hasSummaryContent)

                        Button("Send Whiteboard Prompt") {
                            sendWhiteboardToWebAI()
                        }
                        .disabled(!hasSummaryContent)

                        Button("Send Infographic Prompt") {
                            sendInfographicToWebAI()
                        }
                        .disabled(!hasSummaryContent)
                    } label: {
                        Image(systemName: "globe")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!hasSummaryContent)
                    .help("Web actions for \(appState.settings.selectedWebAIProvider.displayName)")
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .frame(width: 400)
        .background(
            ZStack {
                // Glass background with gradient
                RoundedRectangle(cornerRadius: 24)
                    .fill(.ultraThinMaterial)
                
                // Gradient overlay for depth
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.3),
                        Color.clear,
                        Color.black.opacity(0.1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .cornerRadius(24)
                .blendMode(.overlay)
                
                // Border stroke with gradient
                RoundedRectangle(cornerRadius: 24)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.5),
                                Color.white.opacity(0.1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 8)
        .offset(offset)
        .scaleEffect(isDragging ? 1.05 : 1.0)
        .animation(.spring(response: 0.3), value: isDragging)
        .sheet(isPresented: $showAnswerSheet) {
            NavigationStack {
                ScrollView {
                    Text(.init(qaAnswerText.isEmpty ? "No answer available." : qaAnswerText))
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle("Summary Answer")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            showAnswerSheet = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            copyToClipboard(qaAnswerText)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(32)
            #endif
        }
        .sheet(isPresented: $showWhiteboard) {
            if let data = whiteboardContent, let htmlString = String(data: data, encoding: .utf8) {
                WhiteboardView(
                    htmlContent: htmlString,
                    isPresented: $showWhiteboard,
                    onAskAI: { selection in
                        try await askAIResponse(for: selection, action: .standard)
                    }
                )
            }
        }
        .sheet(isPresented: $showInfographic) {
            InfographicView(
                htmlData: infographicContent,
                onAskAI: { selection in
                    try await askAIResponse(for: selection, action: .standard)
                }
            )
                .environmentObject(appState)
        }
        .sheet(isPresented: $showSelectionAskAIResponse) {
            AskAIResponseSheet(
                isLoading: isSelectionAskAIInFlight,
                response: selectionAskAIResponse,
                errorMessage: selectionAskAIError,
                onClose: { showSelectionAskAIResponse = false },
                onCopy: copySelectionAskAIResponse
            )
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 640, maxWidth: .infinity,
                   minHeight: 420, idealHeight: 520, maxHeight: .infinity)
            #endif
        }
        .overlay(alignment: .top) {
            if let errorMsg = whiteboardError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(errorMsg)
                        .font(.caption)
                    Spacer()
                    Button {
                        whiteboardError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if let errorMsg = infographicError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(errorMsg)
                        .font(.caption)
                    Spacer()
                    Button {
                        infographicError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: whiteboardError != nil)
        .animation(.easeInOut, value: infographicError != nil)
    }

    // MARK: - Clipboard Methods

    private var canCopySummary: Bool {
        !parsedSummaries.isEmpty || appState.aggregateSummaryText != nil
    }

    private var summaryClipboardText: String? {
        var sections: [String] = []
        let header = isRedditContent ? "Reddit Summary Overview" : "Article Summary Overview"
        sections.append(header)
        sections.append(String(repeating: "=", count: header.count))

        if let aggregate = appState.aggregateSummaryText, !aggregate.isEmpty {
            sections.append("\n## Overall Summary\n\(aggregate)")
        }

        if !parsedSummaries.isEmpty {
            sections.append("\n## Individual Summaries")
            for (index, item) in parsedSummaries.enumerated() {
                sections.append("\n\(index + 1). **\(item.subject)**")
                sections.append(item.summary)
            }
        }

        return sections.isEmpty ? nil : sections.joined(separator: "\n")
    }

    private func copySummaryToClipboard() {
        guard let text = summaryClipboardText else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func visualSummaryContent(perItemLimit: Int = 2000) -> String {
        parsedSummaries.enumerated().map { index, item in
            let title = item.subject.isEmpty ? "Item \(index + 1)" : item.subject
            let truncatedContent = String(item.summary.prefix(perItemLimit))
            return "[\(index + 1)] \"\(title)\"\n\(truncatedContent)\n"
        }.joined(separator: "\n---\n")
    }

    private func visualURLReferenceList() -> String {
        if isRedditContent {
            return parsedSummaries.enumerated().compactMap { index, item -> String? in
                guard let referenceId = item.referenceId else { return nil }
                if let post = appState.redditPostForGlobalSummaryReference(referenceId),
                   let postUrl = post.url {
                    return "[\(index + 1)] \"\(item.subject)\" → \(postUrl.absoluteString)"
                }
                return nil
            }.joined(separator: "\n")
        }

        return parsedSummaries.enumerated().compactMap { index, item -> String? in
            guard let referenceId = item.referenceId else { return nil }
            if let article = appState.articleForGlobalSummaryReference(referenceId),
               let articleUrl = article.url {
                return "[\(index + 1)] \"\(item.subject)\" → \(articleUrl.absoluteString)"
            }
            return nil
        }.joined(separator: "\n")
    }

    private func whiteboardPromptForWebAI(rankedCandidates: [RankedVisualCandidate]) -> String {
        makeWhiteboardPrompt(
            from: visualSummaryContent(),
            urlReference: visualURLReferenceList(),
            rankedCandidates: rankedCandidates,
            providerOverride: .webAI
        )
    }

    private func infographicPromptForWebAI(rankedCandidates: [RankedVisualCandidate]) -> String {
        makeInfographicPrompt(
            from: visualSummaryContent(),
            urlReference: visualURLReferenceList(),
            rankedCandidates: rankedCandidates,
            providerOverride: .webAI
        )
    }

    private func sendWhiteboardToWebAI() {
        guard !isGeneratingWhiteboard else { return }

        isGeneratingWhiteboard = true
        whiteboardError = nil

        let rankedCandidates = rankedVisualCandidates(limit: isRedditContent ? 5 : 0)
        generateWhiteboardWithWebAI(
            prompt: whiteboardPromptForWebAI(rankedCandidates: rankedCandidates),
            rankedCandidates: rankedCandidates
        )
    }

    private func sendInfographicToWebAI() {
        guard !isGeneratingInfographic else { return }

        isGeneratingInfographic = true
        infographicError = nil

        let rankedCandidates = rankedVisualCandidates(limit: isRedditContent ? 4 : 0)
        generateInfographicWithWebAI(
            prompt: infographicPromptForWebAI(rankedCandidates: rankedCandidates),
            rankedCandidates: rankedCandidates
        )
    }

    private func openItem(_ item: GlobalSummaryItem, isReddit: Bool) {
        guard let referenceId = item.referenceId else { return }
        if isReddit {
            if let post = appState.redditPostForGlobalSummaryReference(referenceId) {
                appState.setSelectedRedditPost(post)
            }
        } else {
            if let article = appState.articleForGlobalSummaryReference(referenceId) {
                appState.setSelectedArticle(article)
            }
        }
    }

    // MARK: - Q&A Methods
    
    private func askGlobalSummaryQuestion() {
        guard !isProcessingQA && !appState.isWaitingForGlobalQA else { return }
        let trimmed = qaQuestionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            qaInlineError = "Please enter a question first."
            return
        }
        
        qaInlineError = nil
        isProcessingQA = true
        qaAnswerText = ""
        
        appState.askQuestionAboutGlobalSummary(question: trimmed) { answer in
            DispatchQueue.main.async {
                self.qaAnswerText = formatAskAIResponseForDisplay(answer)
                self.isProcessingQA = false
                self.showAnswerSheet = true
            }
        }
    }

    private func askGlobalSummaryWebQuestion() {
        guard !isProcessingQA && !appState.isWaitingForGlobalQA else { return }
        let trimmed = qaQuestionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            qaInlineError = "Please enter a question first."
            return
        }

        qaInlineError = nil
        isProcessingQA = true
        qaAnswerText = ""

        appState.askWebQuestionAboutGlobalSummary(question: trimmed) { answer in
            DispatchQueue.main.async {
                self.qaAnswerText = formatAskAIResponseForDisplay(answer)
                self.isProcessingQA = false
                self.showAnswerSheet = true
            }
        }
    }
    
    private func resetQAState(keepInterface: Bool = false) {
        qaQuestionText = ""
        qaAnswerText = ""
        qaInlineError = nil
        isProcessingQA = false
        if !keepInterface {
            showQAInterface = false
        }
    }

    // MARK: - Ask AI Selection

    private func buildAskAIContext() -> String {
        var sections: [String] = []

        if let aggregate = appState.aggregateSummaryText, !aggregate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Overall Summary:\n\(aggregate)")
        }

        if !parsedSummaries.isEmpty {
            let items = parsedSummaries.enumerated().map { index, item in
                let title = item.subject.isEmpty ? "Item \(index + 1)" : item.subject
                return "[\(index + 1)] \(title)\n\(item.summary)"
            }
            sections.append(items.joined(separator: "\n\n"))
        }

        var context = sections.joined(separator: "\n\n")
        if context.count > 12000 {
            context = String(context.prefix(12000)) + "\n\n[Context truncated]"
        }
        return context
    }

    private func makeAskAISelectionPrompt(for selection: String) throws -> String {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "AskAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "No text selected."])
        }
        let context = buildAskAIContext()
        guard !context.isEmpty else {
            throw NSError(domain: "AskAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "No summary context available."])
        }
        return """
        Context:
        \(context)

        Question: What is said about \(trimmed)

        Respond in plain text only. Do not use Markdown symbols like #, *, _, `, or code fences.
        Use short paragraphs separated by a blank line when the answer has multiple ideas.
        """
    }

    private func performAskAI(prompt: String, action: AskAISelectionAction) async throws -> String {
        if action == .web {
            return try await appState.performWebAIRequestAsync(
                title: "Ask AI Web",
                prompt: prompt
            )
        }

        switch appState.settings.selectedSummaryProvider {
        case .appleLocal:
            return try await withCheckedThrowingContinuation { continuation in
                appState.performLocalWithGeminiFallbackPublic(prompt: prompt, taskName: "Ask AI") { response in
                    continuation.resume(returning: response)
                }
            }
        case .appleCloud:
            return try await withCheckedThrowingContinuation { continuation in
                appState.launchCloudRequest(for: prompt, type: .globalSummaryQA) { response in
                    continuation.resume(returning: response)
                }
            }
        case .applePCCGateway:
            return try await appState.performPCCGatewayRequestAsync(
                prompt: prompt,
                taskName: "Ask AI",
                isQA: true
            )
        case .mlxLocal, .coreAIMLXLocal:
            return try await withCheckedThrowingContinuation { continuation in
                appState.performMLXLocalSummaryPublic(prompt: prompt) { response in
                    continuation.resume(returning: response)
                }
            }
        case .webAI:
            return try await appState.performWebAIRequestAsync(
                title: "Ask AI",
                prompt: prompt
            )
        case .summarizeDaemon:
            return try await appState.performSummarizeRequestAsync(prompt: prompt, taskName: "Ask AI")
        case .gemini:
            return try await appState.summaryService.generateContentWithGemini(prompt: prompt)
        }
    }

    private func askAIResponse(for selection: String, action: AskAISelectionAction) async throws -> String {
        let prompt = try makeAskAISelectionPrompt(for: selection)
        let rawResponse = try await performAskAI(prompt: prompt, action: action)
        return formatAskAIResponseForDisplay(rawResponse)
    }

    private func askAIFromSummarySelection(_ selection: String, action: AskAISelectionAction) {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectionAskAITask?.cancel()
        isSelectionAskAIInFlight = true
        selectionAskAIResponse = nil
        selectionAskAIError = nil
        showSelectionAskAIResponse = true

        selectionAskAITask = Task {
            do {
                let response = try await askAIResponse(for: trimmed, action: action)
                await MainActor.run {
                    self.selectionAskAIResponse = formatAskAIResponseForDisplay(response)
                    self.isSelectionAskAIInFlight = false
                }
            } catch {
                await MainActor.run {
                    self.selectionAskAIError = error.localizedDescription
                    self.isSelectionAskAIInFlight = false
                }
            }
        }
    }

    private func copySelectionAskAIResponse() {
        guard let selectionAskAIResponse, !selectionAskAIResponse.isEmpty else { return }
        #if os(iOS)
        UIPasteboard.general.string = selectionAskAIResponse
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectionAskAIResponse, forType: .string)
        #endif
    }

    // MARK: - Whiteboard Generation

    private func generateWhiteboard() {
        guard !isGeneratingWhiteboard else { return }

        isGeneratingWhiteboard = true
        whiteboardError = nil

        let selectedProvider = appState.settings.selectedSummaryProvider
        let rankedCandidates = rankedVisualCandidates(limit: isRedditContent ? 5 : 0)

        // Build content from parsed summaries
        let content = parsedSummaries.enumerated().map { index, item in
            let title = item.subject.isEmpty ? "Item \(index + 1)" : item.subject
            let truncatedContent = String(item.summary.prefix(2000))
            return "[\(index + 1)] \"\(title)\"\n\(truncatedContent)\n"
        }.joined(separator: "\n---\n")

        // Build URL reference list for Reddit posts or Articles
        var urlReferenceList = ""
        if isRedditContent {
            urlReferenceList = parsedSummaries.enumerated().compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                if let post = appState.redditPostForGlobalSummaryReference(referenceId),
                   let postUrl = post.url {
                    return "[\(index + 1)] \"\(item.subject)\" -> \(postUrl.absoluteString)"
                }
                return nil
            }.joined(separator: "\n")
        } else {
            // Build URL reference list for articles
            urlReferenceList = parsedSummaries.enumerated().compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                if let article = appState.articleForGlobalSummaryReference(referenceId),
                   let articleUrl = article.url {
                    return "[\(index + 1)] \"\(item.subject)\" -> \(articleUrl.absoluteString)"
                }
                return nil
            }.joined(separator: "\n")
        }

        let promptProvider: AppSettings.SummaryProvider =
            (selectedProvider == .appleLocal || selectedProvider == .appleCloud || selectedProvider == .applePCCGateway) ? .mlxLocal : selectedProvider

        let prompt = makeWhiteboardPrompt(
            from: content,
            urlReference: urlReferenceList,
            rankedCandidates: rankedCandidates,
            providerOverride: promptProvider
        )

        // Route to appropriate provider
        switch selectedProvider {
        case .mlxLocal, .coreAIMLXLocal:
            // Use actual MLX model for structured JSON
            generateWhiteboardWithMLXStructured(prompt: prompt, rankedCandidates: rankedCandidates)

        case .appleLocal:
            // Use Apple Local (Foundation Models)
            generateWhiteboardWithMLXLocal(prompt: prompt, rankedCandidates: rankedCandidates)

        case .appleCloud:
            generateWhiteboardWithAppleCloud(prompt: prompt, rankedCandidates: rankedCandidates)

        case .applePCCGateway:
            generateWhiteboardWithPCCGateway(prompt: prompt, rankedCandidates: rankedCandidates)

        case .gemini:
            // Use Gemini API directly
            generateWhiteboardWithGemini(prompt: prompt, rankedCandidates: rankedCandidates)

        case .webAI:
            generateWhiteboardWithWebAI(prompt: prompt, rankedCandidates: rankedCandidates)
        case .summarizeDaemon:
            generateWhiteboardWithSummarize(prompt: prompt, rankedCandidates: rankedCandidates)
        }
    }

    private func generateWhiteboardWithGemini(prompt: String, rankedCandidates: [RankedVisualCandidate]) {
        Task {
            do {
                let apiKey = appState.settings.geminiApiKey
                guard !apiKey.isEmpty else {
                    await MainActor.run {
                        self.whiteboardError = "Gemini API key not configured"
                        self.isGeneratingWhiteboard = false
                    }
                    return
                }

                let response = try await appState.summaryService.generateContentWithGemini(prompt: prompt)

                guard let payload = parseWhiteboardPayload(from: response, rankedCandidates: rankedCandidates) else {
                    await MainActor.run {
                        self.whiteboardError = "Failed to parse whiteboard data"
                        self.isGeneratingWhiteboard = false
                    }
                    return
                }

                let html = buildWhiteboardHTML(from: payload)

                guard let htmlData = html.data(using: .utf8) else {
                    await MainActor.run {
                        self.whiteboardError = "Failed to generate whiteboard"
                        self.isGeneratingWhiteboard = false
                    }
                    return
                }

                await MainActor.run {
                    self.whiteboardContent = htmlData
                    self.isGeneratingWhiteboard = false
                    self.showWhiteboard = true
                }

            } catch {
                await MainActor.run {
                    self.whiteboardError = "Error: \(error.localizedDescription)"
                    self.isGeneratingWhiteboard = false
                }
            }
        }
    }

    private func generateWhiteboardWithWebAI(prompt: String, rankedCandidates: [RankedVisualCandidate]) {
        Task {
            do {
                let rawResponse = try await appState.performWebAIRequestAsync(
                    title: "Whiteboard",
                    prompt: prompt,
                    responseFormat: .strictJSON
                )
                let candidate = sanitizeStructuredJSONCandidate(rawResponse)
                guard let data = candidate.data(using: .utf8) else {
                    throw NSError(domain: "Whiteboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert response to data."])
                }

                let payload: WhiteboardPayload
                do {
                    payload = try parseWhiteboardPayloadFromData(data, rankedCandidates: rankedCandidates)
                } catch {
                    let repaired = try await repairInvalidJSONUsingMLX(kind: .whiteboard, rawOutput: rawResponse)
                    payload = try parseWhiteboardPayloadFromData(repaired, rankedCandidates: rankedCandidates)
                }

                let html = buildWhiteboardHTML(from: payload)
                guard let htmlData = html.data(using: .utf8) else {
                    throw NSError(domain: "Whiteboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate whiteboard HTML"])
                }

                await MainActor.run {
                    self.whiteboardContent = htmlData
                    self.isGeneratingWhiteboard = false
                    self.showWhiteboard = true
                }
            } catch {
                await MainActor.run {
                    self.whiteboardError = "Whiteboard failed: \(error.localizedDescription)"
                    self.isGeneratingWhiteboard = false
                }
            }
        }
    }

    private func generateWhiteboardWithSummarize(prompt: String, rankedCandidates: [RankedVisualCandidate]) {
        Task {
            do {
                let response = try await appState.performSummarizeRequestAsync(prompt: prompt, taskName: "Whiteboard")

                guard let payload = parseWhiteboardPayload(from: response, rankedCandidates: rankedCandidates) else {
                    await MainActor.run {
                        self.whiteboardError = "Failed to parse whiteboard data"
                        self.isGeneratingWhiteboard = false
                    }
                    return
                }

                let html = buildWhiteboardHTML(from: payload)
                guard let htmlData = html.data(using: .utf8) else {
                    await MainActor.run {
                        self.whiteboardError = "Failed to generate whiteboard"
                        self.isGeneratingWhiteboard = false
                    }
                    return
                }

                await MainActor.run {
                    self.whiteboardContent = htmlData
                    self.isGeneratingWhiteboard = false
                    self.showWhiteboard = true
                }
            } catch {
                await MainActor.run {
                    self.whiteboardError = "Error: \(error.localizedDescription)"
                    self.isGeneratingWhiteboard = false
                }
            }
        }
    }

    private func generateWhiteboardWithPCCGateway(prompt: String, rankedCandidates: [RankedVisualCandidate]) {
        Task {
            do {
                let response = try await appState.performPCCGatewayRequestAsync(prompt: prompt, taskName: "Whiteboard")

                guard let payload = parseWhiteboardPayload(from: response, rankedCandidates: rankedCandidates) else {
                    await MainActor.run {
                        self.whiteboardError = "Failed to parse whiteboard data"
                        self.isGeneratingWhiteboard = false
                    }
                    return
                }

                let html = buildWhiteboardHTML(from: payload)
                guard let htmlData = html.data(using: .utf8) else {
                    await MainActor.run {
                        self.whiteboardError = "Failed to generate whiteboard"
                        self.isGeneratingWhiteboard = false
                    }
                    return
                }

                await MainActor.run {
                    self.whiteboardContent = htmlData
                    self.isGeneratingWhiteboard = false
                    self.showWhiteboard = true
                }
            } catch {
                await MainActor.run {
                    self.whiteboardError = "Error: \(error.localizedDescription)"
                    self.isGeneratingWhiteboard = false
                }
            }
        }
    }

    private func generateWhiteboardWithAppleCloud(prompt: String, rankedCandidates: [RankedVisualCandidate]) {
        Task {
            do {
                let rawResponse = try await withCheckedThrowingContinuation { continuation in
                    appState.launchCloudRequest(for: prompt, type: .globalSummaryQA) { response in
                        continuation.resume(returning: response)
                    }
                }

                let candidate = sanitizeStructuredJSONCandidate(rawResponse)
                guard let data = candidate.data(using: .utf8) else {
                    throw NSError(domain: "Whiteboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert response to data."])
                }

                let payload: WhiteboardPayload
                do {
                    payload = try parseWhiteboardPayloadFromData(data, rankedCandidates: rankedCandidates)
                } catch {
                    let repaired = try await repairInvalidJSONUsingMLX(kind: .whiteboard, rawOutput: rawResponse)
                    payload = try parseWhiteboardPayloadFromData(repaired, rankedCandidates: rankedCandidates)
                }

                let html = buildWhiteboardHTML(from: payload)
                guard let htmlData = html.data(using: .utf8) else {
                    throw NSError(domain: "Whiteboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate whiteboard HTML"])
                }

                await MainActor.run {
                    self.whiteboardContent = htmlData
                    self.isGeneratingWhiteboard = false
                    self.showWhiteboard = true
                }
            } catch {
                await MainActor.run {
                    self.whiteboardError = "Whiteboard failed: \(error.localizedDescription)"
                    self.isGeneratingWhiteboard = false
                }
            }
        }
    }

    private func generateWhiteboardWithMLXLocal(prompt: String, rankedCandidates: [RankedVisualCandidate]) {
        // MLX Local redirects to Apple Local for structured JSON output
        // (MLX struggles with strict JSON formatting)
        Task {
            do {
                // MLX-specific: Clear GPU cache to prevent stale context from previous generations
                await MLXLocalService.shared.clearTransientCache()
                print("🔀 [Whiteboard] MLX/AppleLocal/AppleCloud selected - redirecting to Apple Local for JSON generation")

                // Route to Apple Local for structured JSON generation
                let rawResponse: String
                if #available(macOS 15.2, *) {
                    rawResponse = try await withCheckedThrowingContinuation { continuation in
                        appState.performLocalWithGeminiFallbackPublic(prompt: prompt, taskName: "Whiteboard") { result in
                            continuation.resume(returning: result)
                        }
                    }
                } else {
                    // Fall back to Gemini if Apple Local not available
                    rawResponse = try await appState.summaryService.generateContentWithGemini(prompt: prompt)
                }

                guard let payload = parseWhiteboardPayload(from: rawResponse, rankedCandidates: rankedCandidates) else {
                    await MainActor.run {
                        self.whiteboardError = "Failed to parse whiteboard data"
                        self.isGeneratingWhiteboard = false
                    }
                    return
                }

                let html = buildWhiteboardHTML(from: payload)

                guard let htmlData = html.data(using: .utf8) else {
                    await MainActor.run {
                        self.whiteboardError = "Failed to generate whiteboard"
                        self.isGeneratingWhiteboard = false
                    }
                    return
                }

                await MainActor.run {
                    self.whiteboardContent = htmlData
                    self.isGeneratingWhiteboard = false
                    self.showWhiteboard = true
                }

            } catch {
                await MainActor.run {
                    self.whiteboardError = "Error: \(error.localizedDescription)"
                    self.isGeneratingWhiteboard = false
                }
            }
        }
    }

    // MARK: - MLX Structured JSON Generation
    
    private func generateStructuredJSONWithMLX(prompt: String) async throws -> String {
        let modelID = appState.settings.mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            throw NSError(
                domain: "MLXStructuredJSON",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "MLX model id is missing. Set it in Settings → Summary Provider."]
            )
        }

        let configuredMaxOutput = max(1, appState.settings.mlxMaxOutputTokens)
        // Structured JSON often needs more room; enforce a practical minimum while respecting user settings.
        let maxOutputTokens = max(900, configuredMaxOutput)
        let maxContextTokens = appState.settings.mlxMaxContextTokens > 0 ? appState.settings.mlxMaxContextTokens : 4096

        await MLXLocalService.shared.clearTransientCache()
        return try await MLXLocalService.shared.generateText(
            prompt: prompt,
            modelID: modelID,
            maxOutputTokens: maxOutputTokens,
            maxContextTokens: maxContextTokens
        )
    }

    private func sanitizeStructuredJSONCandidate(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove markdown fences
        cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
        cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        // Extract JSON object
        if let firstBrace = cleaned.firstIndex(of: "{"),
           let lastBrace = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[firstBrace...lastBrace])
        }
        return cleaned
    }

    private func repairInvalidJSONUsingMLX(kind: MLXStructuredJSONKind, rawOutput: String) async throws -> Data {
        let clipped = String(rawOutput.prefix(12_000))
        let keys: String
        let extraRules: String
        switch kind {
        case .infographic:
            keys = #"title,subtitle,focus,palette,statTiles,barSections,sentiment,sentimentBand,majorThemes,themes,keyTopics,notableTrends,takeaway,topPosts"#
            extraRules = """
            - barSections "value" must be a plain integer (no quotes, no %, no decimals)
            - sentiment values (positive, neutral, negative) must be plain integers
            - statTiles "value" should be a string
            """
        case .whiteboard:
            keys = #"sessionTitle,sessionContext,whatWeKnow,openQuestions,takeaways,painPoints,hotTakes,connections,ideasToExplore,keyPosts,bottomLine"#
            extraRules = ""
        }

        let repairPrompt = """
        You are a strict JSON fixer. Output ONLY the fixed JSON, nothing else.

        Convert the following model output into a single valid JSON object.
        - Use double quotes for all keys and strings
        - No trailing commas
        - No markdown code fences
        - No text before or after the JSON
        - Only use these top-level keys: \(keys)
        \(extraRules)
        - Keep the JSON short; shorten strings rather than dropping keys.

        Model output to fix:
        \(clipped)
        """

        let repaired = try await generateStructuredJSONWithMLX(prompt: repairPrompt)
        guard let data = sanitizeStructuredJSONCandidate(repaired).data(using: .utf8) else {
            throw NSError(domain: "MLXStructuredJSON", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not convert repaired JSON to data."])
        }
        return data
    }

    private func generateWhiteboardWithMLXStructured(prompt: String, rankedCandidates: [RankedVisualCandidate]) {
        Task {
            do {
                let raw = try await generateStructuredJSONWithMLX(prompt: prompt)
                let candidate = sanitizeStructuredJSONCandidate(raw)
                guard let data = candidate.data(using: .utf8) else {
                    throw NSError(domain: "Whiteboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert response to data."])
                }

                let payload: WhiteboardPayload
                do {
                    payload = try parseWhiteboardPayloadFromData(data, rankedCandidates: rankedCandidates)
                } catch {
                    let repaired = try await repairInvalidJSONUsingMLX(kind: .whiteboard, rawOutput: raw)
                    payload = try parseWhiteboardPayloadFromData(repaired, rankedCandidates: rankedCandidates)
                }

                let html = buildWhiteboardHTML(from: payload)
                guard let htmlData = html.data(using: .utf8) else {
                    throw NSError(domain: "Whiteboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate whiteboard HTML"])
                }

                await MainActor.run {
                    self.whiteboardContent = htmlData
                    self.isGeneratingWhiteboard = false
                    self.showWhiteboard = true
                }
            } catch {
                await MainActor.run {
                    self.whiteboardError = "Whiteboard failed: \(error.localizedDescription)"
                    self.isGeneratingWhiteboard = false
                }
            }
        }
    }

    private func parseWhiteboardPayloadFromData(_ data: Data, rankedCandidates: [RankedVisualCandidate]) throws -> WhiteboardPayload {
        let json = try MLXJSONRepairUtils.parseLLMJSONDictionary(from: data, domain: "Whiteboard")
        return WhiteboardPayload(dictionary: json, isReddit: isRedditContent, rankedCandidates: rankedCandidates)
    }

    private func makeWhiteboardPrompt(
        from content: String,
        urlReference: String,
        rankedCandidates: [RankedVisualCandidate],
        providerOverride: AppSettings.SummaryProvider? = nil
    ) -> String {
        let selectedProvider = providerOverride ?? appState.settings.selectedSummaryProvider
        let trimmed = String(content.prefix(2000))
        let rankingSection = buildRankedPostSection(
            header: "KEY POST RANKING",
            selectionField: "keyPosts",
            candidates: rankedCandidates,
            limit: 5
        )

        // Contextual takeaways section based on content type
        let takeawaysSection: String
        let takeawaysGuideline: String

        if isRedditContent {
            takeawaysSection = """
              "takeaways": [
                { "insight": "What the community recommends or suggests (≤80 chars)", "source": "Community consensus/Highly upvoted/Power user/Experienced member" },
                ... 3-5 items
              ],
            """
            takeawaysGuideline = "- Takeaways should capture what the Reddit community recommends, suggests, or advises. Source indicates credibility (highly upvoted, experienced user, community consensus)."
        } else {
            takeawaysSection = """
              "takeaways": [
                { "insight": "Key takeaway or actionable insight from the article (≤80 chars)", "source": "Expert opinion/Research finding/Industry trend/Data-backed" },
                ... 3-5 items
              ],
            """
            takeawaysGuideline = "- Takeaways should capture the most important insights readers should remember. Source indicates the type of insight (expert opinion, research finding, trend)."
        }

        if selectedProvider == .mlxLocal || selectedProvider == .coreAIMLXLocal {
            return """
            READ THIS CONTENT FIRST - you must extract information from it:

            === \(isRedditContent ? "REDDIT" : "ARTICLE") CONTENT TO ANALYZE ===
            \(trimmed)
            === END CONTENT ===

            === POST/ARTICLE URLs (use these exact URLs for keyPosts) ===
            \(urlReference)
            === END URLs ===

            \(rankingSection)

            Create whiteboard brainstorm notes as JSON.

            OUTPUT RULES:
            - Output ONLY one valid JSON object (no markdown, no code fences, no commentary)
            - Use double quotes for all keys and strings
            - No trailing commas
            - Replace ALL "..." placeholders with real content grounded in the input
            - Keep strings concise (roughly: titles ≤40 chars, bullets ≤90 chars)

            JSON structure to fill:
            {
              "sessionTitle": "...",
              "sessionContext": "\(isRedditContent ? "r/subreddit • topic focus" : "Articles • topic focus")",
              "whatWeKnow": ["...", "...", "...", "..."],
              "openQuestions": ["...", "...", "..."],
            \(takeawaysSection)
              "painPoints": [
                { "issue": "...", "severity": "high" },
                { "issue": "...", "severity": "medium" }
              ],
              "hotTakes": [
                { "quote": "...", "context": "..." },
                { "quote": "...", "context": "..." }
              ],
              "connections": ["...", "..."],
              "ideasToExplore": ["...", "..."],
              "keyPosts": [
                { "title": "...", "url": "EXACT_URL_FROM_REFERENCE_LIST", "why": "..." },
                { "title": "...", "url": "EXACT_URL_FROM_REFERENCE_LIST", "why": "..." },
                { "title": "...", "url": "EXACT_URL_FROM_REFERENCE_LIST", "why": "..." },
                { "title": "...", "url": "EXACT_URL_FROM_REFERENCE_LIST", "why": "..." },
                { "title": "...", "url": "EXACT_URL_FROM_REFERENCE_LIST", "why": "..." }
              ],
              "bottomLine": "..."
            }

            IMPORTANT KEY POST RULES:
            - `keyPosts` must come from the ranked list only.
            - Preserve the ranking order exactly.
            - Do not substitute different posts; write only the short `why` text for each ranked post.

            **CRITICAL FOR keyPosts URLs:**
            You MUST use ONLY the exact URLs from the POST REFERENCE LIST below. Do NOT make up URLs.
            Copy the URL exactly as shown after the → arrow. If you can't find a matching post, leave the url field empty "".

            === POST REFERENCE LIST (use these exact URLs) ===
            \(urlReference)
            === END REFERENCE LIST ===

            Content:
            \(trimmed)
            """
        }

        return """
        You are creating brainstorm notes on a whiteboard after reviewing \(isRedditContent ? "Reddit discussions" : "articles"). This is NOT a polished infographic - it's a working document capturing insights, questions, and key takeaways.

        Output ONLY compact JSON (no markdown, no fences):

        {
          "sessionTitle": "What's being discussed (≤40 chars)",
          "sessionContext": "\(isRedditContent ? "r/subreddit • [topic focus]" : "Articles • [topic focus]")",
          "whatWeKnow": [
            "Key fact or finding from the \(isRedditContent ? "discussions" : "articles") (≤80 chars each)",
            ... 4-6 items
          ],
          "openQuestions": [
            "Question that came up or remains unanswered (≤70 chars each)",
            ... 3-5 items
          ],
        \(takeawaysSection)
          "painPoints": [
            { "issue": "\(isRedditContent ? "Problem or frustration users mention" : "Challenge or concern raised in the articles")", "severity": "high/medium/low" },
            ... 3-4 items
          ],
          "hotTakes": [
            { "quote": "\(isRedditContent ? "Interesting or controversial opinion from comments (actual quote)" : "Notable quote or bold claim from the article")", "context": "brief context" },
            ... 2-4 items
          ],
          "connections": [
            "How X relates to Y - cause/effect or pattern (≤60 chars)",
            ... 2-4 items
          ],
          "ideasToExplore": [
            "\(isRedditContent ? "Topic the community wants to explore further" : "Area worth investigating based on the articles") (≤60 chars)",
            ... 2-4 items
          ],
          "keyPosts": [
            { "title": "\(isRedditContent ? "Post" : "Article") title (≤50 chars)", "url": "EXACT_URL_FROM_REFERENCE_LIST", "why": "why it matters (≤30 chars)" },
            ... 3-5 items
          ],
          "bottomLine": "The 'so what' - one sentence takeaway (≤100 chars)"
        }

        IMPORTANT GUIDELINES:
        - This is brainstorm notes, NOT a formal summary. Use informal language, abbreviations, shorthand.
        \(takeawaysGuideline)
        - Hot takes should be ACTUAL quotes or paraphrases from the content, attributed.
        - Connections should show relationships: "X causes Y", "When A happens, B follows", etc.
        - Pain points need severity levels to prioritize.
        - Open questions are things \(isRedditContent ? "the community is debating" : "left unanswered") or unclear about.
        - Bottom line should be the key insight someone should take away.
        \(rankingSection)
        \(rankingSection.isEmpty ? "" : """

        IMPORTANT KEY POST RULES:
        - `keyPosts` must come from the ranked list only.
        - Preserve the ranking order exactly.
        - Do not substitute different posts; write only the short `why` text for each ranked post.
        """)

        **CRITICAL FOR keyPosts URLs:**
        You MUST use ONLY the exact URLs from the POST REFERENCE LIST below. Do NOT make up URLs.
        Copy the URL exactly as shown after the → arrow. If you can't find a matching post, leave the url field empty "".

        === POST REFERENCE LIST (use these exact URLs) ===
        \(urlReference)
        === END REFERENCE LIST ===

        Content:
        \(trimmed)
        """
    }

    private func parseWhiteboardPayload(from text: String, rankedCandidates: [RankedVisualCandidate]) -> WhiteboardPayload? {
        var rawString = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if rawString.hasPrefix("```") {
            rawString = rawString.replacingOccurrences(of: "```json", with: "")
            rawString = rawString.replacingOccurrences(of: "```", with: "")
        }

        if let firstBrace = rawString.firstIndex(of: "{"),
           let lastBrace = rawString.lastIndex(of: "}") {
            rawString = String(rawString[firstBrace...lastBrace])
        }

        guard let jsonData = rawString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] else {
            return nil
        }

        return WhiteboardPayload(dictionary: json, isReddit: isRedditContent, rankedCandidates: rankedCandidates)
    }

    private func normalizeRedditPermalink(_ permalink: String) -> String {
        let trimmed = permalink.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return ""
        }

        // Already a full URL (external or Reddit) - return as-is
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            return trimmed
        }

        // Reddit relative path - add domain
        let cleaned = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        return "https://reddit.com\(cleaned)"
    }

    // MARK: - Ranked Visual Posts

    private func rankedVisualCandidates(limit: Int) -> [RankedVisualCandidate] {
        guard isRedditContent, limit > 0 else { return [] }

        return Array(rankedVisualCandidates().prefix(limit))
    }

    private func rankedVisualCandidates() -> [RankedVisualCandidate] {
        guard isRedditContent else { return [] }

        var postsByID: [String: RedditPost] = [:]
        for item in parsedSummaries {
            guard let referenceId = item.referenceId,
                  let post = appState.redditPostForGlobalSummaryReference(referenceId),
                  postsByID[post.id] == nil else {
                continue
            }
            postsByID[post.id] = post
        }

        let now = Date().timeIntervalSince1970
        let summaries = Array(parsedSummaries.enumerated())

        let matchedPosts = summaries.compactMap { summaryEntry -> RedditPost? in
            guard let referenceId = summaryEntry.element.referenceId else { return nil }
            return postsByID[referenceId]
        }

        let maxLogUps = max(matchedPosts.map { log1p(Double(max(0, $0.score))) }.max() ?? 0, 1)
        let maxLogComments = max(matchedPosts.map { log1p(Double(max(0, $0.commentCount))) }.max() ?? 0, 1)

        let candidates: [RankedVisualCandidate] = summaries.map { summaryEntry in
            let batchOrder = summaryEntry.offset
            let summary = summaryEntry.element
            let matchedPost = summary.referenceId.flatMap { postsByID[$0] }

            let titleSource = summary.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = !titleSource.isEmpty ? titleSource : (matchedPost?.title ?? "Post \(batchOrder + 1)")
            let url = matchedPost?.url?.absoluteString ?? ""
            let ups: Int
            let numComments: Int
            let createdUTC: TimeInterval
            let ageHours: Double
            let upsNorm: Double
            let commentsNorm: Double
            let recencyNorm: Double
            let score: Double

            if let matchedPost {
                ups = matchedPost.score
                numComments = matchedPost.commentCount
                createdUTC = matchedPost.publishDate.timeIntervalSince1970
                ageHours = max(0, (now - createdUTC) / 3600)
                upsNorm = log1p(Double(max(0, matchedPost.score))) / maxLogUps
                commentsNorm = log1p(Double(max(0, matchedPost.commentCount))) / maxLogComments
                recencyNorm = max(0, 1 - min(ageHours, 168) / 168)
                score = 0.50 * upsNorm + 0.30 * commentsNorm + 0.20 * recencyNorm
            } else {
                ups = 0
                numComments = 0
                createdUTC = 0
                ageHours = 168
                upsNorm = 0
                commentsNorm = 0
                recencyNorm = 0
                score = 0
            }

            return RankedVisualCandidate(
                title: title,
                url: url,
                ups: ups,
                numComments: numComments,
                createdUTC: createdUTC,
                ageHours: ageHours,
                score: score,
                batchOrder: batchOrder
            )
        }

        return candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.ups != $1.ups { return $0.ups > $1.ups }
            if $0.numComments != $1.numComments { return $0.numComments > $1.numComments }
            if $0.createdUTC != $1.createdUTC { return $0.createdUTC > $1.createdUTC }
            return $0.batchOrder < $1.batchOrder
        }
    }

    private func promptSafeString(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func promptFormattedDouble(_ value: Double, fractionDigits: Int) -> String {
        String(format: "%.\(fractionDigits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func buildRankedPostSection(
        header: String,
        selectionField: String,
        candidates: [RankedVisualCandidate],
        limit: Int
    ) -> String {
        guard !candidates.isEmpty else { return "" }

        let lines = candidates.prefix(limit).enumerated().map { index, candidate in
            "[\(index + 1)] title=\"\(promptSafeString(candidate.title))\" | url=\"\(promptSafeString(candidate.url))\" | ups=\(candidate.ups) | num_comments=\(candidate.numComments) | ageHours=\(promptFormattedDouble(candidate.ageHours, fractionDigits: 1)) | score=\(promptFormattedDouble(candidate.score, fractionDigits: 3))"
        }.joined(separator: "\n")

        return """
        === \(header) ===
        - Use only this ranked list for \(selectionField), in the exact order shown.
        - Your job is to write the short `why` text only, not to choose different posts or reorder them.
        - If fewer than \(limit) ranked items are available, use only the available ranked items.
        \(lines)
        === END \(header) ===
        """
    }

    // MARK: - Infographic Generation

    private func generateInfographic() {
        guard !isGeneratingInfographic else { return }

        isGeneratingInfographic = true
        infographicError = nil

        let selectedProvider = appState.settings.selectedSummaryProvider
        let rankedCandidates = rankedVisualCandidates(limit: isRedditContent ? 4 : 0)

        // Build content from parsed summaries
        let perItemLimit = (selectedProvider == .appleCloud || selectedProvider == .applePCCGateway) ? 600 : 2000
        let content = parsedSummaries.enumerated().map { index, item in
            let title = item.subject.isEmpty ? "Item \(index + 1)" : item.subject
            let truncatedContent = String(item.summary.prefix(perItemLimit))
            return "[\(index + 1)] \"\(title)\"\n\(truncatedContent)\n"
        }.joined(separator: "\n---\n")

        // Build URL reference list for posts or articles
        var urlReferenceList = ""
        if isRedditContent {
            urlReferenceList = parsedSummaries.enumerated().compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                if let post = appState.redditPostForGlobalSummaryReference(referenceId),
                   let postUrl = post.url {
                    return "[\(index + 1)] \"\(item.subject)\" → \(postUrl.absoluteString)"
                }
                return nil
            }.joined(separator: "\n")
        } else {
            urlReferenceList = parsedSummaries.enumerated().compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                if let article = appState.articleForGlobalSummaryReference(referenceId),
                   let articleUrl = article.url {
                    return "[\(index + 1)] \"\(item.subject)\" → \(articleUrl.absoluteString)"
                }
                return nil
            }.joined(separator: "\n")
        }

        let promptProvider: AppSettings.SummaryProvider =
            (selectedProvider == .appleLocal || selectedProvider == .appleCloud || selectedProvider == .applePCCGateway) ? .mlxLocal : selectedProvider

        let prompt = makeInfographicPrompt(
            from: content,
            urlReference: urlReferenceList,
            rankedCandidates: rankedCandidates,
            providerOverride: promptProvider
        )

        // Route to appropriate provider - same pattern as whiteboard
        switch selectedProvider {
        case .mlxLocal, .coreAIMLXLocal:
            // Use actual MLX model for structured JSON
            generateInfographicWithMLXStructured(prompt: prompt, rankedCandidates: rankedCandidates)

        case .appleLocal, .appleCloud:
            // Use Apple Local (Foundation Models)
            generateInfographicWithMLXLocal(prompt: prompt, rankedCandidates: rankedCandidates)

        case .applePCCGateway:
            generateInfographicWithPCCGateway(prompt: prompt, rankedCandidates: rankedCandidates)

        case .gemini:
            generateInfographicWithGemini(prompt: prompt, rankedCandidates: rankedCandidates)

        case .webAI:
            generateInfographicWithWebAI(prompt: prompt, rankedCandidates: rankedCandidates)
        case .summarizeDaemon:
            generateInfographicWithSummarize(prompt: prompt, rankedCandidates: rankedCandidates)
        }
    }

    private func generateInfographicWithGemini(prompt: String, rankedCandidates: [RankedVisualCandidate]) {
        Task {
            do {
                let apiKey = appState.settings.geminiApiKey
                guard !apiKey.isEmpty else {
                    await MainActor.run {
                        self.infographicError = "Gemini API key not configured"
                        self.isGeneratingInfographic = false
                    }
                    return
                }

                let response = try await appState.summaryService.generateContentWithGemini(prompt: prompt)

                guard let payload = parseInfographicPayload(from: response, rankedCandidates: rankedCandidates) else {
                    await MainActor.run {
                        self.infographicError = "Failed to parse infographic data"
                        self.isGeneratingInfographic = false
                    }
                    return
                }

                let html = buildInfographicHTML(from: payload)
                let safe = sanitizeInfographicHTML(html)

                guard let htmlData = safe.data(using: .utf8) else {
                    await MainActor.run {
                        self.infographicError = "Failed to generate infographic"
                        self.isGeneratingInfographic = false
                    }
                    return
                }

                await MainActor.run {
                    self.infographicContent = htmlData
                    self.isGeneratingInfographic = false
                    self.showInfographic = true
                }

            } catch {
                await MainActor.run {
                    self.infographicError = "Error: \(error.localizedDescription)"
                    self.isGeneratingInfographic = false
                }
            }
        }
    }

    private func generateInfographicWithSummarize(prompt: String, rankedCandidates: [RankedVisualCandidate]) {
        Task {
            do {
                let response = try await appState.performSummarizeRequestAsync(prompt: prompt, taskName: "Infographic")

                guard let payload = parseInfographicPayload(from: response, rankedCandidates: rankedCandidates) else {
                    await MainActor.run {
                        self.infographicError = "Failed to parse infographic data"
                        self.isGeneratingInfographic = false
                    }
                    return
                }

                let html = buildInfographicHTML(from: payload)
                let safe = sanitizeInfographicHTML(html)

                guard let htmlData = safe.data(using: .utf8) else {
                    await MainActor.run {
                        self.infographicError = "Failed to generate infographic"
                        self.isGeneratingInfographic = false
                    }
                    return
                }

                await MainActor.run {
                    self.infographicContent = htmlData
                    self.isGeneratingInfographic = false
                    self.showInfographic = true
                }
            } catch {
                await MainActor.run {
                    self.infographicError = "Error: \(error.localizedDescription)"
                    self.isGeneratingInfographic = false
                }
            }
        }
    }

    private func generateInfographicWithPCCGateway(prompt: String, rankedCandidates: [RankedVisualCandidate]) {
        Task {
            do {
                let response = try await appState.performPCCGatewayRequestAsync(prompt: prompt, taskName: "Infographic")

                guard let payload = parseInfographicPayload(from: response, rankedCandidates: rankedCandidates) else {
                    await MainActor.run {
                        self.infographicError = "Failed to parse infographic data"
                        self.isGeneratingInfographic = false
                    }
                    return
                }

                let html = buildInfographicHTML(from: payload)
                let safe = sanitizeInfographicHTML(html)

                guard let htmlData = safe.data(using: .utf8) else {
                    await MainActor.run {
                        self.infographicError = "Failed to generate infographic"
                        self.isGeneratingInfographic = false
                    }
                    return
                }

                await MainActor.run {
                    self.infographicContent = htmlData
                    self.isGeneratingInfographic = false
                    self.showInfographic = true
                }
            } catch {
                await MainActor.run {
                    self.infographicError = "Error: \(error.localizedDescription)"
                    self.isGeneratingInfographic = false
                }
            }
        }
    }

    private func generateInfographicWithWebAI(prompt: String, rankedCandidates: [RankedVisualCandidate]) {
        Task {
            do {
                let rawResponse = try await appState.performWebAIRequestAsync(
                    title: "Infographic",
                    prompt: prompt,
                    responseFormat: .strictJSON
                )
                let candidate = sanitizeStructuredJSONCandidate(rawResponse)
                guard let data = candidate.data(using: .utf8) else {
                    throw NSError(domain: "Infographic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert response to data."])
                }

                let payload: InfographicPayload
                do {
                    payload = try parseInfographicPayloadFromData(data, rankedCandidates: rankedCandidates)
                } catch {
                    let repaired = try await repairInvalidJSONUsingMLX(kind: .infographic, rawOutput: rawResponse)
                    payload = try parseInfographicPayloadFromData(repaired, rankedCandidates: rankedCandidates)
                }

                let html = buildInfographicHTML(from: payload)
                let safe = sanitizeInfographicHTML(html)
                guard let htmlData = safe.data(using: .utf8) else {
                    throw NSError(domain: "Infographic", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate infographic HTML"])
                }

                await MainActor.run {
                    self.infographicContent = htmlData
                    self.isGeneratingInfographic = false
                    self.showInfographic = true
                }
            } catch {
                await MainActor.run {
                    self.infographicError = "Infographic failed: \(error.localizedDescription)"
                    self.isGeneratingInfographic = false
                }
            }
        }
    }

    private func generateInfographicWithMLXLocal(prompt: String, rankedCandidates: [RankedVisualCandidate]) {
        Task {
            do {
                await MLXLocalService.shared.clearTransientCache()
                print("🔀 [Infographic] MLX/AppleLocal/AppleCloud selected - redirecting to Apple Local for JSON generation")

                let rawResponse: String
                if #available(macOS 15.2, *) {
                    rawResponse = try await withCheckedThrowingContinuation { continuation in
                        appState.performLocalWithGeminiFallbackPublic(prompt: prompt, taskName: "Infographic") { result in
                            continuation.resume(returning: result)
                        }
                    }
                } else {
                    rawResponse = try await appState.summaryService.generateContentWithGemini(prompt: prompt)
                }

                guard let payload = parseInfographicPayload(from: rawResponse, rankedCandidates: rankedCandidates) else {
                    await MainActor.run {
                        self.infographicError = "Failed to parse infographic data"
                        self.isGeneratingInfographic = false
                    }
                    return
                }

                let html = buildInfographicHTML(from: payload)
                let safe = sanitizeInfographicHTML(html)

                guard let htmlData = safe.data(using: .utf8) else {
                    await MainActor.run {
                        self.infographicError = "Failed to generate infographic"
                        self.isGeneratingInfographic = false
                    }
                    return
                }

                await MainActor.run {
                    self.infographicContent = htmlData
                    self.isGeneratingInfographic = false
                    self.showInfographic = true
                }

            } catch {
                await MainActor.run {
                    self.infographicError = "Error: \(error.localizedDescription)"
                    self.isGeneratingInfographic = false
                }
            }
        }
    }

    private func generateInfographicWithMLXStructured(prompt: String, rankedCandidates: [RankedVisualCandidate]) {
        Task {
            do {
                let raw = try await generateStructuredJSONWithMLX(prompt: prompt)
                let candidate = sanitizeStructuredJSONCandidate(raw)
                guard let data = candidate.data(using: .utf8) else {
                    throw NSError(domain: "Infographic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert response to data."])
                }

                let payload: InfographicPayload
                do {
                    payload = try parseInfographicPayloadFromData(data, rankedCandidates: rankedCandidates)
                } catch {
                    let repaired = try await repairInvalidJSONUsingMLX(kind: .infographic, rawOutput: raw)
                    payload = try parseInfographicPayloadFromData(repaired, rankedCandidates: rankedCandidates)
                }

                let html = buildInfographicHTML(from: payload)
                let safe = sanitizeInfographicHTML(html)
                guard let htmlData = safe.data(using: .utf8) else {
                    throw NSError(domain: "Infographic", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate infographic HTML"])
                }

                await MainActor.run {
                    self.infographicContent = htmlData
                    self.isGeneratingInfographic = false
                    self.showInfographic = true
                }
            } catch {
                await MainActor.run {
                    self.infographicError = "Infographic failed: \(error.localizedDescription)"
                    self.isGeneratingInfographic = false
                }
            }
        }
    }

    private func parseInfographicPayloadFromData(_ data: Data, rankedCandidates: [RankedVisualCandidate]) throws -> InfographicPayload {
        let json = try MLXJSONRepairUtils.parseLLMJSONDictionary(from: data, domain: "Infographic")
        return InfographicPayload(dictionary: json, rankedCandidates: rankedCandidates)
    }

    private func parseInfographicPayload(from text: String, rankedCandidates: [RankedVisualCandidate]) -> InfographicPayload? {
        var rawString = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if rawString.hasPrefix("```") {
            rawString = rawString.replacingOccurrences(of: "```json", with: "")
            rawString = rawString.replacingOccurrences(of: "```", with: "")
        }

        if let firstBrace = rawString.firstIndex(of: "{"),
           let lastBrace = rawString.lastIndex(of: "}") {
            rawString = String(rawString[firstBrace...lastBrace])
        }

        guard let jsonData = rawString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] else {
            return nil
        }

        return InfographicPayload(dictionary: json, rankedCandidates: rankedCandidates)
    }

    private func makeInfographicPrompt(
        from content: String,
        urlReference: String,
        rankedCandidates: [RankedVisualCandidate],
        providerOverride: AppSettings.SummaryProvider? = nil
    ) -> String {
        let selectedProvider = providerOverride ?? appState.settings.selectedSummaryProvider
        let maxChars = (selectedProvider == .appleCloud || selectedProvider == .applePCCGateway || selectedProvider == .mlxLocal || selectedProvider == .coreAIMLXLocal) ? 8000 : 2000
        let trimmed = String(content.prefix(maxChars))
        let contentType = isRedditContent ? "Reddit" : "Article"
        let rankingSection = buildRankedPostSection(
            header: "TOP POST RANKING",
            selectionField: "topPosts",
            candidates: rankedCandidates,
            limit: 4
        )

        if selectedProvider == .mlxLocal || selectedProvider == .coreAIMLXLocal {
            return """
            READ THIS CONTENT FIRST - You must extract information from it:

            === \(contentType.uppercased()) CONTENT TO SUMMARIZE ===
            \(trimmed)
            === END \(contentType.uppercased()) CONTENT ===

            === POST URLs (use these exact URLs for topPosts) ===
            \(urlReference)
            === END URLs ===

            \(rankingSection)

            Now create a JSON infographic based on the \(contentType.lowercased()) content above.

            OUTPUT RULES:
            - Output ONLY valid JSON, no markdown, no code fences
            - Extract themes, topics, trends FROM THE CONTENT ABOVE
            - Use double quotes for all keys and ALL string values
            - Numbers must be plain integers (no quotes, no decimals, no % signs)
            - No trailing commas
            - Do NOT add any text before or after the JSON

            JSON structure to fill (replace ... with extracted content):
            {
              "title": "...",
              "subtitle": "...",
              "focus": "...",
              "palette": {"background": "#0b1021", "primary": "#6df3ff", "accent": "#ff7b72", "muted": "#94a3b8"},
              "statTiles": [{"label": "Posts", "value": "...", "note": "analyzed"}],
              "barSections": [{"label": "...", "value": 50, "caption": "..."}],
              "sentiment": {"positive": 40, "neutral": 40, "negative": 20},
              "sentimentBand": {"up": "...", "mid": "...", "down": "..."},
              "majorThemes": [{"title": "...", "subtitle": "...", "bullets": ["...", "..."]}],
              "themes": ["...", "..."],
              "keyTopics": ["...", "...", "..."],
              "notableTrends": ["...", "...", "..."],
              "takeaway": "...",
              "topPosts": [
                {"title": "...", "url": "..."},
                {"title": "...", "url": "..."},
                {"title": "...", "url": "..."},
                {"title": "...", "url": "..."}
              ]
            }

            IMPORTANT TOP POST RULES:
            - `topPosts` must come from the ranked list only.
            - Preserve the ranking order exactly.
            - Do not choose alternative posts; use the ranking as the selection rule.
            - Your job is to write the short interpretation of the ranked posts, not to pick different ones.

            **CRITICAL FOR topPosts URLs:**
            You MUST use ONLY the exact URLs from the POST REFERENCE LIST below. Do NOT make up URLs.
            Copy the URL exactly as shown after the → arrow. If you can't find a matching post, leave the url field empty "".

            === POST REFERENCE LIST (use these exact URLs) ===
            \(urlReference)
            === END REFERENCE LIST ===

            \(contentType) batch content:
            \(trimmed)
            """
        }

        return """
        You are designing an image-like infographic for a \(contentType.lowercased()) batch summary. Output ONLY compact JSON (no markdown, no fences).

        JSON schema:
        {
          "title": "Short bold title for the pulse",
          "subtitle": "One line hook (≤70 chars)",
          "focus": "One-sentence focus line (≤90 chars)",
          "palette": { "background": "#0b1021", "primary": "#6df3ff", "accent": "#ff7b72", "muted": "#94a3b8" },
          "statTiles": [ { "label": "Posts", "value": "42", "note": "short note" }, ... up to 4 ],
          "barSections": [ { "label": "Topic or metric", "value": 0-100, "caption": "≤28 chars" }, ... up to 4 ],
          "sentiment": { "positive": 0-100, "neutral": 0-100, "negative": 0-100 },
          "sentimentBand": { "up": "short positive text", "mid": "short mixed text", "down": "short negative text" },
          "majorThemes": [
            { "title": "Theme name", "subtitle": "short hook", "bullets": ["3-4 concise bullets"] },
            ... up to 4 total
          ],
          "themes": [ "3-6 ultra-short themes (≤18 chars)" ],
          "keyTopics": [ "6-8 concise topic lines; may include a short label: detail" ],
          "notableTrends": [ "4-6 concise trend lines; may include a short label: detail" ],
          "takeaway": "Single, vivid sentence (≤110 chars)",
          "topPosts": [ { "title": "Post title (≤60 chars)", "url": "EXACT_URL_FROM_REFERENCE_LIST"} ... up to 4 ]
        }

        Style goals:
        - Values must be consistent with the summary; no filler.
        - Keep numbers realistic (avoid 0 or 100 unless warranted).
        - Keep text minimal; bias toward visuals (charts, shapes) over paragraphs.

        \(rankingSection)
        \(rankingSection.isEmpty ? "" : """

        IMPORTANT TOP POST RULES:
        - `topPosts` must come from the ranked list only.
        - Preserve the ranking order exactly.
        - Do not choose alternative posts; use the ranking as the selection rule.
        - Your job is to write the short interpretation of the ranked posts, not to pick different ones.
        """)

        **CRITICAL FOR topPosts URLs:**
        You MUST use ONLY the exact URLs from the POST REFERENCE LIST below. Do NOT make up URLs.
        Copy the URL exactly as shown after the → arrow. If you can't find a matching post, leave the url field empty "".

        === POST REFERENCE LIST (use these exact URLs) ===
        \(urlReference)
        === END REFERENCE LIST ===

        \(contentType) batch content:
        \(trimmed)
        """
    }

    private func sanitizeInfographicHTML(_ html: String) -> String {
        let patterns = [
            "<script[^>]*>[\\s\\S]*?<\\/script>",
            "<iframe[^>]*>[\\s\\S]*?<\\/iframe>",
            "<object[^>]*>[\\s\\S]*?<\\/object>"
        ]

        var sanitized = html
        patterns.forEach { pattern in
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: NSRange(location: 0, length: sanitized.utf16.count), withTemplate: "")
            }
        }
        return sanitized
    }

    private func clampToPercent(_ value: Double, minimum: Double = 3) -> Double {
        max(minimum, min(100.0, value))
    }

    private func buildInfographicHTML(from payload: InfographicPayload) -> String {
        let palette = payload.palette

        let statsHTML = payload.statTiles.prefix(4).map { tile in
            """
            <div class="stat">
              <div class="stat-label">\(escapeHTML(tile.label))</div>
              <div class="stat-value">\(escapeHTML(tile.value))</div>
              <div class="stat-note">\(escapeHTML(tile.note ?? ""))</div>
            </div>
            """
        }.joined()

        let themeCardsHTML = payload.majorThemes.prefix(4).map { card in
            let bullets = card.bullets.prefix(4).map { bullet in
                "<li>\(escapeHTML(bullet))</li>"
            }.joined()
            return """
            <div class="theme-card">
              <div class="theme-title">\(escapeHTML(card.title))</div>
              \(card.subtitle.isEmpty ? "" : "<div class='theme-sub'>\(escapeHTML(card.subtitle))</div>")
              <ul class="theme-bullets">\(bullets)</ul>
            </div>
            """
        }.joined()

        let themesHTML = payload.themes.prefix(6).map { theme in
            "<span class=\"chip\">\(escapeHTML(theme))</span>"
        }.joined(separator: "")

        let keyTopicsHTML = payload.keyTopics.prefix(8).map { item in
            "<li><span class='dot'></span><span class='line'>\(escapeHTML(item))</span></li>"
        }.joined()

        let trendsHTML = payload.notableTrends.prefix(6).map { item in
            "<li><span class='dot accent'></span><span class='line'>\(escapeHTML(item))</span></li>"
        }.joined()

        let postsHTML = payload.topPosts.prefix(4).map { post in
            let normalized = normalizeRedditPermalink(post.url ?? "")
            let linkHTML: String
            if normalized.isEmpty {
                linkHTML = ""
            } else {
                linkHTML = "<a class=\"post-url\" href=\"\(normalized)\" target=\"_blank\">🔗 Open</a>"
            }
            return """
            <li class="post">
              <span class="post-dot"></span>
              <div class="post-content">
                <div class="post-title">\(escapeHTML(post.title))</div>
                \(linkHTML)
              </div>
            </li>
            """
        }.joined()

        let sentiment = payload.sentiment
        let total = max(1.0, sentiment.positive + sentiment.neutral + sentiment.negative)
        let pos = clampToPercent((sentiment.positive / total) * 100.0)
        let neu = clampToPercent((sentiment.neutral / total) * 100.0)
        let neg = clampToPercent((sentiment.negative / total) * 100.0)

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1.0" />
          <style>
            :root {
              --bg: \(palette.background);
              --primary: \(palette.primary);
              --accent: \(palette.accent);
              --muted: \(palette.muted);
              --text: #e2e8f0;
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              padding: 0;
              min-height: 100vh;
              font-family: "SF Pro Display","Helvetica Neue","Segoe UI",sans-serif;
              color: var(--text);
              background: radial-gradient(120% 120% at 15% 20%, rgba(255,255,255,0.08), transparent),
                          radial-gradient(120% 120% at 85% 0%, rgba(255,123,114,0.10), transparent),
                          linear-gradient(145deg, var(--bg), #0c101f 55%, #0a0f1d 100%);
            }
            .wrap {
              max-width: 1040px;
              margin: 0 auto;
              padding: 28px 20px 44px;
              position: relative;
              overflow: hidden;
            }
            .glass {
              background: rgba(255,255,255,0.03);
              border: 1px solid rgba(255,255,255,0.07);
              border-radius: 24px;
              padding: 24px;
              box-shadow: 0 20px 60px rgba(0,0,0,0.35);
              backdrop-filter: blur(10px);
              position: relative;
              overflow: hidden;
            }
            .glow {
              position: absolute;
              inset: -120px;
              background: radial-gradient(300px at 25% 20%, rgba(109,243,255,0.18), transparent 60%),
                          radial-gradient(260px at 80% 10%, rgba(255,123,114,0.16), transparent 55%);
              filter: blur(30px);
              opacity: 0.9;
              pointer-events: none;
            }
            header {
              display: flex;
              flex-direction: column;
              gap: 8px;
              margin-bottom: 18px;
              position: relative;
              z-index: 1;
            }
            .title {
              font-size: 34px;
              font-weight: 800;
              letter-spacing: -0.04em;
            }
            .subtitle {
              color: var(--muted);
              font-size: 16px;
            }
            .section-label { text-transform: uppercase; letter-spacing: 0.08em; font-size: 12px; color: var(--muted); margin-bottom: 8px; }
            .chips { display: flex; flex-wrap: wrap; gap: 8px; margin: 10px 0 14px; }
            .chip { background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 999px; padding: 8px 12px; font-size: 13px; }
            .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 10px; margin-top: 8px; }
            .stat { padding: 12px 14px; background: linear-gradient(145deg, rgba(255,255,255,0.05), rgba(255,255,255,0.02)); border-radius: 14px; border: 1px solid rgba(255,255,255,0.07); }
            .stat-label { text-transform: uppercase; letter-spacing: 0.08em; font-size: 11px; color: var(--muted); }
            .stat-value { font-size: 24px; font-weight: 800; margin: 6px 0 2px; color: var(--primary); }
            .stat-note { font-size: 12px; color: var(--muted); }
            .focus-pill { display: inline-flex; align-items: center; gap: 10px; padding: 10px 14px; border-radius: 14px; border: 1px solid rgba(255,255,255,0.08); background: rgba(255,255,255,0.04); font-size: 14px; margin-top: 6px; }
            .themes-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 12px; margin-top: 10px; }
            .theme-card { padding: 14px; border-radius: 14px; border: 1px solid rgba(255,255,255,0.08); background: rgba(255,255,255,0.03); box-shadow: inset 0 1px 0 rgba(255,255,255,0.05); min-height: 160px; }
            .theme-title { font-weight: 800; margin-bottom: 4px; font-size: 15px; }
            .theme-sub { color: var(--muted); font-size: 12px; margin-bottom: 6px; }
            .theme-bullets { list-style: none; padding: 0; margin: 0; display: grid; gap: 4px; }
            .theme-bullets li { font-size: 13px; line-height: 1.35; position: relative; padding-left: 14px; }
            .theme-bullets li::before { content: "•"; position: absolute; left: 0; color: var(--accent); }
            .sentiment-band { margin: 16px 0 10px; border-radius: 16px; overflow: hidden; border: 1px solid rgba(255,255,255,0.08); box-shadow: inset 0 1px 0 rgba(255,255,255,0.04); }
            .band { display: grid; grid-template-columns: 120px 1fr; align-items: center; padding: 10px 12px; font-size: 13px; }
            .band-label { font-weight: 800; text-transform: uppercase; letter-spacing: 0.05em; }
            .band.up { background: linear-gradient(90deg, rgba(109,243,255,0.20), rgba(109,243,255,0.05)); color: #0b2130; }
            .band.mid { background: linear-gradient(90deg, rgba(255,182,72,0.15), rgba(255,182,72,0.05)); color: #160f00; }
            .band.down { background: linear-gradient(90deg, rgba(255,123,114,0.18), rgba(255,123,114,0.05)); color: #1f0e0e; }
            .band .text { color: rgba(0,0,0,0.78); }
            .sentiment-tags { display: flex; gap: 8px; flex-wrap: wrap; margin: 8px 0 4px; }
            .tag { padding: 6px 10px; border-radius: 12px; font-weight: 700; font-size: 12px; }
            .tag.pos { background: rgba(109,243,255,0.14); color: #9bf5ff; border: 1px solid rgba(109,243,255,0.35); }
            .tag.neu { background: rgba(148,163,184,0.12); color: #cbd5e1; border: 1px solid rgba(148,163,184,0.3); }
            .tag.neg { background: rgba(255,123,114,0.12); color: #ffb4ac; border: 1px solid rgba(255,123,114,0.32); }
            .topics-trends { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 12px; }
            .list-card { padding: 14px; border-radius: 14px; border: 1px solid rgba(255,255,255,0.07); background: rgba(255,255,255,0.03); }
            .list-card ul { list-style: none; padding: 0; margin: 0; display: grid; gap: 6px; }
            .list-card li { display: flex; align-items: flex-start; gap: 8px; font-size: 13px; line-height: 1.35; }
            .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--primary); margin-top: 5px; flex-shrink: 0; }
            .dot.accent { background: var(--accent); }
            .line { flex: 1; }
            .posts { list-style: none; padding: 0; margin: 0; display: grid; gap: 8px; }
            .post { display: flex; align-items: flex-start; gap: 10px; background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.05); border-radius: 12px; padding: 10px 12px; }
            .post-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--accent); margin-top: 6px; flex-shrink: 0; }
            .post-content { flex: 1; display: flex; flex-direction: column; gap: 6px; }
            .post-title { font-size: 14px; font-weight: 600; line-height: 1.3; }
            .post-url { display: inline-block; color: var(--primary); font-size: 12px; text-decoration: none; padding: 4px 10px; background: rgba(109,243,255,0.1); border-radius: 6px; border: 1px solid rgba(109,243,255,0.2); }
            .post-url:hover { background: rgba(109,243,255,0.2); }
            .takeaway { margin-top: 10px; padding: 14px; border-radius: 16px; background: linear-gradient(120deg, rgba(109,243,255,0.12), rgba(255,123,114,0.10)); border: 1px solid rgba(255,255,255,0.07); font-weight: 650; font-size: 15px; }
          </style>
        </head>
        <body>
          <div class="wrap">
            <div class="glass">
              <div class="glow"></div>
              <header>
                <div class="title">\(escapeHTML(payload.title))</div>
                <div class="subtitle">\(escapeHTML(payload.subtitle))</div>
                <div class="focus-pill">\(escapeHTML(payload.focus))</div>
                <div class="stats">\(statsHTML)</div>
                <div class="chips">\(themesHTML)</div>
              </header>
              <div class="section-label">Major Themes</div>
              <div class="themes-grid">\(themeCardsHTML)</div>

              <div class="section-label">Overall Sentiment</div>
              <div class="sentiment-band">
                <div class="band up"><span class="band-label">Positive</span><span class="text">\(escapeHTML(payload.sentimentBand.up))</span></div>
                <div class="band mid"><span class="band-label">Mixed</span><span class="text">\(escapeHTML(payload.sentimentBand.mid))</span></div>
                <div class="band down"><span class="band-label">Critical</span><span class="text">\(escapeHTML(payload.sentimentBand.down))</span></div>
              </div>
              <div class="sentiment-tags">
                <span class="tag pos">Positive \(String(format: "%.0f%%", pos))</span>
                <span class="tag neu">Neutral \(String(format: "%.0f%%", neu))</span>
                <span class="tag neg">Negative \(String(format: "%.0f%%", neg))</span>
              </div>

              <div class="section-label">Key Topics & Notable Trends</div>
              <div class="topics-trends">
                <div class="list-card">
                  <div class="section-label">Key Topics</div>
                  <ul>\(keyTopicsHTML)</ul>
                </div>
                <div class="list-card">
                  <div class="section-label">Notable Trends</div>
                  <ul>\(trendsHTML)</ul>
                </div>
              </div>

              <div style="margin-top:14px;">
                <div class="section-label">Top Signals</div>
                <ul class="posts">\(postsHTML)</ul>
              </div>
              <div class="takeaway">\(escapeHTML(payload.takeaway))</div>
            </div>
          </div>
        </body>
        </html>
        """
    }

    private func escapeHTML(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func buildWhiteboardHTML(from payload: WhiteboardPayload) -> String {
        // Minimalist aesthetic: no rotations, no emojis, clean typography

        // Build What We Know section
        let whatWeKnowHTML = payload.whatWeKnow.prefix(6).map { item in
            "<li class=\"fact-item\">\(escapeHTML(item))</li>"
        }.joined()

        // Build Open Questions section
        let questionsHTML = payload.openQuestions.prefix(5).map { item in
            "<li class=\"question-item\">\(escapeHTML(item))</li>"
        }.joined()

        // Build Takeaways section
        let takeawaysHTML = payload.takeaways.prefix(5).map { item in
            """
            <div class="takeaway-item">
              <p class="takeaway-insight">\(escapeHTML(item.insight))</p>
              <span class="takeaway-source">\(escapeHTML(item.source))</span>
            </div>
            """
        }.joined()

        // Build Pain Points section
        let painHTML = payload.painPoints.prefix(4).map { item in
            let severityClass = item.severity.lowercased()
            return """
            <div class="pain-item">
              <span class="severity severity-\(severityClass)">\(severityClass.uppercased())</span>
              <p class="pain-text">\(escapeHTML(item.issue))</p>
            </div>
            """
        }.joined()

        // Build Hot Takes section
        let hotTakesHTML = payload.hotTakes.prefix(4).map { item in
            """
            <blockquote class="quote-item">
              <p class="quote-text">"\(escapeHTML(item.quote))"</p>
              <cite class="quote-context">\(escapeHTML(item.context))</cite>
            </blockquote>
            """
        }.joined()

        // Build Connections section
        let connectionsHTML = payload.connections.prefix(4).map { connection in
            "<li class=\"connection-item\">\(escapeHTML(connection))</li>"
        }.joined()

        // Build Ideas section
        let ideasHTML = payload.ideasToExplore.prefix(4).map { item in
            "<li class=\"idea-item\">\(escapeHTML(item))</li>"
        }.joined()

        // Build Key Posts section
        let postsHTML = payload.keyPosts.prefix(5).map { post in
            let normalized = normalizeRedditPermalink(post.url ?? "")
            let linkHTML = normalized.isEmpty ? "" : "<a class=\"post-link\" href=\"\(normalized)\" target=\"_blank\">View →</a>"
            return """
            <div class="post-item">
              <p class="post-title">\(escapeHTML(post.title))</p>
              <span class="post-why">\(escapeHTML(post.why))</span>
              \(linkHTML)
            </div>
            """
        }.joined()

        // Contextual labels
        let takeawaysLabel = payload.isRedditContent ? "Community Suggestions" : "Key Takeaways"
        let postsLabel = payload.isRedditContent ? "Key Posts" : "Key Articles"
        let emptyTakeawaysMsg = payload.isRedditContent ? "No suggestions yet" : "No takeaways yet"
        let emptyPostsMsg = payload.isRedditContent ? "No posts pinned" : "No articles pinned"

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1.0" />
          <style>
            :root {
              --accent: #2563eb;
              --accent-light: #eff6ff;
              --highlight: #d97706;
              --alert: #dc2626;
              --gray-900: #0A0A0A;
              --gray-700: #404040;
              --gray-500: #6B6B6B;
              --gray-300: #A3A3A3;
              --gray-100: #E5E5E5;
              --text-xs: 11px;
              --text-sm: 13px;
              --text-base: 14px;
              --text-lg: 18px;
              --text-2xl: 32px;
              --space-unit: 8px;
              --gutter: 24px;
              --margin: 48px;
            }
            * { box-sizing: border-box; margin: 0; padding: 0; }
            body {
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
              background: #FFFFFF;
              color: var(--gray-900);
              line-height: 1.5;
              min-height: 100vh;
              padding: var(--margin);
              -webkit-font-smoothing: antialiased;
            }
            .board { max-width: 1080px; margin: 0 auto; }
            .header {
              margin-bottom: calc(var(--space-unit) * 6);
              padding-bottom: calc(var(--space-unit) * 4);
              border-bottom: 1px solid var(--gray-100);
            }
            .session-title {
              font-family: system-ui, -apple-system, sans-serif;
              font-size: var(--text-2xl);
              font-weight: 600;
              color: var(--gray-900);
              letter-spacing: -0.02em;
              line-height: 1.2;
            }
            .session-context {
              font-size: var(--text-sm);
              color: var(--gray-500);
              margin-top: var(--space-unit);
            }
            .grid-2 {
              display: grid;
              grid-template-columns: 1fr 1fr;
              gap: var(--gutter);
              margin-bottom: calc(var(--space-unit) * 5);
            }
            @media (max-width: 768px) {
              .grid-2 { grid-template-columns: 1fr; }
              body { padding: var(--gutter); }
            }
            .section { margin-bottom: calc(var(--space-unit) * 5); }
            .section-title {
              font-family: system-ui, -apple-system, sans-serif;
              font-size: var(--text-xs);
              font-weight: 600;
              text-transform: uppercase;
              letter-spacing: 0.1em;
              color: var(--gray-500);
              margin-bottom: calc(var(--space-unit) * 2);
            }
            .item-list { list-style: none; }
            .item-list li {
              font-size: var(--text-base);
              color: var(--gray-700);
              padding: calc(var(--space-unit) * 1.5) 0;
              border-bottom: 1px solid var(--gray-100);
            }
            .item-list li:last-child { border-bottom: none; }
            .fact-item::before {
              content: "—";
              color: var(--gray-300);
              margin-right: var(--space-unit);
            }
            .question-item { color: var(--accent); }
            .takeaway-item {
              padding: calc(var(--space-unit) * 2) 0;
              border-bottom: 1px solid var(--gray-100);
            }
            .takeaway-item:last-child { border-bottom: none; }
            .takeaway-insight {
              font-size: var(--text-base);
              font-weight: 500;
              color: var(--gray-900);
              margin: 0;
            }
            .takeaway-source {
              font-size: var(--text-xs);
              color: var(--highlight);
              margin-top: calc(var(--space-unit) / 2);
              display: block;
            }
            .pain-item {
              display: flex;
              align-items: baseline;
              gap: calc(var(--space-unit) * 1.5);
              padding: calc(var(--space-unit) * 1.5) 0;
              border-bottom: 1px solid var(--gray-100);
            }
            .pain-item:last-child { border-bottom: none; }
            .severity {
              font-size: var(--text-xs);
              font-weight: 600;
              text-transform: uppercase;
              letter-spacing: 0.05em;
              padding: 2px 6px;
              border-radius: 2px;
              flex-shrink: 0;
            }
            .severity-high { color: #FFFFFF; background: var(--alert); }
            .severity-medium { color: var(--gray-900); background: var(--gray-100); }
            .severity-low { color: var(--gray-500); background: transparent; border: 1px solid var(--gray-300); }
            .pain-text { font-size: var(--text-base); color: var(--gray-700); margin: 0; }
            .quote-item {
              padding: calc(var(--space-unit) * 2) 0;
              border-bottom: 1px solid var(--gray-100);
              border-left: 2px solid var(--gray-300);
              padding-left: calc(var(--space-unit) * 2);
              margin: 0;
            }
            .quote-item:last-child { border-bottom: none; }
            .quote-text { font-size: var(--text-base); font-style: italic; color: var(--gray-700); margin: 0; }
            .quote-context {
              font-size: var(--text-xs);
              color: var(--gray-500);
              font-style: normal;
              margin-top: calc(var(--space-unit) / 2);
              display: block;
            }
            .post-item {
              padding: calc(var(--space-unit) * 2) 0;
              border-bottom: 1px solid var(--gray-100);
            }
            .post-item:last-child { border-bottom: none; }
            .post-title { font-size: var(--text-base); font-weight: 500; color: var(--gray-900); margin: 0; }
            .post-why {
              font-size: var(--text-xs);
              color: var(--gray-500);
              margin-top: calc(var(--space-unit) / 2);
              display: block;
            }
            .post-link {
              font-size: var(--text-xs);
              color: var(--accent);
              text-decoration: none;
              margin-top: var(--space-unit);
              display: inline-block;
            }
            .post-link:hover { text-decoration: underline; }
            .bottom-line {
              margin-top: calc(var(--space-unit) * 6);
              padding-top: calc(var(--space-unit) * 4);
              border-top: 2px solid var(--gray-900);
            }
            .bottom-line-label {
              font-size: var(--text-xs);
              font-weight: 600;
              text-transform: uppercase;
              letter-spacing: 0.1em;
              color: var(--gray-500);
              margin-bottom: var(--space-unit);
            }
            .bottom-line-text {
              font-family: system-ui, -apple-system, sans-serif;
              font-size: var(--text-lg);
              font-weight: 500;
              color: var(--gray-900);
              line-height: 1.4;
            }
            .empty-state {
              font-size: var(--text-sm);
              color: var(--gray-300);
              padding: calc(var(--space-unit) * 2) 0;
            }
          </style>
        </head>
        <body>
          <div class="board">
            <header class="header">
              <h1 class="session-title">\(escapeHTML(payload.sessionTitle))</h1>
              <p class="session-context">\(escapeHTML(payload.sessionContext))</p>
            </header>

            <div class="grid-2">
              <section class="section">
                <h2 class="section-title">What We Know</h2>
                \(whatWeKnowHTML.isEmpty ? "<p class=\"empty-state\">No confirmed facts yet</p>" : "<ul class=\"item-list\">\(whatWeKnowHTML)</ul>")
              </section>

              <section class="section">
                <h2 class="section-title">Open Questions</h2>
                \(questionsHTML.isEmpty ? "<p class=\"empty-state\">No questions recorded</p>" : "<ul class=\"item-list\">\(questionsHTML)</ul>")
              </section>
            </div>

            <section class="section">
              <h2 class="section-title">\(takeawaysLabel)</h2>
              \(takeawaysHTML.isEmpty ? "<p class=\"empty-state\">\(emptyTakeawaysMsg)</p>" : "<div>\(takeawaysHTML)</div>")
            </section>

            <div class="grid-2">
              <section class="section">
                <h2 class="section-title">Pain Points</h2>
                \(painHTML.isEmpty ? "<p class=\"empty-state\">No issues identified</p>" : "<div>\(painHTML)</div>")
              </section>

              <section class="section">
                <h2 class="section-title">Notable Quotes</h2>
                \(hotTakesHTML.isEmpty ? "<p class=\"empty-state\">No notable quotes</p>" : "<div>\(hotTakesHTML)</div>")
              </section>
            </div>

            \(!payload.connections.isEmpty ? """
            <section class="section">
              <h2 class="section-title">Connections</h2>
              <ul class="item-list">\(connectionsHTML)</ul>
            </section>
            """ : "")

            <div class="grid-2">
              <section class="section">
                <h2 class="section-title">Ideas to Explore</h2>
                \(ideasHTML.isEmpty ? "<p class=\"empty-state\">No ideas yet</p>" : "<ul class=\"item-list\">\(ideasHTML)</ul>")
              </section>

              <section class="section">
                <h2 class="section-title">\(postsLabel)</h2>
                \(postsHTML.isEmpty ? "<p class=\"empty-state\">\(emptyPostsMsg)</p>" : "<div>\(postsHTML)</div>")
              </section>
            </div>

            <footer class="bottom-line">
              <p class="bottom-line-label">Bottom Line</p>
              <p class="bottom-line-text">\(escapeHTML(payload.bottomLine))</p>
            </footer>
          </div>
        </body>
        </html>
        """
    }

    // MARK: - TTS Methods

    private func buildDragSpeechText() -> String? {
        if let aggregate = appState.aggregateSummaryText, !aggregate.isEmpty {
            return aggregate
        }
        let items = parsedSummaries
        guard !items.isEmpty else { return nil }
        return items.map { "\($0.subject). \($0.summary)" }.joined(separator: "\n\n")
    }

    private func speakDragOverviewCloudTTS() {
        ttsCanceledDrag = false
        guard let text = buildDragSpeechText(), !text.isEmpty else {
            speechSynthesisErrorDrag = "No summary available to read."
            return
        }

        audioPlayerDrag?.stop()
        audioPlayerDrag = nil
        ShortcutsTTS.shared.stopSpeaking()

        isSynthesizingSpeechDrag = true
        isSpeakingLocallyDrag = false
        speechSynthesisErrorDrag = nil

        Task {
            await appState.summaryService.synthesizeSpeechFastStartSplit(
                text: text,
                onFirstChunk: { data in
                    DispatchQueue.main.async {
                        self.playDragAudio(data: data)
                    }
                },
                onRemainingReady: { data in
                    DispatchQueue.main.async {
                        if let player = self.audioPlayerDrag, player.isPlaying {
                            self.nextAudioChunkDrag = data
                        } else {
                            self.playDragAudio(data: data)
                        }
                    }
                },
                onComplete: { },
                onError: { error in
                    DispatchQueue.main.async {
                        self.speechSynthesisErrorDrag = "Speech synthesis failed: \(error.localizedDescription)"
                        self.isSynthesizingSpeechDrag = false
                        self.nextAudioChunkDrag = nil
                    }
                }
            )
        }
    }

    private func stopDragOverviewSpeech() {
        ttsCanceledDrag = true
        audioPlayerDrag?.stop()
        audioPlayerDrag = nil
        ShortcutsTTS.shared.stopSpeaking()
        localTTSTaskDrag?.cancel()
        localTTSTaskDrag = nil
        nextAudioChunkDrag = nil
        isSynthesizingSpeechDrag = false
        isSpeakingLocallyDrag = false
    }

    private func playDragAudio(data: Data) {
        audioPlayerDrag?.stop()

        let audioData: Data
        if isMP3Data(data) || isAACData(data) {
            audioData = data
        } else {
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }

        audioPlayerDrag = NSSound(data: audioData)
        if let player = audioPlayerDrag {
            player.delegate = soundDelegateDrag
            if !player.play() {
                speechSynthesisErrorDrag = "Failed to start audio playback."
                isSynthesizingSpeechDrag = false
            }
        } else {
            speechSynthesisErrorDrag = "Failed to initialize audio player with data."
            isSynthesizingSpeechDrag = false
        }
    }

    private func speakDragOverviewLocally() {
        guard let text = buildDragSpeechText(), !text.isEmpty else {
            speechSynthesisErrorDrag = "No summary available to read."
            return
        }

        let settings = PersistenceManager.shared.loadSettings()
        if settings.localTTSEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                isSpeakingLocallyDrag = false
                speechSynthesisErrorDrag = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            if isSpeakingLocallyDrag {
                localTTSTaskDrag?.cancel()
                localTTSTaskDrag = nil
                audioPlayerDrag?.stop()
                isSpeakingLocallyDrag = false
                return
            }
            audioPlayerDrag?.stop()
            isSpeakingLocallyDrag = true
            isSynthesizingSpeechDrag = false
            startKokoroPlaybackDrag(
                text: text,
                voice: settings.kokoroVoice,
                speed: settings.kokoroSpeed,
                setAudioPlayer: { player in audioPlayerDrag = player },
                soundDelegate: soundDelegateDrag,
                taskStore: &localTTSTaskDrag,
                onCompleted: {
                    isSpeakingLocallyDrag = false
                    localTTSTaskDrag = nil
                },
                onError: { message in
                    speechSynthesisErrorDrag = message
                    isSpeakingLocallyDrag = false
                }
            )
            return
        }

        // macOS native: use ShortcutsTTS
        if isSpeakingLocallyDrag {
            ShortcutsTTS.shared.stopSpeaking()
            isSpeakingLocallyDrag = false
            return
        }

        audioPlayerDrag?.stop()
        isSpeakingLocallyDrag = true
        isSynthesizingSpeechDrag = false

        let success = ShortcutsTTS.shared.speakText(text) {
            DispatchQueue.main.async {
                self.isSpeakingLocallyDrag = false
            }
        }

        if !success {
            isSpeakingLocallyDrag = false
            speechSynthesisErrorDrag = "Failed to start Shortcuts TTS on macOS."
        }
    }

    private func startKokoroPlaybackDrag(
        text: String,
        voice: String,
        speed: Double,
        setAudioPlayer: @escaping (NSSound?) -> Void,
        soundDelegate: SoundDelegate,
        taskStore: inout Task<Void, Never>?,
        onCompleted: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        _ = soundDelegate
        taskStore?.cancel()
        taskStore = Task {
            defer {
                if !PersistenceManager.shared.loadSettings().kokoroPrecacheEnabled {
                    KokoroTTSService.shared.unloadIfAllowed()
                }
                Task { @MainActor in
                    onCompleted()
                }
            }
            do {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                func makeKokoroChunks(from input: String) -> [String] {
                    let firstSize = min(240, input.count)
                    let firstChunk = String(input.prefix(firstSize))
                    let remaining = String(input.dropFirst(firstSize)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !remaining.isEmpty else { return [firstChunk] }

                    var chunks: [String] = [firstChunk]
                    let sentences = remaining.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                    var current = ""
                    let maxChunkSize = 420
                    for sentence in sentences {
                        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmedSentence.isEmpty { continue }
                        let sentenceWithPunctuation = trimmedSentence + "."
                        if current.count + sentenceWithPunctuation.count <= maxChunkSize {
                            current += (current.isEmpty ? "" : " ") + sentenceWithPunctuation
                        } else {
                            if !current.isEmpty { chunks.append(current) }
                            current = sentenceWithPunctuation
                        }
                    }
                    if !current.isEmpty { chunks.append(current) }
                    return chunks
                }

                let chunks = makeKokoroChunks(from: trimmed)
                guard let firstChunk = chunks.first else { return }

                func playChunk(_ data: Data) async throws -> TimeInterval {
                    try await MainActor.run {
                        guard let player = NSSound(data: data) else {
                            onError("Failed to initialize audio player.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        setAudioPlayer(player)
                        if player.play() == false {
                            onError("Failed to start audio playback.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        return player.duration
                    }
                }

                enum KokoroPlaybackError: Error { case timeout }

                func synthesizeWithTimeout(_ text: String) async throws -> Data {
                    try await withThrowingTaskGroup(of: Data.self) { group in
                        group.addTask {
                            try await KokoroTTSService.shared.synthesize(
                                text: text,
                                voice: voice,
                                speed: Float(speed)
                            )
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 20_000_000_000)
                            throw KokoroPlaybackError.timeout
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                }

                let firstData = try await synthesizeWithTimeout(firstChunk)
                if Task.isCancelled { return }
                var currentDuration = try await playChunk(firstData)

                if chunks.count == 1 { return }

                var nextIndex = 1
                var nextTask: Task<Data, Error>? = Task {
                    try await synthesizeWithTimeout(chunks[nextIndex])
                }
                defer { nextTask?.cancel() }

                while nextIndex < chunks.count {
                    try await Task.sleep(nanoseconds: UInt64(currentDuration * 1_000_000_000))
                    if Task.isCancelled { return }

                    guard let task = nextTask else { return }
                    let data = try await task.value
                    nextIndex += 1

                    if nextIndex < chunks.count {
                        nextTask = Task {
                            try await synthesizeWithTimeout(chunks[nextIndex])
                        }
                    } else {
                        nextTask = nil
                    }

                    currentDuration = try await playChunk(data)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    let message: String
                    if let kokoroError = error as? KokoroTTSServiceError, kokoroError == .notAvailable {
                        message = "MLX TTS is not available. Add the MLXAudio package and model access."
                    } else if String(describing: error).contains("timeout") {
                        message = "Kokoro is still loading models. Please wait a moment and try again."
                    } else {
                        message = "Kokoro TTS failed: \(error.localizedDescription)"
                    }
                    onError(message)
                }
            }
        }
    }
}

private struct RankedVisualCandidate {
    let title: String
    let url: String
    let ups: Int
    let numComments: Int
    let createdUTC: Double
    let ageHours: Double
    let score: Double
    let batchOrder: Int
}

private func normalizedVisualStringKey(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .lowercased()
}

private func normalizedVisualURLKey(_ value: String?) -> String {
    let trimmed = (value ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}

private func fallbackWhyText(for candidate: RankedVisualCandidate) -> String {
    if candidate.ageHours <= 48 {
        return "High engagement + recent discussion"
    } else if candidate.ageHours <= 168 {
        return "High engagement + steady discussion"
    } else {
        return "Top-ranked engagement signal"
    }
}

// MARK: - Whiteboard Payload
private struct WhiteboardPayload {
    struct Takeaway {
        let insight: String
        let source: String  // For Reddit: "Community consensus", "Highly upvoted", etc. For Articles: "Expert opinion", "Research finding", etc.
    }

    struct PainPoint {
        let issue: String
        let severity: String
    }

    struct HotTake {
        let quote: String
        let context: String
    }

    struct KeyPost {
        let title: String
        let url: String?
        let why: String
    }

    let sessionTitle: String
    let sessionContext: String
    let whatWeKnow: [String]
    let openQuestions: [String]
    let takeaways: [Takeaway]  // Contextual: "Community Suggestions" for Reddit, "Key Takeaways" for Articles
    let painPoints: [PainPoint]
    let hotTakes: [HotTake]
    let connections: [String]
    let ideasToExplore: [String]
    let keyPosts: [KeyPost]
    let bottomLine: String
    let isRedditContent: Bool  // Track content type for contextual display

    init(dictionary: [String: Any], isReddit: Bool = false, rankedCandidates: [RankedVisualCandidate] = []) {
        func string(_ value: Any?, default defaultValue: String) -> String {
            if let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return defaultValue
        }

        self.isRedditContent = isReddit
        self.sessionTitle = string(dictionary["sessionTitle"], default: "Brainstorm Session")
        self.sessionContext = string(dictionary["sessionContext"], default: "Discussion Notes")

        self.whatWeKnow = (dictionary["whatWeKnow"] as? [String] ?? []).filter { !$0.isEmpty }
        self.openQuestions = (dictionary["openQuestions"] as? [String] ?? []).filter { !$0.isEmpty }
        self.connections = (dictionary["connections"] as? [String] ?? []).filter { !$0.isEmpty }
        self.ideasToExplore = (dictionary["ideasToExplore"] as? [String] ?? []).filter { !$0.isEmpty }

        self.takeaways = (dictionary["takeaways"] as? [[String: Any]] ?? []).map {
            Takeaway(
                insight: string($0["insight"], default: "Key insight"),
                source: string($0["source"], default: isReddit ? "Community" : "Article")
            )
        }

        self.painPoints = (dictionary["painPoints"] as? [[String: Any]] ?? []).map {
            PainPoint(
                issue: string($0["issue"], default: "Issue identified"),
                severity: string($0["severity"], default: "medium")
            )
        }

        self.hotTakes = (dictionary["hotTakes"] as? [[String: Any]] ?? []).map {
            HotTake(
                quote: string($0["quote"], default: "Notable opinion"),
                context: string($0["context"], default: "")
            )
        }

        let parsedKeyPosts = (dictionary["keyPosts"] as? [[String: Any]] ?? []).map {
            KeyPost(
                title: string($0["title"], default: "Post"),
                url: string($0["url"], default: ""),
                why: string($0["why"], default: "")
            )
        }

        if rankedCandidates.isEmpty {
            self.keyPosts = parsedKeyPosts
        } else {
            var parsedByMatchKey: [String: KeyPost] = [:]
            for post in parsedKeyPosts {
                let key = "\(normalizedVisualStringKey(post.title))|\(normalizedVisualURLKey(post.url))"
                if parsedByMatchKey[key] == nil {
                    parsedByMatchKey[key] = post
                }
            }

            self.keyPosts = rankedCandidates.map { candidate in
                let key = "\(normalizedVisualStringKey(candidate.title))|\(normalizedVisualURLKey(candidate.url))"
                let title = candidate.title
                let url = candidate.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : candidate.url

                if let parsed = parsedByMatchKey[key] {
                    let parsedWhy = parsed.why.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !parsedWhy.isEmpty {
                        return KeyPost(title: title, url: url, why: parsedWhy)
                    }
                }

                return KeyPost(title: title, url: url, why: fallbackWhyText(for: candidate))
            }
        }

        self.bottomLine = string(dictionary["bottomLine"], default: "Key insight from this session.")
    }
}

// MARK: - Infographic Payload
private struct InfographicPayload {
    struct Palette {
        let background: String
        let primary: String
        let accent: String
        let muted: String
    }
    struct ThemeCard {
        let title: String
        let subtitle: String
        let bullets: [String]
    }
    struct StatTile {
        let label: String
        let value: String
        let note: String?
    }
    struct BarSection {
        let label: String
        let value: Double
        let caption: String?
    }
    struct PostItem {
        let title: String
        let url: String?
    }
    struct Sentiment {
        let positive: Double
        let neutral: Double
        let negative: Double
    }
    struct SentimentBand {
        let up: String
        let mid: String
        let down: String
    }

    let title: String
    let subtitle: String
    let focus: String
    let palette: Palette
    let statTiles: [StatTile]
    let barSections: [BarSection]
    let majorThemes: [ThemeCard]
    let themes: [String]
    let keyTopics: [String]
    let notableTrends: [String]
    let sentimentBand: SentimentBand
    let takeaway: String
    let topPosts: [PostItem]
    let sentiment: Sentiment

    init(dictionary: [String: Any], rankedCandidates: [RankedVisualCandidate] = []) {
        func string(_ value: Any?, default defaultValue: String) -> String {
            if let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return defaultValue
        }

        func double(_ value: Any?, default defaultValue: Double) -> Double {
            if let d = value as? Double { return d }
            if let n = value as? NSNumber { return n.doubleValue }
            if let s = value as? String, let d = Double(s) { return d }
            return defaultValue
        }

        let paletteDict = dictionary["palette"] as? [String: Any] ?? [:]
        self.palette = Palette(
            background: string(paletteDict["background"], default: "#0b1021"),
            primary: string(paletteDict["primary"], default: "#6df3ff"),
            accent: string(paletteDict["accent"], default: "#ff7b72"),
            muted: string(paletteDict["muted"], default: "#94a3b8")
        )

        let themesCards = (dictionary["majorThemes"] as? [[String: Any]] ?? []).map {
            ThemeCard(
                title: string($0["title"], default: "Major Theme"),
                subtitle: string($0["subtitle"], default: ""),
                bullets: ($0["bullets"] as? [String] ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            )
        }
        self.majorThemes = themesCards.isEmpty ? [
            ThemeCard(title: "Theme A", subtitle: "Hook", bullets: ["Key point one", "Key point two", "Key point three"]),
            ThemeCard(title: "Theme B", subtitle: "Hook", bullets: ["Signal A", "Signal B", "Signal C"]),
            ThemeCard(title: "Theme C", subtitle: "Hook", bullets: ["Pain point A", "Pain point B"]),
            ThemeCard(title: "Theme D", subtitle: "Hook", bullets: ["Opportunity", "Gap", "Action"])
        ] : themesCards

        let tiles = (dictionary["statTiles"] as? [[String: Any]] ?? []).map {
            StatTile(label: string($0["label"], default: "Posts"),
                     value: string($0["value"], default: "—"),
                     note: string($0["note"], default: ""))
        }
        self.statTiles = tiles.isEmpty ? [
            StatTile(label: "Posts", value: "—", note: nil),
            StatTile(label: "Engagement", value: "—", note: nil),
            StatTile(label: "Velocity", value: "—", note: nil),
            StatTile(label: "Highlights", value: "—", note: nil)
        ] : tiles

        let bars = (dictionary["barSections"] as? [[String: Any]] ?? []).map {
            BarSection(label: string($0["label"], default: "Topic"),
                       value: double($0["value"], default: 30),
                       caption: string($0["caption"], default: ""))
        }
        self.barSections = bars.isEmpty ? [
            BarSection(label: "Momentum", value: 64, caption: "discussion volume"),
            BarSection(label: "Build Quality", value: 52, caption: "bug/stability chatter"),
            BarSection(label: "Hype", value: 70, caption: "visual excitement"),
            BarSection(label: "Support", value: 48, caption: "help requests")
        ] : bars

        let themesArray = dictionary["themes"] as? [String] ?? []
        self.themes = themesArray.isEmpty ? ["Community pulse", "Topics radar", "Hot signals", "Build health", "UX polish", "Dev hurdles"] : themesArray

        self.keyTopics = (dictionary["keyTopics"] as? [String] ?? []).isEmpty ? [
            "Topic A: key insight",
            "Topic B: important finding",
            "Topic C: notable trend",
            "Topic D: discussion point",
            "Topic E: emerging theme",
            "Topic F: community focus"
        ] : (dictionary["keyTopics"] as? [String] ?? [])

        self.notableTrends = (dictionary["notableTrends"] as? [String] ?? []).isEmpty ? [
            "Trend 1: rising interest",
            "Trend 2: shifting sentiment",
            "Trend 3: new developments",
            "Trend 4: ongoing discussion",
            "Trend 5: emerging pattern"
        ] : (dictionary["notableTrends"] as? [String] ?? [])

        let bandDict = dictionary["sentimentBand"] as? [String: Any] ?? [:]
        self.sentimentBand = SentimentBand(
            up: string(bandDict["up"], default: "Positive reactions and excitement"),
            mid: string(bandDict["mid"], default: "Mixed feelings and concerns"),
            down: string(bandDict["down"], default: "Critical analysis and issues")
        )

        let postsArray = (dictionary["topPosts"] as? [[String: Any]] ?? []).map {
            PostItem(title: string($0["title"], default: "Top post"), url: string($0["url"], default: ""))
        }
        if rankedCandidates.isEmpty {
            self.topPosts = postsArray.isEmpty ? [
                PostItem(title: "Top post insight", url: nil),
                PostItem(title: "Notable discussion", url: nil),
                PostItem(title: "Community question", url: nil),
                PostItem(title: "Open issue", url: nil)
            ] : postsArray
        } else {
            self.topPosts = rankedCandidates.prefix(4).map { candidate in
                let url = candidate.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : candidate.url
                return PostItem(title: candidate.title, url: url)
            }
        }

        let sentimentDict = dictionary["sentiment"] as? [String: Any] ?? [:]
        self.sentiment = Sentiment(
            positive: double(sentimentDict["positive"], default: 48),
            neutral: double(sentimentDict["neutral"], default: 32),
            negative: double(sentimentDict["negative"], default: 20)
        )

        self.title = string(dictionary["title"], default: "Content Pulse")
        self.subtitle = string(dictionary["subtitle"], default: "Visual snapshot of the conversation")
        self.focus = string(dictionary["focus"], default: "Based on recent activity")
        self.takeaway = string(dictionary["takeaway"], default: "Community energy at a glance.")
    }
}

// MARK: - Whiteboard View
struct WhiteboardView: View {
    let htmlContent: String
    @Binding var isPresented: Bool
    var onAskAI: ((String) async throws -> String)? = nil
    @State private var webView: WKWebView?
    @State private var isLoading: Bool = true
    @State private var showAskAIResponse = false
    @State private var isAskingAI = false
    @State private var askAIResponse: String?
    @State private var askAIError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                WhiteboardWebView(
                    htmlContent: htmlContent,
                    webView: $webView,
                    isLoading: $isLoading,
                    onAskAI: onAskAI == nil ? nil : { selection in
                        handleAskAISelection(selection)
                    }
                )

                if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                }
            }
            .navigationTitle("Whiteboard")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(htmlContent, forType: .string)
                        #else
                        UIPasteboard.general.string = htmlContent
                        #endif
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .sheet(isPresented: $showAskAIResponse) {
            AskAIResponseSheet(
                isLoading: isAskingAI,
                response: askAIResponse,
                errorMessage: askAIError,
                onClose: { showAskAIResponse = false },
                onCopy: copyAskAIResponse
            )
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 640, maxWidth: .infinity,
                   minHeight: 420, idealHeight: 520, maxHeight: .infinity)
            #endif
        }
    }

    private func handleAskAISelection(_ selection: String) {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let onAskAI else { return }
        isAskingAI = true
        askAIResponse = nil
        askAIError = nil
        showAskAIResponse = true
        Task {
            do {
                let response = try await onAskAI(trimmed)
                await MainActor.run {
                    self.askAIResponse = formatAskAIResponseForDisplay(response)
                    self.isAskingAI = false
                }
            } catch {
                await MainActor.run {
                    self.askAIError = error.localizedDescription
                    self.isAskingAI = false
                }
            }
        }
    }

    private func copyAskAIResponse() {
        guard let askAIResponse, !askAIResponse.isEmpty else { return }
        #if os(iOS)
        UIPasteboard.general.string = askAIResponse
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(askAIResponse, forType: .string)
        #endif
    }
}

// MARK: - Whiteboard WebView
#if os(iOS)
struct WhiteboardWebView: UIViewRepresentable {
    let htmlContent: String
    @Binding var webView: WKWebView?
    @Binding var isLoading: Bool
    var onAskAI: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = onAskAI != nil
        let wv: WKWebView
        if onAskAI != nil {
            let askAIWebView = AskAIWebView(frame: .zero, configuration: config)
            askAIWebView.onAskAI = onAskAI
            askAIWebView.installAskAIMenuItemIfNeeded()
            wv = askAIWebView
        } else {
            wv = WKWebView(frame: .zero, configuration: config)
        }
        wv.navigationDelegate = context.coordinator
        context.coordinator.webView = wv
        if onAskAI != nil, #available(iOS 16.0, *) {
            context.coordinator.installEditMenuInteraction(on: wv)
        }
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear

        DispatchQueue.main.async {
            self.webView = wv
        }

        context.coordinator.lastHTML = htmlContent
        wv.loadHTMLString(htmlContent, baseURL: nil)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != htmlContent else { return }
        context.coordinator.lastHTML = htmlContent
        uiView.loadHTMLString(htmlContent, baseURL: nil)

        if let askAIWebView = uiView as? AskAIWebView {
            askAIWebView.onAskAI = onAskAI
            askAIWebView.installAskAIMenuItemIfNeeded()
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, UIEditMenuInteractionDelegate {
        var parent: WhiteboardWebView
        var lastHTML: String?
        weak var webView: WKWebView?
        private var editMenuInteraction: UIEditMenuInteraction?

        init(parent: WhiteboardWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }

            if let url = navigationAction.request.url,
               navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.cancel)
        }

        @available(iOS 16.0, *)
        func installEditMenuInteraction(on webView: WKWebView) {
            guard editMenuInteraction == nil else { return }
            let interaction = UIEditMenuInteraction(delegate: self)
            webView.addInteraction(interaction)
            editMenuInteraction = interaction
        }

        @available(iOS 16.0, *)
        func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard parent.onAskAI != nil else {
                return UIMenu(children: suggestedActions)
            }
            let askAction = UIAction(title: "Ask AI", image: UIImage(systemName: "sparkles")) { [weak self] _ in
                self?.sendSelectionToAskAI()
            }
            return UIMenu(children: suggestedActions + [askAction])
        }

        private func sendSelectionToAskAI() {
            guard let webView else { return }
            webView.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, error in
                guard error == nil, let selection = result as? String else { return }
                let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                DispatchQueue.main.async {
                    self?.parent.onAskAI?(trimmed)
                }
            }
        }
    }
}
#elseif os(macOS)
struct WhiteboardWebView: NSViewRepresentable {
    let htmlContent: String
    @Binding var webView: WKWebView?
    @Binding var isLoading: Bool
    var onAskAI: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let preferences = WKPreferences()
        preferences.javaScriptEnabled = onAskAI != nil
        config.preferences = preferences

        let wv: WKWebView
        if onAskAI != nil {
            let askAIWebView = AskAIWebViewMac(frame: .zero, configuration: config)
            askAIWebView.onAskAI = onAskAI
            wv = askAIWebView
        } else {
            wv = WKWebView(frame: .zero, configuration: config)
        }
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = false

        // Configure the web view for proper rendering
        wv.setValue(false, forKey: "drawsBackground")

        DispatchQueue.main.async {
            self.webView = wv
        }

        context.coordinator.lastHTML = htmlContent
        wv.loadHTMLString(htmlContent, baseURL: nil)
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != htmlContent else { return }
        context.coordinator.lastHTML = htmlContent
        nsView.loadHTMLString(htmlContent, baseURL: nil)

        if let askAIWebView = nsView as? AskAIWebViewMac {
            askAIWebView.onAskAI = onAskAI
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WhiteboardWebView
        var lastHTML: String?

        init(parent: WhiteboardWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow the initial HTML load
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }

            // Open external links in browser
            if let url = navigationAction.request.url,
               navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}
#endif

// TEMPORARY: GlobalSummaryResultView included here until added to Xcode project
struct GlobalSummaryResultView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let json: String
    let error: String?

    // TTS State Variables
    @State private var isSynthesizingSpeech: Bool = false
    @State private var isSpeakingLocally: Bool = false
    @State private var speechSynthesisError: String? = nil
    @State private var audioPlayer: NSSound?
    @State private var localSpeechSynth: NSSpeechSynthesizer?
    @StateObject private var soundDelegate = SoundDelegate()
    @State private var nextAudioChunk: Data? = nil
    @State private var ttsCanceled: Bool = false
    @State private var localTTSTask: Task<Void, Never>? = nil

    private var parsedResult: GlobalSummaryResult? {
        guard let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(GlobalSummaryResult.self, from: data) else {
            return nil
        }
        return result
    }
    
    private var parsedSummaries: [GlobalSummaryItem] {
        return parsedResult?.summaries ?? []
    }
    
    private var isRedditContent: Bool {
        return parsedResult?.source == "reddit"
    }

    private var hasSummaryContent: Bool {
        !parsedSummaries.isEmpty || !(appState.aggregateSummaryText?.isEmpty ?? true)
    }

    private func summaryStableID(for item: GlobalSummaryItem, index: Int) -> String {
        if let referenceId = item.referenceId, !referenceId.isEmpty {
            return "ref-\(referenceId)-\(index)"
        }
        return "summary-\(item.subject)-\(index)"
    }

    private struct ParsedSummaryRow: Identifiable {
        let id: String
        let index: Int
        let item: GlobalSummaryItem
    }

    private var parsedSummaryRows: [ParsedSummaryRow] {
        parsedSummaries.enumerated().map { index, item in
            ParsedSummaryRow(
                id: summaryStableID(for: item, index: index),
                index: index,
                item: item
            )
        }
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = error, !error.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.callout)
                            .foregroundColor(.primary)
                    }
                    .padding(10)
                    .background(.regularMaterial)
                    .cornerRadius(8)
                }
                
                if appState.isLoading && appState.aggregateSummaryText == nil {
                    VStack(spacing: 20) {
                        Spacer()
                        ProgressView()
                            .scaleEffect(1.5)
                            .progressViewStyle(CircularProgressViewStyle())
                        Text(isRedditContent ? "Summarizing Reddit posts..." : "Summarizing articles...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text(isRedditContent ? "Fetching comments and generating summaries..." : "This may take a moment for large feeds")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if appState.isLoading && appState.aggregateSummaryText != nil {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Refreshing source summaries...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if parsedSummaries.isEmpty && error == nil {
                                Text("No summaries available")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .padding()
                            }
                            ForEach(parsedSummaryRows) { row in
                            let index = row.index
                            let item = row.item
                            VStack(alignment: .leading, spacing: 8) {
                                // Subject/Title
                                HStack {
                                    Text("\(index + 1).")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(item.subject)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                }
                                
                                // Summary
                                Text(item.summary)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                ZStack {
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(.ultraThinMaterial)
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.15),
                                            Color.clear,
                                            Color.black.opacity(0.05)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    .cornerRadius(16)
                                    .blendMode(.overlay)
                                    if isRedditContent {
                                        RoundedRectangle(cornerRadius: 16)
                                            .strokeBorder(AppColors.redditCardBorder(for: colorScheme), lineWidth: 1)
                                    } else {
                                        RoundedRectangle(cornerRadius: 16)
                                            .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1)
                                    }
                                }
                            )
                            .contentShape(Rectangle())  // Make entire area tappable
                            .onTapGesture {
                                // Navigate to the corresponding article or Reddit post
                                if let referenceId = item.referenceId {
                                    if isRedditContent {
                                        if let post = appState.redditPostForGlobalSummaryReference(referenceId) {
                                            appState.setSelectedRedditPost(post)
                                        }
                                    } else {
                                        if let article = appState.articleForGlobalSummaryReference(referenceId) {
                                            appState.setSelectedArticle(article)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    }
                }

                // Aggregate summary display
                if let aggregateText = appState.aggregateSummaryText {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.blue)
                            Text("Overall Summary")
                                .font(.headline)
                            if let providerName = appState.aggregateSummaryProviderName {
                                Text(providerName)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            }
                        }
                        Text(.init(aggregateText))
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding()
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.regularMaterial)
                            if isRedditContent {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(AppColors.redditCardBorder(for: colorScheme), lineWidth: 1)
                            } else {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1)
                            }
                        }
                    )
                }

                if appState.isGeneratingAggregateSummary {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Generating overall summary...")
                            .foregroundColor(.secondary)
                    }
                }

                if let aggregateError = appState.aggregateSummaryError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(aggregateError)
                            .foregroundColor(.secondary)
                    }
                }

                Text("Depending on the number of posts, this may take a while.")
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                // TTS status indicators
                if isSynthesizingSpeech {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                            .padding(.trailing, 5)
                        Text("Reading overview (Cloud TTS)...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if isSpeakingLocally {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                            .padding(.trailing, 5)
                        Text("Reading overview (Local TTS)...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if let ttsError = speechSynthesisError {
                    Text(ttsError)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                HStack(spacing: 8) {
                    Button {
                        let formattedText = parsedSummaries.enumerated()
                            .map { index, item in "\(index + 1). **\(item.subject)**\n\(item.summary)" }
                            .joined(separator: "\n\n")
                        copyToClipboard(formattedText)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())

                    if appState.aggregateSummaryText == nil {
                        Button {
                            appState.generateCombinedGlobalSummary(force: false)
                        } label: {
                            Label("Overall...", systemImage: "sparkles")
                        }
                        .buttonStyle(LiquidGlassButtonStyle())
                        .disabled(appState.isLoading || appState.isGeneratingAggregateSummary || parsedSummaries.isEmpty)
                    }

                    Button {
                        appState.retryLastGlobalSummary()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    .disabled(appState.isLoading || appState.lastGlobalSummaryContext == nil)

                    // Cloud TTS button
                    Button {
                        speakOverviewCloudTTS()
                    } label: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    .ttsActiveGlow(isSynthesizingSpeech, color: .blue)
                    .help("Read aloud (Cloud TTS)")
                    .disabled(isSynthesizingSpeech || isSpeakingLocally || !hasSummaryContent)

                    // Local TTS button
                    Button {
                        speakOverviewLocally()
                    } label: {
                        Image(systemName: "speaker.wave.2.circle")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    .ttsActiveGlow(isSpeakingLocally, color: .green)
                    .help("Read aloud (Local TTS / MLX)")
                    .disabled(isSynthesizingSpeech || !hasSummaryContent)

                    // Stop button
                    Button {
                        stopOverviewSpeech()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    .help("Stop speech")
                    .disabled(!isSynthesizingSpeech && !isSpeakingLocally)

                    Spacer()

                    Button {
                        dismiss()
                        appState.showGlobalSummary = false
                    } label: {
                        Label("Close", systemImage: "xmark.circle")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                }
        }
        .padding()
        .navigationTitle("Summary Overview")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    }

    // MARK: - TTS Methods

    private func buildSpeechText() -> String? {
        if let aggregate = appState.aggregateSummaryText, !aggregate.isEmpty {
            return aggregate
        }
        let items = parsedSummaries
        guard !items.isEmpty else { return nil }
        return items.map { "\($0.subject). \($0.summary)" }.joined(separator: "\n\n")
    }

    private func speakOverviewCloudTTS() {
        ttsCanceled = false
        guard let text = buildSpeechText(), !text.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }

        audioPlayer?.stop()
        audioPlayer = nil
        ShortcutsTTS.shared.stopSpeaking()
        localSpeechSynth?.stopSpeaking()

        isSynthesizingSpeech = true
        isSpeakingLocally = false
        speechSynthesisError = nil

        Task {
            await appState.summaryService.synthesizeSpeechFastStartSplit(
                text: text,
                onFirstChunk: { data in
                    DispatchQueue.main.async {
                        self.playAudio(data: data)
                    }
                },
                onRemainingReady: { data in
                    DispatchQueue.main.async {
                        if let player = self.audioPlayer, player.isPlaying {
                            self.nextAudioChunk = data
                        } else {
                            self.playAudio(data: data)
                        }
                    }
                },
                onComplete: { },
                onError: { error in
                    DispatchQueue.main.async {
                        self.speechSynthesisError = "Speech synthesis failed: \(error.localizedDescription)"
                        self.isSynthesizingSpeech = false
                        self.nextAudioChunk = nil
                    }
                }
            )
        }
    }

    private func stopOverviewSpeech() {
        ttsCanceled = true
        audioPlayer?.stop()
        audioPlayer = nil
        ShortcutsTTS.shared.stopSpeaking()
        localSpeechSynth?.stopSpeaking()
        localTTSTask?.cancel()
        localTTSTask = nil
        nextAudioChunk = nil
        isSynthesizingSpeech = false
        isSpeakingLocally = false
    }

    private func playAudio(data: Data) {
        audioPlayer?.stop()

        let audioData: Data
        if isMP3Data(data) || isAACData(data) {
            audioData = data
        } else {
            audioData = createWavData(from: data, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        }

        audioPlayer = NSSound(data: audioData)
        if let player = audioPlayer {
            player.delegate = soundDelegate
            if !player.play() {
                speechSynthesisError = "Failed to start audio playback."
                isSynthesizingSpeech = false
            }
        } else {
            speechSynthesisError = "Failed to initialize audio player with data."
            isSynthesizingSpeech = false
        }
    }

    private func speakOverviewLocally() {
        guard let text = buildSpeechText(), !text.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }

        // Check if Kokoro engine is selected
        let settings = PersistenceManager.shared.loadSettings()
        if settings.localTTSEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                isSpeakingLocally = false
                speechSynthesisError = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            if isSpeakingLocally {
                localTTSTask?.cancel()
                localTTSTask = nil
                audioPlayer?.stop()
                isSpeakingLocally = false
                return
            }
            audioPlayer?.stop()
            isSpeakingLocally = true
            isSynthesizingSpeech = false
            startKokoroPlaybackOverview(
                text: text,
                voice: settings.kokoroVoice,
                speed: settings.kokoroSpeed,
                setAudioPlayer: { player in audioPlayer = player },
                soundDelegate: soundDelegate,
                taskStore: &localTTSTask,
                onCompleted: {
                    isSpeakingLocally = false
                    localTTSTask = nil
                },
                onError: { message in
                    speechSynthesisError = message
                    isSpeakingLocally = false
                }
            )
            return
        }

        // macOS native: use ShortcutsTTS
        if isSpeakingLocally {
            ShortcutsTTS.shared.stopSpeaking()
            isSpeakingLocally = false
            return
        }

        audioPlayer?.stop()
        isSpeakingLocally = true
        isSynthesizingSpeech = false

        let success = ShortcutsTTS.shared.speakText(text) {
            DispatchQueue.main.async {
                self.isSpeakingLocally = false
            }
        }

        if !success {
            isSpeakingLocally = false
            speechSynthesisError = "Failed to start Shortcuts TTS on macOS."
        }
    }

    private func startKokoroPlaybackOverview(
        text: String,
        voice: String,
        speed: Double,
        setAudioPlayer: @escaping (NSSound?) -> Void,
        soundDelegate: SoundDelegate,
        taskStore: inout Task<Void, Never>?,
        onCompleted: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        _ = soundDelegate
        taskStore?.cancel()
        taskStore = Task {
            defer {
                if !PersistenceManager.shared.loadSettings().kokoroPrecacheEnabled {
                    KokoroTTSService.shared.unloadIfAllowed()
                }
                Task { @MainActor in
                    onCompleted()
                }
            }
            do {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                func makeKokoroChunks(from input: String) -> [String] {
                    let firstSize = min(240, input.count)
                    let firstChunk = String(input.prefix(firstSize))
                    let remaining = String(input.dropFirst(firstSize)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !remaining.isEmpty else { return [firstChunk] }

                    var chunks: [String] = [firstChunk]
                    let sentences = remaining.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                    var current = ""
                    let maxChunkSize = 420
                    for sentence in sentences {
                        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmedSentence.isEmpty { continue }
                        let sentenceWithPunctuation = trimmedSentence + "."
                        if current.count + sentenceWithPunctuation.count <= maxChunkSize {
                            current += (current.isEmpty ? "" : " ") + sentenceWithPunctuation
                        } else {
                            if !current.isEmpty { chunks.append(current) }
                            current = sentenceWithPunctuation
                        }
                    }
                    if !current.isEmpty { chunks.append(current) }
                    return chunks
                }

                let chunks = makeKokoroChunks(from: trimmed)
                guard let firstChunk = chunks.first else { return }

                func playChunk(_ data: Data) async throws -> TimeInterval {
                    try await MainActor.run {
                        guard let player = NSSound(data: data) else {
                            onError("Failed to initialize audio player.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        setAudioPlayer(player)
                        if player.play() == false {
                            onError("Failed to start audio playback.")
                            throw NSError(domain: "KokoroPlayback", code: -1)
                        }
                        return player.duration
                    }
                }

                enum KokoroPlaybackError: Error { case timeout }

                func synthesizeWithTimeout(_ text: String) async throws -> Data {
                    try await withThrowingTaskGroup(of: Data.self) { group in
                        group.addTask {
                            try await KokoroTTSService.shared.synthesize(
                                text: text,
                                voice: voice,
                                speed: Float(speed)
                            )
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 20_000_000_000)
                            throw KokoroPlaybackError.timeout
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                }

                let firstData = try await synthesizeWithTimeout(firstChunk)
                if Task.isCancelled { return }
                var currentDuration = try await playChunk(firstData)

                if chunks.count == 1 { return }

                var nextIndex = 1
                var nextTask: Task<Data, Error>? = Task {
                    try await synthesizeWithTimeout(chunks[nextIndex])
                }
                defer { nextTask?.cancel() }

                while nextIndex < chunks.count {
                    try await Task.sleep(nanoseconds: UInt64(currentDuration * 1_000_000_000))
                    if Task.isCancelled { return }

                    guard let task = nextTask else { return }
                    let data = try await task.value
                    nextIndex += 1

                    if nextIndex < chunks.count {
                        nextTask = Task {
                            try await synthesizeWithTimeout(chunks[nextIndex])
                        }
                    } else {
                        nextTask = nil
                    }

                    currentDuration = try await playChunk(data)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    let message: String
                    if let kokoroError = error as? KokoroTTSServiceError, kokoroError == .notAvailable {
                        message = "MLX TTS is not available. Add the MLXAudio package and model access."
                    } else if String(describing: error).contains("timeout") {
                        message = "Kokoro is still loading models. Please wait a moment and try again."
                    } else {
                        message = "Kokoro TTS failed: \(error.localizedDescription)"
                    }
                    onError(message)
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
