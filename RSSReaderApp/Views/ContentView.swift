import SwiftUI
@preconcurrency import WebKit
import Combine
import Kingfisher
import SwiftSoup // <-- Add SwiftSoup import

private let articleAntiBlockPhrases = [
    "ad or script blocking software",
    "ad blocking software is interfering",
    "script blocking software is interfering",
    "disable any ad or script blocking software",
    "disable any ad blocking software",
    "disable any script blocking software"
]

private let articleAntiBlockAdSelectors = [
    "script",
    "style",
    "iframe",
    "frame",
    "ins",
    "noscript",
    "object",
    "embed",
    "form",
    "amp-ad",
    "amp-embed",
    "[role=\"advertisement\"]",
    "[data-ad]",
    "[data-ads]",
    "[data-ad-client]",
    "[data-ad-slot]",
    "[data-ad-unit]",
    "[data-dfp]",
    "[data-gpt]",
    "[data-google-query-id]",
    ".adsbygoogle",
    ".ad-container",
    ".author_ad",
    ".inlinead",
    ".google-auto-placed",
    ".googlepublisherpluginad"
]

private let articleAntiBlockAdSelectorString = articleAntiBlockAdSelectors.joined(separator: ", ")
private let articleReaderMobileSafariUserAgent = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

private func containsArticleAntiBlockMessage(_ text: String) -> Bool {
    let normalized = text
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    guard !normalized.isEmpty else { return false }
    return articleAntiBlockPhrases.contains { normalized.contains($0) }
}

private func javaScriptStringLiteral(_ value: String) -> String {
    var escaped = value
    escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
    escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
    escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
    escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
    escaped = escaped.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
    escaped = escaped.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    return "\"\(escaped)\""
}

private func javaScriptArrayLiteral(_ values: [String]) -> String {
    "[" + values.map(javaScriptStringLiteral).joined(separator: ",") + "]"
}

private func articleAntiBlockCheckJavaScript() -> String {
    let phrases = javaScriptArrayLiteral(articleAntiBlockPhrases)
    return """
    (function() {
      var phrases = \(phrases);
      function normalizeText(text) {
        return (text || '').replace(/\\s+/g, ' ').trim().toLowerCase();
      }
      var text = normalizeText(document.body ? document.body.innerText : '');
      return phrases.some(function(phrase) { return text.indexOf(phrase) !== -1; });
    })();
    """
}

private func is9to5MacArticleURL(_ url: URL?) -> Bool {
    guard let host = url?.host?.lowercased() else { return false }
    return host == "9to5mac.com" || host.hasSuffix(".9to5mac.com")
}

private func articleAntiBlockCleanupJavaScript() -> String {
    let phrases = javaScriptArrayLiteral(articleAntiBlockPhrases)
    let selectors = javaScriptStringLiteral(articleAntiBlockAdSelectorString)
    return """
    (function() {
      var phrases = \(phrases);
      var selectors = \(selectors);

      function normalizeText(text) {
        return (text || '').replace(/\\s+/g, ' ').trim().toLowerCase();
      }

      function hasAntiBlockText(text) {
        var normalized = normalizeText(text);
        if (!normalized) { return false; }
        return phrases.some(function(phrase) { return normalized.indexOf(phrase) !== -1; });
      }

      function removeNode(node) {
        if (!node || !node.parentNode || node === document.body || node === document.documentElement) { return; }
        node.parentNode.removeChild(node);
      }

      function injectCSS() {
        if (!document.head || document.getElementById('__rssArticleAntiBlockCSS')) { return; }
        var style = document.createElement('style');
        style.id = '__rssArticleAntiBlockCSS';
        style.textContent = selectors + ' { display: none !important; visibility: hidden !important; width: 0 !important; min-width: 0 !important; max-width: 0 !important; height: 0 !important; min-height: 0 !important; max-height: 0 !important; margin: 0 !important; padding: 0 !important; border: 0 !important; overflow: hidden !important; }';
        document.head.appendChild(style);
      }

      function cleanup(root) {
        var scope = root || document;
        injectCSS();

        try {
          scope.querySelectorAll(selectors).forEach(function(node) {
            if ((node.tagName || '').toLowerCase() === 'style') { return; }
            removeNode(node);
          });
        } catch (_) {}

        var containers = Array.prototype.slice.call(scope.querySelectorAll('p, div, section, aside, figure, span, strong, b'));
        if (scope.matches && scope.matches('p, div, section, aside, figure, span, strong, b')) {
          containers.unshift(scope);
        }

        containers.forEach(function(element) {
          var text = normalizeText(element.innerText || element.textContent || '');
          if (text && text.length < 900 && hasAntiBlockText(text)) {
            removeNode(element.closest('section, aside, figure, div, p') || element);
          }
        });
      }

      cleanup(document);

      if (window.__rssArticleAntiBlockObserver) {
        window.__rssArticleAntiBlockObserver.disconnect();
      }

      if (document.documentElement && window.MutationObserver) {
        window.__rssArticleAntiBlockObserver = new MutationObserver(function() {
          cleanup(document);
        });
        window.__rssArticleAntiBlockObserver.observe(document.documentElement, {
          childList: true,
          subtree: true,
          characterData: true
        });
      }

      if (window.__rssArticleAntiBlockInterval) {
        clearInterval(window.__rssArticleAntiBlockInterval);
      }

      var ticks = 0;
      window.__rssArticleAntiBlockInterval = setInterval(function() {
        cleanup(document);
        ticks += 1;
        if (ticks >= 80) {
          clearInterval(window.__rssArticleAntiBlockInterval);
          window.__rssArticleAntiBlockInterval = null;
        }
      }, 125);

      return hasAntiBlockText(document.body ? (document.body.innerText || document.body.textContent || '') : '');
    })();
    """
}

#if os(iOS)
import AVFoundation
import UIKit

private extension Notification.Name {
    static let articleReaderScrollToTopRequested = Notification.Name("articleReaderScrollToTopRequested")
}

// MARK: - Reader Mode Service (Mozilla Readability.js)
// Provides intelligent article extraction using the same algorithm as Safari Reader, Firefox, and Pocket

enum ReaderModeService {
    /// JavaScript that loads Readability.js and extracts the article content.
    /// Returns a clean HTML document with just the article content.
    static func toggleScript(useCompactTitle: Bool) -> String {
        useCompactTitle ? compactToggleScript : regularToggleScript
    }

    private static let compactToggleScript = makeToggleScript(useCompactTitle: true)
    private static let regularToggleScript = makeToggleScript(useCompactTitle: false)
    private static let readabilitySource = loadReadabilitySource()

    private static func makeToggleScript(useCompactTitle: Bool) -> String {
        let readability = readabilitySource
        let titleFontSize = useCompactTitle ? 28 : 30
        let antiBlockPhrasesJS = javaScriptArrayLiteral(articleAntiBlockPhrases)
        let antiBlockSelectorsJS = javaScriptStringLiteral(articleAntiBlockAdSelectorString)
        let readerScript = """
        (function() {
          try {
            var antiBlockPhrases = \(antiBlockPhrasesJS);
            var antiBlockSelectors = \(antiBlockSelectorsJS);

            function normalizeAntiBlockText(text) {
              return (text || '').replace(/\\s+/g, ' ').trim().toLowerCase();
            }

            function containsAntiBlockMessage(text) {
              var normalized = normalizeAntiBlockText(text);
              if (!normalized) { return false; }
              return antiBlockPhrases.some(function(phrase) {
                return normalized.indexOf(phrase) !== -1;
              });
            }

            function removeElement(el) {
              if (el && el.parentElement) {
                el.parentElement.removeChild(el);
              }
            }

            function shouldCleanAntiBlockDocument() {
              var host = (location.hostname || '').toLowerCase();
              return host === '9to5mac.com' || host.slice(-12) === '.9to5mac.com';
            }

            function removeAntiBlockNodes(root, preserveStyleElements) {
              var scope = root || document;
              if (!scope.querySelectorAll) { return; }

              try {
                var matchingNodes = scope.querySelectorAll(antiBlockSelectors);
                matchingNodes.forEach(function(el) {
                  if (preserveStyleElements && (el.tagName || '').toLowerCase() === 'style') { return; }
                  removeElement(el);
                });
              } catch (e) {}

              var containers = Array.prototype.slice.call(scope.querySelectorAll('p, div, section, aside, figure, span, strong, b'));
              if (scope.matches && scope.matches('p, div, section, aside, figure, span, strong, b')) {
                containers.unshift(scope);
              }

              containers.forEach(function(el) {
                var text = normalizeAntiBlockText(el.textContent || '');
                if (text.length > 0 && text.length < 900 && containsAntiBlockMessage(text)) {
                  removeElement(el);
                }
              });
            }

            function injectAntiBlockCSS() {
              if (!document.head || document.getElementById('__rssArticleAntiBlockCSS')) { return; }
              var style = document.createElement('style');
              style.id = '__rssArticleAntiBlockCSS';
              style.textContent = antiBlockSelectors + ' { display: none !important; visibility: hidden !important; }';
              document.head.appendChild(style);
            }

            function cleanupAntiBlockDocument() {
              injectAntiBlockCSS();
              removeAntiBlockNodes(document, true);
            }

            function installAntiBlockCleanup() {
              cleanupAntiBlockDocument();

              if (window.__rssArticleAntiBlockObserver) {
                window.__rssArticleAntiBlockObserver.disconnect();
              }

              if (document.documentElement && window.MutationObserver) {
                window.__rssArticleAntiBlockObserver = new MutationObserver(function() {
                  cleanupAntiBlockDocument();
                });
                window.__rssArticleAntiBlockObserver.observe(document.documentElement, {
                  childList: true,
                  subtree: true
                });
              }

              if (window.__rssArticleAntiBlockInterval) {
                clearInterval(window.__rssArticleAntiBlockInterval);
              }

              var ticks = 0;
              window.__rssArticleAntiBlockInterval = setInterval(function() {
                cleanupAntiBlockDocument();
                ticks += 1;
                if (ticks >= 80) {
                  clearInterval(window.__rssArticleAntiBlockInterval);
                  window.__rssArticleAntiBlockInterval = null;
                }
              }, 125);
            }

            function articleHTMLIsDominantlyAntiBlock(html) {
              if (!containsAntiBlockMessage(html)) { return false; }
              var probe = document.createElement('div');
              probe.innerHTML = html || '';
              removeAntiBlockNodes(probe, false);
              var text = normalizeAntiBlockText(probe.textContent || '');
              return text.length < 180;
            }

            // If reader mode is already active, reload the original page
            if (window.__rssReaderModeActive) {
              window.__rssReaderModeActive = false;
              var url = window.__rssReaderOriginalURL || location.href;
              if (url) { location.href = url; }
              return false;
            }

            if (shouldCleanAntiBlockDocument()) {
              cleanupAntiBlockDocument();
            }

            // Check if Readability is available
            if (typeof Readability === 'undefined') { return false; }

            // Clone the document and parse with Readability
            var clone = document.cloneNode(true);
            var article = new Readability(clone).parse();
            if (!article || !article.content) { return false; }
            if (articleHTMLIsDominantlyAntiBlock(article.content)) { return false; }

            // Escape HTML for safe display
            function escapeHtml(text) {
              return (text || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
            }

            // Clean up promotional/ad content from the extracted article
            function cleanContent(html) {
              var div = document.createElement('div');
              div.innerHTML = html;
              if (shouldCleanAntiBlockDocument() || containsAntiBlockMessage(html)) {
                removeAntiBlockNodes(div, false);
              }

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
              // First, find ALL elements and check if they're section headers
              var allElements = div.querySelectorAll('*');
              var elementsToRemove = [];

              allElements.forEach(function(el) {
                var text = (el.textContent || '').toLowerCase().trim();
                // Check if this element's direct text (not children) matches a section header
                var directText = '';
                for (var i = 0; i < el.childNodes.length; i++) {
                  if (el.childNodes[i].nodeType === 3) { // Text node
                    directText += el.childNodes[i].textContent;
                  }
                }
                directText = directText.toLowerCase().trim();

                var isHeaderElement = sectionHeaders.some(function(p) {
                  return directText === p || (directText.indexOf(p) !== -1 && directText.length < 50);
                });

                if (isHeaderElement) {
                  console.log('Reader: Found section header to remove:', directText);
                  // Find the section container (parent div/section/aside)
                  var container = el;
                  while (container.parentElement &&
                         container.parentElement.tagName !== 'BODY' &&
                         container.parentElement.tagName !== 'ARTICLE' &&
                         container.parentElement.tagName !== 'DIV') {
                    container = container.parentElement;
                  }
                  // Remove this element and all following siblings
                  var current = container;
                  while (current) {
                    var next = current.nextElementSibling;
                    elementsToRemove.push(current);
                    current = next;
                  }
                }
              });

              // Remove collected elements
              elementsToRemove.forEach(function(el) {
                if (el.parentElement) {
                  el.parentElement.removeChild(el);
                }
              });

              // Second pass: remove any remaining elements containing section header text
              var remaining = div.querySelectorAll('h1, h2, h3, h4, h5, h6, strong, b, header, section, aside');
              remaining.forEach(function(el) {
                var text = (el.textContent || '').toLowerCase().trim();
                var isSection = sectionHeaders.some(function(p) { return text === p || (text.indexOf(p) !== -1 && text.length < 100); });
                if (isSection && el.parentElement) {
                  console.log('Reader: Removing section element:', text.substring(0, 50));
                  el.parentElement.removeChild(el);
                }
              });

              // Google News badge patterns to remove image-only promos
              var googleBadgePatterns = [
                'preferred source on google',
                'add as a preferred',
                'add as preferred',
                'follow on google news',
                'follow us on google news',
                'add to google news'
              ];

              function hasGoogleBadgeText(text) {
                var normalized = (text || '').toLowerCase();
                return googleBadgePatterns.some(function(p) { return normalized.indexOf(p) !== -1; });
              }

              function hasGoogleBadgeAttr(el) {
                if (!el || !el.getAttribute) { return false; }
                var aria = el.getAttribute('aria-label') || '';
                var title = el.getAttribute('title') || '';
                var alt = el.getAttribute('alt') || '';
                return hasGoogleBadgeText(aria) || hasGoogleBadgeText(title) || hasGoogleBadgeText(alt);
              }

              // FIRST: Remove Google News promotional links and their containers (including images inside them)
              // These are the "Add as a preferred source on Google" banners
              // Be surgical - only remove links to Google promotional URLs, not all Google images
              var googlePromoLinks = div.querySelectorAll('a[href*="news.google.com"], a[href*="google.com/publisher"], a[href*="google.com/s/notification"], a[href*="google.com/alerts"], a[href*="google.com/publications"]');
              googlePromoLinks.forEach(function(link) {
                // Find the best container to remove (figure > div > parent)
                var container = link.closest('figure') || link.closest('aside');
                if (container && container.parentElement) {
                  container.parentElement.removeChild(container);
                } else if (link.parentElement) {
                  link.parentElement.removeChild(link);
                }
              });

              // Remove badge-style Google News promos that are image-only (no visible text)
              var googleBadgeImages = div.querySelectorAll('img');
              googleBadgeImages.forEach(function(img) {
                if (!hasGoogleBadgeAttr(img)) { return; }
                var container = img.closest('figure') || img.closest('picture') || img.closest('aside') || img.closest('a') || img;
                if (container && container.parentElement) {
                  container.parentElement.removeChild(container);
                }
              });

              var googleBadgeLinks = div.querySelectorAll('a[aria-label], a[title]');
              googleBadgeLinks.forEach(function(link) {
                if (!hasGoogleBadgeAttr(link)) { return; }
                var container = link.closest('figure') || link.closest('aside') || link;
                if (container && container.parentElement) {
                  container.parentElement.removeChild(container);
                }
              });

              // Remove containers that have promotional text like "Add as a preferred source"
              // But be careful not to remove article content
              var allContainers = div.querySelectorAll('figure, aside, div');
              allContainers.forEach(function(el) {
                var text = (el.textContent || '').toLowerCase().trim();
                // Only remove if it's SHORT text that matches promo patterns (not article paragraphs)
                if (text.length < 100 && text.length > 5) {
                  if (text.indexOf('preferred source') !== -1 ||
                      text.indexOf('add as a preferred') !== -1 ||
                      text.indexOf('follow us on google') !== -1 ||
                      text.indexOf('follow on google news') !== -1) {
                    el.parentElement && el.parentElement.removeChild(el);
                  }
                }
              });

              // Pass 2: Remove entire ULs that look like affiliate link lists
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

              // Pass 3: Remove individual affiliate links and their parent LIs
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

              // Pass 4: Remove elements with promotional text
              var elements = div.querySelectorAll('li, figure, div, p, a, span');
              elements.forEach(function(el) {
                var text = (el.textContent || '').toLowerCase();
                var isPromo = promoPatterns.some(function(p) { return text.indexOf(p) !== -1; });
                if (isPromo && text.length < 400) {
                  el.parentElement && el.parentElement.removeChild(el);
                }
              });

              // Clean up empty elements (multiple passes)
              for (var i = 0; i < 3; i++) {
                var empties = div.querySelectorAll('p:empty, div:empty, figure:empty, ul:empty, li:empty, span:empty, a:empty');
                empties.forEach(function(el) { el.parentElement && el.parentElement.removeChild(el); });
              }

              return div.innerHTML;
            }

            var cleanedContent = cleanContent(article.content);
            if (articleHTMLIsDominantlyAntiBlock(cleanedContent)) { return false; }
            var title = article.title || document.title || '';
            var byline = article.byline || '';
            var bylineHtml = byline ? '<div class="reader-byline">' + escapeHtml(byline) + '</div>' : '';
            var baseHref = document.baseURI || location.href;
            var dirAttr = article.dir ? ' dir="' + article.dir + '"' : '';

            // Build the reader mode HTML document
            var html = '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
              '<base href="' + baseHref + '">' +
              '<title>' + escapeHtml(title) + '</title>' +
              '<style>' +
              ':root { --bg-color: #f6f4ef; --text-color: #1e1e1e; --secondary-color: #6b6b6b; --link-color: #007AFF; }' +
              '@media (prefers-color-scheme: dark) { :root { --bg-color: #101113; --text-color: #f2f2f2; --secondary-color: #a5a5a5; --link-color: #5AC8FA; } }' +
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

            // Store original URL and replace document
            window.__rssReaderOriginalURL = location.href;
            document.open();
            document.write(html);
            document.close();
            if (shouldCleanAntiBlockDocument()) {
              installAntiBlockCleanup();
            }
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

private func ensureBackgroundTTSReady() {
    let audioSession = AVAudioSession.sharedInstance()
    do {
        try audioSession.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP]
        )
        try audioSession.setActive(true)
    } catch {
        print("🔊 [ContentView] Failed to configure audio session: \(error)")
    }
}
#elseif os(macOS)
import AppKit

// MARK: - Reader Mode Service (Mozilla Readability.js) - macOS
// Provides intelligent article extraction using the same algorithm as Safari Reader, Firefox, and Pocket

enum ReaderModeService {
    /// JavaScript that loads Readability.js and extracts the article content.
    static func toggleScript(useCompactTitle: Bool) -> String {
        let readability = loadReadabilitySource()
        let antiBlockPhrasesJS = javaScriptArrayLiteral(articleAntiBlockPhrases)
        let antiBlockSelectorsJS = javaScriptStringLiteral(articleAntiBlockAdSelectorString)
        let readerScript = """
        (function() {
          try {
            var antiBlockPhrases = \(antiBlockPhrasesJS);
            var antiBlockSelectors = \(antiBlockSelectorsJS);

            function normalizeAntiBlockText(text) {
              return (text || '').replace(/\\s+/g, ' ').trim().toLowerCase();
            }

            function containsAntiBlockMessage(text) {
              var normalized = normalizeAntiBlockText(text);
              if (!normalized) { return false; }
              return antiBlockPhrases.some(function(phrase) {
                return normalized.indexOf(phrase) !== -1;
              });
            }

            function removeElement(el) {
              if (el && el.parentElement) {
                el.parentElement.removeChild(el);
              }
            }

            function shouldCleanAntiBlockDocument() {
              var host = (location.hostname || '').toLowerCase();
              return host === '9to5mac.com' || host.slice(-12) === '.9to5mac.com';
            }

            function removeAntiBlockNodes(root, preserveStyleElements) {
              var scope = root || document;
              if (!scope.querySelectorAll) { return; }

              try {
                var matchingNodes = scope.querySelectorAll(antiBlockSelectors);
                matchingNodes.forEach(function(el) {
                  if (preserveStyleElements && (el.tagName || '').toLowerCase() === 'style') { return; }
                  removeElement(el);
                });
              } catch (e) {}

              var containers = Array.prototype.slice.call(scope.querySelectorAll('p, div, section, aside, figure, span, strong, b'));
              if (scope.matches && scope.matches('p, div, section, aside, figure, span, strong, b')) {
                containers.unshift(scope);
              }

              containers.forEach(function(el) {
                var text = normalizeAntiBlockText(el.textContent || '');
                if (text.length > 0 && text.length < 900 && containsAntiBlockMessage(text)) {
                  removeElement(el);
                }
              });
            }

            function injectAntiBlockCSS() {
              if (!document.head || document.getElementById('__rssArticleAntiBlockCSS')) { return; }
              var style = document.createElement('style');
              style.id = '__rssArticleAntiBlockCSS';
              style.textContent = antiBlockSelectors + ' { display: none !important; visibility: hidden !important; }';
              document.head.appendChild(style);
            }

            function cleanupAntiBlockDocument() {
              injectAntiBlockCSS();
              removeAntiBlockNodes(document, true);
            }

            function installAntiBlockCleanup() {
              cleanupAntiBlockDocument();

              if (window.__rssArticleAntiBlockObserver) {
                window.__rssArticleAntiBlockObserver.disconnect();
              }

              if (document.documentElement && window.MutationObserver) {
                window.__rssArticleAntiBlockObserver = new MutationObserver(function() {
                  cleanupAntiBlockDocument();
                });
                window.__rssArticleAntiBlockObserver.observe(document.documentElement, {
                  childList: true,
                  subtree: true
                });
              }

              if (window.__rssArticleAntiBlockInterval) {
                clearInterval(window.__rssArticleAntiBlockInterval);
              }

              var ticks = 0;
              window.__rssArticleAntiBlockInterval = setInterval(function() {
                cleanupAntiBlockDocument();
                ticks += 1;
                if (ticks >= 80) {
                  clearInterval(window.__rssArticleAntiBlockInterval);
                  window.__rssArticleAntiBlockInterval = null;
                }
              }, 125);
            }

            function articleHTMLIsDominantlyAntiBlock(html) {
              if (!containsAntiBlockMessage(html)) { return false; }
              var probe = document.createElement('div');
              probe.innerHTML = html || '';
              removeAntiBlockNodes(probe, false);
              var text = normalizeAntiBlockText(probe.textContent || '');
              return text.length < 180;
            }

            if (window.__rssReaderModeActive) {
              window.__rssReaderModeActive = false;
              var url = window.__rssReaderOriginalURL || location.href;
              if (url) { location.href = url; }
              return false;
            }

            if (shouldCleanAntiBlockDocument()) {
              cleanupAntiBlockDocument();
            }

            if (typeof Readability === 'undefined') { return false; }

            var clone = document.cloneNode(true);
            var article = new Readability(clone).parse();
            if (!article || !article.content) { return false; }
            if (articleHTMLIsDominantlyAntiBlock(article.content)) { return false; }

            function escapeHtml(text) {
              return (text || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
            }

            // Clean up promotional/ad content from the extracted article
            function cleanContent(html) {
              var div = document.createElement('div');
              div.innerHTML = html;
              if (shouldCleanAntiBlockDocument() || containsAntiBlockMessage(html)) {
                removeAntiBlockNodes(div, false);
              }

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
              // First, find ALL elements and check if they're section headers
              var allElements = div.querySelectorAll('*');
              var elementsToRemove = [];

              allElements.forEach(function(el) {
                var text = (el.textContent || '').toLowerCase().trim();
                // Check if this element's direct text (not children) matches a section header
                var directText = '';
                for (var i = 0; i < el.childNodes.length; i++) {
                  if (el.childNodes[i].nodeType === 3) { // Text node
                    directText += el.childNodes[i].textContent;
                  }
                }
                directText = directText.toLowerCase().trim();

                var isHeaderElement = sectionHeaders.some(function(p) {
                  return directText === p || (directText.indexOf(p) !== -1 && directText.length < 50);
                });

                if (isHeaderElement) {
                  console.log('Reader: Found section header to remove:', directText);
                  // Find the section container (parent div/section/aside)
                  var container = el;
                  while (container.parentElement &&
                         container.parentElement.tagName !== 'BODY' &&
                         container.parentElement.tagName !== 'ARTICLE' &&
                         container.parentElement.tagName !== 'DIV') {
                    container = container.parentElement;
                  }
                  // Remove this element and all following siblings
                  var current = container;
                  while (current) {
                    var next = current.nextElementSibling;
                    elementsToRemove.push(current);
                    current = next;
                  }
                }
              });

              // Remove collected elements
              elementsToRemove.forEach(function(el) {
                if (el.parentElement) {
                  el.parentElement.removeChild(el);
                }
              });

              // Second pass: remove any remaining elements containing section header text
              var remaining = div.querySelectorAll('h1, h2, h3, h4, h5, h6, strong, b, header, section, aside');
              remaining.forEach(function(el) {
                var text = (el.textContent || '').toLowerCase().trim();
                var isSection = sectionHeaders.some(function(p) { return text === p || (text.indexOf(p) !== -1 && text.length < 100); });
                if (isSection && el.parentElement) {
                  console.log('Reader: Removing section element:', text.substring(0, 50));
                  el.parentElement.removeChild(el);
                }
              });

              // Google News badge patterns to remove image-only promos
              var googleBadgePatterns = [
                'preferred source on google',
                'add as a preferred',
                'add as preferred',
                'follow on google news',
                'follow us on google news',
                'add to google news'
              ];

              function hasGoogleBadgeText(text) {
                var normalized = (text || '').toLowerCase();
                return googleBadgePatterns.some(function(p) { return normalized.indexOf(p) !== -1; });
              }

              function hasGoogleBadgeAttr(el) {
                if (!el || !el.getAttribute) { return false; }
                var aria = el.getAttribute('aria-label') || '';
                var title = el.getAttribute('title') || '';
                var alt = el.getAttribute('alt') || '';
                return hasGoogleBadgeText(aria) || hasGoogleBadgeText(title) || hasGoogleBadgeText(alt);
              }

              // FIRST: Remove Google News promotional links and their containers (including images inside them)
              // These are the "Add as a preferred source on Google" banners
              // Be surgical - only remove links to Google promotional URLs, not all Google images
              var googlePromoLinks = div.querySelectorAll('a[href*="news.google.com"], a[href*="google.com/publisher"], a[href*="google.com/s/notification"], a[href*="google.com/alerts"], a[href*="google.com/publications"]');
              googlePromoLinks.forEach(function(link) {
                // Find the best container to remove (figure > div > parent)
                var container = link.closest('figure') || link.closest('aside');
                if (container && container.parentElement) {
                  container.parentElement.removeChild(container);
                } else if (link.parentElement) {
                  link.parentElement.removeChild(link);
                }
              });

              // Remove badge-style Google News promos that are image-only (no visible text)
              var googleBadgeImages = div.querySelectorAll('img');
              googleBadgeImages.forEach(function(img) {
                if (!hasGoogleBadgeAttr(img)) { return; }
                var container = img.closest('figure') || img.closest('picture') || img.closest('aside') || img.closest('a') || img;
                if (container && container.parentElement) {
                  container.parentElement.removeChild(container);
                }
              });

              var googleBadgeLinks = div.querySelectorAll('a[aria-label], a[title]');
              googleBadgeLinks.forEach(function(link) {
                if (!hasGoogleBadgeAttr(link)) { return; }
                var container = link.closest('figure') || link.closest('aside') || link;
                if (container && container.parentElement) {
                  container.parentElement.removeChild(container);
                }
              });

              // Remove containers that have promotional text like "Add as a preferred source"
              // But be careful not to remove article content
              var allContainers = div.querySelectorAll('figure, aside, div');
              allContainers.forEach(function(el) {
                var text = (el.textContent || '').toLowerCase().trim();
                // Only remove if it's SHORT text that matches promo patterns (not article paragraphs)
                if (text.length < 100 && text.length > 5) {
                  if (text.indexOf('preferred source') !== -1 ||
                      text.indexOf('add as a preferred') !== -1 ||
                      text.indexOf('follow us on google') !== -1 ||
                      text.indexOf('follow on google news') !== -1) {
                    el.parentElement && el.parentElement.removeChild(el);
                  }
                }
              });

              // Pass 2: Remove entire ULs that look like affiliate link lists
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

              // Pass 3: Remove individual affiliate links and their parent LIs
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

              // Pass 4: Remove elements with promotional text
              var elements = div.querySelectorAll('li, figure, div, p, a, span');
              elements.forEach(function(el) {
                var text = (el.textContent || '').toLowerCase();
                var isPromo = promoPatterns.some(function(p) { return text.indexOf(p) !== -1; });
                if (isPromo && text.length < 400) {
                  el.parentElement && el.parentElement.removeChild(el);
                }
              });

              // Clean up empty elements (multiple passes)
              for (var i = 0; i < 3; i++) {
                var empties = div.querySelectorAll('p:empty, div:empty, figure:empty, ul:empty, li:empty, span:empty, a:empty');
                empties.forEach(function(el) { el.parentElement && el.parentElement.removeChild(el); });
              }

              return div.innerHTML;
            }

            var cleanedContent = cleanContent(article.content);
            if (articleHTMLIsDominantlyAntiBlock(cleanedContent)) { return false; }
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
              '@media (prefers-color-scheme: dark) { :root { --bg-color: #101113; --text-color: #f2f2f2; --secondary-color: #a5a5a5; --link-color: #5AC8FA; } }' +
              'body { margin: 0; background: var(--bg-color); color: var(--text-color); }' +
              '.reader-shell { max-width: 860px; margin: 0 auto; padding: 32px 20px 60px; }' +
              '.reader-title { font-size: 30px; line-height: 1.2; margin: 0 0 16px; font-weight: 700; }' +
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
            if (shouldCleanAntiBlockDocument()) {
              installAntiBlockCleanup();
            }
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

        print("⚠️ ReaderModeService: Readability.js not found in bundle")
        return ""
    }
}

private func ensureBackgroundTTSReady() {}
#else
private func ensureBackgroundTTSReady() {}
#endif

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
    
    private var isDetailActive: Bool {
        appState.selectedArticle != nil || appState.selectedRedditPost != nil
    }
    
    func body(content: Content) -> some View {
        content
            .gesture(primaryNavigationGesture)
            #if os(iOS)
            .simultaneousGesture(trackpadGesture)
            #endif
            .onKeyPress(.leftArrow) { 
                if appState.canGoBack && isDetailActive {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        appState.navigateBackInHistory()
                    }
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.rightArrow) { 
                if appState.canGoForward && isDetailActive {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        appState.navigateForwardInHistory()
                    }
                    return .handled
                }
                return .ignored
            }
    }
    
    // Primary gesture for touch and general interaction
    private var primaryNavigationGesture: some Gesture {
        DragGesture(minimumDistance: 25, coordinateSpace: .local)
            .onEnded { value in
                let horizontalAmount = value.translation.width
                let verticalAmount = value.translation.height
                
                // Ensure horizontal swipe is dominant (at least roughly 3:2 ratio)
                guard abs(horizontalAmount) > abs(verticalAmount) * 1.5 else { return }
                
                guard isDetailActive else { return }
                
                if horizontalAmount > 0 && appState.canGoBack {
                    // Swipe right - go back
                    withAnimation(.easeInOut(duration: 0.14)) {
                        appState.navigateBackInHistory()
                    }
                } else if horizontalAmount < 0 && appState.canGoForward {
                    // Swipe left - go forward
                    withAnimation(.easeInOut(duration: 0.14)) {
                        appState.navigateForwardInHistory()
                    }
                }
            }
    }
    
    #if os(iOS)
    // Trackpad gesture for iPad and Mac
    private var trackpadGesture: some Gesture {
        // Use a more sensitive gesture for trackpad
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onEnded { value in
                let horizontalAmount = value.translation.width
                let verticalAmount = value.translation.height
                
                // Different sensitivity for trackpad gestures
                guard abs(horizontalAmount) > abs(verticalAmount) * 1.3 else { return }
                guard abs(horizontalAmount) > 20 else { return }
                guard isDetailActive else { return }
                
                if horizontalAmount > 0 {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        appState.navigateBack()
                    }
                } else if horizontalAmount < 0 && appState.canGoForward {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        appState.navigateForwardInHistory()
                    }
                }
            }
    }
    #endif
}

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
        return Color(NSColor.windowBackgroundColor)
        #endif
    }

    static var systemGray5: Color {
        #if os(iOS)
        return Color(UIColor.systemGray5)
        #else
        return Color(NSColor.systemGray)
        #endif
    }

    static var systemGray6: Color {
        #if os(iOS)
        return Color(UIColor.systemGray6)
        #else
        return Color(NSColor.systemGray)
        #endif
    }

    static var neutralGray: Color {
        #if os(iOS)
        return Color(UIColor.systemGray)
        #else
        return Color(NSColor.systemGray)
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
        return Color(NSColor.controlBackgroundColor)
        #endif
    }

    @ViewBuilder
    static func feedListBackground(for colorScheme: ColorScheme, scrollOffset: CGFloat = 0) -> some View {
        if colorScheme == .dark {
            feedListDarkBackground(scrollOffset: scrollOffset)
        } else {
            background
        }
    }

    static func feedListCardFill(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            return Color(red: 0.075, green: 0.105, blue: 0.150).opacity(0.82)
        }
        return systemGray6
    }

    static func redditBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.135, green: 0.245, blue: 0.315)
            : background
    }

    static func redditCardFill(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            return feedListCardFill(for: colorScheme)
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

    private static func feedListDarkBackground(scrollOffset: CGFloat) -> LinearGradient {
        let progress = min(max(scrollOffset / 950, 0), 1)

        return LinearGradient(
            colors: [
                interpolatedColor(
                    from: (0.105, 0.205, 0.270),
                    to: (0.310, 0.490, 0.585),
                    progress: progress
                ),
                interpolatedColor(
                    from: (0.175, 0.275, 0.375),
                    to: (0.360, 0.485, 0.610),
                    progress: progress
                ),
                interpolatedColor(
                    from: (0.095, 0.105, 0.215),
                    to: (0.175, 0.220, 0.345),
                    progress: progress
                )
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static func interpolatedColor(
        from start: (Double, Double, Double),
        to end: (Double, Double, Double),
        progress: CGFloat
    ) -> Color {
        let amount = Double(progress)
        return Color(
            red: start.0 + (end.0 - start.0) * amount,
            green: start.1 + (end.1 - start.1) * amount,
            blue: start.2 + (end.2 - start.2) * amount
        )
    }
}

private func setPlatformClipboardString(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
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

#if os(iOS)
private struct ArticleDetailScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
#endif

// Extension to enable enhanced swipe back navigation
extension View {
    func onSwipeGesture(perform action: @escaping () -> Void) -> some View {
        self.background(
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { } // Dummy to ensure gesture recognition
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                let horizontalAmount = value.translation.width
                                let verticalAmount = value.translation.height
                                
                                // Check if swipe is mostly horizontal and to the right
                                if abs(horizontalAmount) > abs(verticalAmount) {
                                    if horizontalAmount > 0 {
                                        action()
                                    }
                                }
                            }
                    )
            }
        )
    }
    
    func enhancedSwipeBack(perform action: @escaping () -> Void) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .local)
                .onEnded { value in
                    let horizontalDistance = value.translation.width
                    let verticalDistance = value.translation.height
                    let velocity = value.velocity.width

                    let startedNearEdge = value.startLocation.x <= 85
                    let clearlyHorizontal = abs(horizontalDistance) > 90 && abs(verticalDistance) < 40
                    guard startedNearEdge || clearlyHorizontal else { return }

                    let isRightSwipe = horizontalDistance > 0
                    let isHorizontalSwipe = abs(horizontalDistance) > abs(verticalDistance) * 1.4
                    let hasGoodVelocity = velocity > 160
                    let hasGoodDistance = horizontalDistance > 60
                    let verticalNotTooLarge = abs(verticalDistance) < 80

                    if isRightSwipe && isHorizontalSwipe && (hasGoodVelocity || hasGoodDistance) && verticalNotTooLarge {
                        #if os(iOS)
                        // Wait one event cycle for UITextViewDelegate to publish
                        // the selectedRange change caused by this same touch.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                            guard !AskAITextView.didActiveTextTouchChangeSelection else { return }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.easeOut(duration: 0.14)) {
                                action()
                            }
                        }
                        #else
                        withAnimation(.easeOut(duration: 0.14)) {
                            action()
                        }
                        #endif
                    }
                }
        )
        #if os(iOS)
        // Trackpad scroll gesture overlay to capture two-finger swipes without a click
        .overlay(
            TrackpadScrollGestureOverlay(onSwipeRight: action)
        )
        #endif
    }

    // Swipe back gesture that works from anywhere on screen (for list views on iPhone)
    @ViewBuilder
    func anywhereSwipeBack(enabled: Bool, isTracking: Binding<Bool>? = nil, perform action: @escaping () -> Void) -> some View {
        if enabled {
            self
                // Touch-based swipe gesture
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { value in
                            guard let isTracking else { return }
                            let horizontalDistance = value.translation.width
                            let verticalDistance = value.translation.height
                            let isRightSwipe = horizontalDistance > 0
                            let isHorizontalSwipe = abs(horizontalDistance) > abs(verticalDistance) * 1.4
                            if !isTracking.wrappedValue && isRightSwipe && isHorizontalSwipe && horizontalDistance > 10 {
                                isTracking.wrappedValue = true
                            }
                        }
                        .onEnded { value in
                            let horizontalDistance = value.translation.width
                            let verticalDistance = value.translation.height
                            let predictedHorizontal = value.predictedEndTranslation.width
                            let effectiveHorizontal = max(horizontalDistance, predictedHorizontal)
                            let velocity = value.velocity.width
                            let startedNearEdge = value.startLocation.x <= 60
                            if let isTracking, isTracking.wrappedValue {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                    isTracking.wrappedValue = false
                                }
                            }

                            let isRightSwipe = effectiveHorizontal > 0
                            let isHorizontalSwipe = abs(effectiveHorizontal) > abs(verticalDistance) * 1.4
                            let hasGoodVelocity = velocity > 160
                            let distanceThreshold: CGFloat = startedNearEdge ? 40 : 60
                            let hasGoodDistance = effectiveHorizontal > distanceThreshold
                            let verticalNotTooLarge = abs(verticalDistance) < 80

                            if isRightSwipe && isHorizontalSwipe && (hasGoodVelocity || hasGoodDistance) && verticalNotTooLarge {
                                #if os(iOS)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                #endif
                                withAnimation(.easeOut(duration: 0.2)) {
                                    action()
                                }
                            }
                        }
                )
                #if os(iOS)
                // Trackpad scroll gesture overlay (must not block vertical scrolling)
                .overlay(
                    TrackpadScrollGestureOverlay(onSwipeRight: action)
                )
                #endif
        } else {
            self
        }
    }

    func anywhereSwipeBack(perform action: @escaping () -> Void) -> some View {
        anywhereSwipeBack(enabled: true, isTracking: nil, perform: action)
    }
}

#if os(iOS)
// Trackpad scroll gesture overlay using allowedScrollTypesMask
// This captures trackpad two-finger scroll without blocking touch events
struct TrackpadScrollGestureOverlay: UIViewRepresentable {
    let onSwipeRight: () -> Void

    func makeUIView(context: Context) -> TrackpadGestureView {
        let view = TrackpadGestureView(onSwipeRight: onSwipeRight)
        return view
    }

    func updateUIView(_ uiView: TrackpadGestureView, context: Context) {
        uiView.onSwipeRight = onSwipeRight
    }
}

class TrackpadGestureView: UIView, UIGestureRecognizerDelegate {
    var onSwipeRight: () -> Void
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var hasTriggered = false
    private weak var gestureHostView: UIView?

    private lazy var trackpadPanGesture: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTrackpadPan(_:)))
        // KEY: This enables trackpad two-finger scroll detection
        if #available(iOS 13.4, *) {
            pan.allowedScrollTypesMask = [.continuous, .discrete]
            // Ignore direct touches; only handle indirect scroll input
            pan.allowedTouchTypes = []
        }
        pan.delegate = self
        // Don't delay or cancel touches - let them pass through
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.cancelsTouchesInView = false
        return pan
    }()

    init(onSwipeRight: @escaping () -> Void) {
        self.onSwipeRight = onSwipeRight
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .clear
        // This view exists only to install a gesture recognizer on its host view.
        // It must not participate in hit-testing, otherwise it will steal scroll-wheel events
        // from ScrollView/List and break trackpad scrolling on iPad.
        isUserInteractionEnabled = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        // Attach to the UIWindow so we can observe trackpad scroll gestures without stealing
        // hit-testing from the underlying ScrollView/List. (Attaching to intermediate SwiftUI
        // overlay containers is unreliable because they may not be ancestors of the scroll view.)
        guard gestureHostView !== window else { return }

        if let previousHost = gestureHostView {
            previousHost.removeGestureRecognizer(trackpadPanGesture)
        }

        gestureHostView = window

        if let newHost = window {
            newHost.addGestureRecognizer(trackpadPanGesture)
        }
    }

    deinit {
        if let host = gestureHostView {
            host.removeGestureRecognizer(trackpadPanGesture)
        }
    }

    @objc private func handleTrackpadPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            accumulatedX = 0
            accumulatedY = 0
            hasTriggered = false

        case .changed:
            let referenceView = gesture.view ?? self
            let delta = gesture.translation(in: referenceView)
            gesture.setTranslation(.zero, in: referenceView)

            accumulatedX += delta.x
            accumulatedY += delta.y

            // Check for horizontal swipe right
            let isHorizontal = abs(accumulatedX) > abs(accumulatedY) * 1.3
            let isRightSwipe = accumulatedX > 0

            if !hasTriggered && isHorizontal && isRightSwipe && accumulatedX > 60 {
                hasTriggered = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.easeOut(duration: 0.2)) {
                    onSwipeRight()
                }
            }

        case .ended, .cancelled:
            accumulatedX = 0
            accumulatedY = 0
            hasTriggered = false

        default:
            break
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    // Only respond to indirect pointer (trackpad/mouse), not direct touches
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if #available(iOS 13.4, *) {
            return touch.type == .indirectPointer
        }
        return false
    }

    // Allow other gestures to work simultaneously
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}
#endif

private extension View {
    func feedListColumnStyle(
        colorScheme: ColorScheme,
        scrollOffset: CGFloat,
        restorationKey: String,
        trackedItemIDs: [String],
        onRawScrollActivity: (() -> Void)? = nil,
        onScrollOffsetChange: @escaping (CGFloat) -> Void
    ) -> some View {
        #if os(iOS)
        return self
            .scrollContentBackground(.hidden)
            .background {
                AppColors.feedListBackground(for: colorScheme, scrollOffset: scrollOffset)
                    .ignoresSafeArea()
            }
            .modifier(
                NativeScrollRestorationModifier(
                    restorationKey: restorationKey,
                    trackedItemIDs: trackedItemIDs,
                    onRawScrollActivity: onRawScrollActivity,
                    onOffsetChange: onScrollOffsetChange
                )
            )
        #else
        return self
            .scrollContentBackground(.hidden)
            .background {
                AppColors.feedListBackground(for: colorScheme, scrollOffset: scrollOffset)
                    .ignoresSafeArea()
            }
        #endif
    }
}

#if os(iOS)
private struct NativeScrollGeometry: Equatable {
    let contentOffset: CGPoint
    let containerSize: CGSize
}

@MainActor
private final class NativeScrollRestorationTracker {
    var geometry = NativeScrollGeometry(contentOffset: .zero, containerSize: .zero)
    var visibleIDs: [String] = []
    var isRestoring = false
    var lastReportedOffset: CGFloat = -1
    var restoreTask: Task<Void, Never>?
}

private struct NativeScrollRestorationModifier: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let restorationKey: String
    let trackedItemIDs: [String]
    let onRawScrollActivity: (() -> Void)?
    let onOffsetChange: (CGFloat) -> Void

    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var tracker = NativeScrollRestorationTracker()

    private var contentFingerprint: UInt64 {
        trackedItemIDs.reduce(14_695_981_039_346_656_037) { hash, id in
            id.utf8.reduce(hash) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        }
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($scrollPosition)
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
                tracker.visibleIDs = ids
            }
            .onScrollGeometryChange(
                for: NativeScrollGeometry.self,
                of: { NativeScrollGeometry(contentOffset: $0.contentOffset, containerSize: $0.containerSize) }
            ) { _, newGeometry in
                tracker.geometry = newGeometry
                let normalizedOffset = max(0, newGeometry.contentOffset.y)
                let quantizedOffset = (normalizedOffset / 8).rounded() * 8
                if abs(quantizedOffset - tracker.lastReportedOffset) >= 8 {
                    tracker.lastReportedOffset = quantizedOffset
                    onOffsetChange(quantizedOffset)
                }
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                if !tracker.isRestoring, oldPhase != newPhase {
                    onRawScrollActivity?()
                }
                if newPhase == .idle {
                    saveSnapshot()
                }
            }
            .onAppear {
                restorePosition()
            }
            .onDisappear {
                saveSnapshot()
                tracker.restoreTask?.cancel()
                tracker.restoreTask = nil
            }
    }

    private func preferredAnchorID() -> String? {
        let visible = Set(tracker.visibleIDs)
        return trackedItemIDs.first(where: visible.contains)
            ?? scrollPosition.viewID(type: String.self)
            ?? appState.getSavedScrollPosition(for: restorationKey)
    }

    private func saveSnapshot() {
        guard !tracker.isRestoring else { return }
        let anchorID = preferredAnchorID()
        let anchorIndex = anchorID.flatMap { trackedItemIDs.firstIndex(of: $0) } ?? 0
        appState.saveScrollRestorationSnapshot(
            ScrollRestorationSnapshot(
                anchorID: anchorID,
                anchorIndex: anchorIndex,
                contentOffset: tracker.geometry.contentOffset,
                contentFingerprint: contentFingerprint,
                containerWidth: tracker.geometry.containerSize.width,
                dynamicTypeSize: String(describing: dynamicTypeSize),
                horizontalSizeClass: String(describing: horizontalSizeClass)
            ),
            for: restorationKey
        )
    }

    private func restorePosition() {
        tracker.restoreTask?.cancel()
        guard let snapshot = appState.scrollRestorationSnapshot(for: restorationKey) else {
            if let savedID = appState.getSavedScrollPosition(for: restorationKey), trackedItemIDs.contains(savedID) {
                var target = scrollPosition
                target.scrollTo(id: savedID, anchor: .center)
                scrollPosition = target
            }
            return
        }

        tracker.isRestoring = true
        let fingerprint = contentFingerprint
        let ids = trackedItemIDs
        let dynamicType = String(describing: dynamicTypeSize)
        let sizeClass = String(describing: horizontalSizeClass)

        tracker.restoreTask = Task { @MainActor in
            for attempt in 0..<3 {
                guard !Task.isCancelled else { return }
                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(60 * attempt))
                } else {
                    await Task.yield()
                }

                let geometryReady = tracker.geometry.containerSize.width > 0
                guard geometryReady, !ids.isEmpty else { continue }

                let canRestoreExactOffset = snapshot.contentFingerprint == fingerprint
                    && abs(snapshot.containerWidth - tracker.geometry.containerSize.width) <= 1
                    && snapshot.dynamicTypeSize == dynamicType
                    && snapshot.horizontalSizeClass == sizeClass

                var target = scrollPosition
                if canRestoreExactOffset {
                    target.scrollTo(point: snapshot.contentOffset)
                } else if let anchorID = fallbackAnchorID(for: snapshot, in: ids) {
                    target.scrollTo(id: anchorID, anchor: .top)
                }
                scrollPosition = target

                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }

                if canRestoreExactOffset,
                   abs(tracker.geometry.contentOffset.y - snapshot.contentOffset.y) > 2,
                   let anchorID = fallbackAnchorID(for: snapshot, in: ids) {
                    var fallback = scrollPosition
                    fallback.scrollTo(id: anchorID, anchor: .top)
                    scrollPosition = fallback
                }
                tracker.isRestoring = false
                tracker.restoreTask = nil
                return
            }

            tracker.isRestoring = false
            tracker.restoreTask = nil
        }
    }

    private func fallbackAnchorID(for snapshot: ScrollRestorationSnapshot, in ids: [String]) -> String? {
        if let anchorID = snapshot.anchorID, ids.contains(anchorID) {
            return anchorID
        }
        guard !ids.isEmpty else { return nil }
        return ids[min(max(snapshot.anchorIndex, 0), ids.count - 1)]
    }
}
#endif

#if os(iOS)

private extension UIView {
    func firstSuperview<T: UIView>(of type: T.Type) -> T? {
        var view = superview
        while let current = view {
            if let typed = current as? T {
                return typed
            }
            view = current.superview
        }
        return nil
    }
}

#if os(iOS)
@MainActor
private final class ArticleScrollToTopController {
    static let shared = ArticleScrollToTopController()

    private weak var outerScrollView: UIScrollView?
    private weak var readerWebView: WKWebView?

    func registerOuterScrollView(_ scrollView: UIScrollView) {
        outerScrollView = scrollView
    }

    func registerReaderWebView(_ webView: WKWebView) {
        readerWebView = webView
    }

    func scrollToTop() {
        performScrollToTop(animated: true)

        for delay in [0.05, 0.18, 0.35, 0.60] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor in
                    self?.performScrollToTop(animated: true)
                }
            }
        }
    }

    private func performScrollToTop(animated: Bool) {
        if let outerScrollView {
            outerScrollView.setContentOffset(topContentOffset(for: outerScrollView), animated: animated)
        }

        if let readerWebView {
            scrollWebViewToTop(readerWebView, animated: animated)
        }

        for scrollView in visibleScrollViews() {
            scrollView.setContentOffset(topContentOffset(for: scrollView), animated: animated)
            if let webView = scrollView.firstSuperview(of: WKWebView.self) {
                scrollWebViewToTop(webView, animated: animated)
            }
        }
    }

    private func topContentOffset(for scrollView: UIScrollView) -> CGPoint {
        CGPoint(x: -scrollView.adjustedContentInset.left, y: -scrollView.adjustedContentInset.top)
    }

    private func scrollWebViewToTop(_ webView: WKWebView, animated: Bool) {
        let readerScrollView = webView.scrollView
        readerScrollView.setContentOffset(topContentOffset(for: readerScrollView), animated: animated)
        readerScrollView.setContentOffset(.zero, animated: animated)
        readerScrollView.scrollRectToVisible(CGRect(x: 0, y: 0, width: 1, height: 1), animated: animated)
        webView.evaluateJavaScript(
            """
            (function() {
              var targets = [document.scrollingElement, document.documentElement, document.body].filter(Boolean);
              document.querySelectorAll('*').forEach(function(element) {
                var style = window.getComputedStyle(element);
                var canScrollY = /(auto|scroll|overlay)/.test(style.overflowY || style.overflow);
                if (canScrollY && element.scrollHeight > element.clientHeight) {
                  targets.push(element);
                }
              });
              targets.forEach(function(target) {
                target.scrollTop = 0;
                target.scrollLeft = 0;
                if (target.scrollTo) { target.scrollTo({ top: 0, left: 0, behavior: 'auto' }); }
              });
              window.scrollTo(0, 0);
              return true;
            })();
            """,
            completionHandler: nil
        )
    }

    private func visibleScrollViews() -> [UIScrollView] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { $0.isKeyWindow }
            .flatMap { collectScrollViews(in: $0) }
            .filter { !$0.isHidden && $0.alpha > 0.01 && $0.window != nil }
    }

    private func collectScrollViews(in view: UIView) -> [UIScrollView] {
        var results: [UIScrollView] = []
        if let scrollView = view as? UIScrollView {
            results.append(scrollView)
        }
        for subview in view.subviews {
            results.append(contentsOf: collectScrollViews(in: subview))
        }
        return results
    }
}

private struct ArticleOuterScrollViewResolver: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            if let scrollView = uiView.firstSuperview(of: UIScrollView.self) {
                ArticleScrollToTopController.shared.registerOuterScrollView(scrollView)
            }
        }
    }
}
#endif

private struct IOSArticleActionCapsule<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 2) {
            content
        }
        .padding(4)
        .modifier(
            SummaryTTSMiniPlayerGlassModifier(
                tint: .clear
            )
        )
        .overlay {
            Capsule(style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.38 : 0.34),
                            Color.white.opacity(0.10),
                            Color.black.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 10, x: 0, y: 5)
        .accessibilityElement(children: .contain)
    }
}

private struct ArticleActionSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.24))
            .frame(width: 1, height: 24)
            .padding(.horizontal, 8)
            .accessibilityHidden(true)
    }
}

private struct IOSArticleChromeIconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 44, height: 36)
            .contentShape(Capsule(style: .continuous))
            .background {
                Capsule(style: .continuous)
                    .fill(configuration.isPressed ? Color.white.opacity(colorScheme == .dark ? 0.16 : 0.12) : .clear)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct IOSArticleChromeSelectedButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(minWidth: 96, minHeight: 36)
            .contentShape(Capsule(style: .continuous))
            .background {
                Capsule(style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(colorScheme == .dark ? 0.28 : 0.34), lineWidth: 0.8)
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct DetailTopBar: View {
    @EnvironmentObject var appState: AppState
    @Binding var showShareSheet: Bool
    @Binding var shareItems: [Any]
    private let articleViewMode: Binding<ArticleContentRenderer.ViewMode>?

    init(
        showShareSheet: Binding<Bool>,
        shareItems: Binding<[Any]>,
        articleViewMode: Binding<ArticleContentRenderer.ViewMode>? = nil
    ) {
        self._showShareSheet = showShareSheet
        self._shareItems = shareItems
        self.articleViewMode = articleViewMode
    }

    private var shouldShowExplicitWebAIControls: Bool {
        appState.settings.selectedSummaryProvider != .webAI
    }

    var body: some View {
        ZStack {
            HStack {
                Spacer()

                // Action buttons
                IOSArticleActionCapsule {
                    HStack(spacing: 2) {
                    if let article = appState.selectedArticle {
                        if let articleViewMode, selectedArticleHasReaderURL {
                            Button(action: toggleArticleViewMode) {
                                articleModeToggleLabel(for: articleViewMode.wrappedValue)
                            }
                            .buttonStyle(IOSArticleChromeSelectedButtonStyle())
                            .accessibilityLabel("Article mode")
                            .accessibilityValue(articleViewMode.wrappedValue.rawValue)
                        }

                        Button(action: {
                            appState.requestSummary(for: article)
                        }) {
                            topBarIcon("text.quote")
                        }
                        .buttonStyle(IOSArticleChromeIconButtonStyle())

                        if shouldShowExplicitWebAIControls {
                            Button(action: {
                                appState.requestWebSummary(for: article)
                            }) {
                                topBarIcon("globe")
                            }
                            .buttonStyle(IOSArticleChromeIconButtonStyle())
                            .help("Generate article summary with \(appState.settings.selectedWebAIProvider.displayName)")
                        }
                    } else if let post = appState.selectedRedditPost {
                        Button(action: {
                            appState.requestSummary(for: nil, redditPost: post)
                        }) {
                            topBarIcon("text.quote")
                        }
                        .buttonStyle(IOSArticleChromeSelectedButtonStyle())
                    }

                    if let article = appState.selectedArticle {
                        Button(action: {
                            appState.toggleArticleFavorite(article)
                        }) {
                            topBarIcon(article.isFavorite ? "star.fill" : "star", color: article.isFavorite ? .yellow : .primary)
                        }
                        .buttonStyle(IOSArticleChromeIconButtonStyle())
                    } else if let post = appState.selectedRedditPost {
                        Button(action: {
                            appState.toggleRedditPostFavorite(post)
                        }) {
                            topBarIcon(post.isFavorite ? "star.fill" : "star", color: post.isFavorite ? .yellow : .primary)
                        }
                        .buttonStyle(IOSArticleChromeIconButtonStyle())
                    }

                    if appState.selectedArticle != nil {
                        Button(action: {
                            ArticleQAState.shared.toggleQAInterface()
                        }) {
                            topBarIcon("questionmark.circle")
                        }
                        .buttonStyle(IOSArticleChromeIconButtonStyle())
                    }

                    if let article = appState.selectedArticle {
                        ArticleActionSeparator()

                        Button(action: {
                            if let url = article.url {
                                shareItems = [url]
                            } else {
                                shareItems = [article.title]
                            }
                            showShareSheet = true
                        }) {
                            topBarIcon("square.and.arrow.up")
                        }
                        .buttonStyle(IOSArticleChromeIconButtonStyle())
                    } else if let post = appState.selectedRedditPost {
                        Button(action: {
                            if let url = post.url {
                                shareItems = [url]
                            } else {
                                let redditURL = URL(string: "https://www.reddit.com/r/\(post.subreddit)/comments/\(post.id)")!
                                shareItems = [redditURL]
                            }
                            showShareSheet = true
                        }) {
                            topBarIcon("square.and.arrow.up")
                        }
                        .buttonStyle(IOSArticleChromeIconButtonStyle())
                    }

                    ActivityViewPresenter(isPresented: $showShareSheet, items: shareItems)
                        .frame(width: 0, height: 0)
                    }
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 60)
        .zIndex(2000)
    }

    private var selectedArticleHasReaderURL: Bool {
        guard let url = appState.selectedArticle?.url else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https"
    }

    private func toggleArticleViewMode() {
        guard let articleViewMode else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            articleViewMode.wrappedValue = articleViewMode.wrappedValue == .reader ? .rss : .reader
        }
    }

    private func articleModeToggleLabel(for mode: ArticleContentRenderer.ViewMode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: mode == .reader ? "doc.plaintext" : "dot.radiowaves.left.and.right")
                .font(.system(size: 15, weight: .semibold))

            Text(mode.rawValue)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
        }
        .frame(minWidth: 72, minHeight: 24)
    }

    private func topBarIcon(_ systemName: String, color: Color = .primary) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(color)
            .frame(width: 24, height: 24)
    }
}
#endif

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
                UIPasteboard.general.url = url
            } else if let string = firstItem as? String {
                UIPasteboard.general.string = string
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
    @Environment(\.colorScheme) private var colorScheme

    private var controlFill: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.34, green: 0.47, blue: 0.62).opacity(0.46),
                Color(red: 0.24, green: 0.34, blue: 0.48).opacity(0.58)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var selectedFill: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.24),
                Color.white.opacity(0.10),
                Color.black.opacity(0.04)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(RedditService.SortOption.allCases) { option in
                Button {
                    selection = option
                } label: {
                    Text(option.displayName)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background {
                            if selection == option {
                                Capsule()
                                    .fill(selectedFill)
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                                    )
                            }
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white)
            }
        }
        .frame(maxWidth: .infinity)
        .background(controlFill, in: Capsule())
        .overlay(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.30),
                            Color.clear,
                            Color.black.opacity(0.05)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.overlay)
                )
                .allowsHitTesting(false)
        )
        .overlay(
            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.32),
                            Color.white.opacity(0.10),
                            Color.black.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.1
                )
        )
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.24), radius: 10, x: 0, y: 6)
        .accessibilityElement(children: .contain)
    }
}

private struct RedditSummaryScopeGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color
    let isInteractive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if isInteractive {
                content.glassEffect(.regular.tint(tint).interactive(), in: shape)
            } else {
                content.glassEffect(.regular.tint(tint), in: shape)
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(tint.opacity(0.18), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.28),
                            tint.opacity(0.42),
                            Color.black.opacity(0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
            }
    }
}

private extension View {
    func redditSummaryScopeGlass<S: Shape>(
        in shape: S,
        tint: Color,
        interactive: Bool = false
    ) -> some View {
        modifier(
            RedditSummaryScopeGlassModifier(
                shape: shape,
                tint: tint,
                isInteractive: interactive
            )
        )
    }
}

private struct RedditFloatingSubscriptionChrome: View {
    let statusMessage: String?
    let hidesSortBar: Bool
    @Binding var sortOption: RedditService.SortOption
    let onSortChange: (RedditService.SortOption) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Color.clear
                .frame(height: 48)

            RedditSortPicker(selection: $sortOption)
                .opacity(hidesSortBar ? 0 : 1)
                .allowsHitTesting(!hidesSortBar)
                .onChange(of: sortOption) { newOption in
                    onSortChange(newOption)
                }

            if let statusMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.16), value: hidesSortBar)
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    // Programmatic pop for NavigationStack on iPhone
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isPhoneStyleLayout: Bool {
        // Treat compact horizontal size as phone-style navigation.
        // This keeps compressed iPad layouts on the single-column path while
        // preserving the regular-width iPad split/overlay branch.
        return horizontalSizeClass == .compact
    }
    @State private var cachedShouldUsePhoneLayout: Bool = UIDevice.current.userInterfaceIdiom == .phone
    #else
    private var isPhoneStyleLayout: Bool { false }
    #endif
    
    // Existing properties
    @State private var showAddSubscription = false
    @State private var selectedCategory: FeedCategory = .all
    @State private var showSettings = false
    @State private var showRedditSummaryScopePicker = false
    @State private var redditSummaryScopeSubreddit: String?
    @State private var feedListScrollOffset: CGFloat = 0
    @State private var redditSubscriptionScrollOffset: CGFloat = 0
    @State private var isRedditSubscriptionSortBarHidden = false
    @State private var redditSubscriptionScrollIdleTask: Task<Void, Never>? = nil
    #if os(iOS)
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var isBackSwipeInProgress = false
    @State private var isArticleReadingChromeHidden = false
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

    private var iPadShellBackground: Color {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad && colorScheme == .dark {
            return .black
        }
        #endif
        return AppColors.background
    }

    private var shouldShowExplicitWebAIControls: Bool {
        appState.settings.selectedSummaryProvider != .webAI
    }

    private func articleListID(for article: Article) -> String {
        article.id
    }

    private func redditPostListID(for post: RedditPost) -> String {
        post.id
    }

    private func noteRedditSubscriptionScrollActivity() {
        redditSubscriptionScrollIdleTask?.cancel()

        if !isRedditSubscriptionSortBarHidden {
            withAnimation(.easeInOut(duration: 0.12)) {
                isRedditSubscriptionSortBarHidden = true
            }
        }

        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 360_000_000)
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 0.18)) {
                isRedditSubscriptionSortBarHidden = false
            }
            redditSubscriptionScrollIdleTask = nil
        }

        redditSubscriptionScrollIdleTask = task
    }

    private var shouldHideRedditSubscriptionSortBar: Bool {
        #if os(iOS)
        // Once the inline selector has scrolled away, keep it hidden even when
        // scrolling becomes idle. Sorting remains available from the toolbar.
        return redditSubscriptionScrollOffset >= 8
        #else
        return isRedditSubscriptionSortBarHidden
        #endif
    }

    private var shouldShowRedditSubscriptionToolbarSortMenu: Bool {
        #if os(iOS)
        return shouldHideRedditSubscriptionSortBar
        #else
        return false
        #endif
    }

    
    var body: some View {
        #if os(iOS)
        let shouldUsePhoneLayout = isPhoneStyleLayout
        #endif
        // FIX: Use a stack-based navigation approach instead
        ZStack {
            // Dynamic background that adapts to color scheme
            iPadShellBackground
                .edgesIgnoringSafeArea(.all)
            
            // Main content
                        #if os(iOS)
            if shouldUsePhoneLayout {
                // iPhone navigation
                if let post = appState.selectedRedditPost {
                    RedditDetailView()
                        .transition(.move(edge: .trailing))
                        .zIndex(1)
                        .navigationBarHidden(true)
                        .overlay(alignment: .top) {
                            if UIDevice.current.userInterfaceIdiom == .pad && !shouldUsePhoneLayout {
                                DetailTopBar(showShareSheet: $showShareSheet, shareItems: $shareItems)
                            }
                        }
                        .phoneStyleBackGestures(enabled: shouldUsePhoneLayout) {
                            appState.navigateBack()
                        }
                } else if appState.selectedArticle != nil {
                    ArticleDetailView(
                        isReadingChromeHidden: $isArticleReadingChromeHidden,
                        showShareSheet: $showShareSheet,
                        shareItems: $shareItems
                    )
                        .transition(.move(edge: .trailing))
                        .zIndex(1)
                        .navigationBarHidden(true)
                        .overlay(alignment: .top) {
                            if UIDevice.current.userInterfaceIdiom == .pad && !shouldUsePhoneLayout {
                                EmptyView()
                                    .transition(.articleChromeContinuity(edge: .top))
                            }
                        }
                        .phoneStyleBackGestures(enabled: shouldUsePhoneLayout, usesSystemEdgeSwipe: false) {
                            appState.navigateBack()
                        }
                } else if let activeURL = appState.activeSubscriptionURL, let subscription = appState.subscriptions.first(where: { $0.url == activeURL }) {
                    // Show the subscription list we were in
                    subscriptionView(for: subscription)
                        .id(activeURL) // Force view recreation when navigating to different subscription
                } else {
                    // Root view with sidebar only (allows navigating back to main UI)
                    NavigationView {
                        sidebar
                    }
                    .navigationViewStyle(StackNavigationViewStyle())
                    .background(iPadShellBackground)
                }
            } else {
                // iPad: Keep NavigationView alive, overlay detail views on top
                // This prevents the NavigationView from being destroyed/recreated
                // when navigating to/from detail views, which caused the content
                // column to reset its width (sidebar appearing, compressing content).
                ZStack {
                    NavigationView {
                        sidebar
                        restoreNavigationState()
                    }
                    .navigationViewStyle(DoubleColumnNavigationViewStyle())
                    .background(iPadShellBackground)

                    if let post = appState.selectedRedditPost {
                        RedditDetailView()
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                            .enhancedSwipeBack {
                                appState.navigateBack()
                            }
                    } else if appState.selectedArticle != nil {
                        ArticleDetailView(
                            isReadingChromeHidden: $isArticleReadingChromeHidden,
                            showShareSheet: $showShareSheet,
                            shareItems: $shareItems
                        )
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                            .enhancedSwipeBack {
                                appState.navigateBack()
                            }
                    }
                }
            }
            #else
            // macOS: Use the original conditional logic
            if let post = appState.selectedRedditPost {
                // Show Reddit post detail when selected
                RedditDetailView()
                    .transition(.move(edge: .trailing))
                    .zIndex(1) // Keep on top
                    .enhancedSwipeBack {
                        appState.navigateBack()
                    }
            } else if let article = appState.selectedArticle {
                // Show article detail when selected
                ArticleDetailView()
                    .transition(.move(edge: .trailing))
                    .zIndex(1) // Keep on top
                    .enhancedSwipeBack {
                        appState.navigateBack()
                    }
            } else {
                // Regular navigation
                NavigationView {
                    sidebar
                    // Restore the appropriate view based on what was active
                    restoreNavigationState()
                    detailView
                }
                .navigationViewStyle(DoubleColumnNavigationViewStyle())
                .background(iPadShellBackground)
                .zIndex(0)
                .onAppear {
                    // Sync local state with app state when navigation view appears
                    self.selectedCategory = appState.lastSelectedCategory
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
        // Add a navigation bar overlay when in detail view
        .overlay(alignment: .top) {
            Group {
                #if os(iOS)
                if !shouldUsePhoneLayout &&
                    appState.selectedRedditPost != nil {
                    DetailTopBar(showShareSheet: $showShareSheet, shareItems: $shareItems)
                        .transition(.articleChromeContinuity(edge: .top))
                } // iPhone action bar moved into detail views (bottom HUD)
                #else
                if appState.selectedRedditPost != nil || appState.selectedArticle != nil {
                    VStack(spacing: 0) {
                        ZStack {
                            // Glass background for navigation bar
                            Color.clear
                                .background(.ultraThinMaterial)
                                .glassEffectCompat(in: Rectangle())

                            HStack {
                                Spacer()

                                // Action buttons (platform-agnostic)
                                HStack(spacing: 12) {
                                    if let article = appState.selectedArticle {
                                        Button(action: {
                                            appState.requestSummary(for: article)
                                        }) {
                                            Label("Summarize", systemImage: "text.quote")
                                                .font(.subheadline)
                                        }
                                        .buttonStyle(LiquidGlassButtonStyle())
                                    } else if let post = appState.selectedRedditPost {
                                        Button(action: {
                                            appState.requestSummary(for: nil, redditPost: post)
                                        }) {
                                            Label("Summarize", systemImage: "text.quote")
                                                .font(.subheadline)
                                        }
                                        .buttonStyle(LiquidGlassButtonStyle())
                                    }

                                    if let article = appState.selectedArticle {
                                        Button(action: {
                                            appState.toggleArticleFavorite(article)
                                        }) {
                                            Label("Favorite", systemImage: article.isFavorite ? "star.fill" : "star")
                                                .font(.subheadline)
                                                .foregroundColor(article.isFavorite ? .yellow : .primary)
                                        }
                                        .buttonStyle(LiquidGlassButtonStyle())
                                    } else if let post = appState.selectedRedditPost {
                                        Button(action: {
                                            appState.toggleRedditPostFavorite(post)
                                        }) {
                                            Label("Favorite", systemImage: post.isFavorite ? "star.fill" : "star")
                                                .font(.subheadline)
                                                .foregroundColor(post.isFavorite ? .yellow : .primary)
                                        }
                                        .buttonStyle(LiquidGlassButtonStyle())
                                    }

                                    if let _ = appState.selectedArticle {
                                        Button(action: {
                                            ArticleQAState.shared.toggleQAInterface()
                                        }) {
                                            Label("Ask", systemImage: "questionmark.circle")
                                                .font(.subheadline)
                                        }
                                        .buttonStyle(LiquidGlassButtonStyle())
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        .frame(height: 60)

                        Spacer()
                    }
                    .offset(y: isRunningOnMac ? -20 : 0)
                }
                #endif
            }
        }
        // Sheet for adding subscription
        .sheet(isPresented: $showAddSubscription) {
            AddSubscriptionView()
                .environmentObject(appState)
        }
        // Sheet for Settings
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(appState)
                .presentationDetents([.large])
                .presentationCornerRadius(40) // Balanced radius to prevent clipping
                .presentationBackground(.ultraThinMaterial) // Use thin material for iOS 26
                .presentationBackgroundInteraction(.enabled)
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
        // Global Summary overlay and floating button
        .overlay(
            ZStack {
                let hidesGlobalSummaryWhileWebAIIsMinimized =
                    (appState.isLoading || appState.isWebAIBatchHandoffInProgress) &&
                    appState.isWebAIHandoffMinimized

                if appState.showGlobalSummary && !hidesGlobalSummaryWhileWebAIIsMinimized {
                    DraggableGlobalSummaryView(
                        json: appState.globalSummaryJSON,
                        error: appState.lastGlobalSummaryError
                    )
                    .environmentObject(appState)
                    .allowsHitTesting(true)
                }

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
                                    .foregroundStyle(.primary)
                                    .frame(width: 50, height: 50)
                            }
                            .buttonStyle(.plain)
                            .batchPodcastGlass(in: Circle())
                            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                            .padding()
                        }
                    }
                }
            }
        )
#if os(iOS)
        // Podcast presentation is hosted at the app shell so minimizing the
        // podcast does not destroy generation or playback state.
        .overlay {
            BatchPodcastPresentationHost(session: appState.batchPodcastSession)
                .environmentObject(appState)
        }
#endif
        // (iOS share presented via ActivityViewPresenter background anchor near the button)
        // Fallback notification overlay - high priority (non-interactive so it never blocks scroll)
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
            .allowsHitTesting(false)
        )
        .zIndex(1000) // High z-index to ensure it's above other content
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
            AppColors.background
                .ignoresSafeArea()
        )
        #if os(iOS)
        .navigationFeedback()
        .onChange(of: shouldUsePhoneLayout) { newValue in
            cachedShouldUsePhoneLayout = newValue
            if !newValue {
                appState.activeSubscriptionURL = nil
            }
        }
        #else
        .navigationGestures()
        .navigationFeedback()
        #endif
    }

    // presentMacShare function removed - using ShareLink instead
    
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

    private func sidebarSectionHeader(_ title: String, showsDivider: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsDivider {
                Rectangle()
                    .fill(sidebarDividerColor)
                    .frame(height: 1)
                    .padding(.bottom, 2)
            }

            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(sidebarHeaderTextColor)
                .textCase(nil)
                .tracking(0.6)
        }
        .padding(.top, showsDivider ? 10 : 22)
        .padding(.bottom, 2)
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
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                sidebarRedditIcon()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color(red: 1.0, green: 0.28, blue: 0.10))
            } else {
                sidebarRedditIcon()
            }
            #else
            sidebarRedditIcon()
            #endif
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

    // MARK: - Sidebar
    var sidebar: some View {
        ScrollViewReader { _ in
            List {
                Section(header: 
                    sidebarSectionHeader("LIBRARY")
                ) {
                NavigationLink(destination: redditView) {
                    let unreadRedditCount = appState.redditFeeds
                        .flatMap { $0.posts }
                        .filter { !$0.isRead }
                        .count

                    sidebarMenuRow(
                        title: FeedCategory.reddit.rawValue,
                        unreadCount: unreadRedditCount,
                        isSelected: isLibraryCategorySelected(.reddit),
                        accentColor: Color(red: 1.0, green: 0.28, blue: 0.10)
                    ) {
                        sidebarRedditIcon()
                    }
                }
                .buttonStyle(.plain)
                .sidebarRowChrome(backgroundColor: isPhoneStyleLayout ? iPadShellBackground : .clear)
                #if os(iOS)
                .simultaneousGesture(
                    UIDevice.current.userInterfaceIdiom == .pad ? 
                    TapGesture().onEnded { 
                        selectedCategory = .reddit 
                        appState.lastSelectedCategory = .reddit
                        appState.activeSubscriptionURL = nil
                    } : nil
                )
                #else
                .simultaneousGesture(TapGesture().onEnded { 
                    selectedCategory = .reddit 
                    appState.lastSelectedCategory = .reddit
                    appState.activeSubscriptionURL = nil
                })
                #endif
	                
                NavigationLink(destination: allView) {
                    let unreadArticlesCount = appState.feeds
                        .flatMap { $0.articles }
                        .filter { !$0.isRead }
                        .count

                    sidebarMenuRow(
                        title: FeedCategory.all.rawValue,
                        unreadCount: unreadArticlesCount,
                        isSelected: isLibraryCategorySelected(.all)
                    ) {
                        sidebarSystemIcon(FeedCategory.all.systemImageName, tint: Color(red: 0.64, green: 0.68, blue: 1.0))
                    }
                }
                .buttonStyle(.plain)
                .sidebarRowChrome(backgroundColor: isPhoneStyleLayout ? iPadShellBackground : .clear)
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
                    selectedCategory = .all 
                    appState.lastSelectedCategory = .all
                    appState.activeSubscriptionURL = nil
                })
                #endif
	                
                NavigationLink(destination: unreadView) {
                    sidebarMenuRow(
                        title: FeedCategory.unread.rawValue,
                        isSelected: isLibraryCategorySelected(.unread)
                    ) {
                        sidebarSystemIcon(FeedCategory.unread.systemImageName, tint: Color(red: 0.52, green: 0.65, blue: 1.0))
                    }
                }
                .buttonStyle(.plain)
                .sidebarRowChrome(backgroundColor: isPhoneStyleLayout ? iPadShellBackground : .clear)
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
                    selectedCategory = .unread 
                    appState.lastSelectedCategory = .unread
                    appState.activeSubscriptionURL = nil
                })
                #endif
	                
                NavigationLink(destination: favoritesView) {
                    sidebarMenuRow(
                        title: FeedCategory.favorites.rawValue,
                        isSelected: isLibraryCategorySelected(.favorites)
                    ) {
                        sidebarSystemIcon("star", tint: Color(red: 0.60, green: 0.67, blue: 1.0))
                    }
                }
                .buttonStyle(.plain)
                .sidebarRowChrome(backgroundColor: isPhoneStyleLayout ? iPadShellBackground : .clear)
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
                    selectedCategory = .favorites 
                    appState.lastSelectedCategory = .favorites
                    appState.activeSubscriptionURL = nil
                })
                #endif
	                
                NavigationLink(destination: todayView) {
                    let calendar = Calendar.current
                    let todayArticlesCount = appState.feeds
                        .flatMap { $0.articles }
                        .filter { calendar.isDateInToday($0.publishDate) && !$0.isRead }
                        .count
                    let todayRedditCount = appState.redditFeeds
                        .flatMap { $0.posts }
                        .filter { calendar.isDateInToday($0.publishDate) && !$0.isRead }
                        .count
                    let totalTodayUnseen = todayArticlesCount + todayRedditCount

                    sidebarMenuRow(
                        title: FeedCategory.today.rawValue,
                        unreadCount: totalTodayUnseen,
                        isSelected: isLibraryCategorySelected(.today)
                    ) {
                        sidebarSystemIcon(FeedCategory.today.systemImageName, tint: Color(red: 0.58, green: 0.65, blue: 1.0))
                    }
                }
                .buttonStyle(.plain)
                .sidebarRowChrome(backgroundColor: isPhoneStyleLayout ? iPadShellBackground : .clear)
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
                    selectedCategory = .today 
	                    appState.lastSelectedCategory = .today
	                    appState.activeSubscriptionURL = nil
	                })
	                #endif
	            }
	            
	            Section(header: 
	                sidebarSectionHeader("SUBSCRIPTIONS", showsDivider: true)
	            ) {
                let rssUnreadCounts = Dictionary(
                    uniqueKeysWithValues: appState.feeds.map { feed in
                        (feed.url, feed.articles.reduce(into: 0) { count, article in
                            if !article.isRead {
                                count += 1
                            }
                        })
                    }
                )
                let redditUnreadCounts = Dictionary(
                    uniqueKeysWithValues: appState.redditFeeds.map { feed in
                        (feed.subreddit, feed.posts.reduce(into: 0) { count, post in
                            if !post.isRead {
                                count += 1
                            }
                        })
                    }
                )

                ForEach(appState.subscriptions) { subscription in
                    let unreadCount = sidebarUnreadCount(
                        for: subscription,
                        rssUnreadCounts: rssUnreadCounts,
                        redditUnreadCounts: redditUnreadCounts
                    )

                    #if os(iOS)
                    if isPhoneStyleLayout {
                        NavigationLink(tag: subscription.url, selection: $appState.activeSubscriptionURL, destination: { subscriptionView(for: subscription) }) {
                            subscriptionSidebarRow(for: subscription, unreadCount: unreadCount)
                        }
                        .buttonStyle(.plain)
                        .sidebarSelectionBorder(appState.activeSubscriptionURL == subscription.url)
                        .id(subscription.url)
                        .onAppear {
                            if appState.activeSubscriptionURL == subscription.url {
                                appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.url)
                            }

                            if appState.activeSubscriptionURL == subscription.url {
                                appState.lastSelectedCategory = subscription.type == .reddit ? .reddit : .all
                            }
                        }
                        .onChange(of: appState.activeSubscriptionURL) { newValue in
                            if newValue == subscription.url {
                                appState.activeSubscriptionURL = subscription.url
                                appState.lastSelectedCategory = subscription.type == .reddit ? .reddit : .all
                                appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.url)
                            }
                        }
                    } else if UIDevice.current.userInterfaceIdiom == .pad {
                        Button(action: {
                            appState.selectedArticle = nil
                            appState.selectedRedditPost = nil
                            appState.activeSubscriptionURL = subscription.url
                            appState.lastSelectedCategory = subscription.type == .reddit ? .reddit : .all
                            appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.url)
                        }) {
                            subscriptionSidebarRow(for: subscription, unreadCount: unreadCount)
                        }
                        .buttonStyle(.plain)
                        .sidebarRowChrome(backgroundColor: isPhoneStyleLayout ? iPadShellBackground : .clear)
                        .id(subscription.url)
                        .onAppear {
                            // Remember subscription selection when it appears as selected
                            if appState.activeSubscriptionURL == subscription.url {
                                appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.url)
                            }
                        }
                        .onChange(of: appState.activeSubscriptionURL) { newValue in
                            if newValue == subscription.url {
                                appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.url)
                            }
                        }
                    } else {
                    NavigationLink(tag: subscription.url, selection: $appState.activeSubscriptionURL, destination: { subscriptionView(for: subscription) }) {
                        subscriptionSidebarRow(for: subscription, unreadCount: unreadCount)
                    }
                    .buttonStyle(.plain)
                    .sidebarRowChrome(backgroundColor: isPhoneStyleLayout ? iPadShellBackground : .clear)
                    .id(subscription.url)
                    .onAppear {
                        // Remember subscription selection when it appears as selected
                        if appState.activeSubscriptionURL == subscription.url {
                            appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.url)
                        }
                    }
                    .onChange(of: appState.activeSubscriptionURL) { newValue in
                        if newValue == subscription.url {
                            appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.url)
                        }
                    }
                    }
                    #else
                    NavigationLink(tag: subscription.url, selection: $appState.activeSubscriptionURL, destination: { subscriptionView(for: subscription) }) {
                        subscriptionSidebarRow(for: subscription, unreadCount: unreadCount)
                    }
                    .buttonStyle(.plain)
                    .sidebarRowChrome(backgroundColor: isPhoneStyleLayout ? iPadShellBackground : .clear)
                    .id(subscription.url)
                    .onAppear {
                        // Remember subscription selection when it appears as selected
                        if appState.activeSubscriptionURL == subscription.url {
                            appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.url)
                        }
                    }
                    .onChange(of: appState.activeSubscriptionURL) { newValue in
                        if newValue == subscription.url {
                            appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.url)
                        }
                    }
                    #endif
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
	                .sidebarRowChrome(backgroundColor: isPhoneStyleLayout ? iPadShellBackground : .clear)
	            }

                Section {
                    Button(action: { showSettings = true }) {
                        sidebarMenuRow(title: "Settings", accentColor: Color(red: 0.76, green: 0.78, blue: 0.88)) {
                            sidebarSystemIcon("gearshape", tint: Color(red: 0.78, green: 0.80, blue: 0.90))
                        }
                    }
                    .buttonStyle(.plain)
                    .sidebarRowChrome(backgroundColor: isPhoneStyleLayout ? iPadShellBackground : .clear)
                }
	        }
            #if os(iOS)
            .modifier(
                NativeScrollRestorationModifier(
                    restorationKey: "sidebar_subscriptions",
                    trackedItemIDs: appState.subscriptions.map(\.url),
                    onRawScrollActivity: nil,
                    onOffsetChange: { _ in }
                )
            )
            #endif
	        .listStyle(.plain)
	        .scrollContentBackground(.hidden)
	        .frame(minWidth: 200)
            #if os(iOS)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    EmptyView()
                }
            }
            #endif
	        .background(sidebarSurfaceBackground)
	        .ignoresSafeArea()
        .onAppear {
            // Sync Reddit read states from persistence to ensure badge counts are accurate
            appState.syncRedditReadStatesFromPersistence()

        }
        #if os(macOS)
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
        #endif
        }
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

    @ViewBuilder
    private func subscriptionSidebarRow(for subscription: Subscription, unreadCount: Int) -> some View {
        let isSelected = appState.activeSubscriptionURL == subscription.url
        let selectionColor: Color = subscription.type == .reddit
            ? Color(red: 1.0, green: 0.28, blue: 0.10)
            : sidebarSelectionAccent

        sidebarMenuRow(
            title: subscription.title,
            unreadCount: unreadCount,
            isSelected: isSelected,
            accentColor: selectionColor
        ) {
            sidebarSubscriptionIcon(for: subscription, isSelected: isSelected)
        }
    }

    private func sidebarUnreadCount(
        for subscription: Subscription,
        rssUnreadCounts: [String: Int],
        redditUnreadCounts: [String: Int]
    ) -> Int {
        switch subscription.type {
        case .rss:
            return rssUnreadCounts[subscription.url] ?? 0
        case .reddit:
            return redditUnreadCounts[subscription.url] ?? 0
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
        ScrollViewReader { _ in
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
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .id(articleListID(for: article)) // Set ID for scroll position tracking
                }
            }
            .listStyle(.plain)
            .feedListColumnStyle(
                colorScheme: colorScheme,
                scrollOffset: feedListScrollOffset,
                restorationKey: "all_category",
                trackedItemIDs: appState.feeds.flatMap { $0.articles }
                    .sorted(by: { $0.publishDate > $1.publishDate })
                    .map(\.id)
            ) { offset in
                feedListScrollOffset = offset
            }
            .onAppear {
                #if os(iOS)
                // Update navigation state for iPhone
                if UIDevice.current.userInterfaceIdiom == .phone {
                    selectedCategory = .all
                    appState.lastSelectedCategory = .all
                    appState.activeSubscriptionURL = nil
                }
                #endif
            }
            .navigationTitle("All Articles")
        }
    }
    
    var unreadView: some View {
        ScrollViewReader { _ in
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
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
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
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .id(redditPostListID(for: post)) // Set ID for scroll position tracking
                        }
                    }
                }
            }
            .listStyle(.plain)
            .feedListColumnStyle(
                colorScheme: colorScheme,
                scrollOffset: feedListScrollOffset,
                restorationKey: "unread_category",
                trackedItemIDs: appState.feeds.flatMap { $0.articles }
                    .filter { !$0.isRead }
                    .sorted(by: { $0.publishDate > $1.publishDate })
                    .map(\.id)
                    + appState.redditFeeds.flatMap { $0.posts }
                    .filter { !$0.isRead }
                    .sorted(by: { $0.publishDate > $1.publishDate })
                    .map(\.id)
            ) { offset in
                feedListScrollOffset = offset
            }
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
                            appState.saveScrollPosition(for: "favorites_category", itemID: article.id)
                            appState.selectedArticle = article
                            if !article.isRead {
                                appState.markArticleAsRead(article)
                            }
                        }) {
                            ArticleRow(article: article)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .id(articleListID(for: article))
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
                            appState.saveScrollPosition(for: "favorites_category", itemID: post.id)
                            appState.selectedRedditPost = post
                            if !post.isRead {
                                appState.markRedditPostAsRead(post)
                            }
                        }) {
                            RedditPostRow(post: post)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .id(redditPostListID(for: post))
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
        .feedListColumnStyle(
            colorScheme: colorScheme,
            scrollOffset: feedListScrollOffset,
            restorationKey: "favorites_category",
            trackedItemIDs: appState.feeds.flatMap { $0.articles }
                .filter(\.isFavorite)
                .sorted(by: { $0.publishDate > $1.publishDate })
                .map(\.id)
                + appState.redditFeeds.flatMap { $0.posts }
                .filter(\.isFavorite)
                .sorted(by: { $0.publishDate > $1.publishDate })
                .map(\.id)
        ) { offset in
            feedListScrollOffset = offset
        }
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
                .prefix(50)
        )
    }

    private var filteredTodayRedditPosts: [RedditPost] {
        let calendar = Calendar.current
        return Array(
            appState.redditFeeds.flatMap { $0.posts }
                .filter { calendar.isDateInToday($0.publishDate) }
                .sorted(by: { $0.publishDate > $1.publishDate })
                .prefix(50)
        )
    }

    var todayView: some View {
        ScrollViewReader { _ in
            List {
                let todayArticles = filteredTodayArticles
                let todayRedditPosts = filteredTodayRedditPosts
                
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
                } else if let summary = appState.todaySummaryResult {
                    Section(header: Text("Today's Topics Overview")) {
                        VStack(alignment: .leading, spacing: 12) {
                            ArticleGlassySummary(summary: summary)
                            HStack(spacing: 12) {
                                Button(action: {
                                setPlatformClipboardString(summary)
                            }) {
                                Label("Copy Summary", systemImage: "doc.on.doc")
                            }
                                .buttonStyle(LiquidGlassButtonStyle())
                                .disabled(summary.isEmpty)

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
                } else if let error = appState.todaySummaryError {
                    Section(header: Text("Today's Topics Overview")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error)
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
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
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
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
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
            .feedListColumnStyle(
                colorScheme: colorScheme,
                scrollOffset: feedListScrollOffset,
                restorationKey: "today_category",
                trackedItemIDs: filteredTodayArticles.map(\.id) + filteredTodayRedditPosts.map(\.id)
            ) { offset in
                feedListScrollOffset = offset
            }
            .onAppear {
                // Update the last selected category when this view appears
                appState.lastSelectedCategory = .today
                selectedCategory = .today

                #if os(iOS)
                // Clear activeSubscriptionURL for iPhone
                if UIDevice.current.userInterfaceIdiom == .phone {
                    appState.activeSubscriptionURL = nil
                }
                #endif

                // Clear any cached today summary state to prevent stale data reuse
                if appState.isGeneratingTodaySummary ||
                    appState.todaySummaryResult != nil ||
                    appState.todaySummaryError != nil ||
                    appState.todaySummaryInfo != nil {
                    DispatchQueue.main.async {
                        appState.clearTodaySummary()
                    }
                }

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
                            Label("Summarize Today", systemImage: "sparkles")
                        }
                        #else
                        Label("Summarize Today", systemImage: "sparkles")
                        #endif
                    }
                    .buttonStyle(LiquidGlassButtonStyle(isTranslucent: true, showsBorder: false, showsBackground: false))
                    .disabled(appState.isGeneratingTodaySummary)
                    #if os(macOS)
                    .help("Summarize today's content by subject")
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
                    .buttonStyle(LiquidGlassButtonStyle(isTranslucent: true, showsBorder: false, showsBackground: false))
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

    private func dismissRedditSummaryScopePicker() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            showRedditSummaryScopePicker = false
            redditSummaryScopeSubreddit = nil
        }
    }

    private var redditSummaryScopePanelTint: Color {
        Color(red: 0.30, green: 0.38, blue: 0.48).opacity(0.28)
    }

    private var redditSummaryScopeButtonTint: Color {
        Color(red: 0.34, green: 0.47, blue: 0.62).opacity(0.30)
    }

    @ViewBuilder
    private func redditSummaryScopePickerActions(subscription: Subscription) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                redditSummaryScopePickerActionContent(subscription: subscription)
            }
        } else {
            redditSummaryScopePickerActionContent(subscription: subscription)
        }
        #else
        redditSummaryScopePickerActionContent(subscription: subscription)
        #endif
    }

    private func redditSummaryScopePickerActionContent(subscription: Subscription) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button("New") {
                    dismissRedditSummaryScopePicker()
                    appState.summarizeSubredditPostsGlobally(subreddit: subscription.url, topComments: 10)
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .redditSummaryScopeGlass(
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                    tint: redditSummaryScopeButtonTint,
                    interactive: true
                )

                Button("Hot") {
                    dismissRedditSummaryScopePicker()
                    appState.summarizeSubredditHotPostsGlobally(subreddit: subscription.url, topComments: 10)
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .redditSummaryScopeGlass(
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                    tint: redditSummaryScopeButtonTint,
                    interactive: true
                )
            }

            HStack(spacing: 12) {
                Button("Top Day") {
                    dismissRedditSummaryScopePicker()
                    appState.summarizeSubredditTopDayPostsGlobally(subreddit: subscription.url, topComments: 10)
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .redditSummaryScopeGlass(
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                    tint: redditSummaryScopeButtonTint,
                    interactive: true
                )

                Button("Top Week") {
                    dismissRedditSummaryScopePicker()
                    appState.summarizeSubredditTopWeekPostsGlobally(subreddit: subscription.url, topComments: 10)
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .redditSummaryScopeGlass(
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                    tint: redditSummaryScopeButtonTint,
                    interactive: true
                )
            }

            Button("Cancel") {
                dismissRedditSummaryScopePicker()
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .redditSummaryScopeGlass(
                in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                tint: redditSummaryScopeButtonTint,
                interactive: true
            )
        }
    }

    @ViewBuilder
    private func redditSummaryScopePickerOverlay(feed: RedditFeed, subscription: Subscription) -> some View {
        ZStack {
            Color.black
                .opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissRedditSummaryScopePicker()
                }

            VStack(spacing: 16) {
                let unreadCount = feed.posts.filter { !$0.isRead }.count
                Text("New: \(unreadCount) unread • Ranked: up to 50 posts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                redditSummaryScopePickerActions(subscription: subscription)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .redditSummaryScopeGlass(
                in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                tint: redditSummaryScopePanelTint
            )
            .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 12)
            .padding()
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
                    // Use a small delay to ensure UI updates before making the request
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        // Only refresh the current subreddit feed instead of all feeds
                        appState.refreshRedditFeeds(specificSubreddit: appState.activeSubscriptionURL)
                    }
                }
            
            ScrollViewReader { _ in
                List {
                    if !appState.redditFeedStatusMessages.isEmpty {
                        ForEach(appState.redditFeedStatusMessages.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("r/\(entry.key): \(entry.value)")
                                    .font(.footnote)
                                    .foregroundColor(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    
                    ForEach(appState.redditFeeds.flatMap { $0.posts }
                        .sorted(by: { $0.publishDate > $1.publishDate })) { post in
                            
                        // Use a button for navigation instead of NavigationLink
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
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .id(redditPostListID(for: post)) // Set ID for scroll position tracking
                    }
                }
                .listStyle(.plain)
                .feedListColumnStyle(
                    colorScheme: colorScheme,
                    scrollOffset: feedListScrollOffset,
                    restorationKey: "reddit_category",
                    trackedItemIDs: appState.redditFeeds.flatMap { $0.posts }
                        .sorted(by: { $0.publishDate > $1.publishDate })
                        .map(\.id)
                ) { offset in
                    feedListScrollOffset = offset
                }
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
                    
                }
            }
        }
        .background {
            AppColors.feedListBackground(for: colorScheme, scrollOffset: feedListScrollOffset)
                .ignoresSafeArea()
        }
        .navigationTitle("Reddit")
    }
    
    func subscriptionView(for subscription: Subscription) -> some View {
        Group {
            if subscription.type == .rss {
                if let feed = appState.feeds.first(where: { $0.url == subscription.url }) {
                    feedSubscriptionView(feed: feed, subscription: subscription)
                } else {
                    Text("Loading feed...")
                        .navigationTitle(subscription.title)
                        .onAppear {
                            appState.refreshSingleRSSFeed(url: subscription.url)
                        }
                }
            } else {
                if let feed = appState.redditFeeds.first(where: { $0.subreddit == subscription.url }) {
                    redditSubscriptionView(feed: feed, subscription: subscription)
                } else {
                    Text("Loading subreddit...")
                        .navigationTitle(subscription.title)
                        .onAppear {
                            appState.refreshRedditFeeds(specificSubreddit: subscription.url)
                        }
                }
            }
        }
    }
    
    @ViewBuilder
    private func feedSubscriptionView(feed: Feed, subscription: Subscription) -> some View {
        ScrollViewReader { scrollProxy in
            feedArticlesList(feed: feed, subscription: subscription, scrollProxy: scrollProxy)
        }
    }

    private func feedArticlesList(feed: Feed, subscription: Subscription, scrollProxy: ScrollViewProxy) -> some View {
        let sortedArticles = displayArticles(for: feed)
        let showsSubscriptionTitle = feedListScrollOffset < 1

        return List {
            ForEach(sortedArticles) { article in
                Button(action: {
                    #if os(iOS)
                    if isPhoneStyleLayout && isBackSwipeInProgress {
                        return
                    }
                    #endif
                    appState.rememberCurrentSubscription(url: subscription.url)
                    appState.saveScrollPosition(for: subscription.url, itemID: article.id)
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
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .id(articleListID(for: article))
            }
        }
        .listStyle(.plain)
        #if os(iOS)
        .scrollEdgeEffectHidden(true, for: .top)
        #endif
        .feedListColumnStyle(
            colorScheme: colorScheme,
            scrollOffset: feedListScrollOffset,
            restorationKey: subscription.url,
            trackedItemIDs: sortedArticles.map(\.id)
        ) { offset in
            feedListScrollOffset = offset
        }
        .navigationTitle(showsSubscriptionTitle ? feed.title : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isPhoneStyleLayout)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .padding(.top, isPhoneStyleLayout ? 0 : 0)
        #endif
        .onAppear {
            appState.activeSubscriptionURL = subscription.url
            appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.url)
            if sortedArticles.isEmpty {
                appState.refreshSingleRSSFeed(url: subscription.url)
            }
        }
        #if os(iOS)
        .anywhereSwipeBack(enabled: isPhoneStyleLayout, isTracking: $isBackSwipeInProgress) {
            if isPhoneStyleLayout && appState.activeSubscriptionURL == subscription.url {
                appState.exitActiveSubscriptionView()
            }
        }
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: {
                    let count = feed.articles.count
                    print("Validation: Feed \(subscription.title) articles count=\(count)")
                    appState.summarizeFeedArticlesGlobally(feedURL: subscription.url)
                }) {
                    #if os(iOS)
                    if UIDevice.current.userInterfaceIdiom == .phone {
                        Image(systemName: "text.bubble")
                    } else {
                        Label("Summarize Articles", systemImage: "text.bubble")
                    }
                    #else
                    Label("Summarize Articles", systemImage: "text.bubble")
                    #endif
                }
                .buttonStyle(LiquidGlassButtonStyle(isTranslucent: true, showsBorder: false, showsBackground: false))

                let articleScrollTarget = sortedArticles.first?.id
                Button(action: {
                    if let target = articleScrollTarget {
                        withAnimation(.easeInOut) {
                            scrollProxy.scrollTo(target, anchor: .top)
                        }
                    }
                    appState.isLoading = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        appState.refreshSingleRSSFeed(url: subscription.url)
                    }
                }) {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(LiquidGlassButtonStyle(isTranslucent: true, showsBorder: false, showsBackground: false))
                .disabled(articleScrollTarget == nil)

                let hasUnread = feed.articles.contains { !$0.isRead }
                Button(action: {
                    appState.markAllArticlesAsRead(for: subscription.url)
                    appState.navigateToNextSubscription(after: subscription.url)
                }) {
                    #if os(iOS)
                    if UIDevice.current.userInterfaceIdiom == .phone {
                        Image(systemName: "checkmark.circle")
                    } else {
                        Label("Mark All Read", systemImage: "checkmark.circle")
                    }
                    #else
                    Label("Mark All Read", systemImage: "checkmark.circle")
                    #endif
                }
                .buttonStyle(LiquidGlassButtonStyle(isTranslucent: true, showsBorder: false, showsBackground: false))
                .disabled(!hasUnread)
            }
        }
    }

    @ViewBuilder
    private func redditSubscriptionView(feed: RedditFeed, subscription: Subscription) -> some View {
        ScrollViewReader { scrollProxy in
            ZStack(alignment: .top) {
                let statusMessage = appState.redditFeedStatusMessages[subscription.url]
                let showsSubscriptionTitle = redditSubscriptionScrollOffset < 1

                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: 1)

                        Text("r/\(feed.subreddit)")
                            .font(.title2.bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .allowsTightening(true)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .padding(.horizontal, 24)
                            .opacity(showsSubscriptionTitle ? 1 : 0)
                            .clipped()

                        LazyVStack(spacing: 12) {
                            ForEach(feed.posts) { post in
                                Button(action: {
                                    #if os(iOS)
                                    if isPhoneStyleLayout && isBackSwipeInProgress {
                                        return
                                    }
                                    #endif
                                    appState.rememberCurrentSubscription(url: subscription.url)
                                    appState.saveScrollPosition(for: subscription.url, itemID: post.id)
                                    appState.setSelectedRedditPost(post)
                                    appState.lastSelectedCategory = .reddit
                                    if !post.isRead {
                                        appState.markRedditPostAsRead(post)
                                    }
                                }) {
                                    RedditPostRow(post: post, showsSubredditLabel: false)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(redditPostListID(for: post))
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.top, statusMessage == nil ? 75 : 115)
                        .padding(.bottom, 8)
                        .padding(.horizontal, 4)
                    }
                }
                #if os(iOS)
                .scrollEdgeEffectHidden(true, for: .top)
                #endif
                .coordinateSpace(name: "subscriptionRedditList-\(subscription.id.uuidString)")
                .feedListColumnStyle(
                    colorScheme: colorScheme,
                    scrollOffset: feedListScrollOffset,
                    restorationKey: subscription.url,
                    trackedItemIDs: feed.posts.map(\.id),
                    onRawScrollActivity: {
                        #if os(macOS)
                        noteRedditSubscriptionScrollActivity()
                        #endif
                    }
                ) { offset in
                    feedListScrollOffset = offset
                    redditSubscriptionScrollOffset = offset
                }

                RedditFloatingSubscriptionChrome(
                    statusMessage: statusMessage,
                    hidesSortBar: shouldHideRedditSubscriptionSortBar,
                    sortOption: $appState.redditSortOption,
                    onSortChange: { newOption in
                        print("📱 ContentView: Reddit sort option changed to \(newOption.rawValue) for r/\(subscription.url)")
                        appState.isLoading = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            appState.refreshRedditFeeds(specificSubreddit: subscription.url)
                        }
                    }
                )
            }
            .background {
                AppColors.feedListBackground(for: colorScheme, scrollOffset: feedListScrollOffset)
                    .ignoresSafeArea()
            }
            .onAppear {
                #if os(macOS)
                redditSubscriptionScrollIdleTask?.cancel()
                redditSubscriptionScrollIdleTask = nil
                isRedditSubscriptionSortBarHidden = false
                #endif
                redditSubscriptionScrollOffset = 0
                appState.activeSubscriptionURL = subscription.url
                appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.url)
                if feed.posts.isEmpty {
                    appState.refreshRedditFeeds(specificSubreddit: subscription.url)
                }
            }
            .onDisappear {
                #if os(macOS)
                redditSubscriptionScrollIdleTask?.cancel()
                redditSubscriptionScrollIdleTask = nil
                isRedditSubscriptionSortBarHidden = false
                #endif
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isPhoneStyleLayout)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .anywhereSwipeBack(enabled: isPhoneStyleLayout, isTracking: $isBackSwipeInProgress) {
                if isPhoneStyleLayout && appState.activeSubscriptionURL == subscription.url {
                    appState.exitActiveSubscriptionView()
                }
            }
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    #if os(iOS)
                    if shouldShowRedditSubscriptionToolbarSortMenu {
                        Menu {
                            ForEach(RedditService.SortOption.allCases) { option in
                                Button {
                                    appState.redditSortOption = option
                                } label: {
                                    if appState.redditSortOption == option {
                                        Label(option.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(option.displayName)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down.circle")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .accessibilityLabel("Sort Reddit posts")
                        .accessibilityValue(appState.redditSortOption.displayName)
                    }
                    #endif

                    Button(action: {
                        redditSummaryScopeSubreddit = subscription.url
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            showRedditSummaryScopePicker = true
                        }
                    }) {
                        #if os(iOS)
                        if UIDevice.current.userInterfaceIdiom == .phone {
                            Image(systemName: "text.bubble")
                        } else {
                            Label("Summarize Reddit", systemImage: "text.bubble")
                        }
                        #else
                        Label("Summarize Reddit", systemImage: "text.bubble")
                        #endif
                    }
                    .buttonStyle(LiquidGlassButtonStyle(isTranslucent: true, showsBorder: false, showsBackground: false))

                    let redditScrollTarget = feed.posts.first?.id
                    Button(action: {
                        if let target = redditScrollTarget {
                            withAnimation(.easeInOut) {
                                scrollProxy.scrollTo(target, anchor: .top)
                            }
                        }
                        appState.isLoading = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            appState.refreshRedditFeeds(specificSubreddit: subscription.url)
                        }
                    }) {
                        Image(systemName: "arrow.up.circle")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(LiquidGlassButtonStyle(isTranslucent: true, showsBorder: false, showsBackground: false))
                    .disabled(redditScrollTarget == nil)

                    let hasUnread = feed.posts.contains { !$0.isRead }
                    Button(action: {
                        appState.markAllRedditPostsAsRead(for: subscription.url)
                        appState.navigateToNextSubscription(after: subscription.url)
                    }) {
                        #if os(iOS)
                        if UIDevice.current.userInterfaceIdiom == .phone {
                            Image(systemName: "checkmark.circle")
                        } else {
                            Label("Mark All Read", systemImage: "checkmark.circle")
                        }
                        #else
                        Label("Mark All Read", systemImage: "checkmark.circle")
                        #endif
                    }
                    .buttonStyle(LiquidGlassButtonStyle(isTranslucent: true, showsBorder: false, showsBackground: false))
                    .disabled(!hasUnread)
                }
            }
            .overlay {
                if showRedditSummaryScopePicker && redditSummaryScopeSubreddit == subscription.url {
                    redditSummaryScopePickerOverlay(feed: feed, subscription: subscription)
                }
            }
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
    
        // MARK: - Detail View
    var detailView: some View {
        Group {
            if appState.selectedArticle != nil {
                #if os(iOS)
                ArticleDetailView(
                    isReadingChromeHidden: $isArticleReadingChromeHidden,
                    showShareSheet: $showShareSheet,
                    shareItems: $shareItems
                )
                #else
                ArticleDetailView()
                #endif
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
    
// MARK: - Global Summary Views
struct DraggableGlobalSummaryView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var offset = CGSize.zero
    @State private var isDragging = false
    @State private var showQAInterface = false
    @State private var qaQuestionText: String = ""
    @State private var qaAnswerText: String = ""
    @State private var isProcessingQA = false
    @State private var qaInlineError: String?
    @State private var showAnswerSheet = false
    @State private var isAskingSelectionAI = false
    @State private var selectionAskAIPrompt = ""
    @State private var selectionAskAIResponse = ""
    @State private var showSelectionAskAISheet = false
    @State private var baseSummaryClipboardText: String?
    @State private var cachedSummaryClipboardText: String?
    @State private var cachedFormattedAggregateSummary: String?
    @State private var parsedSummaries: [GlobalSummaryItem] = []
    @State private var parsedSummaryDisplayCache: [String: String] = [:]
    @State private var highlightedSummaryID: String?
    @State private var summaryScrollProxy: ScrollViewProxy?
    @State private var summaryScrollPosition = ScrollPosition(idType: String.self)
    @State private var currentSummaryContentOffset: CGPoint = .zero
    @State private var summaryReturnContentOffset: CGPoint?
    @State private var isRedditContent: Bool = false
    @State private var showQuestionReliabilityWarning = false
    @State private var pendingQuestionUsesWebAI = false
    @State private var isSummaryContentScrolling = false
    @State private var summaryChromeReturnTask: Task<Void, Never>?
    @State private var isSummaryScrollActive = false

    private let summaryChromeReturnDelay: UInt64 = 450_000_000

    // Whiteboard state
    @State private var showWhiteboard: Bool = false
    @State private var whiteboardContent: Data?
    @State private var isGeneratingWhiteboard: Bool = false
    @State private var whiteboardError: String?
    @State private var isWhiteboardMinimized: Bool = false

    // Infographic state
    @State private var showInfographic: Bool = false
    @State private var infographicContent: Data?
    @State private var isGeneratingInfographic: Bool = false
    @State private var infographicError: String?
    @State private var isInfographicMinimized: Bool = false

    let json: String
    let error: String?

    private var summaryClipboardText: String? {
        cachedSummaryClipboardText
    }

    private static let overallSummaryAnchorID = "global-summary-overall-anchor"

    private func formatOverallSummaryForDisplay(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }

        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        t = t.replacingOccurrences(of: "\r", with: "\n")

        // Ensure headings and list items start on their own lines
        t = t.replacingOccurrences(of: "(?<!\\n)(#{1,6}\\s+)", with: "\n$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?<!\\n)(-\\s+|•\\s+|\\d+\\.\\s+)", with: "\n$1", options: .regularExpression)

        // Convert ATX headings into bold lines for SwiftUI Text markdown
        if let headingToBold = try? NSRegularExpression(pattern: "^(?:\\s{0,3})#{1,6}\\s+(.+)$", options: [.anchorsMatchLines]) {
            let range = NSRange(t.startIndex..., in: t)
            t = headingToBold.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "**$1**")
        }

        // Ensure a blank line after bold heading lines
        if let headingSpacing = try? NSRegularExpression(pattern: "^(\\*\\*.+\\*\\*)\\n(\\S)", options: [.anchorsMatchLines]) {
            let range = NSRange(t.startIndex..., in: t)
            t = headingSpacing.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "$1\n\n$2")
        }

        // If we have no paragraph breaks, add them after sentence endings.
        if !t.contains("\n\n") {
            if let sentenceBreaks = try? NSRegularExpression(pattern: "([a-z0-9][\\.\\!\\?])\\s*(?=[A-Z0-9])", options: []) {
                let range = NSRange(t.startIndex..., in: t)
                t = sentenceBreaks.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "$1\n\n")
            }
        }

        // Collapse excessive blank lines
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return t
    }
    
    private var canCopySummary: Bool {
        summaryClipboardText != nil
    }

    private func rebuildAggregateSummaryCache() {
        guard let combined = appState.aggregateSummaryText?.trimmingCharacters(in: .whitespacesAndNewlines), !combined.isEmpty else {
            cachedFormattedAggregateSummary = nil
            cachedSummaryClipboardText = baseSummaryClipboardText
            return
        }
        cachedFormattedAggregateSummary = formatOverallSummaryForDisplay(combined)
        if let baseClipboard = baseSummaryClipboardText, !baseClipboard.isEmpty {
            cachedSummaryClipboardText = "\(baseClipboard)\n\nOverall Summary:\n\(combined)"
        } else {
            cachedSummaryClipboardText = "Overall Summary:\n\(combined)"
        }
    }

    private func summaryDisplayCacheKey(for item: GlobalSummaryItem) -> String {
        summaryStableID(for: item)
    }

    private func summaryStableID(for item: GlobalSummaryItem) -> String {
        let reference = item.referenceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subject = item.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reference.isEmpty {
            return "ref-\(reference)"
        }
        if !subject.isEmpty {
            return "subject-\(subject)-summary-\(item.summary.prefix(80))"
        }
        return "summary-\(item.summary.prefix(80))"
    }

    private struct ParsedSummaryRow: Identifiable {
        let id: String
        let index: Int
        let item: GlobalSummaryItem
    }

    private var parsedSummaryRows: [ParsedSummaryRow] {
        parsedSummaries.enumerated().map { index, item in
            ParsedSummaryRow(
                id: summaryStableID(for: item),
                index: index,
                item: item
            )
        }
    }

    private func scrollToSummary(referenceNumber: Int, using proxy: ScrollViewProxy) {
        let index = referenceNumber - 1
        guard parsedSummaries.indices.contains(index) else { return }

        summaryReturnContentOffset = currentSummaryContentOffset
        let targetID = summaryStableID(for: parsedSummaries[index])
        highlightedSummaryID = targetID
        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo(targetID, anchor: .top)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard highlightedSummaryID == targetID else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                highlightedSummaryID = nil
            }
        }
    }

    private func scrollToOverallSummary() {
        if let summaryReturnContentOffset {
            var target = summaryScrollPosition
            target.scrollTo(point: summaryReturnContentOffset)
            withAnimation(.easeInOut(duration: 0.35)) {
                summaryScrollPosition = target
            }
            self.summaryReturnContentOffset = nil
            highlightedSummaryID = nil
            return
        }

        guard let summaryScrollProxy else { return }
        highlightedSummaryID = nil
        withAnimation(.easeInOut(duration: 0.35)) {
            summaryScrollProxy.scrollTo(Self.overallSummaryAnchorID, anchor: .top)
        }
    }

    private func rebuildParsedSummaryCache(from json: String) {
        guard let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(GlobalSummaryResult.self, from: data) else {
            parsedSummaries = []
            parsedSummaryDisplayCache = [:]
            isRedditContent = false
            baseSummaryClipboardText = nil
            cachedSummaryClipboardText = nil
            cachedFormattedAggregateSummary = nil
            return
        }

        parsedSummaries = result.summaries
        isRedditContent = result.source == "reddit"

        var displayCache: [String: String] = [:]
        displayCache.reserveCapacity(result.summaries.count)
        for item in result.summaries {
            let cacheKey = summaryDisplayCacheKey(for: item)
            displayCache[cacheKey] = cleanMarkdownArtifactsForDisplay(item.summary)
        }
        parsedSummaryDisplayCache = displayCache

        let header = isRedditContent ? "Reddit Summary Overview" : "Article Summary Overview"
        var sections: [String] = [header]
        if !parsedSummaries.isEmpty {
            for (index, item) in parsedSummaries.enumerated() {
                let subjectLine = "\(index + 1). \(item.subject)"
                let summary = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                if summary.isEmpty {
                    sections.append(subjectLine)
                } else {
                    sections.append("\(subjectLine)\n\(summary)")
                }
            }
        }

        let resultText = sections
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseClipboard = resultText.isEmpty ? nil : resultText
        baseSummaryClipboardText = baseClipboard
        cachedSummaryClipboardText = baseClipboard
    }

    private func restoreSummaryScrollPositionAfterRefresh(from offset: CGPoint) {
        guard summaryScrollProxy != nil else { return }

        DispatchQueue.main.async {
            guard !isSummaryScrollActive else { return }

            var restoredPosition = summaryScrollPosition
            restoredPosition.scrollTo(point: offset)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                summaryScrollPosition = restoredPosition
            }
        }
    }
    
    private var hasSummaryContent: Bool {
        !parsedSummaries.isEmpty || !(appState.aggregateSummaryText?.isEmpty ?? true)
    }

    private var formattedAggregateSummary: String? {
        cachedFormattedAggregateSummary
    }

    private var shouldShowExplicitWebAIControls: Bool {
        appState.settings.selectedSummaryProvider != .webAI
    }

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding: CGFloat = 16
            let verticalPadding: CGFloat = 16
            let availableWidth = max(0, proxy.size.width - (horizontalPadding * 2))
            let availableHeight = max(0, proxy.size.height - (verticalPadding * 2))
            let cardWidth = min(520, availableWidth)
            let cardHeight = min(600, availableHeight)
            let formattedAggregateSummary = self.formattedAggregateSummary

            ZStack {
                summaryCard(formattedAggregateSummary: formattedAggregateSummary)
                    .frame(width: cardWidth, height: cardHeight)
                    .offset(offset)
                    .scaleEffect(isDragging ? 1.05 : 1.0)
                    .animation(.spring(response: 0.3), value: isDragging)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
        }
        .onAppear {
            rebuildParsedSummaryCache(from: json)
            rebuildAggregateSummaryCache()
        }
        .onChange(of: json) { newValue in
            let preservedOffset = currentSummaryContentOffset
            rebuildParsedSummaryCache(from: newValue)
            rebuildAggregateSummaryCache()
            restoreSummaryScrollPositionAfterRefresh(from: preservedOffset)
        }
        .onChange(of: appState.aggregateSummaryText) { _ in
            rebuildAggregateSummaryCache()
        }
        .alert("Less Reliable Answer", isPresented: $showQuestionReliabilityWarning) {
            Button("Generate Overall Summary") {
                appState.generateCombinedGlobalSummary(force: false)
            }
            Button("Continue with Saved Summaries") {
                askGlobalSummaryQuestionUsingSavedSummaries(useWebAI: pendingQuestionUsesWebAI)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A full overall summary has not been generated. The answer will use the saved per-item summaries and may miss important details. Generate the overall summary first for a more reliable answer. No comments will be downloaded again if you continue.")
        }
    }

    private func summaryCard(formattedAggregateSummary: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Hide surrounding controls while the summary itself is scrolling.
            if !isSummaryContentScrolling {
                HStack {
                Image(systemName: "line.3.horizontal")
                    .foregroundColor(.secondary)
                Spacer()

                if !parsedSummaries.isEmpty && formattedAggregateSummary == nil {
                    Button {
                        appState.generateCombinedGlobalSummary(force: false)
                    } label: {
                        Image(systemName: "sparkles")
                            .foregroundColor(appState.isGeneratingAggregateSummary ? .gray : .secondary)
                    }
                    .disabled(appState.isGeneratingAggregateSummary || appState.isLoading)
                    .help("Generate overall summary")
                }

                if formattedAggregateSummary != nil {
                    Button {
                        scrollToOverallSummary()
                    } label: {
                        Image(systemName: "house.fill")
                            .foregroundColor(.secondary)
                    }
                    .disabled(summaryScrollProxy == nil)
                    .accessibilityLabel("Back to overall summary")
                    .help("Back to overall summary")

                    SummaryToolbarSeparator()
                }

                if appState.lastGlobalSummaryContext != nil {
                    Button {
                        appState.retryLastGlobalSummary()
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .disabled(appState.isLoading)
                }

                Button {
                    appState.showGlobalSummary = false
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.secondary)
                }

                Button {
                    appState.dismissGlobalSummaryAndClearContext()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }

                Button {
                    copySummaryToClipboard()
                } label: {
                    Image(systemName: "c.circle.fill")
                        .foregroundColor(.secondary)
                }
                .disabled(!canCopySummary)
                .help("Copy summary overview")

                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        if showQAInterface {
                            resetQAState()
                        } else {
                            showQAInterface = true
                        }
                    }
                } label: {
                    Image(systemName: showQAInterface ? "questionmark.circle.fill" : "questionmark.circle.fill")
                        .foregroundColor(showQAInterface ? .accentColor : .secondary)
                }
                .disabled(!hasSummaryContent)
                .help("Ask a question about this overview")

                SummaryToolbarSeparator()

                // Whiteboard button
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
                .disabled(isGeneratingWhiteboard || !hasSummaryContent)
                .help("Generate whiteboard visualization")

                // Infographic button
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
                .disabled(isGeneratingInfographic || !hasSummaryContent)
                .help("Generate infographic visualization")

                SummaryToolbarSeparator()

#if os(iOS)
                // Batch Podcast button
                Button {
                    appState.presentBatchPodcast()
                } label: {
                    Image(systemName: "waveform.badge.mic")
                        .foregroundColor(.secondary)
                }
                .disabled(!hasSummaryContent)
                .help("Generate batch podcast")
                .accessibilityLabel("Generate batch podcast")

                SummaryToolbarSeparator()
#endif

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
                    .disabled(!hasSummaryContent)
                    .help("Web actions for \(appState.settings.selectedWebAIProvider.displayName)")
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
                .highPriorityGesture(
                    DragGesture(minimumDistance: 16)
                        .onChanged { value in
                            let horizontal = abs(value.translation.width)
                            let vertical = abs(value.translation.height)
                            guard horizontal > vertical * 1.2 || vertical > horizontal * 1.2 else { return }
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
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if showQAInterface && !isSummaryContentScrolling {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ask a question about these \(isRedditContent ? "Reddit discussions" : "articles")")
                        .font(.headline)
                    
                    TextField("Type your question...", text: $qaQuestionText)
                        .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(cornerRadius: 12, tintColor: .blue.opacity(0.25)))
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
                    }
                    
                    if isProcessingQA || appState.isWaitingForGlobalQA {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(appState.globalQAWaitProgress.isEmpty ? "Thinking..." : appState.globalQAWaitProgress)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else if !qaAnswerText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Answer")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            HStack {
                                Button {
                                    showAnswerSheet = true
                                } label: {
                                    Label("Open Answer", systemImage: "arrow.up.left.and.arrow.down.right")
                                }
                                .buttonStyle(LiquidGlassButtonStyle())

                                Button {
                                    copySummaryToClipboard(text: qaAnswerText)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(LiquidGlassButtonStyle())

                                Spacer()
                            }
                        }
                        .transition(.opacity.combined(with: .slide))
                    }
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
            }

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
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

                    if appState.isLoading && !hidesBatchSummaryProgressWhileWebAIIsMinimized && formattedAggregateSummary == nil {
                        VStack(spacing: 20) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .progressViewStyle(CircularProgressViewStyle())
                            Text(isRedditContent ? "Summarizing Reddit posts..." : "Summarizing articles...")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("Depending on the number of posts, this may take a while")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    } else {
                        if appState.isLoading && formattedAggregateSummary != nil {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Refreshing source summaries...")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
                            .cornerRadius(8)
                        }

                        if appState.isGeneratingAggregateSummary {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Generating overall summary...")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
                            .cornerRadius(8)
                        } else if formattedAggregateSummary == nil && (appState.aggregateSummaryError?.isEmpty ?? true) && !parsedSummaries.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .foregroundColor(.secondary)
                                Text("Tap the sparkles button to generate an overall summary.")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
                            .cornerRadius(8)
                        }

                        if let formattedAggregateSummary {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Overall Summary")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                    .padding(.leading, 4)

                                ArticleGlassySummary(
                                    summary: formattedAggregateSummary,
                                    onAskAISelection: { selectedText, context in
                                        handleSummaryAskAISelection(
                                            selectedText: selectedText,
                                            context: context,
                                            sourceContext: sourceContextForGlobalSelection()
                                        )
                                    },
                                    onAskAIWebSelection: { selectedText, context in
                                        handleSummaryAskAIWebSelection(
                                            selectedText: selectedText,
                                            context: context,
                                            sourceContext: sourceContextForGlobalSelection()
                                        )
                                    },
                                    summaryReferenceCount: parsedSummaries.count,
                                    onSummaryReferenceTap: { referenceNumber in
                                        scrollToSummary(referenceNumber: referenceNumber, using: scrollProxy)
                                    },
                                    borderStyle: isRedditContent ? .reddit : .article
                                )
                                    .environmentObject(appState)
                            }
                            .id(Self.overallSummaryAnchorID)
                        } else if let aggregateError = appState.aggregateSummaryError, !aggregateError.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(aggregateError)
                                    .font(.callout)
                                    .foregroundColor(.primary)
                            }
                            .padding(10)
                            .background(.regularMaterial)
                            .cornerRadius(8)
                        }

                        ForEach(parsedSummaryRows) { row in
                            let index = row.index
                            let item = row.item
                            let cacheKey = summaryDisplayCacheKey(for: item)
                            let displaySummary = parsedSummaryDisplayCache[cacheKey] ?? cleanMarkdownArtifactsForDisplay(item.summary)
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
                                    displaySummary: displaySummary,
                                    onAskAISelection: { selectedText, context in
                                        handleSummaryAskAISelection(
                                            selectedText: selectedText,
                                            context: context,
                                            sourceContext: sourceContextForGlobalSelection(referenceId: item.referenceId),
                                            referenceId: item.referenceId
                                        )
                                    },
                                    onAskAIWebSelection: { selectedText, context in
                                        handleSummaryAskAIWebSelection(
                                            selectedText: selectedText,
                                            context: context,
                                            sourceContext: sourceContextForGlobalSelection(referenceId: item.referenceId),
                                            referenceId: item.referenceId
                                        )
                                    },
                                    borderStyle: isRedditContent ? .reddit : .article
                                )
                                    .environmentObject(appState)
                            }
                            .padding(.bottom, 4)
                            .padding(.horizontal, 4)
                            .background {
                                if highlightedSummaryID == row.id {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.12))
                                }
                            }
                            .overlay {
                                if highlightedSummaryID == row.id {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.accentColor.opacity(0.9), lineWidth: 2)
                                }
                            }
                            .id(row.id)
                            .animation(.easeInOut(duration: 0.2), value: highlightedSummaryID)
                        }
                    }
                    }
                    .padding()
                }
                .scrollPosition($summaryScrollPosition)
                .frame(maxHeight: .infinity)
                .onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { _, newOffset in
                    currentSummaryContentOffset = newOffset
                }
                .onScrollPhaseChange { _, newPhase in
                    if newPhase.isScrolling {
                        isSummaryScrollActive = true
                        summaryChromeReturnTask?.cancel()
                        summaryChromeReturnTask = nil
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isSummaryContentScrolling = true
                        }
                    } else {
                        isSummaryScrollActive = false
                        scheduleSummaryChromeReturn()
                    }
                }
                .onAppear {
                    summaryScrollProxy = scrollProxy
                }
                .onDisappear {
                    summaryScrollProxy = nil
                    summaryChromeReturnTask?.cancel()
                    summaryChromeReturnTask = nil
                }
            }
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.blue.opacity(colorScheme == .dark ? 0.14 : 0.08))

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
        .askAILoadingOverlay(isAskingSelectionAI)
        .sheet(isPresented: $showAnswerSheet) {
            NavigationStack {
                ScrollView {
                    if qaAnswerText.isEmpty {
                        Text("No answer available.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else {
                        ArticleGlassySummary(
                            summary: qaAnswerText,
                            onAskAISelection: { selectedText, context in
                                handleSummaryAnswerSelection(
                                    selectedText: selectedText,
                                    context: context,
                                    useWebAI: false
                                )
                            },
                            onAskAIWebSelection: { selectedText, context in
                                handleSummaryAnswerSelection(
                                    selectedText: selectedText,
                                    context: context,
                                    useWebAI: true
                                )
                            }
                        )
                            .environmentObject(appState)
                            .padding()
                    }
                }
                .navigationTitle("Summary Answer")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showAnswerSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .none) {
                            copySummaryToClipboard(text: qaAnswerText)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .tint(.primary)
                    }
                }
            }
            #if os(iOS)
            .background(Color.clear)
            .background(AskAISheetTransparencyBridge())
            .toolbarBackground(.hidden, for: .navigationBar)
            .presentationBackground {
                AskAIPresentationBackground()
            }
            #endif
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(32)
            #endif
        }
        .sheet(isPresented: $showSelectionAskAISheet) {
            AskAIResponseSheet(
                question: selectionAskAIPrompt,
                answer: selectionAskAIResponse,
                onCopy: { copySummaryToClipboard(text: selectionAskAIResponse) }
            )
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(32)
            #endif
        }
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { showWhiteboard && !isWhiteboardMinimized },
            set: { newValue in
                // Only reset showWhiteboard if user actually closed (not minimized)
                if !newValue && !isWhiteboardMinimized {
                    showWhiteboard = false
                }
            }
        )) {
            WhiteboardView(
                htmlData: whiteboardContent,
                onDismiss: { showWhiteboard = false; isWhiteboardMinimized = false },
                onMinimize: { isWhiteboardMinimized = true }
            )
        }
        #elseif os(macOS)
        .sheet(isPresented: Binding(
            get: { showWhiteboard && !isWhiteboardMinimized },
            set: { newValue in
                // Only reset showWhiteboard if user actually closed (not minimized)
                if !newValue && !isWhiteboardMinimized {
                    showWhiteboard = false
                }
            }
        )) {
            WhiteboardView(
                htmlData: whiteboardContent,
                onDismiss: { showWhiteboard = false; isWhiteboardMinimized = false },
                onMinimize: { isWhiteboardMinimized = true }
            )
        }
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { showInfographic && !isInfographicMinimized },
            set: { newValue in
                // Only reset showInfographic if user actually closed (not minimized)
                if !newValue && !isInfographicMinimized {
                    showInfographic = false
                }
            }
        )) {
            InfographicView(
                htmlData: infographicContent,
                onMinimize: { isInfographicMinimized = true }
            )
        }
        #elseif os(macOS)
        .sheet(isPresented: Binding(
            get: { showInfographic && !isInfographicMinimized },
            set: { newValue in
                // Only reset showInfographic if user actually closed (not minimized)
                if !newValue && !isInfographicMinimized {
                    showInfographic = false
                }
            }
        )) {
            InfographicView(
                htmlData: infographicContent,
                onMinimize: { isInfographicMinimized = true }
            )
        }
        #endif
        // Minimized floating pills
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 12) {
                if showWhiteboard && isWhiteboardMinimized {
                    MinimizedFloatingPill(
                        title: "Whiteboard",
                        icon: "rectangle.and.pencil.and.ellipsis",
                        color: .blue,
                        onRestore: { isWhiteboardMinimized = false },
                        onClose: { showWhiteboard = false; isWhiteboardMinimized = false }
                    )
                    .transition(.scale.combined(with: .opacity))
                }
                if showInfographic && isInfographicMinimized {
                    MinimizedFloatingPill(
                        title: "Infographic",
                        icon: "chart.bar.doc.horizontal",
                        color: .purple,
                        onRestore: { isInfographicMinimized = false },
                        onClose: { showInfographic = false; isInfographicMinimized = false }
                    )
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 100)
            .animation(.spring(response: 0.3), value: isWhiteboardMinimized)
            .animation(.spring(response: 0.3), value: isInfographicMinimized)
        }
        // Whiteboard error display
        .overlay(alignment: .bottom) {
            if let error = whiteboardError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.9))
                    .cornerRadius(8)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { whiteboardError = nil }
                        }
                    }
            }
        }
        // Infographic error display
        .overlay(alignment: .bottom) {
            if let error = infographicError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.9))
                    .cornerRadius(8)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { infographicError = nil }
                        }
                    }
            }
        }
    }

    private func scheduleSummaryChromeReturn() {
        summaryChromeReturnTask?.cancel()
        summaryChromeReturnTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: summaryChromeReturnDelay)
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 0.18)) {
                isSummaryContentScrolling = false
            }
            summaryChromeReturnTask = nil
        }
    }

    private func copySummaryToClipboard() {
        guard let text = summaryClipboardText else { return }
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
    
    private func copySummaryToClipboard(text: String) {
        guard !text.isEmpty else { return }
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
    
    private func askGlobalSummaryQuestion() {
        guard !isProcessingQA && !appState.isWaitingForGlobalQA else { return }
        let trimmed = qaQuestionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            qaInlineError = "Please enter a question first."
            return
        }
        if isRedditContent,
           appState.aggregateSummaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            pendingQuestionUsesWebAI = false
            showQuestionReliabilityWarning = true
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
        if isRedditContent,
           appState.aggregateSummaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            pendingQuestionUsesWebAI = true
            showQuestionReliabilityWarning = true
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

    private func askGlobalSummaryQuestionUsingSavedSummaries(useWebAI: Bool) {
        let trimmed = qaQuestionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        qaInlineError = nil
        isProcessingQA = true
        qaAnswerText = ""
        appState.askQuestionAboutSavedGlobalSummaries(
            question: trimmed,
            useWebAI: useWebAI
        ) { answer in
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

    private func sourceContextForGlobalSelection(referenceId: String? = nil) -> (label: String, text: String)? {
        appState.globalSummarySelectionSourceContext(referenceId: referenceId, isReddit: isRedditContent)
    }

    private func handleSummaryAskAISelection(
        selectedText: String,
        context: String,
        sourceContext: (label: String, text: String)? = nil,
        referenceId: String? = nil
    ) {
        guard !isAskingSelectionAI else { return }
        let prompt = buildAskAISelectionPrompt(
            selectedText: selectedText,
            extractedContext: context,
            sourceContext: sourceContext?.text ?? "",
            sourceLabel: sourceContext?.label ?? ""
        )
        guard !prompt.isEmpty else { return }

        selectionAskAIPrompt = prompt
        selectionAskAIResponse = ""
        isAskingSelectionAI = true

        let answerHandler: (String) -> Void = { answer in
            DispatchQueue.main.async {
                self.selectionAskAIResponse = formatAskAIResponseForDisplay(answer)
                self.isAskingSelectionAI = false
                self.showSelectionAskAISheet = true
            }
        }
        if isRedditContent {
            appState.askQuestionAboutGlobalSummarySelection(
                selectedText: selectedText,
                extractedContext: context,
                referenceId: referenceId,
                useWebAI: false,
                completion: answerHandler
            )
        } else {
            appState.askQuestionAboutSelection(prompt: prompt, completion: answerHandler)
        }
    }

    private func handleSummaryAskAIWebSelection(
        selectedText: String,
        context: String,
        sourceContext: (label: String, text: String)? = nil,
        referenceId: String? = nil
    ) {
        guard !isAskingSelectionAI else { return }
        let prompt = buildAskAISelectionPrompt(
            selectedText: selectedText,
            extractedContext: context,
            sourceContext: sourceContext?.text ?? "",
            sourceLabel: sourceContext?.label ?? ""
        )
        guard !prompt.isEmpty else { return }

        selectionAskAIPrompt = prompt
        selectionAskAIResponse = ""
        isAskingSelectionAI = true

        let answerHandler: (String) -> Void = { answer in
            DispatchQueue.main.async {
                self.selectionAskAIResponse = formatAskAIResponseForDisplay(answer)
                self.isAskingSelectionAI = false
                self.showSelectionAskAISheet = true
            }
        }
        if isRedditContent {
            appState.askQuestionAboutGlobalSummarySelection(
                selectedText: selectedText,
                extractedContext: context,
                referenceId: referenceId,
                useWebAI: true,
                completion: answerHandler
            )
        } else {
            appState.askWebQuestionAboutSelection(prompt: prompt, completion: answerHandler)
        }
    }

    private func handleSummaryAnswerSelection(
        selectedText: String,
        context: String,
        useWebAI: Bool
    ) {
        guard !isAskingSelectionAI else { return }

        let currentAnswer = qaAnswerText
        let prompt = buildAskAISelectionPrompt(
            selectedText: selectedText,
            extractedContext: context,
            sourceContext: currentAnswer,
            sourceLabel: "Current Summary Answer"
        )
        guard !prompt.isEmpty else { return }

        selectionAskAIPrompt = prompt
        selectionAskAIResponse = ""
        isAskingSelectionAI = true
        showAnswerSheet = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let completion: (String) -> Void = { answer in
                DispatchQueue.main.async {
                    self.selectionAskAIResponse = formatAskAIResponseForDisplay(answer)
                    self.isAskingSelectionAI = false
                    self.showSelectionAskAISheet = true
                }
            }

            if useWebAI {
                appState.askWebQuestionAboutSelection(prompt: prompt, completion: completion)
            } else {
                appState.askQuestionAboutSelection(prompt: prompt, completion: completion)
            }
        }
    }

    // MARK: - Whiteboard Generation

    private func buildWhiteboardPrompt() -> String {
        let selectedProvider = appState.settings.selectedSummaryProvider
        let summariesForPrompt = (selectedProvider == .appleCloud || selectedProvider == .applePCCGateway)
            ? Array(parsedSummaries.prefix(12).enumerated())
            : Array(parsedSummaries.enumerated())
        let rankedCandidates = rankedVisualCandidates(limit: isRedditContent ? 5 : 0)

        let perItemLimit = (selectedProvider == .appleCloud || selectedProvider == .applePCCGateway) ? 600 : 2000
        let content = summariesForPrompt.map { index, item in
            let title = item.subject.isEmpty ? "Item \(index + 1)" : item.subject
            let truncatedContent = String(item.summary.prefix(perItemLimit))
            return "[\(index + 1)] \"\(title)\"\n\(truncatedContent)\n"
        }.joined(separator: "\n---\n")

        let urlReferenceList: String
        if isRedditContent {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                if let post = appState.redditPostForGlobalSummaryReference(referenceId),
                   let postUrl = post.url {
                    let arrow = (selectedProvider == .appleCloud || selectedProvider == .applePCCGateway) ? "→" : "->"
                    return "[\(index + 1)] \"\(item.subject)\" \(arrow) \(postUrl.absoluteString)"
                }
                return nil
            }.joined(separator: "\n")
        } else {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                if let article = appState.articleForGlobalSummaryReference(referenceId),
                   let articleUrl = article.url {
                    let arrow = (selectedProvider == .appleCloud || selectedProvider == .applePCCGateway) ? "→" : "->"
                    return "[\(index + 1)] \"\(item.subject)\" \(arrow) \(articleUrl.absoluteString)"
                }
                return nil
            }.joined(separator: "\n")
        }

        let promptProvider: AppSettings.SummaryProvider = (selectedProvider == .appleLocal || selectedProvider == .appleCloud) ? .mlxLocal : selectedProvider
        return makeWhiteboardPrompt(
            from: content,
            urlReference: urlReferenceList,
            rankedCandidates: rankedCandidates,
            providerOverride: promptProvider
        )
    }

    private func buildWhiteboardWebPrompt() -> String {
        let selectedProvider = appState.settings.selectedSummaryProvider
        let summariesForPrompt = (selectedProvider == .appleCloud || selectedProvider == .applePCCGateway)
            ? Array(parsedSummaries.prefix(12).enumerated())
            : Array(parsedSummaries.enumerated())
        let rankedCandidates = rankedVisualCandidates(limit: isRedditContent ? 5 : 0)
        let perItemLimit = (selectedProvider == .appleCloud || selectedProvider == .applePCCGateway) ? 600 : 2000
        let content = summariesForPrompt.map { index, item in
            let title = item.subject.isEmpty ? "Item \(index + 1)" : item.subject
            let truncatedContent = String(item.summary.prefix(perItemLimit))
            return "[\(index + 1)] \"\(title)\"\n\(truncatedContent)\n"
        }.joined(separator: "\n---\n")

        let urlReferenceList: String
        if isRedditContent {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                if let post = appState.redditPostForGlobalSummaryReference(referenceId),
                   let postUrl = post.url {
                    return "[\(index + 1)] \"\(item.subject)\" -> \(postUrl.absoluteString)"
                }
                return nil
            }.joined(separator: "\n")
        } else {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                if let article = appState.articleForGlobalSummaryReference(referenceId),
                   let articleUrl = article.url {
                    return "[\(index + 1)] \"\(item.subject)\" -> \(articleUrl.absoluteString)"
                }
                return nil
            }.joined(separator: "\n")
        }

        let rankingSection = buildRankedPostSection(
            header: "KEY POST RANKING",
            selectionField: "key posts",
            candidates: rankedCandidates,
            limit: 5
        )
        let takeawaysLabel = isRedditContent ? "Community Suggestions" : "Key Takeaways"

        return """
        Create the actual visual whiteboard from the source material below.

        IMPORTANT:
        - Do NOT return JSON.
        - Do NOT describe how to make the whiteboard.
        - Produce the whiteboard itself.
        - If your interface supports canvas, artifact, or rich HTML/SVG rendering, use it.
        - Otherwise, output a single self-contained SVG that visually looks like a brainstorm whiteboard with sticky notes, clusters, arrows, and section headers.
        - Keep the layout readable on a laptop screen.
        - Use concise text taken from the source material.

        The whiteboard should include these sections:
        - What We Know
        - Open Questions
        - \(takeawaysLabel)
        - Pain Points
        - Hot Takes
        - Connections
        - Ideas to Explore
        - Key Posts
        - Bottom Line

        Key visual direction:
        - Whiteboard / workshop style, not a polished infographic
        - Sticky notes, grouped clusters, connector arrows, short labels
        - Prioritize clarity and hierarchy over decoration

        KEY POSTS RULES:
        - Use only the exact URLs from the reference list.
        - Preserve the ranked order when choosing key posts.

        \(rankingSection.isEmpty ? "" : rankingSection + "\n")
        === REFERENCE URLS ===
        \(urlReferenceList)
        === END REFERENCE URLS ===

        === SOURCE MATERIAL ===
        \(content)
        === END SOURCE MATERIAL ===
        """
    }

    private func sendWhiteboardToWebAI() {
        guard !isGeneratingWhiteboard else { return }

        isGeneratingWhiteboard = true
        whiteboardError = nil
        isWhiteboardMinimized = false
        generateWhiteboardWithWebAI(prompt: buildWhiteboardPrompt())
    }

    private func generateWhiteboard() {
        guard !isGeneratingWhiteboard else { return }

        isGeneratingWhiteboard = true
        whiteboardError = nil

        let selectedProvider = appState.settings.selectedSummaryProvider
        let prompt = buildWhiteboardPrompt()

        // Route to appropriate provider
        switch appState.settings.selectedSummaryProvider {
        case .mlxLocal, .coreAIMLXLocal:
            // Local models redirect to Apple Local for structured JSON.
            generateWhiteboardWithMLXLocal(prompt: prompt)

        case .appleLocal:
            // For Whiteboard, use the same path as MLX Local (keeps regular summaries unchanged).
            generateWhiteboardWithMLXLocal(prompt: prompt)

        case .appleCloud:
            generateWhiteboardWithAppleCloud(prompt: prompt)

        case .applePCCGateway:
            generateWhiteboardWithPCCGateway(prompt: prompt)

        case .webAI:
            generateWhiteboardWithWebAI(prompt: prompt)

        case .summarizeDaemon:
            generateWhiteboardWithSummarize(prompt: prompt)

        case .gemini:
            // Use Gemini API directly
            generateWhiteboardWithGemini(prompt: prompt)
        }
    }

    private func generateWhiteboardWithGemini(prompt: String) {
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

                // Use the summary service's Gemini integration
                let response = try await appState.summaryService.generateContentWithGemini(prompt: prompt)

                guard let payload = parseWhiteboardPayload(from: response) else {
                    await MainActor.run {
                        self.whiteboardError = "Failed to parse whiteboard data"
                        self.isGeneratingWhiteboard = false
                    }
                    return
                }

                // Build HTML
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

    private func generateWhiteboardWithAppleLocal(prompt: String) {
        // Use Apple Intelligence on-device with Gemini fallback
        if #available(iOS 18.2, macOS 15.2, *) {
            appState.performLocalWithGeminiFallbackPublic(prompt: prompt, taskName: "Whiteboard") { result in
                handleWhiteboardResponse(result)
            }
        } else {
            // Fall back to Gemini if Apple Local not available
            generateWhiteboardWithGemini(prompt: prompt)
        }
    }

    private func generateWhiteboardWithAppleCloud(prompt: String) {
        // Apple Cloud can handle JSON output with explicit instructions
        print("☁️ ContentView: Using Apple Cloud for whiteboard generation")

        Task {
            do {
                let timeoutSeconds = appleCloudTimeoutSeconds(promptCharCount: prompt.count)
                let raw = try await runAppleCloudStructured(
                    prompt: prompt,
                    timeoutSeconds: timeoutSeconds,
                    requiredTopLevelKeys: ["sessionTitle", "sessionContext", "whatWeKnow", "openQuestions", "takeaways", "painPoints", "hotTakes", "connections", "ideasToExplore", "keyPosts", "bottomLine"]
                )

                func parseAndValidate(_ text: String) throws -> WhiteboardPayload {
                    let candidate = sanitizeStructuredJSONCandidate(text)
                    guard let data = candidate.data(using: .utf8) else {
                        throw NSError(domain: "Whiteboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert response to data."])
                    }
                    let json = try MLXJSONRepairUtils.parseLLMJSONDictionary(from: data, domain: "Whiteboard")
                    guard isAppleCloudWhiteboardJSONSufficient(json) else {
                        throw AppleCloudIncompleteStructuredOutput(message: "Apple Cloud returned incomplete whiteboard data.")
                    }
                    return WhiteboardPayload(dictionary: json, isReddit: isRedditContent, rankedCandidates: rankedVisualCandidates(limit: isRedditContent ? 5 : 0))
                }

                let payload: WhiteboardPayload
                do {
                    payload = try parseAndValidate(raw)
                } catch {
                    // If JSON is malformed OR valid-but-empty, regenerate once using Apple Cloud.
                    let regenerated = try await regenerateAppleCloudStructuredJSON(
                        kind: .whiteboard,
                        originalPrompt: prompt,
                        previousOutput: raw,
                        timeoutSeconds: 300
                    )
                    payload = try parseAndValidate(regenerated)
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

    private func generateWhiteboardWithWebAI(prompt: String) {
        Task {
            do {
                let response = try await appState.performWebAIRequestAsync(
                    title: "Whiteboard",
                    prompt: prompt,
                    responseFormat: .strictJSON
                )
                await MainActor.run {
                    handleWhiteboardResponse(response)
                }
            } catch {
                await MainActor.run {
                    self.whiteboardError = "Whiteboard failed: \(error.localizedDescription)"
                    self.isGeneratingWhiteboard = false
                }
            }
        }
    }

    private func generateWhiteboardWithSummarize(prompt: String) {
        Task {
            do {
                let response = try await appState.performSummarizeRequestAsync(prompt: prompt, taskName: "Whiteboard")
                guard let rawData = response.data(using: .utf8) else {
                    throw NSError(domain: "Whiteboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert response to data."])
                }
                let payload: WhiteboardPayload
                do {
                    payload = try parseWhiteboardPayloadFromData(rawData)
                } catch {
                    let repairedData = try await repairInvalidJSON(kind: .whiteboard, rawOutput: response)
                    payload = try parseWhiteboardPayloadFromData(repairedData)
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

    private func generateWhiteboardWithPCCGateway(prompt: String) {
        Task {
            do {
                let response = try await appState.performPCCGatewayRequestAsync(prompt: prompt, taskName: "Whiteboard")
                guard let rawData = response.data(using: .utf8) else {
                    throw NSError(domain: "Whiteboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert response to data."])
                }
                let payload: WhiteboardPayload
                do {
                    payload = try parseWhiteboardPayloadFromData(rawData)
                } catch {
                    let repairedData = try await repairInvalidJSON(kind: .whiteboard, rawOutput: response)
                    payload = try parseWhiteboardPayloadFromData(repairedData)
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

    private func runAppleCloudStructured(prompt: String, timeoutSeconds: TimeInterval? = nil, requiredTopLevelKeys: [String]? = nil) async throws -> String {
        var didReturn = false
        return try await withCheckedThrowingContinuation { continuation in
            func finish(_ result: Result<String, Error>) {
                if didReturn { return }
                didReturn = true
                continuation.resume(with: result)
            }

            func satisfiesRequiredKeys(_ text: String) -> Bool {
                guard let requiredTopLevelKeys, !requiredTopLevelKeys.isEmpty else { return true }
                let candidate = sanitizeStructuredJSONCandidate(text)
                guard let data = candidate.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data),
                      let dict = obj as? [String: Any] else {
                    return false
                }
                return requiredTopLevelKeys.allSatisfy { dict[$0] != nil }
            }

            var timeoutTask: Task<Void, Never>?
            timeoutTask = Task {
                let effectiveTimeout = timeoutSeconds ?? appleCloudTimeoutSeconds(promptCharCount: prompt.count)
                try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                finish(.failure(NSError(
                    domain: "AppleCloud",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Apple Cloud response timed out after \(Int(effectiveTimeout)) seconds."]
                )))
            }

            appState.launchCloudRequest(for: prompt, type: .summary, useClipboardMonitoring: false) { response in
                timeoutTask?.cancel()
                let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    finish(.failure(NSError(domain: "AppleCloud", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple Cloud returned an empty response."])))
                } else if !satisfiesRequiredKeys(trimmed) {
                    finish(.failure(AppleCloudIncompleteStructuredOutput(message: "Apple Cloud returned incomplete structured data.")))
                } else {
                    finish(.success(trimmed))
                }
            }
        }
    }

    private func appleCloudTimeoutSeconds(promptCharCount: Int) -> TimeInterval {
        // Dynamic timeout based on prompt size (mirrors the red sample approach).
        // Small prompts (< 5k): ~30-60s, larger prompts scale up to 10 minutes.
        let scaled = 60 + (promptCharCount / 500)
        return TimeInterval(min(600, max(120, scaled)))
    }

    private actor AppleCloudShortcutCallbackBox {
        private var result: String?
        private var errorMessage: String?

        func setResult(_ value: String) { result = value }
        func setError(_ message: String) { errorMessage = message }
        func snapshot() -> (result: String?, errorMessage: String?) { (result, errorMessage) }
    }

    private func waitForAppleCloudOutput(
        timeout: TimeInterval = 120,
        interval: TimeInterval = 0.75,
        originalClipboard: String? = nil,
        requiredTopLevelKeys: [String]? = nil
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        let baseline = originalClipboard ?? currentClipboardString() ?? ""

        let callbackBox = AppleCloudShortcutCallbackBox()
        let callbackObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("ShortcutCallbackReceived"),
            object: nil,
            queue: .main
        ) { notification in
            let userInfo = notification.userInfo ?? [:]
            if (userInfo["error"] as? Bool) == true {
                let message = (userInfo["message"] as? String) ?? "Shortcut returned an error."
                Task { await callbackBox.setError(message) }
                return
            }
            if let result = userInfo["result"] as? String {
                Task { await callbackBox.setResult(result) }
            }
        }
        defer { NotificationCenter.default.removeObserver(callbackObserver) }

        func satisfiesRequiredKeys(_ text: String) -> Bool {
            guard let requiredTopLevelKeys, !requiredTopLevelKeys.isEmpty else { return true }
            let candidate = sanitizeStructuredJSONCandidate(text)
            guard let data = candidate.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any] else {
                return false
            }
            return requiredTopLevelKeys.allSatisfy { dict[$0] != nil }
        }

        func isValidJSONCandidate(_ text: String) -> Bool {
            let cleaned = MLXJSONRepairUtils.stripMarkdownFences(from: text.trimmingCharacters(in: .whitespacesAndNewlines))

            if let first = cleaned.firstIndex(of: "{"),
               let last = cleaned.lastIndex(of: "}"),
               first < last,
               let data = String(cleaned[first...last]).data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return true
            }

            if let first = cleaned.firstIndex(of: "["),
               let last = cleaned.lastIndex(of: "]"),
               first < last,
               let data = String(cleaned[first...last]).data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return true
            }

            return false
        }

        var lastFileValue: String?
        var lastFileChangeAt = Date.distantPast
        var fileSeenAt: Date?

        while Date() < deadline {
            let callbackSnapshot = await callbackBox.snapshot()
            if let error = callbackSnapshot.errorMessage {
                throw NSError(domain: "AppleCloudShortcut", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
            }
            if let result = callbackSnapshot.result?.trimmingCharacters(in: .whitespacesAndNewlines),
               result.count > 10 {
                // IMPORTANT: callback URL results are often URL-length truncated for large JSON.
                // Only accept callback `result` if it looks like complete JSON for this request.
                if isValidJSONCandidate(result) && satisfiesRequiredKeys(result) {
                    return result
                }
            }

            if let fileContent = appState.readShortcutOutputFile() {
                let trimmed = fileContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 10 {
                    if fileSeenAt == nil { fileSeenAt = Date() }

                    if trimmed != lastFileValue {
                        lastFileValue = trimmed
                        lastFileChangeAt = Date()
                    } else {
                        let stableFor = Date().timeIntervalSince(lastFileChangeAt)
                        let seenFor = fileSeenAt.map { Date().timeIntervalSince($0) } ?? 0
                        let validJSON = isValidJSONCandidate(trimmed)

                        // Avoid reading a partially-written file: require stability, and prefer valid JSON.
                        // If JSON is invalid, wait a bit longer before returning so repair has the full text.
                        if stableFor >= 0.8 && (validJSON || seenFor >= 2.0) && satisfiesRequiredKeys(trimmed) {
                            appState.clearShortcutOutputFile()
                            return trimmed
                        }
                    }
                }
            }

            if let clipboard = currentClipboardString() {
                let trimmed = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 10 && trimmed != baseline && satisfiesRequiredKeys(trimmed) {
                    return trimmed
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }

        throw NSError(
            domain: "AppleCloudShortcut",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Apple Cloud response timed out after \(Int(timeout)) seconds. (If your shortcut returns JSON via the callback URL, it may be truncated; prefer writing to ShortcutOutput.txt or copying to clipboard.)"]
        )
    }

    private func currentClipboardString() -> String? {
        #if os(iOS)
        return UIPasteboard.general.string
        #elseif os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }

    private func sanitizeStructuredJSONCandidate(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = MLXJSONRepairUtils.stripMarkdownFences(from: cleaned)

        if let firstBrace = cleaned.firstIndex(of: "{") {
            cleaned = String(cleaned[firstBrace...])
        }

        let openBrackets = cleaned.filter { $0 == "[" }.count
        let closeBrackets = cleaned.filter { $0 == "]" }.count
        let openBraces = cleaned.filter { $0 == "{" }.count
        let closeBraces = cleaned.filter { $0 == "}" }.count

        var repaired = cleaned
        if openBrackets > closeBrackets {
            repaired.append(String(repeating: "]", count: openBrackets - closeBrackets))
        }
        if openBraces > closeBraces {
            repaired.append(String(repeating: "}", count: openBraces - closeBraces))
        }

        return repaired.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct AppleCloudIncompleteStructuredOutput: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func isAppleCloudWhiteboardJSONSufficient(_ json: [String: Any]) -> Bool {
        let whatWeKnow = (json["whatWeKnow"] as? [Any] ?? []).count
        let openQuestions = (json["openQuestions"] as? [Any] ?? []).count
        let takeaways = (json["takeaways"] as? [Any] ?? []).count
        let painPoints = (json["painPoints"] as? [Any] ?? []).count
        let hotTakes = (json["hotTakes"] as? [Any] ?? []).count
        let connections = (json["connections"] as? [Any] ?? []).count
        let ideasToExplore = (json["ideasToExplore"] as? [Any] ?? []).count
        let keyPosts = (json["keyPosts"] as? [Any] ?? []).count

        // Whiteboard can be concise, but should not be mostly empty.
        return whatWeKnow >= 3 && takeaways >= 2 && keyPosts >= 2 && painPoints >= 1
            && (openQuestions + hotTakes + connections + ideasToExplore) >= 2
    }

    private func isAppleCloudInfographicJSONSufficient(_ json: [String: Any]) -> Bool {
        let majorThemes = (json["majorThemes"] as? [Any] ?? []).count
        let themes = (json["themes"] as? [Any] ?? []).count
        let keyTopics = (json["keyTopics"] as? [Any] ?? []).count
        let notableTrends = (json["notableTrends"] as? [Any] ?? []).count
        let statTiles = (json["statTiles"] as? [Any] ?? []).count
        let barSections = (json["barSections"] as? [Any] ?? []).count

        let topPosts = (json["topPosts"] as? [[String: Any]] ?? [])
        let hasAnyURL = topPosts.contains { post in
            guard let url = post["url"] as? String else { return false }
            return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        // Infographic should have real structure; URLs can be empty, but content lists must exist.
        return majorThemes >= 2 && keyTopics >= 4 && notableTrends >= 2 && themes >= 3
            && statTiles >= 2 && barSections >= 2
            && (hasAnyURL || topPosts.count >= 2)
    }

    private func regenerateAppleCloudStructuredJSON(
        kind: MLXStructuredJSONKind,
        originalPrompt: String,
        previousOutput: String,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        let keys: String
        switch kind {
        case .infographic:
            keys = #"title,subtitle,focus,palette,statTiles,barSections,sentiment,sentimentBand,majorThemes,themes,keyTopics,notableTrends,takeaway,topPosts"#
        case .whiteboard:
            keys = #"sessionTitle,sessionContext,whatWeKnow,openQuestions,takeaways,painPoints,hotTakes,connections,ideasToExplore,keyPosts,bottomLine"#
        }

        let prompt = """
        You are regenerating a strict JSON response because the previous output was incomplete/empty.

        Output ONLY one valid JSON object (no markdown, no code fences, no commentary).
        - Include ALL keys exactly as required.
        - Do not leave arrays empty. If unsure, add best-effort items grounded in the provided content.
        - Keep strings short to avoid truncation.

        Required top-level keys: \(keys)

        ORIGINAL TASK (follow this):
        \(originalPrompt)

        PREVIOUS OUTPUT (incomplete; do NOT repeat emptiness):
        \(previousOutput.prefix(3500))
        """

        let requiredKeys = keys
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return try await runAppleCloudStructured(prompt: prompt, timeoutSeconds: timeoutSeconds, requiredTopLevelKeys: requiredKeys)
    }

    // MARK: - MLX Structured JSON (used when Apple Local/Cloud is selected for Whiteboard/Infographic)

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

    private func generateWhiteboardWithMLXStructured(prompt: String) {
        Task {
            do {
                let raw = try await generateStructuredJSONWithMLX(prompt: prompt)
                let candidate = sanitizeStructuredJSONCandidate(raw)
                guard let data = candidate.data(using: .utf8) else {
                    throw NSError(domain: "Whiteboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert response to data."])
                }

                let payload: WhiteboardPayload
                do {
                    payload = try parseWhiteboardPayloadFromData(data)
                } catch {
                    let repaired = try await repairInvalidJSONUsingMLX(kind: .whiteboard, rawOutput: raw)
                    payload = try parseWhiteboardPayloadFromData(repaired)
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

    private func generateInfographicWithMLXStructured(prompt: String) {
        Task {
            do {
                let raw = try await generateStructuredJSONWithMLX(prompt: prompt)
                let candidate = sanitizeStructuredJSONCandidate(raw)
                guard let data = candidate.data(using: .utf8) else {
                    throw NSError(domain: "Infographic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert response to data."])
                }

                let payload: InfographicPayload
                do {
                    payload = try parseInfographicPayloadFromData(data)
                } catch {
                    let repaired = try await repairInvalidJSONUsingMLX(kind: .infographic, rawOutput: raw)
                    payload = try parseInfographicPayloadFromData(repaired)
                }

                let html = buildInfographicHTML(from: payload)
                let safe = sanitizeInfographicHTML(html)
                guard let htmlData = safe.data(using: .utf8) else {
                    throw NSError(domain: "Infographic", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not convert infographic to data."])
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

    private func generateWhiteboardWithMLXLocal(prompt: String) {
        // MLX Local redirects to Apple Local for structured JSON output
        // (MLX struggles with strict JSON formatting)
        // Pattern matches red folder: clear cache, generate via Apple Local, repair if needed
        Task {
            do {
                // MLX-specific: Clear GPU cache to prevent stale context from previous generations
                await MLXLocalService.shared.clearTransientCache()
                print("🔀 [Whiteboard] MLX selected - redirecting to Apple Local for JSON generation")

                // Route to Apple Local for structured JSON generation
                let rawResponse: String
                if #available(iOS 18.2, macOS 15.2, *) {
                    rawResponse = try await withCheckedThrowingContinuation { continuation in
                        appState.performLocalWithGeminiFallbackPublic(prompt: prompt, taskName: "Whiteboard") { result in
                            continuation.resume(returning: result)
                        }
                    }
                } else {
                    // Fall back to Gemini if Apple Local not available
                    rawResponse = try await appState.summaryService.generateContentWithGemini(prompt: prompt)
                }

                guard let rawData = rawResponse.data(using: .utf8) else {
                    throw NSError(domain: "Whiteboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert response to data."])
                }

                // Try to parse the JSON response
                let payload: WhiteboardPayload
                do {
                    payload = try parseWhiteboardPayloadFromData(rawData)
                } catch {
                    // If parsing fails and MLX is selected, attempt JSON repair via Gemini
                    print("⚠️ [Whiteboard] Initial JSON parsing failed for MLX output, attempting repair...")
                    let repairedData = try await repairInvalidJSONFromMLX(kind: .whiteboard, rawOutput: rawResponse)
                    payload = try parseWhiteboardPayloadFromData(repairedData)
                }

                // Build HTML
                let html = buildWhiteboardHTML(from: payload)

                guard let htmlData = html.data(using: .utf8) else {
                    throw NSError(domain: "Whiteboard", code: 7, userInfo: [NSLocalizedDescriptionKey: "Could not convert whiteboard to data."])
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

    private func handleWhiteboardResponse(_ response: String) {
        guard let payload = parseWhiteboardPayload(from: response) else {
            self.whiteboardError = "Failed to parse whiteboard data"
            self.isGeneratingWhiteboard = false
            return
        }

        // Build HTML
        let html = buildWhiteboardHTML(from: payload)

        guard let htmlData = html.data(using: .utf8) else {
            self.whiteboardError = "Failed to generate whiteboard"
            self.isGeneratingWhiteboard = false
            return
        }

        self.whiteboardContent = htmlData
        self.isGeneratingWhiteboard = false
        self.showWhiteboard = true
    }

    // MARK: - MLX JSON Repair (matches red folder pattern)

    private func parseWhiteboardPayloadFromData(_ data: Data) throws -> WhiteboardPayload {
        let json = try MLXJSONRepairUtils.parseLLMJSONDictionary(from: data, domain: "Whiteboard")
        return WhiteboardPayload(dictionary: json, isReddit: isRedditContent, rankedCandidates: rankedVisualCandidates(limit: isRedditContent ? 5 : 0))
    }

    /// Repair invalid JSON using the same provider that generated it
    private func repairInvalidJSON(kind: MLXStructuredJSONKind, rawOutput: String) async throws -> Data {
        let selectedProvider = appState.settings.selectedSummaryProvider

        if selectedProvider == .appleCloud || selectedProvider == .applePCCGateway {
            let sanitized = sanitizeStructuredJSONCandidate(rawOutput)
            if let data = sanitized.data(using: .utf8) {
                let domain = (kind == .infographic) ? "Infographic" : "Whiteboard"
                if (try? MLXJSONRepairUtils.parseLLMJSONDictionary(from: data, domain: domain)) != nil {
                    return data
                }
            }
        }

        let clippedLimit = (selectedProvider == .appleCloud || selectedProvider == .applePCCGateway) ? 6_000 : 12_000
        let clipped = String(rawOutput.prefix(clippedLimit))
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
        - Keep the same meaning, but ensure it parses as JSON
        - Only use these top-level keys: \(keys)
        \(extraRules)
        \((selectedProvider == .appleCloud || selectedProvider == .applePCCGateway) ? "- Keep the JSON short to avoid truncation; prefer fewer items with shorter strings." : "")

        Model output to fix:
        \(clipped)
        """

        // Use the same provider that generated the original output
        let repaired: String
        
        switch selectedProvider {
        case .mlxLocal:
            let modelID = appState.settings.mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let maxOutputTokens = max(1, appState.settings.mlxMaxOutputTokens)
            repaired = try await LiteRTLocalService.shared.generateText(
                prompt: repairPrompt,
                modelID: modelID,
                maxOutputTokens: maxOutputTokens,
                maxContextTokens: 4096
            )
        case .coreAIMLXLocal:
            let modelID = appState.settings.coreAIMLXModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let maxOutputTokens = max(1, appState.settings.coreAIMLXMaxOutputTokens)
            repaired = try await CoreAIMLXLocalService.shared.generateText(
                prompt: repairPrompt,
                modelID: modelID,
                maxOutputTokens: maxOutputTokens,
                maxContextTokens: appState.settings.coreAIMLXMaxContextTokens > 0 ? appState.settings.coreAIMLXMaxContextTokens : CoreAIMLXLocalService.defaultContextTokens
            )
        case .appleCloud:
            let requiredKeys = keys
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            repaired = try await runAppleCloudStructured(
                prompt: repairPrompt,
                timeoutSeconds: 240,
                requiredTopLevelKeys: requiredKeys
            )
        case .appleLocal:
            if #available(iOS 18.2, macOS 15.2, *), LocalSummaryService.isAvailable() {
                repaired = try await withCheckedThrowingContinuation { continuation in
                    LocalSummaryService.summarizeText(repairPrompt) { result in
                        switch result {
                        case .success(let text):
                            continuation.resume(returning: text)
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } else {
                throw NSError(domain: "AppleLocal", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple Local is not available."])
            }
        case .gemini:
            repaired = try await appState.summaryService.generateContentWithGemini(prompt: repairPrompt)
        case .webAI:
            repaired = try await appState.performWebAIRequestAsync(
                title: kind == .whiteboard ? "Whiteboard JSON Repair" : "Infographic JSON Repair",
                prompt: repairPrompt,
                responseFormat: .strictJSON
            )
        case .applePCCGateway:
            repaired = try await appState.performPCCGatewayRequestAsync(
                prompt: repairPrompt,
                taskName: kind == .whiteboard ? "Whiteboard JSON Repair" : "Infographic JSON Repair"
            )
        case .summarizeDaemon:
            repaired = try await appState.performSummarizeRequestAsync(
                prompt: repairPrompt,
                taskName: kind == .whiteboard ? "Whiteboard JSON Repair" : "Infographic JSON Repair"
            )
        }
        
        guard let data = repaired.data(using: .utf8) else {
            throw NSError(domain: "JSONRepair", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert repaired JSON to data."])
        }
        return data
    }
    
    /// Legacy wrapper for MLX repair - now uses generic repair function
    private func repairInvalidJSONFromMLX(kind: MLXStructuredJSONKind, rawOutput: String) async throws -> Data {
        return try await repairInvalidJSON(kind: kind, rawOutput: rawOutput)
    }

    private func makeWhiteboardPrompt(
        from content: String,
        urlReference: String,
        rankedCandidates: [RankedVisualCandidate],
        providerOverride: AppSettings.SummaryProvider? = nil
    ) -> String {
        let selectedProvider = providerOverride ?? appState.settings.selectedSummaryProvider
        let maxChars = (selectedProvider == .appleCloud || selectedProvider == .applePCCGateway || selectedProvider == .mlxLocal || selectedProvider == .coreAIMLXLocal) ? 8000 : 2000
        let trimmed = String(content.prefix(maxChars))
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

        let appleCloudStrict: String
        if selectedProvider == .appleCloud || selectedProvider == .applePCCGateway {
            appleCloudStrict = """

            APPLE CLOUD STRICT MODE:
            - Include ALL keys exactly as shown (do not omit any key).
            - Do not leave arrays empty; if unsure, add best-effort items grounded in the provided content.
            - Keep output short to avoid truncation: aim for these list sizes:
              whatWeKnow 4-5, openQuestions 2-3, takeaways 3, painPoints 2, hotTakes 2, connections 2, ideasToExplore 2, keyPosts 5.
            - If you're running out of space, shorten strings and reduce list lengths (but keep at least 2 items per list).
            """
        } else {
            appleCloudStrict = ""
        }

        if selectedProvider == .mlxLocal || selectedProvider == .coreAIMLXLocal {
            let contextHint = isRedditContent ? "r/subreddit • topic focus" : "Articles • topic focus"
            let takeawaysTemplate: String
            if isRedditContent {
                takeawaysTemplate = """
                  "takeaways": [
                    { "insight": "...", "source": "Community consensus" },
                    { "insight": "...", "source": "Highly upvoted" },
                    { "insight": "...", "source": "Experienced member" }
                  ],
                """
            } else {
                takeawaysTemplate = """
                  "takeaways": [
                    { "insight": "...", "source": "Expert opinion" },
                    { "insight": "...", "source": "Research finding" },
                    { "insight": "...", "source": "Industry trend" }
                  ],
                """
            }

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
              "sessionContext": "\(contextHint)",
              "whatWeKnow": ["...", "...", "...", "..."],
              "openQuestions": ["...", "...", "..."],
            \(takeawaysTemplate)
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
            ... up to 5 items
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
        \(appleCloudStrict)
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

    private func parseWhiteboardPayload(from text: String) -> WhiteboardPayload? {
        // Use MLXJSONRepairUtils for robust JSON parsing with multiple repair strategies
        guard let data = text.data(using: .utf8) else { return nil }

        do {
            let json = try MLXJSONRepairUtils.parseLLMJSONDictionary(from: data, domain: "Whiteboard")
            return WhiteboardPayload(dictionary: json, isReddit: isRedditContent, rankedCandidates: rankedVisualCandidates(limit: isRedditContent ? 5 : 0))
        } catch {
            print("⚠️ ContentView: Whiteboard JSON parsing failed after all repair attempts: \(error.localizedDescription)")
            return nil
        }
    }

    private func normalizeRedditPermalink(_ permalink: String) -> String {
        let trimmed = permalink.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return "" }

        let lower = trimmed.lowercased()

        // Already absolute URL (any domain). For Reddit, prefer https.
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            if lower.hasPrefix("http://reddit.com") || lower.hasPrefix("http://www.reddit.com") {
                return trimmed.replacingOccurrences(of: "http://", with: "https://")
            }
            return trimmed
        }

        // Reddit domains without scheme
        if lower.hasPrefix("reddit.com") || lower.hasPrefix("www.reddit.com") {
            return "https://\(trimmed)"
        }

        // Relative Reddit paths
        let redditPrefixes = ["r/", "/r/", "u/", "/u/", "comments", "/comments"]
        if redditPrefixes.contains(where: { lower.hasPrefix($0) }) {
            let cleaned = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
            return "https://reddit.com\(cleaned)"
        }

        // Non-Reddit URL without scheme (e.g., article) - return as-is to avoid injecting Reddit domain
        return trimmed
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
            /* ============================================
               MINIMALIST AESTHETIC
               - Typography: SF Pro (geometric) + system-ui (humanist)
               - Colors: 3 hues max + 5-value gray ramp
               - Layout: 12-col grid, 40%+ negative space
               - Zero chartjunk: no shadows, gradients, decorations
               ============================================ */

            :root {
              /* Primary palette: Blue accent */
              --accent: #2563eb;
              --accent-light: #eff6ff;

              /* Secondary: Amber for highlights */
              --highlight: #d97706;

              /* Tertiary: Red for severity */
              --alert: #dc2626;

              /* Neutral gray ramp (5 values) */
              --gray-900: #0A0A0A;
              --gray-700: #404040;
              --gray-500: #6B6B6B;
              --gray-300: #A3A3A3;
              --gray-100: #E5E5E5;

              /* Typography scale (1.618 ratio) */
              --text-xs: 11px;
              --text-sm: 13px;
              --text-base: 14px;
              --text-lg: 18px;
              --text-xl: 23px;
              --text-2xl: 32px;
              --text-3xl: 42px;

              /* Spacing */
              --space-unit: 8px;
              --gutter: 24px;
              --margin: 48px;
            }

            * {
              box-sizing: border-box;
              margin: 0;
              padding: 0;
            }

            body {
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
              background: #FFFFFF;
              color: var(--gray-900);
              line-height: 1.5;
              min-height: 100vh;
              padding: var(--margin);
              -webkit-font-smoothing: antialiased;
            }

            /* Container with max-width for readability */
            .board {
              max-width: 1080px;
              margin: 0 auto;
            }

            /* ============================================
               HEADER
               ============================================ */
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

            /* ============================================
               GRID LAYOUT
               ============================================ */
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

            .section {
              margin-bottom: calc(var(--space-unit) * 5);
            }

            /* ============================================
               SECTION HEADERS
               ============================================ */
            .section-title {
              font-family: system-ui, -apple-system, sans-serif;
              font-size: var(--text-xs);
              font-weight: 600;
              text-transform: uppercase;
              letter-spacing: 0.1em;
              color: var(--gray-500);
              margin-bottom: calc(var(--space-unit) * 2);
            }

            /* ============================================
               LISTS (Facts, Questions, Connections, Ideas)
               ============================================ */
            .item-list {
              list-style: none;
            }

            .item-list li {
              font-size: var(--text-base);
              color: var(--gray-700);
              padding: calc(var(--space-unit) * 1.5) 0;
              border-bottom: 1px solid var(--gray-100);
            }

            .item-list li:last-child {
              border-bottom: none;
            }

            .fact-item::before {
              content: "—";
              color: var(--gray-300);
              margin-right: var(--space-unit);
            }

            .question-item {
              color: var(--accent);
            }

            /* ============================================
               TAKEAWAYS
               ============================================ */
            .takeaway-item {
              padding: calc(var(--space-unit) * 2) 0;
              border-bottom: 1px solid var(--gray-100);
            }

            .takeaway-item:last-child {
              border-bottom: none;
            }

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

            /* ============================================
               PAIN POINTS
               ============================================ */
            .pain-item {
              display: flex;
              align-items: baseline;
              gap: calc(var(--space-unit) * 1.5);
              padding: calc(var(--space-unit) * 1.5) 0;
              border-bottom: 1px solid var(--gray-100);
            }

            .pain-item:last-child {
              border-bottom: none;
            }

            .severity {
              font-size: var(--text-xs);
              font-weight: 600;
              text-transform: uppercase;
              letter-spacing: 0.05em;
              padding: 2px 6px;
              border-radius: 2px;
              flex-shrink: 0;
            }

            .severity-high {
              color: #FFFFFF;
              background: var(--alert);
            }

            .severity-medium {
              color: var(--gray-900);
              background: var(--gray-100);
            }

            .severity-low {
              color: var(--gray-500);
              background: transparent;
              border: 1px solid var(--gray-300);
            }

            .pain-text {
              font-size: var(--text-base);
              color: var(--gray-700);
              margin: 0;
            }

            /* ============================================
               QUOTES
               ============================================ */
            .quote-item {
              padding: calc(var(--space-unit) * 2) 0;
              border-bottom: 1px solid var(--gray-100);
              border-left: 2px solid var(--gray-300);
              padding-left: calc(var(--space-unit) * 2);
              margin: 0;
            }

            .quote-item:last-child {
              border-bottom: none;
            }

            .quote-text {
              font-size: var(--text-base);
              font-style: italic;
              color: var(--gray-700);
              margin: 0;
            }

            .quote-context {
              font-size: var(--text-xs);
              color: var(--gray-500);
              font-style: normal;
              margin-top: calc(var(--space-unit) / 2);
              display: block;
            }

            /* ============================================
               KEY POSTS/ARTICLES
               ============================================ */
            .post-item {
              padding: calc(var(--space-unit) * 2) 0;
              border-bottom: 1px solid var(--gray-100);
            }

            .post-item:last-child {
              border-bottom: none;
            }

            .post-title {
              font-size: var(--text-base);
              font-weight: 500;
              color: var(--gray-900);
              margin: 0;
            }

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

            .post-link:hover {
              text-decoration: underline;
            }

            /* ============================================
               BOTTOM LINE
               ============================================ */
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

            /* ============================================
               EMPTY STATES
               ============================================ */
            .empty-state {
              font-size: var(--text-sm);
              color: var(--gray-300);
              padding: calc(var(--space-unit) * 2) 0;
            }
          </style>
        </head>
        <body>
          <div class="board">
            <!-- Header -->
            <header class="header">
              <h1 class="session-title">\(escapeHTML(payload.sessionTitle))</h1>
              <p class="session-context">\(escapeHTML(payload.sessionContext))</p>
            </header>

            <!-- Facts & Questions -->
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

            <!-- Takeaways -->
            <section class="section">
              <h2 class="section-title">\(takeawaysLabel)</h2>
              \(takeawaysHTML.isEmpty ? "<p class=\"empty-state\">\(emptyTakeawaysMsg)</p>" : "<div>\(takeawaysHTML)</div>")
            </section>

            <!-- Pain Points & Quotes -->
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

            <!-- Connections (if any) -->
            \(!payload.connections.isEmpty ? """
            <section class="section">
              <h2 class="section-title">Connections</h2>
              <ul class="item-list">\(connectionsHTML)</ul>
            </section>
            """ : "")

            <!-- Ideas & Key Posts -->
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

            <!-- Bottom Line -->
            <footer class="bottom-line">
              <p class="bottom-line-label">Bottom Line</p>
              <p class="bottom-line-text">\(escapeHTML(payload.bottomLine))</p>
            </footer>
          </div>
        </body>
        </html>
        """
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

    // MARK: - Ranked Visual Posts

    private func rankedVisualCandidates(limit: Int) -> [RankedVisualCandidate] {
        guard isRedditContent, limit > 0 else { return [] }

        let allCandidates = rankedVisualCandidates()
        return Array(allCandidates.prefix(limit))
    }

    private func rankedVisualCandidates() -> [RankedVisualCandidate] {
        guard isRedditContent else { return [] }

        var postsByID: [String: RedditPost] = [:]
        for post in appState.redditFeeds.flatMap({ $0.posts }) {
            if postsByID[post.id] == nil {
                postsByID[post.id] = post
            }
        }
        for summary in parsedSummaries {
            guard let referenceId = summary.referenceId,
                  postsByID[referenceId] == nil,
                  let post = appState.redditPostForGlobalSummaryReference(referenceId) else {
                continue
            }
            postsByID[referenceId] = post
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

    private func buildInfographicPrompt() -> String {
        let selectedProvider = appState.settings.selectedSummaryProvider
        let summariesForPrompt = (selectedProvider == .appleCloud || selectedProvider == .applePCCGateway)
            ? Array(parsedSummaries.prefix(12).enumerated())
            : Array(parsedSummaries.enumerated())
        let rankedCandidates = rankedVisualCandidates(limit: isRedditContent ? 4 : 0)

        let perItemLimit = (selectedProvider == .appleCloud || selectedProvider == .applePCCGateway) ? 600 : 2000
        let content = summariesForPrompt.map { index, item in
            let title = item.subject.isEmpty ? "Item \(index + 1)" : item.subject
            let truncatedContent = String(item.summary.prefix(perItemLimit))
            return "[\(index + 1)] \"\(title)\"\n\(truncatedContent)\n"
        }.joined(separator: "\n---\n")

        let urlReferenceList: String
        if isRedditContent {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                if let post = appState.redditPostForGlobalSummaryReference(referenceId),
                   let postUrl = post.url {
                    return "[\(index + 1)] \"\(item.subject)\" → \(postUrl.absoluteString)"
                }
                return nil
            }.joined(separator: "\n")
        } else {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                if let article = appState.articleForGlobalSummaryReference(referenceId),
                   let articleUrl = article.url {
                    return "[\(index + 1)] \"\(item.subject)\" → \(articleUrl.absoluteString)"
                }
                return nil
            }.joined(separator: "\n")
        }

        let promptProvider: AppSettings.SummaryProvider = (selectedProvider == .appleLocal || selectedProvider == .appleCloud) ? .mlxLocal : selectedProvider
        return makeInfographicPrompt(
            from: content,
            urlReference: urlReferenceList,
            rankedCandidates: rankedCandidates,
            providerOverride: promptProvider
        )
    }

    private func buildInfographicWebPrompt() -> String {
        let selectedProvider = appState.settings.selectedSummaryProvider
        let summariesForPrompt = (selectedProvider == .appleCloud || selectedProvider == .applePCCGateway)
            ? Array(parsedSummaries.prefix(12).enumerated())
            : Array(parsedSummaries.enumerated())
        let rankedCandidates = rankedVisualCandidates(limit: isRedditContent ? 4 : 0)
        let perItemLimit = (selectedProvider == .appleCloud || selectedProvider == .applePCCGateway) ? 600 : 2000
        let content = summariesForPrompt.map { index, item in
            let title = item.subject.isEmpty ? "Item \(index + 1)" : item.subject
            let truncatedContent = String(item.summary.prefix(perItemLimit))
            return "[\(index + 1)] \"\(title)\"\n\(truncatedContent)\n"
        }.joined(separator: "\n---\n")

        let urlReferenceList: String
        if isRedditContent {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                if let post = appState.redditPostForGlobalSummaryReference(referenceId),
                   let postUrl = post.url {
                    return "[\(index + 1)] \"\(item.subject)\" -> \(postUrl.absoluteString)"
                }
                return nil
            }.joined(separator: "\n")
        } else {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                if let article = appState.articleForGlobalSummaryReference(referenceId),
                   let articleUrl = article.url {
                    return "[\(index + 1)] \"\(item.subject)\" -> \(articleUrl.absoluteString)"
                }
                return nil
            }.joined(separator: "\n")
        }

        let rankingSection = buildRankedPostSection(
            header: "TOP POST RANKING",
            selectionField: "top posts",
            candidates: rankedCandidates,
            limit: 4
        )

        return """
        Create the actual infographic from the source material below.

        IMPORTANT:
        - Do NOT return JSON.
        - Do NOT explain how to make the infographic.
        - Produce the infographic itself.
        - If your interface supports canvas, artifact, or rich HTML/SVG rendering, use it.
        - Otherwise, output a single self-contained SVG infographic.
        - Keep it visually polished, compact, and readable on a laptop screen.

        The infographic should include:
        - A strong title and short subtitle
        - 3-4 key stats
        - A small comparison/bar-chart area
        - Main themes
        - Key topics or notable trends
        - A short takeaway
        - Top posts/articles using the exact URLs from the reference list

        Visual direction:
        - Editorial infographic, not brainstorm notes
        - Strong hierarchy, clear sections, concise labels
        - Emphasize the most important insights rather than dumping all details

        TOP POSTS RULES:
        - Use only the exact URLs from the reference list.
        - Preserve the ranked order when choosing top posts.

        \(rankingSection.isEmpty ? "" : rankingSection + "\n")
        === REFERENCE URLS ===
        \(urlReferenceList)
        === END REFERENCE URLS ===

        === SOURCE MATERIAL ===
        \(content)
        === END SOURCE MATERIAL ===
        """
    }

    private func sendInfographicToWebAI() {
        guard !isGeneratingInfographic else { return }

        isGeneratingInfographic = true
        infographicError = nil
        isInfographicMinimized = false
        generateInfographicWithWebAI(prompt: buildInfographicPrompt())
    }

    private func generateInfographicWithWebAI(prompt: String) {
        let rankedCandidates = rankedVisualCandidates(limit: isRedditContent ? 4 : 0)

        Task {
            do {
                let rawResponse = try await appState.performWebAIRequestAsync(
                    title: "Infographic",
                    prompt: prompt,
                    responseFormat: .strictJSON
                )

                guard let rawData = rawResponse.data(using: .utf8) else {
                    throw NSError(domain: "Infographic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert response to data."])
                }

                let payload: InfographicPayload
                do {
                    payload = try parseInfographicPayloadFromData(rawData)
                } catch {
                    let repairedData = try await repairInvalidJSON(kind: .infographic, rawOutput: rawResponse)
                    let json = try MLXJSONRepairUtils.parseLLMJSONDictionary(from: repairedData, domain: "Infographic")
                    payload = InfographicPayload(dictionary: json, rankedCandidates: rankedCandidates)
                }

                let html = buildInfographicHTML(from: payload)
                let safe = sanitizeInfographicHTML(html)

                guard let htmlData = safe.data(using: .utf8) else {
                    throw NSError(domain: "Infographic", code: 7, userInfo: [NSLocalizedDescriptionKey: "Could not convert infographic to data."])
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

    private func generateInfographic() {
        guard !isGeneratingInfographic else { return }

        isGeneratingInfographic = true
        infographicError = nil

        let selectedProvider = appState.settings.selectedSummaryProvider
        let rankedCandidates = rankedVisualCandidates(limit: isRedditContent ? 4 : 0)
        let prompt = buildInfographicPrompt()

        Task {
            do {
                // For Infographic, use the same provider path as MLX Local when Apple Local/Cloud is selected.
                let effectiveProvider: AppSettings.SummaryProvider =
                    (selectedProvider == .appleLocal || selectedProvider == .appleCloud) ? .mlxLocal : selectedProvider

                // MLX-specific: Clear GPU cache to prevent stale context
                if effectiveProvider == .mlxLocal || effectiveProvider == .coreAIMLXLocal {
                    await MLXLocalService.shared.clearTransientCache()
                    print("🔀 [Infographic] MLX selected - redirecting to Apple Local for JSON generation")
                }

                let rawResponse: String
                switch effectiveProvider {
                case .mlxLocal, .coreAIMLXLocal:
                    // MLX redirects to Apple Local for structured JSON
                    if #available(iOS 18.2, macOS 15.2, *) {
                        rawResponse = try await withCheckedThrowingContinuation { continuation in
                            appState.performLocalWithGeminiFallbackPublic(prompt: prompt, taskName: "Infographic") { result in
                                continuation.resume(returning: result)
                            }
                        }
                    } else {
                        rawResponse = try await appState.summaryService.generateContentWithGemini(prompt: prompt)
                    }
                case .appleLocal:
                    if #available(iOS 18.2, macOS 15.2, *) {
                        rawResponse = try await withCheckedThrowingContinuation { continuation in
                            appState.performLocalWithGeminiFallbackPublic(prompt: prompt, taskName: "Infographic") { result in
                                continuation.resume(returning: result)
                            }
                        }
                    } else {
                        rawResponse = try await appState.summaryService.generateContentWithGemini(prompt: prompt)
                    }
                case .appleCloud:
                    // Apple Cloud via Private Cloud Compute can handle JSON with explicit instructions.
                    rawResponse = try await runAppleCloudStructured(
                        prompt: prompt,
                        timeoutSeconds: 300,
                        requiredTopLevelKeys: ["title", "subtitle", "focus", "palette", "statTiles", "barSections", "sentiment", "sentimentBand", "majorThemes", "themes", "keyTopics", "notableTrends", "takeaway", "topPosts"]
                    )
                case .applePCCGateway:
                    rawResponse = try await appState.performPCCGatewayRequestAsync(
                        prompt: prompt,
                        taskName: "Infographic"
                    )
                case .gemini:
                    rawResponse = try await appState.summaryService.generateContentWithGemini(prompt: prompt)
                case .webAI:
                    rawResponse = try await appState.performWebAIRequestAsync(
                        title: "Infographic",
                        prompt: prompt,
                        responseFormat: .strictJSON
                    )
                case .summarizeDaemon:
                    rawResponse = try await appState.performSummarizeRequestAsync(
                        prompt: prompt,
                        taskName: "Infographic"
                    )
                }

                let responseForParsing = (effectiveProvider == .appleCloud || effectiveProvider == .applePCCGateway)
                    ? sanitizeStructuredJSONCandidate(rawResponse)
                    : rawResponse

                guard let rawData = responseForParsing.data(using: .utf8) else {
                    throw NSError(domain: "Infographic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert response to data."])
                }

                // Try to parse the JSON response
                let payload: InfographicPayload
                do {
                    if effectiveProvider == .appleCloud {
                        let json = try MLXJSONRepairUtils.parseLLMJSONDictionary(from: rawData, domain: "Infographic")
                        guard isAppleCloudInfographicJSONSufficient(json) else {
                            throw AppleCloudIncompleteStructuredOutput(message: "Apple Cloud returned incomplete infographic data.")
                        }
                        payload = InfographicPayload(dictionary: json, rankedCandidates: rankedCandidates)
                    } else {
                        payload = try parseInfographicPayloadFromData(rawData)
                    }
                } catch {
                    // If parsing fails for local/cloud/Summarize providers, attempt JSON repair using the same provider.
                    if effectiveProvider == .mlxLocal || effectiveProvider == .appleCloud || effectiveProvider == .applePCCGateway || effectiveProvider == .summarizeDaemon {
                        print("⚠️ [Infographic] Initial JSON parsing failed for \(effectiveProvider.rawValue) output, attempting repair...")
                        do {
                            let repairedData = try await repairInvalidJSON(kind: .infographic, rawOutput: responseForParsing)
                            if effectiveProvider == .appleCloud {
                                let json = try MLXJSONRepairUtils.parseLLMJSONDictionary(from: repairedData, domain: "Infographic")
                                guard isAppleCloudInfographicJSONSufficient(json) else {
                                    throw AppleCloudIncompleteStructuredOutput(message: "Apple Cloud repair still incomplete.")
                                }
                                payload = InfographicPayload(dictionary: json, rankedCandidates: rankedCandidates)
                            } else {
                                payload = try parseInfographicPayloadFromData(repairedData)
                            }
                        } catch {
                            if effectiveProvider == .appleCloud {
                                let regenerated = try await regenerateAppleCloudStructuredJSON(
                                    kind: .infographic,
                                    originalPrompt: prompt,
                                    previousOutput: rawResponse,
                                    timeoutSeconds: 300
                                )
                                let regeneratedCandidate = sanitizeStructuredJSONCandidate(regenerated)
                                guard let regeneratedData = regeneratedCandidate.data(using: .utf8) else {
                                    throw NSError(domain: "Infographic", code: 8, userInfo: [NSLocalizedDescriptionKey: "Could not convert regenerated infographic to data."])
                                }
                                let json = try MLXJSONRepairUtils.parseLLMJSONDictionary(from: regeneratedData, domain: "Infographic")
                                payload = InfographicPayload(dictionary: json, rankedCandidates: rankedCandidates)
                            } else {
                                throw error
                            }
                        }
                    } else {
                        throw error
                    }
                }

                // Build HTML
                let html = buildInfographicHTML(from: payload)
                let safe = sanitizeInfographicHTML(html)

                guard let htmlData = safe.data(using: .utf8) else {
                    throw NSError(domain: "Infographic", code: 7, userInfo: [NSLocalizedDescriptionKey: "Could not convert infographic to data."])
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

    private func parseInfographicPayloadFromData(_ data: Data) throws -> InfographicPayload {
        let json = try MLXJSONRepairUtils.parseLLMJSONDictionary(from: data, domain: "Infographic")
        return InfographicPayload(dictionary: json, rankedCandidates: rankedVisualCandidates(limit: isRedditContent ? 4 : 0))
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

    private func makeInfographicPrompt(from content: String, urlReference: String) -> String {
        let selectedProvider = appState.settings.selectedSummaryProvider
        let rankedCandidates = rankedVisualCandidates(limit: isRedditContent ? 4 : 0)
        return makeInfographicPrompt(
            from: content,
            urlReference: urlReference,
            rankedCandidates: rankedCandidates,
            providerOverride: selectedProvider
        )
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
            """
        }

        if selectedProvider == .appleCloud || selectedProvider == .applePCCGateway {
            return """
            You are designing an image-like infographic for a \(contentType.lowercased()) batch summary.

            OUTPUT RULES (MUST FOLLOW):
            - Output ONLY one valid JSON object (no markdown, no code fences, no commentary)
            - Include ALL keys exactly as shown in the schema (do not omit any key)
            - Keep output SHORT to avoid truncation: fewer/shorter items are OK, but do not leave arrays empty
            - Use standard double quotes (") for all keys and string values
            - Numbers must be plain integers (no quotes, no %, no decimals)
            - No trailing commas
            - Start with { and end with }

            JSON schema (keep strings short, keep lists small):
            {
              "title": "≤32 chars",
              "subtitle": "≤70 chars",
              "focus": "≤90 chars",
              "palette": { "background": "#0b1021", "primary": "#6df3ff", "accent": "#ff7b72", "muted": "#94a3b8" },
              "statTiles": [
                { "label": "Posts", "value": "string number", "note": "≤20 chars" },
                { "label": "Engagement", "value": "string number", "note": "≤20 chars" },
                { "label": "Velocity", "value": "string number", "note": "≤20 chars" },
                { "label": "Highlights", "value": "string number", "note": "≤20 chars" }
              ],
              "barSections": [
                { "label": "≤16 chars", "value": 0-100, "caption": "≤22 chars" },
                { "label": "≤16 chars", "value": 0-100, "caption": "≤22 chars" },
                { "label": "≤16 chars", "value": 0-100, "caption": "≤22 chars" }
              ],
              "sentiment": { "positive": 0-100, "neutral": 0-100, "negative": 0-100 },
              "sentimentBand": { "up": "≤36 chars", "mid": "≤36 chars", "down": "≤36 chars" },
              "majorThemes": [
                { "title": "≤22 chars", "subtitle": "≤36 chars", "bullets": ["≤30 chars", "≤30 chars", "≤30 chars"] },
                { "title": "≤22 chars", "subtitle": "≤36 chars", "bullets": ["≤30 chars", "≤30 chars", "≤30 chars"] },
                { "title": "≤22 chars", "subtitle": "≤36 chars", "bullets": ["≤30 chars", "≤30 chars", "≤30 chars"] }
              ],
              "themes": ["≤18 chars", "≤18 chars", "≤18 chars", "≤18 chars"],
              "keyTopics": ["≤60 chars", "≤60 chars", "≤60 chars", "≤60 chars", "≤60 chars", "≤60 chars"],
              "notableTrends": ["≤70 chars", "≤70 chars", "≤70 chars", "≤70 chars"],
              "takeaway": "≤110 chars",
              "topPosts": [
                { "title": "≤60 chars", "url": "EXACT_URL_FROM_REFERENCE_LIST" },
                { "title": "≤60 chars", "url": "EXACT_URL_FROM_REFERENCE_LIST" },
                { "title": "≤60 chars", "url": "EXACT_URL_FROM_REFERENCE_LIST" },
                { "title": "≤60 chars", "url": "EXACT_URL_FROM_REFERENCE_LIST" }
              ]
            }

            **CRITICAL FOR topPosts URLs:**
            You MUST use ONLY the exact URLs from the POST REFERENCE LIST below. Do NOT make up URLs.
            Copy the URL exactly as shown after the → arrow. If you can't find a matching post, leave the url field empty "".

            \(rankingSection)

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

        **CRITICAL FOR topPosts URLs:**
        You MUST use ONLY the exact URLs from the POST REFERENCE LIST below. Do NOT make up URLs.
        Copy the URL exactly as shown after the → arrow. If you can't find a matching post, leave the url field empty "".

        \(rankingSection)

        === POST REFERENCE LIST (use these exact URLs) ===
        \(urlReference)
        === END REFERENCE LIST ===

        \(contentType) batch content:
        \(trimmed)
        """
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

// MARK: - Whiteboard Data Structures

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

// MARK: - Infographic Data Structures

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
            self.topPosts = rankedCandidates.map {
                PostItem(
                    title: $0.title,
                    url: $0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.url
                )
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

// MARK: - Minimized Floating Pill

struct MinimizedFloatingPill: View {
    let title: String
    let icon: String
    let color: Color
    let onRestore: () -> Void
    let onClose: () -> Void

    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onRestore) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(color)

                    if isExpanded {
                        Text(title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                    }
                }
                .padding(.horizontal, isExpanded ? 16 : 12)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)

            if isExpanded {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
        .onAppear {
            withAnimation(.spring(response: 0.4).delay(0.3)) {
                isExpanded = true
            }
        }
        .onTapGesture {
            if !isExpanded {
                withAnimation(.spring(response: 0.3)) {
                    isExpanded = true
                }
            }
        }
    }
}

// MARK: - Whiteboard View

struct WhiteboardView: View {
    let htmlData: Data?
    let onDismiss: () -> Void
    var onMinimize: (() -> Void)? = nil

    @EnvironmentObject var appState: AppState
    @State private var isLoading = true
    @State private var webViewRef: WKWebView?
    @State private var isAskingAI = false
    @State private var askAIPrompt = ""
    @State private var askAIResponse = ""
    @State private var showAskAIResponseSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let data = htmlData,
                   let htmlString = String(data: data, encoding: .utf8) {
                    ZStack {
                        WhiteboardWebView(
                            htmlContent: htmlString,
                            webView: $webViewRef,
                            isLoading: $isLoading,
                            onAskAISelection: { selectedText, context in
                                handleAskAISelection(selectedText: selectedText, context: context, useWebAI: false)
                            },
                            onAskAIWebSelection: { selectedText, context in
                                handleAskAISelection(selectedText: selectedText, context: context, useWebAI: true)
                            }
                        )
                        .edgesIgnoringSafeArea(.bottom)

                        if isLoading {
                            ProgressView("Rendering whiteboard...")
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .cornerRadius(12)
                        } else if isAskingAI {
                            ProgressView("Asking AI...")
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .cornerRadius(12)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Unable to load whiteboard")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Whiteboard")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onDismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let onMinimize = onMinimize {
                        Button {
                            onMinimize()
                        } label: {
                            Label("Minimize", systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        copyWhiteboardImage()
                    } label: {
                        Label("Copy Image", systemImage: "square.on.square")
                    }
                    .disabled(htmlData == nil || webViewRef == nil || isLoading)
                }
            }
        }
        .sheet(isPresented: $showAskAIResponseSheet) {
            AskAIResponseSheet(
                question: askAIPrompt,
                answer: askAIResponse,
                onCopy: copyAskAIResponseToClipboard
            )
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
        }
    }

    private func copyWhiteboardImage() {
        guard let webView = webViewRef else { return }

        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true

        webView.takeSnapshot(with: config) { image, error in
            if let image = image {
                #if os(iOS)
                UIPasteboard.general.image = image
                #elseif os(macOS)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                if let tiffData = image.tiffRepresentation {
                    pasteboard.setData(tiffData, forType: .tiff)
                }
                #endif
            }
        }
    }

    private func handleAskAISelection(selectedText: String, context: String, useWebAI: Bool) {
        guard !isAskingAI else { return }
        let prompt = buildAskAISelectionPrompt(selectedText: selectedText, extractedContext: context)
        guard !prompt.isEmpty else { return }

        askAIPrompt = prompt
        askAIResponse = ""
        isAskingAI = true

        appState.askQuestionAboutGlobalSummarySelection(
            selectedText: selectedText,
            extractedContext: context,
            useWebAI: useWebAI
        ) { answer in
            DispatchQueue.main.async {
                self.isAskingAI = false
                self.askAIResponse = formatAskAIResponseForDisplay(answer)
                self.showAskAIResponseSheet = true
            }
        }
    }

    private func copyAskAIResponseToClipboard() {
        guard !askAIResponse.isEmpty else { return }
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
    var onAskAISelection: ((String, String) -> Void)? = nil
    var onAskAIWebSelection: ((String, String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
        let wv = AskAIEnabledWKWebView(frame: .zero, configuration: config)
        wv.onAskAISelection = { action, selectedText, context in
            switch action {
            case .standard:
                onAskAISelection?(selectedText, context)
            case .web:
                onAskAIWebSelection?(selectedText, context)
            }
        }
        wv.navigationDelegate = context.coordinator
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
        if let askAIWebView = uiView as? AskAIEnabledWKWebView {
            askAIWebView.onAskAISelection = { action, selectedText, context in
                switch action {
                case .standard:
                    onAskAISelection?(selectedText, context)
                case .web:
                    onAskAIWebSelection?(selectedText, context)
                }
            }
        }
        guard context.coordinator.lastHTML != htmlContent else { return }
        context.coordinator.lastHTML = htmlContent
        uiView.loadHTMLString(htmlContent, baseURL: nil)
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
    }
}
#elseif os(macOS)
struct WhiteboardWebView: NSViewRepresentable {
    let htmlContent: String
    @Binding var webView: WKWebView?
    @Binding var isLoading: Bool
    var onAskAISelection: ((String, String) -> Void)? = nil
    var onAskAIWebSelection: ((String, String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = false
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator

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
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }

            if let url = navigationAction.request.url,
               navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.cancel)
        }
    }
}
#endif

// MARK: - Domain Icon View
struct DomainIconView: View {
    let domain: String?
    let size: CGFloat
    
    var body: some View {
        Group {
            if let domain = domain {
                // Create a Google favicon URL
                if let googleFaviconURL = URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=64") {
                    KFImage(googleFaviconURL)
                        .placeholder {
                            DomainLetterView(domain: domain, size: size)
                        }
                        .cancelOnDisappear(true)
                        .setProcessor(DownsamplingImageProcessor(size: CGSize(width: size * 2, height: size * 2)))
                        .cacheMemoryOnly()
                        .fade(duration: 0)
                        .resizable()
                        .scaledToFit()
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

private struct FeedRowThumbnailView: View {
    let url: URL
    let width: CGFloat
    let height: CGFloat
    let contentMode: SwiftUI.ContentMode

    var body: some View {
        KFImage(url)
            .placeholder {
                placeholder
            }
            .cancelOnDisappear(true)
            .setProcessor(DownsamplingImageProcessor(size: CGSize(width: width * 2, height: height * 2)))
            .fade(duration: 0)
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .frame(width: width, height: height)
            .clipped()
            .background(AppColors.systemGray5)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Rectangle()
                .fill(AppColors.systemGray5)
            Image(systemName: "photo")
                .foregroundColor(.gray)
        }
        .frame(width: width, height: height)
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
    @Environment(\.colorScheme) private var colorScheme
    let article: Article

    private var cardBackground: Color {
        AppColors.feedListCardFill(for: colorScheme)
    }

    private var cardBorderColor: Color {
        Color.blue
    }
    
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
                if !article.previewText.isEmpty {
                    Text(article.previewText)
                        .font(.system(size: 14))
                        // Use secondary color that adapts to color scheme
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // Image if available
                if let imageURL = article.imageURL {
                    FeedRowThumbnailView(
                        url: imageURL,
                        width: 148,
                        height: 92,
                        contentMode: .fill
                    )
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
                .fill(cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(cardBorderColor, lineWidth: 1.1)
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
            return Self.todayTimeFormatter.string(from: date)
        }
        
        // If within a week, show day name
        let now = Date()
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return Self.weekdayFormatter.string(from: date)
        }
        
        // Otherwise show compact date
        return Self.compactDateFormatter.string(from: date)
    }

    private static let todayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let compactDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

// MARK: - Reddit Post Row
struct RedditPostRow: View {
    let post: RedditPost
    var showsSubredditLabel = true
    @Environment(\.colorScheme) private var colorScheme

    private var cardBackground: Color {
        return AppColors.redditCardFill(for: colorScheme)
    }
    
    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 12)
                .fill(cardBackground)
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
                        
                        if showsSubredditLabel {
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
                    if !post.cleanPreviewText.isEmpty {
                        Text(post.cleanPreviewText)
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
                if let imageURL = post.resolvedImageURL {
                    FeedRowThumbnailView(
                        url: imageURL,
                        width: 100,
                        height: 100,
                        contentMode: .fill
                    )
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
    @Binding var showShareSheet: Bool
    @Binding var shareItems: [Any]
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
    @State private var isAskingSelectionAI = false
    @State private var selectionAskAIPrompt = ""
    @State private var selectionAskAIResponse = ""
    @State private var showSelectionAskAISheet = false
    @State private var articleChromeRestoreWorkItem: DispatchWorkItem?
    @State private var isArticleMetadataChromeHidden: Bool = false
    @State private var isArticleReaderLoading: Bool = true
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

    init(
        isReadingChromeHidden: Binding<Bool> = .constant(false),
        showShareSheet: Binding<Bool> = .constant(false),
        shareItems: Binding<[Any]> = .constant([])
    ) {
        self._isReadingChromeHidden = isReadingChromeHidden
        self._showShareSheet = showShareSheet
        self._shareItems = shareItems
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
        return true
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
        return usesPhoneArticleLayout ? 56 : 190
        #else
        return 72
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
                    isArticleReaderLoading = true
                    resetArticleReadingChrome()
                }
                .onChange(of: articleViewMode) { mode in
                    if mode == .reader {
                        isArticleReaderLoading = true
                    }
                }
                .onDisappear {
                    resetArticleReadingChrome()
                }
        }
    }

    private func articleScene(article: Article, proxy: ScrollViewProxy) -> some View {
        GeometryReader { geometry in
            ZStack {
                articleDetailBackground
                    .ignoresSafeArea()

                articleScrollContent(article: article, viewportHeight: geometry.size.height)
                    .edgesIgnoringSafeArea(.all)
                    #if !os(iOS)
                    .enhancedSwipeBack {
                        appState.navigateBack()
                    }
                    #endif

                VStack {
                    Spacer()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
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
        #if os(iOS)
        .overlay(alignment: .top) {
            if !usesPhoneArticleLayout && !isReadingChromeHidden {
                articleTopChromeOverlay(article: article)
                .transition(.articleChromeContinuity(edge: .top))
            }
        }
        #endif
        .overlay(alignment: .bottomTrailing) {
            if !isReadingChromeHidden {
                scrollToTopOverlay(proxy: proxy)
                    .transition(.articleChromeContinuity(edge: .bottom))
            }
        }
        .askAILoadingOverlay(isAskingSelectionAI)
        .simultaneousGesture(
            TapGesture().onEnded {
                revealArticleReadingChrome()
            }
        )
        .onChange(of: qaState.showQAInterface) { isVisible in
            scrollToArticleQAIfNeeded(isVisible: isVisible, proxy: proxy)
        }
        .sheet(isPresented: $showSelectionAskAISheet) {
            AskAIResponseSheet(
                question: selectionAskAIPrompt,
                answer: selectionAskAIResponse,
                onCopy: { setPlatformClipboardString(selectionAskAIResponse) }
            )
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(32)
            #endif
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

        #if os(iOS)
        guard usesPhoneArticleLayout else { return }
        #endif

        DispatchQueue.main.async {
            withAnimation(.easeInOut) {
                proxy.scrollTo(articleQAAnchor, anchor: UnitPoint(x: 0.5, y: 0.35))
            }
        }
    }

    private func scrollArticleToTop(proxy: ScrollViewProxy) {
        print("⬆️ Article bottom toolbar scroll-to-top tapped")
        #if os(iOS)
        if articleViewMode == .reader {
            articleReaderScrollToTopTrigger += 1

            if usesPhoneArticleLayout {
                resetPhoneActionBarVisibility()
            }

            return
        }

        if usesPhoneArticleLayout {
            resetPhoneActionBarVisibility()
        }
        #endif

        withAnimation(.easeInOut) {
            proxy.scrollTo(articleTopAnchor, anchor: .top)
        }
    }

    private func noteArticleTextScrollActivity() {
        #if os(iOS)
        if !usesPhoneArticleLayout {
            setArticleMetadataChromeHidden(true)
            return
        }
        #endif

        hideArticleReadingChromeTemporarily()
    }

    private func noteArticleReaderScrollActivity(isAtTop: Bool) {
        #if os(iOS)
        if usesPhoneArticleLayout {
            notePhoneActionBarScrollActivity()
        } else {
            setArticleMetadataChromeHidden(!isAtTop)
        }
        #else
        hideArticleReadingChromeTemporarily()
        #endif
    }

    private func setArticleMetadataChromeHidden(_ hidden: Bool) {
        guard isArticleMetadataChromeHidden != hidden else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            isArticleMetadataChromeHidden = hidden
        }
    }

    private func hideArticleReadingChromeTemporarily() {
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
        isArticleMetadataChromeHidden = false
        #if os(iOS)
        resetPhoneActionBarVisibility()
        #endif
    }

    #if os(iOS)
    private func handlePhoneArticleScrollOffsetChange(_ offset: CGFloat) {
        guard usesPhoneArticleLayout else {
            setArticleMetadataChromeHidden(offset < -8)
            return
        }

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

    private var articleTopChromeBackdrop: some View {
        let isScrolled = isArticleMetadataChromeHidden

        return ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(isScrolled ? 0 : 0.28)

            Rectangle()
                .fill(Color.black.opacity(colorScheme == .dark ? (isScrolled ? 0 : 0.035) : (isScrolled ? 0 : 0.015)))

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(colorScheme == .dark ? (isScrolled ? 0 : 0.055) : (isScrolled ? 0 : 0.02)),
                            Color.black.opacity(colorScheme == .dark ? (isScrolled ? 0 : 0.025) : (isScrolled ? 0 : 0.008)),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .frame(height: isScrolled ? 0 : 220)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.78),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func scrollToTopOverlay(proxy: ScrollViewProxy) -> some View {
        #if os(iOS)
        if !usesPhoneArticleLayout {
            Button(action: {
                scrollArticleToTop(proxy: proxy)
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
        isArticleReaderLoading = true
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

    private func articleScrollContent(article: Article, viewportHeight: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: usesPhoneArticleLayout ? 1 : 0)
                    .id(articleTopAnchor)
                    #if os(iOS)
                    .background(phoneArticleScrollOffsetReader)
                    #endif

                Spacer()
                    .frame(height: shouldReserveOuterArticleTopSpace ? (isReadingChromeHidden ? 0 : articleTopSpacerHeight) : 0)

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
                    isLoadingReader: $isArticleReaderLoading,
                    isReadingChromeHidden: isReadingChromeHidden,
                    scrollToTopTrigger: articleReaderScrollToTopTrigger,
                    readerTopContentInset: readerTopContentInset(for: article),
                    readerViewportHeight: articleReaderViewportHeight(for: viewportHeight),
                    onPhoneScrollActivity: { isAtTop in
                        noteArticleReaderScrollActivity(isAtTop: isAtTop)
                    },
                    onArticleTextScroll: noteArticleTextScrollActivity,
                    onArticleTextTap: revealArticleReadingChrome
                )
                .id(article.id)
                .padding(.top, 8)
                .padding(.horizontal, articleContentHorizontalPadding)

                Spacer()
                    .frame(height: 40)

                if !isReadingChromeHidden {
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
            .padding(.bottom, 20)
            #endif
        }
        #if os(iOS)
        .coordinateSpace(name: articleScrollCoordinateSpace)
        .background(ArticleOuterScrollViewResolver().frame(width: 0, height: 0))
        .onPreferenceChange(ArticleDetailScrollOffsetPreferenceKey.self, perform: handlePhoneArticleScrollOffsetChange)
        #endif
    }

    private func articleReaderViewportHeight(for viewportHeight: CGFloat) -> CGFloat {
        #if os(iOS)
        if usesPhoneArticleLayout && !isReadingChromeHidden {
            return max(viewportHeight - 200, 320)
        }
        #endif

        return max(viewportHeight, 320)
    }

    private var shouldReserveOuterArticleTopSpace: Bool {
        #if os(iOS)
        return usesPhoneArticleLayout || articleViewMode != .reader
        #else
        return true
        #endif
    }

    private func readerTopContentInset(for article: Article) -> CGFloat {
        #if os(iOS)
        return usesPhoneArticleLayout || isReadingChromeHidden || isArticleSummaryVisible(for: article)
            ? 0
            : articleTopSpacerHeight
        #else
        return 0
        #endif
    }

    private func isArticleSummaryVisible(for article: Article) -> Bool {
        let hasCompletedSummary = article.summary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let isShowingSummaryProgress = appState.isSummarizingArticle(article) && article.summary == nil

        return hasCompletedSummary || isShowingSummaryProgress || qaState.showQAInterface
    }

    private func articleTopChromeOverlay(article: Article) -> some View {
        ZStack(alignment: .top) {
            articleTopChromeBackdrop

            DetailTopBar(
                showShareSheet: $showShareSheet,
                shareItems: $shareItems,
                articleViewMode: $articleViewMode
            )

            if articleViewMode == .reader,
               !isArticleReaderLoading,
               !isArticleMetadataChromeHidden,
               !isArticleSummaryVisible(for: article) {
                articleMetadataCard(article: article)
                    .padding(.horizontal, articleCardOuterHorizontalPadding + articleHeaderHorizontalPadding)
                    .padding(.top, 94)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isArticleMetadataChromeHidden)
    }

    private func articleHeader(article: Article) -> some View {
        Group {
            if usesPhoneArticleLayout {
                VStack(alignment: .leading, spacing: 18) {
                    if articleViewMode == .reader,
                       !isArticleReaderLoading,
                       !isArticleSummaryVisible(for: article) {
                        articleMetadataCard(article: article)
                    }
                    if articleViewMode == .rss {
                        articleTitlePanel(article: article)
                    }
                }
                .padding(.horizontal, articleHeaderHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 10)
            } else if articleViewMode == .rss {
                articleTitlePanel(article: article)
                    .padding(.horizontal, articleHeaderHorizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
            } else {
                EmptyView()
            }
        }
    }

    private func articleTitlePanel(article: Article) -> some View {
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

    private func articleMetadataCard(article: Article) -> some View {
        Group {
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

                    Spacer(minLength: 18)

                    if shouldShowArticleLanguageChip {
                        articleLanguageChip
                    }
                }
            }
        }
        .padding(.horizontal, usesPhoneArticleLayout ? 16 : 18)
        .padding(.vertical, usesPhoneArticleLayout ? 16 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(articleMetadataPanelBackground(cornerRadius: 22))
    }

    private var articleLanguageChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.caption.weight(.semibold))
            Text("English")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(articleSoftFill, in: Capsule())
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
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
            .frame(width: 1, height: 48)
            .padding(.horizontal, 18)
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

    private func articleMetadataPanelBackground(cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.34)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.018) : Color.white.opacity(0.08))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.30), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.09 : 0.035), radius: 8, x: 0, y: 5)
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
        .padding(.top, articleSummaryToolbarClearance(for: article))
    }

    private func articleSummaryToolbarClearance(for article: Article) -> CGFloat {
        #if os(iOS)
        guard !usesPhoneArticleLayout,
              articleViewMode == .reader,
              isArticleSummaryVisible(for: article) else {
            return 0
        }

        return qaState.showQAInterface ? 104 : 72
        #else
        return 0
        #endif
    }

    @ViewBuilder
    private func summarySection(article: Article) -> some View {
        if appState.isSummarizingArticle(article) && article.summary == nil {
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
                        Text(appState.isWaitingForAppleIntelligence
                             ? appState.appleIntelligenceWaitProgress
                             : "Summarizing article...")
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
        } else if let summary = article.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Summary")
                        .font(.headline)
                    Spacer()
                }
                ArticleGlassySummary(
                    summary: summary,
                    onAskAISelection: handleAskAISelection(selectedText:context:),
                    onAskAIWebSelection: handleAskAIWebSelection(selectedText:context:)
                )
                HStack(spacing: 12) {
                    Button(action: {
                        setPlatformClipboardString(summary)
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
            SelectableText(
                text: qaState.answerText,
                onAskAI: handleAskAISelection(selectedText:context:),
                onAskAIWeb: handleAskAIWebSelection(selectedText:context:),
                textIsPrecleaned: true
            )
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
                setPlatformClipboardString(qaState.answerText)
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
        runSelectionAskAI(selectedText: selectedText, context: context, useWebPath: false)
    }

    private func handleAskAIWebSelection(selectedText: String, context: String) {
        runSelectionAskAI(selectedText: selectedText, context: context, useWebPath: true)
    }

    private func runSelectionAskAI(selectedText: String, context: String, useWebPath: Bool) {
        guard !isAskingSelectionAI else { return }
        let sourceContext = appState.selectedArticle.map { appState.articleSelectionSourceContext(for: $0) }
        let prompt = buildAskAISelectionPrompt(
            selectedText: selectedText,
            extractedContext: context,
            sourceContext: sourceContext?.text ?? "",
            sourceLabel: sourceContext?.label ?? ""
        )
        guard !prompt.isEmpty else { return }

        selectionAskAIPrompt = prompt
        selectionAskAIResponse = ""
        isAskingSelectionAI = true

        let finish: (String) -> Void = { answer in
            DispatchQueue.main.async {
                self.selectionAskAIResponse = formatAskAIResponseForDisplay(answer)
                self.isAskingSelectionAI = false
                self.showSelectionAskAISheet = true
            }
        }

        if useWebPath {
            appState.askWebQuestionAboutSelection(prompt: prompt, completion: finish)
        } else {
            appState.askQuestionAboutSelection(prompt: prompt, completion: finish)
        }
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
            let document: SwiftSoup.Document = try SwiftSoup.parseBodyFragment(html)
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
    @Binding var isLoadingReader: Bool
    let isReadingChromeHidden: Bool
    let scrollToTopTrigger: Int
    let readerTopContentInset: CGFloat
    let readerViewportHeight: CGFloat
    let onPhoneScrollActivity: (Bool) -> Void
    let onArticleTextScroll: () -> Void
    let onArticleTextTap: () -> Void

    enum ViewMode: String, CaseIterable {
        case reader = "Reader"
        case rss = "RSS"
    }

    @State private var contentHeight: CGFloat = 100
    @State private var readerModeAvailable: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    /// Check if we have a valid article URL to load in reader mode
    private var hasArticleURL: Bool {
        guard let url = baseURL else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            articleContentPanel
        }
        .animation(articleChromeContinuityAnimation, value: isReadingChromeHidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: content) { _ in
            isLoadingReader = true
            if viewMode == .rss {
                contentHeight = 100
            }
        }
        .onChange(of: baseURL) { _ in
            isLoadingReader = true
            readerModeAvailable = true
            if viewMode == .rss {
                contentHeight = 100
            }
        }
        .onChange(of: viewMode) { newMode in
            if newMode == .reader {
                isLoadingReader = true
                readerModeAvailable = true
            }
        }
        .onChange(of: readerModeAvailable) { isAvailable in
            if !isAvailable && viewMode == .reader {
                viewMode = .rss
            }
        }
        .onAppear {
            // If no valid URL, default to RSS mode
            if !hasArticleURL {
                viewMode = .rss
            }
        }
    }

    @ViewBuilder
    private var articleContentPanel: some View {
        if viewMode == .reader && hasArticleURL && readerModeAvailable {
            ZStack(alignment: .top) {
                readerLoadingFallback
                    .opacity(isLoadingReader ? 1 : 0)
                    .allowsHitTesting(isLoadingReader)
                    .accessibilityHidden(!isLoadingReader)
                    .zIndex(1)

                ArticleReaderWebView(
                    articleURL: baseURL!,
                    isLoading: $isLoadingReader,
                    readerModeAvailable: $readerModeAvailable,
                    useCompactTitleSizing: prefersCompactTitleSizing,
                    scrollToTopTrigger: scrollToTopTrigger,
                    topContentInset: readerTopContentInset,
                    onScrollActivity: onPhoneScrollActivity
                )
                .frame(maxWidth: .infinity)
                .frame(height: readerViewportHeight)
                .opacity(isLoadingReader ? 0 : 1)
                .allowsHitTesting(!isLoadingReader)
                .accessibilityHidden(isLoadingReader)
                .animation(articleChromeContinuityAnimation, value: isReadingChromeHidden)
                .zIndex(2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: readerViewportHeight)
            .animation(.easeOut(duration: 0.18), value: isLoadingReader)
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

    @ViewBuilder
    private var readerLoadingFallback: some View {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Opening article…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: readerViewportHeight)
            .articleReaderPanel(colorScheme: colorScheme)
        } else {
            HTMLWebView(
                htmlContent: enhanceHTML(content),
                baseURL: baseURL,
                contentHeight: .constant(readerViewportHeight)
            )
            .frame(maxWidth: .infinity)
            .frame(height: readerViewportHeight)
            .articleReaderPanel(colorScheme: colorScheme)
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

        let antiBlockContainers = try document.select("p, div, section, aside, figure, span, strong, b")
        for container in antiBlockContainers {
            let text = (try? container.text().trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            if text.count < 900 && containsArticleAntiBlockMessage(text) {
                try container.remove()
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
            if isLikelyAdLabel(text) || (text.count < 900 && containsArticleAntiBlockMessage(text)) {
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

        if normalized.count < 900 && containsArticleAntiBlockMessage(normalized) {
            return true
        }

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
    let topContentInset: CGFloat
    let onScrollActivity: (Bool) -> Void

    private static func conceal(_ webView: WKWebView) {
        webView.isHidden = false
        webView.alphaValue = 1
    }

    private static func reveal(_ webView: WKWebView) {
        guard webView.alphaValue != 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            webView.animator().alphaValue = 1
        }
    }

    private static func hideForRSSFallback(_ webView: WKWebView) {
        webView.isHidden = true
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
        webView.customUserAgent = articleReaderMobileSafariUserAgent

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
                self.fallbackToRSS(on: webView, reason: "navigation failed")
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("📖 ArticleReaderWebView: Provisional navigation failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.pendingReaderModeRetry?.cancel()
                self.pendingReaderModeRetry = nil
                self.fallbackToRSS(on: webView, reason: "provisional navigation failed")
            }
        }

        private func applyReaderMode(on webView: WKWebView) {
            guard !hasAppliedReaderMode else { return }

            pendingReaderModeRetry?.cancel()
            pendingReaderModeRetry = nil
            readerModeAttempt += 1

            guard is9to5MacArticleURL(parent.articleURL) else {
                evaluateReaderMode(on: webView)
                return
            }

            webView.evaluateJavaScript(articleAntiBlockCleanupJavaScript()) { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.evaluateReaderMode(on: webView)
                }
            }
        }

        private func evaluateReaderMode(on webView: WKWebView) {
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

                fallbackToRSS(on: webView, reason: "readability javascript error")
                return
            }

            if let success = result as? Bool {
                print("📖 ArticleReaderWebView: Readability.js result on attempt \(readerModeAttempt): \(success)")
                if success {
                    hasAppliedReaderMode = true
                    verifyAntiBlockAfterReader(on: webView)
                    return
                }

                if scheduleReaderModeRetry(on: webView) { return }

                fallbackToRSS(on: webView, reason: "readability failed")
                return
            }

            print("📖 ArticleReaderWebView: Unexpected result type on attempt \(readerModeAttempt): \(String(describing: result))")
            if scheduleReaderModeRetry(on: webView) { return }

            fallbackToRSS(on: webView, reason: "unexpected readability result")
        }

        private func verifyAntiBlockAfterReader(on webView: WKWebView) {
            guard is9to5MacArticleURL(parent.articleURL) else {
                finishReaderModeSuccess(on: webView)
                return
            }

            webView.evaluateJavaScript(articleAntiBlockCleanupJavaScript()) { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finishReaderModeSuccess(on: webView)
                }
            }
        }

        private func finishReaderModeSuccess(on webView: WKWebView) {
            hasAppliedReaderMode = true
            parent.isLoading = false
            parent.readerModeAvailable = true
            ArticleReaderWebView.reveal(webView)
        }

        private func fallbackToRSS(on webView: WKWebView, reason: String) {
            print("📖 ArticleReaderWebView: Falling back to RSS content (\(reason))")
            pendingReaderModeRetry?.cancel()
            pendingReaderModeRetry = nil
            hasAppliedReaderMode = true
            parent.isLoading = false
            parent.readerModeAvailable = false
            ArticleReaderWebView.hideForRSSFallback(webView)
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
    let topContentInset: CGFloat
    let onScrollActivity: (Bool) -> Void

    private static func conceal(_ webView: WKWebView) {
        webView.isHidden = false
        webView.alpha = 1
    }

    private static func reveal(_ webView: WKWebView) {
        guard webView.alpha != 1 else { return }
        UIView.animate(withDuration: 0.15) {
            webView.alpha = 1
        }
    }

    private static func hideForRSSFallback(_ webView: WKWebView) {
        webView.isHidden = true
    }

    private static func scrollToTop(_ webView: WKWebView) {
        let topOffset = CGPoint(x: 0, y: -webView.scrollView.adjustedContentInset.top)
        webView.scrollView.setContentOffset(topOffset, animated: true)
    }

    private static func applyTopContentInset(_ inset: CGFloat, to webView: WKWebView, preserveTopPosition: Bool = false) {
        let scrollView = webView.scrollView
        let wasAtTop = abs(scrollView.contentOffset.y + scrollView.adjustedContentInset.top) < 2
        guard abs(scrollView.contentInset.top - inset) > 0.5 else {
            if preserveTopPosition || wasAtTop {
                scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false)
            }
            return
        }

        var contentInset = scrollView.contentInset
        contentInset.top = inset
        scrollView.contentInset = contentInset

        var indicatorInsets = scrollView.scrollIndicatorInsets
        indicatorInsets.top = inset
        scrollView.scrollIndicatorInsets = indicatorInsets

        if preserveTopPosition || wasAtTop {
            scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false)
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.delegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
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
        webView.customUserAgent = articleReaderMobileSafariUserAgent

        print("📖 ArticleReaderWebView: Created WebView for \(articleURL)")
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attachScrollToTopObserver(to: uiView)
        ArticleScrollToTopController.shared.registerReaderWebView(uiView)
        Self.applyTopContentInset(topContentInset, to: uiView)

        if context.coordinator.currentURL != articleURL || context.coordinator.currentUseCompactTitleSizing != useCompactTitleSizing {
            context.coordinator.currentURL = articleURL
            context.coordinator.currentUseCompactTitleSizing = useCompactTitleSizing
            context.coordinator.resetReaderModeState()

            DispatchQueue.main.async {
                self.isLoading = true
            }

            Self.conceal(uiView)
            Self.applyTopContentInset(topContentInset, to: uiView, preserveTopPosition: true)
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
                self.fallbackToRSS(on: webView, reason: "navigation failed")
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("📖 ArticleReaderWebView: Provisional navigation failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.pendingReaderModeRetry?.cancel()
                self.pendingReaderModeRetry = nil
                self.fallbackToRSS(on: webView, reason: "provisional navigation failed")
            }
        }

        private func applyReaderMode(on webView: WKWebView) {
            guard !hasAppliedReaderMode else { return }

            pendingReaderModeRetry?.cancel()
            pendingReaderModeRetry = nil
            readerModeAttempt += 1

            guard is9to5MacArticleURL(parent.articleURL) else {
                evaluateReaderMode(on: webView)
                return
            }

            webView.evaluateJavaScript(articleAntiBlockCleanupJavaScript()) { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.evaluateReaderMode(on: webView)
                }
            }
        }

        private func evaluateReaderMode(on webView: WKWebView) {
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

                fallbackToRSS(on: webView, reason: "readability javascript error")
                return
            }

            if let success = result as? Bool {
                print("📖 ArticleReaderWebView: Readability.js result on attempt \(readerModeAttempt): \(success)")
                if success {
                    hasAppliedReaderMode = true
                    verifyAntiBlockAfterReader(on: webView)
                    return
                }

                if scheduleReaderModeRetry(on: webView) { return }

                fallbackToRSS(on: webView, reason: "readability failed")
                return
            }

            print("📖 ArticleReaderWebView: Unexpected result type on attempt \(readerModeAttempt): \(String(describing: result))")
            if scheduleReaderModeRetry(on: webView) { return }

            fallbackToRSS(on: webView, reason: "unexpected readability result")
        }

        private func verifyAntiBlockAfterReader(on webView: WKWebView) {
            guard is9to5MacArticleURL(parent.articleURL) else {
                finishReaderModeSuccess(on: webView)
                return
            }

            webView.evaluateJavaScript(articleAntiBlockCleanupJavaScript()) { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finishReaderModeSuccess(on: webView)
                }
            }
        }

        private func finishReaderModeSuccess(on webView: WKWebView) {
            hasAppliedReaderMode = true
            parent.isLoading = false
            parent.readerModeAvailable = true
            ArticleReaderWebView.applyTopContentInset(parent.topContentInset, to: webView, preserveTopPosition: true)
            ArticleReaderWebView.reveal(webView)
        }

        private func fallbackToRSS(on webView: WKWebView, reason: String) {
            print("📖 ArticleReaderWebView: Falling back to RSS content (\(reason))")
            pendingReaderModeRetry?.cancel()
            pendingReaderModeRetry = nil
            hasAppliedReaderMode = true
            parent.isLoading = false
            parent.readerModeAvailable = false
            ArticleReaderWebView.hideForRSSFallback(webView)
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
            let normalizedOffset = max(0, scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
            let isAtTop = normalizedOffset < 8
            parent.onScrollActivity(isAtTop)
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
        context.coordinator.parent = self
        guard context.coordinator.currentHTMLContent != htmlContent || context.coordinator.currentBaseURL != baseURL else {
            return
        }
        context.coordinator.currentHTMLContent = htmlContent
        context.coordinator.currentBaseURL = baseURL
        uiView.loadHTMLString(htmlContent, baseURL: baseURL)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLWebView
        var currentHTMLContent: String?
        var currentBaseURL: URL?
        
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
    @Environment(\.colorScheme) var colorScheme
    
    @State private var title = ""
    @State private var url = ""
    @State private var type: SubscriptionType = .rss
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            ZStack {
                // Adaptive gradient background
                LinearGradient(
                    colors: colorScheme == .dark ? [
                        Color.blue.opacity(0.2),
                        Color.cyan.opacity(0.2),
                        Color.mint.opacity(0.2),
                        Color.green.opacity(0.2)
                    ] : [
                        Color.blue.opacity(0.4),
                        Color.cyan.opacity(0.4),
                        Color.mint.opacity(0.4),
                        Color.green.opacity(0.4)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                Form {
                Section(header: Text("Subscription Details")) {
                    TextField("Title", text: $title)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    TextField(type == .rss ? "Feed URL" : "Subreddit Name", text: $url)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
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
                .scrollContentBackground(.hidden) // Hide the default form background
            }
            }
            .navigationTitle("Add Subscription")
            #if os(macOS)
            .frame(minWidth: 400, minHeight: 300)
            .padding()
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
    
    private func addSubscription() {
        if type == .rss && !url.lowercased().starts(with: "http") {
            errorMessage = "Please enter a valid URL starting with http:// or https://"
            return
        }
        let finalUrl = type == .rss ? url : url.replacingOccurrences(of: "r/", with: "")
        appState.addSubscription(title: title, url: finalUrl, type: type)
        presentationMode.wrappedValue.dismiss()
    }
}

enum SummaryCardBorderStyle {
    case article
    case reddit
}

private struct SummaryToolbarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.24))
            .frame(width: 1, height: 24)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
    }
}

private struct SummaryTTSMiniPlayerGlassModifier: ViewModifier {
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.tint(tint).interactive(), in: Capsule(style: .continuous))
        } else {
            fallback(content)
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(tint).interactive(), in: Capsule(style: .continuous))
        } else {
            fallback(content)
        }
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(tint.opacity(0.22), in: Capsule(style: .continuous))
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.30),
                                Color.white.opacity(0.08),
                                Color.black.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
    }
}

struct SummaryTTSMiniPlayer: View {
    let isReddit: Bool
    let playDisabled: Bool
    let stopDisabled: Bool
    let localDisabled: Bool
    let localIsActive: Bool
    let onPlay: () -> Void
    let onStop: () -> Void
    let onLocal: () -> Void
    let playHelp: String
    let localHelp: String
    @Environment(\.colorScheme) private var colorScheme

    private var playColor: Color {
        isReddit
            ? Color(red: 0.96, green: 0.42, blue: 0.12)
            : Color(red: 0.27, green: 0.53, blue: 0.92)
    }

    private var glassTint: Color {
        isReddit
            ? Color(red: 0.35, green: 0.40, blue: 0.49).opacity(0.40)
            : Color(red: 0.28, green: 0.43, blue: 0.61).opacity(0.42)
    }

    private var neutralIconColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.88) : Color.black.opacity(0.72)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(playColor))
            }
            .buttonStyle(.plain)
            .disabled(playDisabled)
            .opacity(playDisabled ? 0.45 : 1)
            .help(playHelp)

            Rectangle()
                .fill(Color.white.opacity(0.20))
                .frame(width: 1, height: 24)
                .padding(.horizontal, 8)

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(stopDisabled ? neutralIconColor.opacity(0.38) : neutralIconColor)
                    .frame(width: 58, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(stopDisabled)
            .help("Stop speech")

            Rectangle()
                .fill(Color.white.opacity(0.20))
                .frame(width: 1, height: 24)
                .padding(.horizontal, 8)

            Button(action: onLocal) {
                Image(systemName: "speaker.wave.2.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(localIsActive ? Color.green : neutralIconColor)
                    .frame(width: 58, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(localDisabled)
            .opacity(localDisabled ? 0.45 : 1)
            .help(localHelp)
        }
        .padding(6)
        .modifier(SummaryTTSMiniPlayerGlassModifier(tint: glassTint))
        .overlay {
            Capsule(style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.34),
                            Color.white.opacity(0.10),
                            Color.black.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Summary audio controls")
    }
}

// Replace the ArticleGlassyBackgroundModifier with this enhanced version
struct ArticleGlassyBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let borderStyle: SummaryCardBorderStyle?

    init(borderStyle: SummaryCardBorderStyle? = nil) {
        self.borderStyle = borderStyle
    }
    
    func body(content: Content) -> some View {
        content
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(backgroundFillColor)
            )
            .overlay(borderOverlay)
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.12 : 0.05), radius: 4, x: 0, y: 2)
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

    private var backgroundFillColor: Color {
        if colorScheme == .dark {
            return Color.black.opacity(0.16)
        }
        return AppColors.systemGray6.opacity(0.96)
    }
}



// Also update the ArticleGlassySummary with enhanced styling and TTS
struct ArticleGlassySummary: View {
    let summary: String
    private let displaySummary: String
    var onAskAISelection: ((String, String) -> Void)? = nil
    var onAskAIWebSelection: ((String, String) -> Void)? = nil
    var summaryReferenceCount: Int = 0
    var onSummaryReferenceTap: ((Int) -> Void)? = nil
    var borderStyle: SummaryCardBorderStyle? = nil
    @EnvironmentObject var appState: AppState

    // TTS state variables
    @State private var isSynthesizingSpeech: Bool = false
    @State private var isSpeakingLocally: Bool = false
    @State private var isPreparingLocalTTS: Bool = false
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
    #endif

    init(
        summary: String,
        displaySummary: String? = nil,
        onAskAISelection: ((String, String) -> Void)? = nil,
        onAskAIWebSelection: ((String, String) -> Void)? = nil,
        summaryReferenceCount: Int = 0,
        onSummaryReferenceTap: ((Int) -> Void)? = nil,
        borderStyle: SummaryCardBorderStyle? = nil
    ) {
        self.summary = summary
        self.displaySummary = displaySummary ?? cleanMarkdownArtifactsForDisplay(summary)
        self.onAskAISelection = onAskAISelection
        self.onAskAIWebSelection = onAskAIWebSelection
        self.summaryReferenceCount = summaryReferenceCount
        self.onSummaryReferenceTap = onSummaryReferenceTap
        self.borderStyle = borderStyle
    }

    var body: some View {
        ArticleGlassySummaryContent(
            summary: summary,
            displaySummary: displaySummary,
            onAskAISelection: onAskAISelection,
            onAskAIWebSelection: onAskAIWebSelection,
            summaryReferenceCount: summaryReferenceCount,
            onSummaryReferenceTap: onSummaryReferenceTap,
            borderStyle: borderStyle,
            isSynthesizingSpeech: isSynthesizingSpeech,
            isSpeakingLocally: isSpeakingLocally,
            isPreparingLocalTTS: isPreparingLocalTTS,
            speechSynthesisError: speechSynthesisError,
            throughputText: throughputText,
            speakSummary: speakSummary,
            stopArticleSummarySpeech: stopArticleSummarySpeech,
            speakSummaryLocally: speakSummaryLocally
        )
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
                    self.isPreparingLocalTTS = false
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
                    self.isPreparingLocalTTS = false
                    self.isSpeakingLocally = false
                }
            }
            #endif
        }
    }

    private var throughputText: String? {
        let provider = appState.settings.selectedSummaryProvider
        guard (provider == .mlxLocal || provider == .coreAIMLXLocal || provider == .appleLocal || provider == .applePCCGateway || provider == .summarizeDaemon), !appState.mlxLastThroughput.isEmpty else {
            return nil
        }
        return appState.mlxLastThroughput
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
        isPreparingLocalTTS = false
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
                        self.isPreparingLocalTTS = false
                        self.nextAudioChunk = nil
                    }
                }
            )
        }
    }
    
    private func stopArticleSummarySpeech() {
        ttsCanceled = true
        #if os(iOS)
        stopAnyKokoroPlaybackNow()
        localTTSTask?.cancel()
        localTTSTask = nil
        KokoroTTSService.shared.cancelPlayback()
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking(at: .immediate)
        #elseif os(macOS)
        audioPlayer?.stop()
        audioPlayer = nil
        localSpeechSynth?.stopSpeaking()
        #endif
        nextAudioChunk = nil
        isSynthesizingSpeech = false
        isSpeakingLocally = false
        isPreparingLocalTTS = false
    }
    
    private func playAudio(data: Data) {
        #if os(iOS)
        ensureBackgroundTTSReady()
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
        // Toggle off if already speaking
        if isSpeakingLocally || isPreparingLocalTTS {
            stopAnyKokoroPlaybackNow()
            localTTSTask?.cancel()
            localTTSTask = nil
            KokoroTTSService.shared.cancelPlayback()
            audioPlayer?.stop()
            audioPlayer = nil
            localSpeechSynth?.stopSpeaking(at: .immediate)
            isSpeakingLocally = false
            isPreparingLocalTTS = false
            return
        }
        
        guard !summary.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }
        
        // Stop any other audio playing
        audioPlayer?.stop()
        localSpeechSynth?.stopSpeaking(at: .immediate)
        
        // Configure audio session for high-quality speech (stays active while locked)
        ensureBackgroundTTSReady()

        let localEngine = appState.summaryService.getLocalTTSEngine()
        if localEngine == .kokoro {
            guard KokoroTTSService.shared.isAvailable else {
                speechSynthesisError = "MLX TTS is not available. Add the MLXAudio package and model access."
                return
            }
            isSpeakingLocally = true
            isPreparingLocalTTS = true
            isSynthesizingSpeech = false
            speechSynthesisError = nil
            let allowCaching = appState.summaryService.isKokoroPrecacheEnabled()
            startKokoroPlayback(
                text: summary,
                voice: appState.summaryService.getKokoroVoice(),
                speed: appState.summaryService.getKokoroSpeed(),
                allowCaching: allowCaching,
                precacheEnabled: allowCaching,
                setAudioPlayer: { [self] player in audioPlayer = player },
                soundDelegate: soundDelegate,
                taskStore: &localTTSTask,
                onCompleted: {
                    self.isPreparingLocalTTS = false
                    self.isSpeakingLocally = false
                    self.localTTSTask = nil
                },
                onError: { message in
                    self.speechSynthesisError = message
                    self.isPreparingLocalTTS = false
                    self.isSpeakingLocally = false
                },
                onPlaybackStarted: {
                    self.isPreparingLocalTTS = false
                },
                stopCurrentPlayback: {
                    self.audioPlayer?.stop()
                    self.audioPlayer = nil
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

            // Start speaking via Shortcuts
            isSpeakingLocally = true
            isPreparingLocalTTS = false
            isSynthesizingSpeech = false

            let success = ShortcutsTTS.shared.speakText(summary) {
                // Completion handler - called when speech ends (estimated)
                DispatchQueue.main.async {
                    self.isSpeakingLocally = false
                }
            }

            if !success {
                isSpeakingLocally = false
                isPreparingLocalTTS = false
                speechSynthesisError = "Failed to start Shortcuts TTS"
            }

            return
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
        isPreparingLocalTTS = false
        isSynthesizingSpeech = false
        if let synth = localSpeechSynth {
            DispatchQueue.main.async { synth.speak(utterance) }
        } else {
            isSpeakingLocally = false
            isPreparingLocalTTS = false
            speechSynthesisError = "Failed to initialize speech synthesizer."
        }
        #elseif os(macOS)
        // Toggle off if already speaking
        if isSpeakingLocally {
            localSpeechSynth?.stopSpeaking()
            isSpeakingLocally = false
            return
        }
        
        guard !summary.isEmpty else {
            speechSynthesisError = "No summary available to read."
            return
        }
        
        // Stop all other audio
        audioPlayer?.stop()
        
        let synth = NSSpeechSynthesizer()
        let override = UserDefaults.standard.string(forKey: "LocalTTS.Mac.SelectedVoiceID") ?? ""
        if !override.isEmpty {
            _ = setMacSpeechVoice(synth, identifier: override)
        } else if let voiceID = preferredMacVoiceIdentifier() {
            _ = setMacSpeechVoice(synth, identifier: voiceID)
        }
        synth.delegate = soundDelegate
        
        isSpeakingLocally = true
        isSynthesizingSpeech = false
        if !synth.startSpeaking(summary) {
            isSpeakingLocally = false
            speechSynthesisError = "Failed to start local speech synthesis."
        } else {
            localSpeechSynth = synth
        }
        #endif
    }
    
}

private struct ArticleGlassySummaryContent: View {
    let summary: String
    let displaySummary: String
    let onAskAISelection: ((String, String) -> Void)?
    let onAskAIWebSelection: ((String, String) -> Void)?
    let summaryReferenceCount: Int
    let onSummaryReferenceTap: ((Int) -> Void)?
    let borderStyle: SummaryCardBorderStyle?
    let isSynthesizingSpeech: Bool
    let isSpeakingLocally: Bool
    let isPreparingLocalTTS: Bool
    let speechSynthesisError: String?
    let throughputText: String?
    let speakSummary: () -> Void
    let stopArticleSummarySpeech: () -> Void
    let speakSummaryLocally: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Spacer()
                SummaryTTSMiniPlayer(
                    isReddit: borderStyle == .reddit,
                    playDisabled: isSynthesizingSpeech || isSpeakingLocally || summary.isEmpty,
                    stopDisabled: !isSynthesizingSpeech && !isSpeakingLocally,
                    localDisabled: isSynthesizingSpeech || summary.isEmpty,
                    localIsActive: isSpeakingLocally || isPreparingLocalTTS,
                    onPlay: speakSummary,
                    onStop: stopArticleSummarySpeech,
                    onLocal: speakSummaryLocally,
                    playHelp: "Read aloud (Cloud)",
                    localHelp: "Read aloud (Local)"
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Group {
                if onAskAISelection != nil || onAskAIWebSelection != nil || onSummaryReferenceTap != nil {
                    SelectableText(
                        text: displaySummary,
                        onAskAI: onAskAISelection,
                        onAskAIWeb: onAskAIWebSelection,
                        summaryReferenceCount: summaryReferenceCount,
                        onSummaryReferenceTap: onSummaryReferenceTap,
                        textIsPrecleaned: true
                    )
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(displaySummary)
                        .font(.body)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)

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
            } else if isPreparingLocalTTS {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 5)
                    Text("Preparing local TTS...")
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

            if let throughputText {
                HStack(spacing: 4) {
                    Image(systemName: "cpu").font(.caption2)
                    Text(throughputText).font(.caption2).monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            }

            if let speechSynthesisError {
                Text(speechSynthesisError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
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

private extension View {
    func sidebarRowChrome(backgroundColor: Color = .clear) -> some View {
        modifier(SidebarRowChromeModifier(backgroundColor: backgroundColor))
    }

    func sidebarSelectionBorder(_ isSelected: Bool) -> some View {
        modifier(SidebarSelectionBorderModifier(isSelected: isSelected))
    }
}

#if os(iOS)
// Native UIScreenEdgePan-based back-swipe recognizer to avoid scrolling conflicts on iPhone
struct EdgeBackSwipeRecognizer: UIViewRepresentable {
    let action: () -> Void
    
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = true
        let edge = UIScreenEdgePanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleEdgePan(_:)))
        edge.edges = .left
        edge.cancelsTouchesInView = false // do not cancel ScrollView touches; allow vertical scrolling to proceed
        v.addGestureRecognizer(edge)
        return v
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }
    
    class Coordinator: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        
        @objc func handleEdgePan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            if recognizer.state == .ended {
                let translation = recognizer.translation(in: recognizer.view)
                if translation.x > 40 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    action()
                }
            }
        }
    }
}
#endif

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

    // Leading-edge back-swipe hot zone to mimic iOS interactive pop
    func edgeSwipeBack(perform action: @escaping () -> Void) -> some View {
        self.overlay(alignment: .leading) {
            Color.black.opacity(0.01) // Make hit-testable over WKWebView/ScrollView
                .frame(width: 20)
                .contentShape(Rectangle())
                .allowsHitTesting(true)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 10)
                        .onEnded { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            if dx > 60 && abs(dx) > abs(dy) * 2 {
                                #if os(iOS)
                                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                                impactFeedback.impactOccurred()
                                #endif
                                withAnimation(.easeOut(duration: 0.3)) {
                                    action()
                                }
                            }
                        }
                )
                .ignoresSafeArea()
        }
    }

    // Full-screen drag recognizer that only triggers if the drag begins near the left edge.
    // This sits at a higher priority than scroll/web content and improves reliability.
    func fullScreenEdgeBackSwipe(perform action: @escaping () -> Void) -> some View {
        self.contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .onEnded { value in
                        let startX = value.startLocation.x
                        let dx = value.translation.width
                        let dy = value.translation.height
                        let horizontalDominant = abs(dx) > abs(dy) * 1.5
                        if startX <= 60 && dx > 50 && horizontalDominant {
                            withAnimation(.easeOut(duration: 0.3)) {
                                action()
                            }
                        }
                    }
            )
    }
}

// Visual effect blur for macOS
 // Native iPhone edge-swipe back (uses UIScreenEdgePanGestureRecognizer)
extension View {
    @ViewBuilder
    func systemEdgeBackSwipe(bottomExclusion: CGFloat = 0, perform action: @escaping () -> Void) -> some View {
        #if os(iOS)
        self.overlay(alignment: .leading) {
            VStack(spacing: 0) {
                EdgeBackSwipeRecognizer(action: action)
                    .frame(width: 72)                    // generous hot zone for reliable swipes in compact layouts
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)

                if bottomExclusion > 0 {
                    Color.clear
                        .frame(width: 72, height: bottomExclusion)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        #else
        self
        #endif
    }
    
    @ViewBuilder
    func phoneStyleBackGestures(
        enabled: Bool,
        bottomExclusion: CGFloat = 0,
        usesSystemEdgeSwipe: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        if enabled {
            if usesSystemEdgeSwipe {
                self
                    .systemEdgeBackSwipe(bottomExclusion: bottomExclusion, perform: action)
                    .enhancedSwipeBack(perform: action)
            } else {
                self
                    .enhancedSwipeBack(perform: action)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

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
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 8)
        } else if #available(iOS 15.0, macOS 12.0, *) {
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
