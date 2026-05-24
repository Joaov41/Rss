import SwiftUI
@preconcurrency import WebKit
import Combine
import Kingfisher
import SwiftSoup // <-- Add SwiftSoup import
#if os(iOS)
import AVFoundation
import UIKit

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
        let readerScript = """
        (function() {
          try {
            if (window.__rssReaderModeActive) {
              window.__rssReaderModeActive = false;
              var url = window.__rssReaderOriginalURL || location.href;
              if (url) { location.href = url; }
              return false;
            }

            if (typeof Readability === 'undefined') { return false; }

            var clone = document.cloneNode(true);
            var article = new Readability(clone).parse();
            if (!article || !article.content) { return false; }

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
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                        withAnimation(.easeOut(duration: 0.14)) {
                            action()
                        }
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

#if os(iOS)
private final class SidebarScrollObserverHostView: UIView {
    var onWindowChange: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}

private struct SidebarScrollOffsetObserver: UIViewRepresentable {
    let appState: AppState
    let isEnabled: Bool

    func makeUIView(context: Context) -> SidebarScrollObserverHostView {
        let view = SidebarScrollObserverHostView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.onWindowChange = { [weak view] in
            guard let view else { return }
            MainActor.assumeIsolated {
                context.coordinator.tryAttachAndRestore(from: view)
            }
        }
        return view
    }

    func updateUIView(_ uiView: SidebarScrollObserverHostView, context: Context) {
        context.coordinator.appState = appState
        context.coordinator.isEnabled = isEnabled
        uiView.onWindowChange = { [weak uiView] in
            guard let uiView else { return }
            MainActor.assumeIsolated {
                context.coordinator.tryAttachAndRestore(from: uiView)
            }
        }
        MainActor.assumeIsolated {
            context.coordinator.tryAttachAndRestore(from: uiView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var scrollView: UIScrollView?
        var observation: NSKeyValueObservation?
        var appState: AppState?
        var isEnabled = false
        var isApplyingRestore = false
        private var didScheduleRetry = false
        private let maxRestoreAttempts = 3

        func tryAttachAndRestore(from view: UIView) {
            guard isEnabled else { return }
            guard view.window != nil else { return }

            if scrollView == nil {
                if let tableView = view.firstSuperview(of: UITableView.self) {
                    attach(to: tableView)
                } else if let scrollView = view.firstSuperview(of: UIScrollView.self) {
                    attach(to: scrollView)
                } else if !didScheduleRetry {
                    didScheduleRetry = true
                    DispatchQueue.main.async { [weak self, weak view] in
                        guard let self, let view else { return }
                        MainActor.assumeIsolated {
                            self.didScheduleRetry = false
                            self.tryAttachAndRestore(from: view)
                        }
                    }
                    return
                }
            }

            applyPendingRestoreIfNeeded()
        }

        private func attach(to scrollView: UIScrollView) {
            guard self.scrollView !== scrollView else { return }

            observation?.invalidate()
            self.scrollView = scrollView

            observation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] scrollView, _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    guard let appState = self.appState, self.isEnabled else { return }
                    guard !self.isApplyingRestore else { return }
                    guard appState.compactSidebarPendingRestoreOffset == nil else { return }
                    appState.updateCompactSidebarScrollOffset(scrollView.contentOffset)
                }
            }
        }

        private func applyPendingRestoreIfNeeded() {
            guard let appState = appState, let scrollView = scrollView else { return }
            guard let pendingOffset = appState.compactSidebarPendingRestoreOffset else { return }

            if scrollView.bounds.height <= 0 || scrollView.contentSize.height <= 0 {
                if !didScheduleRetry {
                    didScheduleRetry = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        MainActor.assumeIsolated {
                            self.didScheduleRetry = false
                            self.applyPendingRestoreIfNeeded()
                        }
                    }
                }
                return
            }

            isApplyingRestore = true
            applyRestorePass(targetOffset: pendingOffset, attempt: 0, scrollView: scrollView, appState: appState)
        }

        private func applyRestorePass(
            targetOffset: CGPoint,
            attempt: Int,
            scrollView: UIScrollView,
            appState: AppState
        ) {
            scrollView.layoutIfNeeded()
            scrollView.setContentOffset(targetOffset, animated: false)

            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                MainActor.assumeIsolated {
                    let offsetDeltaX = abs(scrollView.contentOffset.x - targetOffset.x)
                    let offsetDeltaY = abs(scrollView.contentOffset.y - targetOffset.y)
                    let needsRetry = (offsetDeltaX > 0.5 || offsetDeltaY > 0.5) && attempt < self.maxRestoreAttempts

                    if needsRetry {
                        self.applyRestorePass(
                            targetOffset: targetOffset,
                            attempt: attempt + 1,
                            scrollView: scrollView,
                            appState: appState
                        )
                    } else {
                        self.finishRestore(appState: appState)
                    }
                }
            }
        }

        private func finishRestore(appState: AppState) {
            isApplyingRestore = false
            appState.clearCompactSidebarScrollRestore()
        }
    }
}

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

struct DetailTopBar: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Binding var showShareSheet: Bool
    @Binding var shareItems: [Any]

    var body: some View {
        ZStack {
            // Glass background for navigation bar
            if colorScheme == .dark {
                Color.black
            } else {
                Color.clear
                    .background(.ultraThinMaterial)
                    .glassEffectCompat(in: Rectangle())
            }

            HStack {
                Spacer()

                // Action buttons
                HStack(spacing: 12) {
                    if let article = appState.selectedArticle {
                        Button(action: {
                            appState.requestSummary(for: article)
                        }) {
                            Image(systemName: "text.quote")
                                .font(.subheadline)
                        }
                        .buttonStyle(LiquidGlassButtonStyle())
                    } else if let post = appState.selectedRedditPost {
                        Button(action: {
                            appState.requestSummary(for: nil, redditPost: post)
                        }) {
                            Image(systemName: "text.quote")
                                .font(.subheadline)
                        }
                        .buttonStyle(LiquidGlassButtonStyle())
                    }

                    if let article = appState.selectedArticle {
                        Button(action: {
                            appState.toggleArticleFavorite(article)
                        }) {
                            Image(systemName: article.isFavorite ? "star.fill" : "star")
                                .font(.subheadline)
                                .foregroundColor(article.isFavorite ? .yellow : .primary)
                        }
                        .buttonStyle(LiquidGlassButtonStyle())
                    } else if let post = appState.selectedRedditPost {
                        Button(action: {
                            appState.toggleRedditPostFavorite(post)
                        }) {
                            Image(systemName: post.isFavorite ? "star.fill" : "star")
                                .font(.subheadline)
                                .foregroundColor(post.isFavorite ? .yellow : .primary)
                        }
                        .buttonStyle(LiquidGlassButtonStyle())
                    }

                    if appState.selectedArticle != nil {
                        Button(action: {
                            ArticleQAState.shared.toggleQAInterface()
                        }) {
                            Image(systemName: "questionmark.circle")
                                .font(.subheadline)
                        }
                        .buttonStyle(LiquidGlassButtonStyle())
                    }

                    if let article = appState.selectedArticle {
                        Button(action: {
                            if let url = article.url {
                                shareItems = [url]
                            } else {
                                shareItems = [article.title]
                            }
                            showShareSheet = true
                        }) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.subheadline)
                        }
                        .buttonStyle(LiquidGlassButtonStyle())
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
                            Image(systemName: "square.and.arrow.up")
                                .font(.subheadline)
                        }
                        .buttonStyle(LiquidGlassButtonStyle())
                    }

                    ActivityViewPresenter(isPresented: $showShareSheet, items: shareItems)
                        .frame(width: 0, height: 0)
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 60)
        .zIndex(2000)
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
    @State private var currentlyVisibleSubscription: String?
    @State private var showRedditSummaryScopePicker = false
    @State private var redditSummaryScopeSubreddit: String?
    @State private var isRestoringScrollPosition = false
    #if os(iOS)
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var isBackSwipeInProgress = false
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

    private func restoreSidebarPosition(using scrollProxy: ScrollViewProxy) {
        guard let savedPosition = appState.getSavedScrollPosition(for: "sidebar_subscriptions") else {
            return
        }

        let target: UUID?
        if let savedUUID = UUID(uuidString: savedPosition) {
            target = savedUUID
        } else {
            target = appState.subscriptions.first(where: { $0.url == savedPosition })?.id
        }

        guard let target else {
            return
        }

        isRestoringScrollPosition = true
        DispatchQueue.main.async {
            #if os(iOS)
            if isPhoneStyleLayout {
                scrollProxy.scrollTo(target, anchor: .center)
                DispatchQueue.main.async {
                    isRestoringScrollPosition = false
                }
            } else {
                scrollProxy.scrollTo(target, anchor: .center)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    scrollProxy.scrollTo(target, anchor: .center)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    scrollProxy.scrollTo(target, anchor: .center)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isRestoringScrollPosition = false
                }
            }
            #else
            scrollProxy.scrollTo(target, anchor: .center)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                scrollProxy.scrollTo(target, anchor: .center)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                scrollProxy.scrollTo(target, anchor: .center)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isRestoringScrollPosition = false
            }
            #endif
        }
    }

    private var usesCompactSidebarOffsetRestore: Bool {
        return false
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
                            if UIDevice.current.userInterfaceIdiom == .pad {
                                DetailTopBar(showShareSheet: $showShareSheet, shareItems: $shareItems)
                            }
                        }
                        .phoneStyleBackGestures(enabled: shouldUsePhoneLayout) {
                            appState.navigateBack()
                        }
                } else if let article = appState.selectedArticle {
                    ArticleDetailView()
                        .transition(.move(edge: .trailing))
                        .zIndex(1)
                        .navigationBarHidden(true)
                        .overlay(alignment: .top) {
                            if UIDevice.current.userInterfaceIdiom == .pad {
                                DetailTopBar(showShareSheet: $showShareSheet, shareItems: $shareItems)
                            }
                        }
                        .phoneStyleBackGestures(enabled: shouldUsePhoneLayout) {
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
                    } else if let article = appState.selectedArticle {
                        ArticleDetailView()
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
                    (appState.selectedRedditPost != nil || appState.selectedArticle != nil) {
                    DetailTopBar(showShareSheet: $showShareSheet, shareItems: $shareItems)
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
    
    // MARK: - Sidebar
    var sidebar: some View {
        ScrollViewReader { scrollProxy in
            List {
                Section(header: 
                    Text("Feeds")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.none)
                        .padding(.leading, 8)
                ) {
                NavigationLink(destination: redditView) {
                    HStack {
                        Image("RedditLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .foregroundColor(.orange)
                        Text(FeedCategory.reddit.rawValue)
                        Spacer()

                        let unreadRedditCount = appState.redditFeeds
                            .flatMap { $0.posts }
                            .filter { !$0.isRead }
                            .count

                        if unreadRedditCount > 0 {
                            Text("\(unreadRedditCount)")
                                .font(.caption)
                                .foregroundColor(.blue.opacity(0.7))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                        }
                    }
                }
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
                    HStack {
                        Image(systemName: FeedCategory.all.systemImageName)
                        Text(FeedCategory.all.rawValue)
                        Spacer()

                        let unreadArticlesCount = appState.feeds
                            .flatMap { $0.articles }
                            .filter { !$0.isRead }
                            .count

                        if unreadArticlesCount > 0 {
                            Text("\(unreadArticlesCount)")
                                .font(.caption)
                                .foregroundColor(.blue.opacity(0.7))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                        }
                    }
                }
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
                    Label(FeedCategory.unread.rawValue, systemImage: FeedCategory.unread.systemImageName)
                }
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
                    Label(FeedCategory.favorites.rawValue, systemImage: FeedCategory.favorites.systemImageName)
                }
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
                    HStack {
                        Image(systemName: FeedCategory.today.systemImageName)
                            .font(.system(size: 18))
                        Text(FeedCategory.today.rawValue)
                            .font(.callout)
                            .fontWeight(.medium)
                        Spacer()

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

                        if totalTodayUnseen > 0 {
                            Text("\(totalTodayUnseen)")
                                .font(.caption)
                                .foregroundColor(.blue.opacity(0.7))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
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
                
                Button(action: { showSettings = true }) {
                    HStack {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18))
                        Text("Settings")
                            .font(.callout)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        if !isPhoneStyleLayout {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.regularMaterial)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sidebarRowChrome(backgroundColor: isPhoneStyleLayout ? iPadShellBackground : .clear)
            }
            
            Section(header: 
                Text("Subscriptions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.none)
                    .padding(.leading, 8)
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
                        .id(subscription.id)
                        .onAppear {
                            guard !isRestoringScrollPosition else { return }

                            currentlyVisibleSubscription = subscription.id.uuidString

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
                            appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.id.uuidString)
                        }) {
                            subscriptionSidebarRow(for: subscription, unreadCount: unreadCount)
                                .background(iPadShellBackground)
                        }
                        .buttonStyle(.plain)
                        .id(subscription.id)
                        .onAppear {
                            // Don't save position if we're in the middle of restoring scroll
                            guard !isRestoringScrollPosition else { return }

                            // Remember subscription selection when it appears as selected
                            if appState.activeSubscriptionURL == subscription.url {
                                appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.id.uuidString)
                            }
                        }
                        .onChange(of: appState.activeSubscriptionURL) { newValue in
                            if newValue == subscription.url {
                                appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.id.uuidString)
                            }
                        }
                    } else {
                    NavigationLink(tag: subscription.url, selection: $appState.activeSubscriptionURL, destination: { subscriptionView(for: subscription) }) {
                        subscriptionSidebarRow(for: subscription, unreadCount: unreadCount)
                            .background(iPadShellBackground)
                    }
                    .id(subscription.id)
                    .onAppear {
                        // Don't save position if we're in the middle of restoring scroll
                        guard !isRestoringScrollPosition else { return }

                        // Remember subscription selection when it appears as selected
                        if appState.activeSubscriptionURL == subscription.url {
                            appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.id.uuidString)
                        }
                    }
                    .onChange(of: appState.activeSubscriptionURL) { newValue in
                        if newValue == subscription.url {
                            appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.id.uuidString)
                        }
                    }
                    }
                    #else
                    NavigationLink(tag: subscription.url, selection: $appState.activeSubscriptionURL, destination: { subscriptionView(for: subscription) }) {
                        subscriptionSidebarRow(for: subscription, unreadCount: unreadCount)
                            .background(iPadShellBackground)
                    }
                    .id(subscription.id)
                    .onAppear {
                        // Don't save position if we're in the middle of restoring scroll
                        guard !isRestoringScrollPosition else { return }

                        // Remember subscription selection when it appears as selected
                        if appState.activeSubscriptionURL == subscription.url {
                            appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.id.uuidString)
                        }
                    }
                    .onChange(of: appState.activeSubscriptionURL) { newValue in
                        if newValue == subscription.url {
                            appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.id.uuidString)
                        }
                    }
                    #endif
                }
                .onDelete { indexSet in
                    appState.removeSubscription(at: indexSet)
                }
                
                Button(action: { showAddSubscription = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                        Text("Add Subscription")
                            .font(.callout)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        if !isPhoneStyleLayout {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.regularMaterial)
                        }
                    }
                }
                .buttonStyle(.plain)
                .sidebarRowChrome(backgroundColor: isPhoneStyleLayout ? iPadShellBackground : .clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(minWidth: 200)
        .background(iPadShellBackground)
        .ignoresSafeArea()
        .background(
            Group {
                #if os(iOS)
                SidebarScrollOffsetObserver(appState: appState, isEnabled: usesCompactSidebarOffsetRestore)
                    .frame(width: 0, height: 0)
                #else
                EmptyView()
                #endif
            }
        )
        .onAppear {
            // Sync Reddit read states from persistence to ensure badge counts are accurate
            appState.syncRedditReadStatesFromPersistence()

            // Restore scroll position for subscriptions when sidebar appears
            if !usesCompactSidebarOffsetRestore {
                restoreSidebarPosition(using: scrollProxy)
            }
        }
        .onChange(of: appState.selectedArticleId) { newValue in
            // Restore scroll position when coming back from an article
            guard newValue == nil else { return }
            if !usesCompactSidebarOffsetRestore {
                restoreSidebarPosition(using: scrollProxy)
            }
        }
        .onChange(of: appState.selectedRedditPostId) { newValue in
            // Restore scroll position when coming back from a Reddit post
            guard newValue == nil else { return }
            if !usesCompactSidebarOffsetRestore {
                restoreSidebarPosition(using: scrollProxy)
            }
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
        let selectionColor: Color = subscription.type == .reddit ? .orange : .blue

        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(isSelected ? selectionColor : Color.clear)
                .frame(width: 3, height: 22)

            if subscription.type == .rss {
                if let url = URL(string: subscription.url), let host = url.host {
                    DomainIconView(domain: host, size: 16)
                } else {
                    Image(systemName: "rss")
                }
            } else {
                Image("RedditLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundColor(.orange)
            }

            Text(subscription.title)
                .foregroundColor(.primary)

            Spacer()

            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.caption)
                    .foregroundColor(.blue.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
            }
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
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .id(articleListID(for: article)) // Set ID for scroll position tracking
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(iPadShellBackground)
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
                if let savedPosition = appState.getSavedScrollPosition(for: "all_category") {
                    scrollProxy.scrollTo(savedPosition, anchor: .center)
                }
            }
            .navigationTitle("All Articles")
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
            .scrollContentBackground(.hidden)
            .background(iPadShellBackground)
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
                if let savedPosition = appState.getSavedScrollPosition(for: "unread_category") {
                    scrollProxy.scrollTo(savedPosition, anchor: .center)
                }
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
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
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
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
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
        ScrollViewReader { scrollProxy in
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
            .scrollContentBackground(.hidden)
            .background(iPadShellBackground)
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

                // Restore scroll position when view appears
                if let savedPosition = appState.getSavedScrollPosition(for: "today_category") {
                    withAnimation {
                        scrollProxy.scrollTo(savedPosition, anchor: .center)
                    }
                }
            }
            .onChange(of: appState.selectedArticleId) { newValue in
                guard newValue == nil else { return }
                if let savedPosition = appState.getSavedScrollPosition(for: "today_category") {
                    withAnimation {
                        scrollProxy.scrollTo(savedPosition, anchor: .center)
                    }
                }
            }
            .onChange(of: appState.selectedRedditPostId) { newValue in
                guard newValue == nil else { return }
                if let savedPosition = appState.getSavedScrollPosition(for: "today_category") {
                    withAnimation {
                        scrollProxy.scrollTo(savedPosition, anchor: .center)
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

    @ViewBuilder
    private func redditSummaryScopePickerOverlay(feed: RedditFeed, subscription: Subscription) -> some View {
        ZStack {
            Color.black
                .opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissRedditSummaryScopePicker()
                }

            VStack(spacing: 12) {
                let unreadCount = feed.posts.filter { !$0.isRead }.count
                Text("New: \(unreadCount) unread • Hot: \(feed.posts.count) posts")
                    .font(.caption)
                    .foregroundColor(.secondary)

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

                Button("Cancel") {
                    dismissRedditSummaryScopePicker()
                }
                .buttonStyle(LiquidGlassButtonStyle(isTranslucent: true))
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
    }
    
    var redditView: some View {
        VStack {
            Picker("Sort", selection: $appState.redditSortOption) {
                Text("Hot").tag(RedditService.SortOption.hot)
                Text("New").tag(RedditService.SortOption.new)
            }
            .pickerStyle(SegmentedPickerStyle())
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
            
            ScrollViewReader { scrollProxy in
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
                .scrollContentBackground(.hidden)
                .background(AppColors.redditBackground(for: colorScheme))
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
                    if let savedPosition = appState.getSavedScrollPosition(for: "reddit_category") {
                        scrollProxy.scrollTo(savedPosition, anchor: .center)
                    }
                }
            }
        }
        .background(AppColors.redditBackground(for: colorScheme))
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
        .scrollContentBackground(.hidden)
        .background(iPadShellBackground)
        .navigationTitle(feed.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isPhoneStyleLayout)
        .padding(.top, isPhoneStyleLayout ? 0 : 0)
        #endif
        .onAppear {
            appState.activeSubscriptionURL = subscription.url
            appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.url)
            if let savedPosition = appState.getSavedScrollPosition(for: subscription.url) {
                scrollProxy.scrollTo(savedPosition, anchor: .center)
            }
            if sortedArticles.isEmpty {
                appState.refreshSingleRSSFeed(url: subscription.url)
            }
        }
        .onChange(of: appState.selectedArticleId) { newValue in
            guard newValue == nil else { return }
            if let savedPosition = appState.getSavedScrollPosition(for: subscription.url) {
                scrollProxy.scrollTo(savedPosition, anchor: .center)
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
            VStack(spacing: 0) {
                Picker("Sort", selection: $appState.redditSortOption) {
                    Text("Hot").tag(RedditService.SortOption.hot)
                    Text("New").tag(RedditService.SortOption.new)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
                .padding(.bottom, 8)
                .onChange(of: appState.redditSortOption) { newOption in
                    print("📱 ContentView: Reddit sort option changed to \(newOption.rawValue) for r/\(subscription.url)")
                    appState.isLoading = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        appState.refreshRedditFeeds(specificSubreddit: subscription.url)
                    }
                }

                if let statusMessage = appState.redditFeedStatusMessages[subscription.url] {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                List {
                    ForEach(feed.posts) { post in
                        Button(action: {
                            #if os(iOS)
                            if isPhoneStyleLayout && isBackSwipeInProgress {
                                return
                            }
                            #endif
                            appState.rememberCurrentSubscription(url: subscription.url)
                            appState.saveScrollPosition(for: subscription.url, itemID: post.id)
                            appState.selectedRedditPost = post
                            appState.lastSelectedCategory = .reddit
                            if !post.isRead {
                                appState.markRedditPostAsRead(post)
                            }
                        }) {
                            RedditPostRow(post: post)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .id(redditPostListID(for: post))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(AppColors.redditBackground(for: colorScheme))
                .onAppear {
                    appState.activeSubscriptionURL = subscription.url
                    appState.saveScrollPosition(for: "sidebar_subscriptions", itemID: subscription.url)
                    if let savedPosition = appState.getSavedScrollPosition(for: subscription.url) {
                        withAnimation {
                            scrollProxy.scrollTo(savedPosition, anchor: .center)
                        }
                    }
                    if feed.posts.isEmpty {
                        appState.refreshRedditFeeds(specificSubreddit: subscription.url)
                    }
                }
                .onChange(of: appState.selectedRedditPostId) { newValue in
                    guard newValue == nil else { return }
                    if let savedPosition = appState.getSavedScrollPosition(for: subscription.url) {
                        withAnimation {
                            scrollProxy.scrollTo(savedPosition, anchor: .center)
                        }
                    }
                }
        #if os(iOS)
        .anywhereSwipeBack(enabled: isPhoneStyleLayout, isTracking: $isBackSwipeInProgress) {
            if isPhoneStyleLayout && appState.activeSubscriptionURL == subscription.url {
                appState.exitActiveSubscriptionView()
            }
        }
        #endif
            }
            .background(AppColors.redditBackground(for: colorScheme).ignoresSafeArea())
            .navigationTitle("r/\(feed.subreddit)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isPhoneStyleLayout)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        redditSummaryScopeSubreddit = subscription.url
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            showRedditSummaryScopePicker = true
                        }
                    } label: {
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

                    let postScrollTarget = feed.posts.first?.id
                    Button(action: {
                        if let target = postScrollTarget {
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
                    .disabled(postScrollTarget == nil)

                    let hasUnreadPosts = feed.posts.contains { !$0.isRead }
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
                    .disabled(!hasUnreadPosts)
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
                ArticleDetailView()
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
    @State private var isRedditContent: Bool = false

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

    private func summaryDisplayCacheKey(for item: GlobalSummaryItem, index: Int) -> String {
        summaryStableID(for: item, index: index)
    }

    private func summaryStableID(for item: GlobalSummaryItem, index: Int) -> String {
        let reference = item.referenceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subject = item.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reference.isEmpty {
            return "\(index)-ref-\(reference)"
        }
        if !subject.isEmpty {
            return "\(index)-subject-\(subject)"
        }
        return "\(index)-summary-\(item.summary.prefix(80))"
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
        for (index, item) in result.summaries.enumerated() {
            let cacheKey = summaryDisplayCacheKey(for: item, index: index)
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
            rebuildParsedSummaryCache(from: newValue)
            rebuildAggregateSummaryCache()
        }
        .onChange(of: appState.aggregateSummaryText) { _ in
            rebuildAggregateSummaryCache()
        }
    }

    private func summaryCard(formattedAggregateSummary: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title bar with drag handle and controls
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
                    appState.showGlobalSummary = false
                    appState.hasCachedSummary = false
                    appState.globalSummaryJSON = ""
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

            if showQAInterface {
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
                                    onAskAISelection: handleSummaryAskAISelection(selectedText:context:),
                                    onAskAIWebSelection: handleSummaryAskAIWebSelection(selectedText:context:),
                                    borderStyle: isRedditContent ? .reddit : .article
                                )
                                    .environmentObject(appState)
                            }
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
                            let cacheKey = summaryDisplayCacheKey(for: item, index: index)
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
                                    onAskAISelection: handleSummaryAskAISelection(selectedText:context:),
                                    onAskAIWebSelection: handleSummaryAskAIWebSelection(selectedText:context:),
                                    borderStyle: isRedditContent ? .reddit : .article
                                )
                                    .environmentObject(appState)
                            }
                            .padding(.bottom, 4)
                        }
                    }
                }
                .padding()
            }
            .frame(maxHeight: .infinity)
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.ultraThinMaterial)

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
                        ArticleGlassySummary(summary: qaAnswerText)
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
                    }
                }
            }
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
        qaInlineError = nil
        isProcessingQA = true
        qaAnswerText = ""
        
        appState.askQuestionAboutGlobalSummary(question: trimmed) { answer in
            DispatchQueue.main.async {
                self.qaAnswerText = cleanMarkdownArtifactsForDisplay(answer)
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
                self.qaAnswerText = cleanMarkdownArtifactsForDisplay(answer)
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

    private func handleSummaryAskAISelection(selectedText: String, context: String) {
        guard !isAskingSelectionAI else { return }
        let prompt = buildAskAISelectionPrompt(selectedText: selectedText, extractedContext: context)
        guard !prompt.isEmpty else { return }

        selectionAskAIPrompt = prompt
        selectionAskAIResponse = ""
        isAskingSelectionAI = true

        appState.askQuestionAboutSelection(prompt: prompt) { answer in
            DispatchQueue.main.async {
                self.selectionAskAIResponse = cleanMarkdownArtifactsForDisplay(answer)
                self.isAskingSelectionAI = false
                self.showSelectionAskAISheet = true
            }
        }
    }

    private func handleSummaryAskAIWebSelection(selectedText: String, context: String) {
        guard !isAskingSelectionAI else { return }
        let prompt = buildAskAISelectionPrompt(selectedText: selectedText, extractedContext: context)
        guard !prompt.isEmpty else { return }

        selectionAskAIPrompt = prompt
        selectionAskAIResponse = ""
        isAskingSelectionAI = true

        appState.askWebQuestionAboutSelection(prompt: prompt) { answer in
            DispatchQueue.main.async {
                self.selectionAskAIResponse = cleanMarkdownArtifactsForDisplay(answer)
                self.isAskingSelectionAI = false
                self.showSelectionAskAISheet = true
            }
        }
    }

    // MARK: - Whiteboard Generation

    private func buildWhiteboardPrompt() -> String {
        let selectedProvider = appState.settings.selectedSummaryProvider
        let summariesForPrompt = (selectedProvider == .appleCloud)
            ? Array(parsedSummaries.prefix(12).enumerated())
            : Array(parsedSummaries.enumerated())
        let rankedCandidates = rankedVisualCandidates(limit: isRedditContent ? 5 : 0)

        let perItemLimit = selectedProvider == .appleCloud ? 600 : 2000
        let content = summariesForPrompt.map { index, item in
            let title = item.subject.isEmpty ? "Item \(index + 1)" : item.subject
            let truncatedContent = String(item.summary.prefix(perItemLimit))
            return "[\(index + 1)] \"\(title)\"\n\(truncatedContent)\n"
        }.joined(separator: "\n---\n")

        let urlReferenceList: String
        if isRedditContent {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                for feed in appState.redditFeeds {
                    if let post = feed.posts.first(where: { $0.id == referenceId }),
                       let postUrl = post.url {
                        let arrow = selectedProvider == .appleCloud ? "→" : "->"
                        return "[\(index + 1)] \"\(item.subject)\" \(arrow) \(postUrl.absoluteString)"
                    }
                }
                return nil
            }.joined(separator: "\n")
        } else {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                for feed in appState.feeds {
                    if let article = feed.articles.first(where: { $0.id == referenceId }),
                       let articleUrl = article.url {
                        let arrow = selectedProvider == .appleCloud ? "→" : "->"
                        return "[\(index + 1)] \"\(item.subject)\" \(arrow) \(articleUrl.absoluteString)"
                    }
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
        let summariesForPrompt = (selectedProvider == .appleCloud)
            ? Array(parsedSummaries.prefix(12).enumerated())
            : Array(parsedSummaries.enumerated())
        let rankedCandidates = rankedVisualCandidates(limit: isRedditContent ? 5 : 0)
        let perItemLimit = selectedProvider == .appleCloud ? 600 : 2000
        let content = summariesForPrompt.map { index, item in
            let title = item.subject.isEmpty ? "Item \(index + 1)" : item.subject
            let truncatedContent = String(item.summary.prefix(perItemLimit))
            return "[\(index + 1)] \"\(title)\"\n\(truncatedContent)\n"
        }.joined(separator: "\n---\n")

        let urlReferenceList: String
        if isRedditContent {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                for feed in appState.redditFeeds {
                    if let post = feed.posts.first(where: { $0.id == referenceId }),
                       let postUrl = post.url {
                        return "[\(index + 1)] \"\(item.subject)\" -> \(postUrl.absoluteString)"
                    }
                }
                return nil
            }.joined(separator: "\n")
        } else {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                for feed in appState.feeds {
                    if let article = feed.articles.first(where: { $0.id == referenceId }),
                       let articleUrl = article.url {
                        return "[\(index + 1)] \"\(item.subject)\" -> \(articleUrl.absoluteString)"
                    }
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
        case .mlxLocal:
            // MLX Local redirects to Apple Local for structured JSON (MLX struggles with strict JSON)
            generateWhiteboardWithMLXLocal(prompt: prompt)

        case .appleLocal:
            // For Whiteboard, use the same path as MLX Local (keeps regular summaries unchanged).
            generateWhiteboardWithMLXLocal(prompt: prompt)

        case .appleCloud:
            // For Whiteboard, use the same path as MLX Local (keeps regular summaries unchanged).
            generateWhiteboardWithMLXLocal(prompt: prompt)

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

    private func runAppleCloudStructured(prompt: String, timeoutSeconds: TimeInterval? = nil, requiredTopLevelKeys: [String]? = nil) async throws -> String {
        var didReturn = false
        return try await withCheckedThrowingContinuation { continuation in
            func finish(_ result: Result<String, Error>) {
                if didReturn { return }
                didReturn = true
                continuation.resume(with: result)
            }

            let originalClipboard = currentClipboardString()
            appState.launchCloudRequest(for: prompt, type: .summary, useClipboardMonitoring: false, completion: nil)

            Task {
                let effectiveTimeout = timeoutSeconds ?? appleCloudTimeoutSeconds(promptCharCount: prompt.count)
                do {
                    let fileResult = try await waitForAppleCloudOutput(
                        timeout: effectiveTimeout,
                        originalClipboard: originalClipboard,
                        requiredTopLevelKeys: requiredTopLevelKeys
                    )
                    let trimmed = fileResult.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        finish(.failure(NSError(domain: "AppleCloud", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple Cloud returned an empty response."])))
                    } else {
                        finish(.success(trimmed))
                    }
                } catch {
                    finish(.failure(error))
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

        if selectedProvider == .appleCloud {
            let sanitized = sanitizeStructuredJSONCandidate(rawOutput)
            if let data = sanitized.data(using: .utf8) {
                let domain = (kind == .infographic) ? "Infographic" : "Whiteboard"
                if (try? MLXJSONRepairUtils.parseLLMJSONDictionary(from: data, domain: domain)) != nil {
                    return data
                }
            }
        }

        let clippedLimit = selectedProvider == .appleCloud ? 6_000 : 12_000
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
        \(selectedProvider == .appleCloud ? "- Keep the JSON short to avoid truncation; prefer fewer items with shorter strings." : "")

        Model output to fix:
        \(clipped)
        """

        // Use the same provider that generated the original output
        let repaired: String
        
        switch selectedProvider {
        case .mlxLocal:
            let modelID = appState.settings.mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let maxOutputTokens = max(1, appState.settings.mlxMaxOutputTokens)
            repaired = try await MLXLocalService.shared.generateText(
                prompt: repairPrompt,
                modelID: modelID,
                maxOutputTokens: maxOutputTokens,
                maxContextTokens: 4096
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
        let maxChars = (selectedProvider == .appleCloud || selectedProvider == .mlxLocal) ? 8000 : 2000
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
        if selectedProvider == .appleCloud {
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

        if selectedProvider == .mlxLocal {
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
            for feed in appState.redditFeeds {
                if let post = feed.posts.first(where: { $0.id == referenceId }) {
                    appState.setSelectedRedditPost(post)
                    return
                }
            }
        } else {
            for feed in appState.feeds {
                if let article = feed.articles.first(where: { $0.id == referenceId }) {
                    appState.setSelectedArticle(article)
                    return
                }
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
        let summariesForPrompt = (selectedProvider == .appleCloud)
            ? Array(parsedSummaries.prefix(12).enumerated())
            : Array(parsedSummaries.enumerated())
        let rankedCandidates = rankedVisualCandidates(limit: isRedditContent ? 4 : 0)

        let perItemLimit = selectedProvider == .appleCloud ? 600 : 2000
        let content = summariesForPrompt.map { index, item in
            let title = item.subject.isEmpty ? "Item \(index + 1)" : item.subject
            let truncatedContent = String(item.summary.prefix(perItemLimit))
            return "[\(index + 1)] \"\(title)\"\n\(truncatedContent)\n"
        }.joined(separator: "\n---\n")

        let urlReferenceList: String
        if isRedditContent {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                for feed in appState.redditFeeds {
                    if let post = feed.posts.first(where: { $0.id == referenceId }),
                       let postUrl = post.url {
                        return "[\(index + 1)] \"\(item.subject)\" → \(postUrl.absoluteString)"
                    }
                }
                return nil
            }.joined(separator: "\n")
        } else {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                for feed in appState.feeds {
                    if let article = feed.articles.first(where: { $0.id == referenceId }),
                       let articleUrl = article.url {
                        return "[\(index + 1)] \"\(item.subject)\" → \(articleUrl.absoluteString)"
                    }
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
        let summariesForPrompt = (selectedProvider == .appleCloud)
            ? Array(parsedSummaries.prefix(12).enumerated())
            : Array(parsedSummaries.enumerated())
        let rankedCandidates = rankedVisualCandidates(limit: isRedditContent ? 4 : 0)
        let perItemLimit = selectedProvider == .appleCloud ? 600 : 2000
        let content = summariesForPrompt.map { index, item in
            let title = item.subject.isEmpty ? "Item \(index + 1)" : item.subject
            let truncatedContent = String(item.summary.prefix(perItemLimit))
            return "[\(index + 1)] \"\(title)\"\n\(truncatedContent)\n"
        }.joined(separator: "\n---\n")

        let urlReferenceList: String
        if isRedditContent {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                for feed in appState.redditFeeds {
                    if let post = feed.posts.first(where: { $0.id == referenceId }),
                       let postUrl = post.url {
                        return "[\(index + 1)] \"\(item.subject)\" -> \(postUrl.absoluteString)"
                    }
                }
                return nil
            }.joined(separator: "\n")
        } else {
            urlReferenceList = summariesForPrompt.compactMap { (index, item) -> String? in
                guard let referenceId = item.referenceId else { return nil }
                for feed in appState.feeds {
                    if let article = feed.articles.first(where: { $0.id == referenceId }),
                       let articleUrl = article.url {
                        return "[\(index + 1)] \"\(item.subject)\" -> \(articleUrl.absoluteString)"
                    }
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
                if effectiveProvider == .mlxLocal {
                    await MLXLocalService.shared.clearTransientCache()
                    print("🔀 [Infographic] MLX selected - redirecting to Apple Local for JSON generation")
                }

                let rawResponse: String
                switch effectiveProvider {
                case .mlxLocal:
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
                    // Apple Cloud via Shortcuts - can handle JSON with explicit instructions
                    rawResponse = try await runAppleCloudStructured(
                        prompt: prompt,
                        timeoutSeconds: 300,
                        requiredTopLevelKeys: ["title", "subtitle", "focus", "palette", "statTiles", "barSections", "sentiment", "sentimentBand", "majorThemes", "themes", "keyTopics", "notableTrends", "takeaway", "topPosts"]
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

                let responseForParsing = effectiveProvider == .appleCloud
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
                    if effectiveProvider == .mlxLocal || effectiveProvider == .appleCloud || effectiveProvider == .summarizeDaemon {
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
        let maxChars = (selectedProvider == .appleCloud || selectedProvider == .mlxLocal) ? 8000 : 2000
        let trimmed = String(content.prefix(maxChars))
        let contentType = isRedditContent ? "Reddit" : "Article"
        let rankingSection = buildRankedPostSection(
            header: "TOP POST RANKING",
            selectionField: "topPosts",
            candidates: rankedCandidates,
            limit: 4
        )

        if selectedProvider == .mlxLocal {
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

        if selectedProvider == .appleCloud {
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
                            onAskAISelection: handleAskAISelection(selectedText:context:)
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

    private func handleAskAISelection(selectedText: String, context: String) {
        guard !isAskingAI else { return }
        let prompt = buildAskAISelectionPrompt(selectedText: selectedText, extractedContext: context)
        guard !prompt.isEmpty else { return }

        askAIPrompt = prompt
        askAIResponse = ""
        isAskingAI = true

        appState.askQuestionAboutGlobalSummary(question: prompt) { answer in
            DispatchQueue.main.async {
                self.isAskingAI = false
                self.askAIResponse = cleanMarkdownArtifactsForDisplay(answer)
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

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
        let wv = AskAIEnabledWKWebView(frame: .zero, configuration: config)
        wv.onAskAISelection = { action, selectedText, context in
            guard action == .standard else { return }
            onAskAISelection?(selectedText, context)
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
                guard action == .standard else { return }
                onAskAISelection?(selectedText, context)
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
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad && colorScheme == .dark {
            return .black
        }
        #endif
        return AppColors.systemGray6
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
    @Environment(\.colorScheme) private var colorScheme

    private var cardBackground: Color {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad && colorScheme == .dark {
            return .black
        }
        #endif
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
// iPhone-only: bottom action bar visibility controller (always visible now)
@State private var showActionBar: Bool = true
#endif

    private let articleTopAnchor = "articleDetailTopAnchor"

    private var detailBackground: Color {
        colorScheme == .dark ? .black : AppColors.background
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

    private var articleHeaderHorizontalPadding: CGFloat {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone ? 0 : 24
        #else
        return 24
        #endif
    }

    private var articleContentHorizontalPadding: CGFloat {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone ? 0 : 4
        #else
        return 4
        #endif
    }

    private var articleCardOuterHorizontalPadding: CGFloat {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone ? 0 : 16
        #else
        return 16
        #endif
    }

    private var articleTopSpacerHeight: CGFloat {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone ? 16 : 110
        #else
        return 110
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
        }
    }

    private func articleScene(article: Article, proxy: ScrollViewProxy) -> some View {
        ZStack {
            detailBackground
                .ignoresSafeArea()

            articleScrollContent(article: article)
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
        .overlay(alignment: .bottom) { phoneBottomActionBar(proxy: proxy) }
        .overlay { phoneFloatingStatusOverlay() }
        .overlay(alignment: .bottomTrailing) { scrollToTopOverlay(proxy: proxy) }
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

    private var emptyArticlePlaceholder: some View {
        Text("Select an article to read")
            .font(.title)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func scrollToTopOverlay(proxy: ScrollViewProxy) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom != .phone {
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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 0)
                    .id(articleTopAnchor)

                Spacer()
                    .frame(height: articleTopSpacerHeight)

                articleHeader(article: article)
                articleSummaryAndQASection(article: article)

                ArticleContentRenderer(
                    content: contentToRender,
                    baseURL: article.url,
                    prefersCompactTitleSizing: usesCompactTitleSizing,
                    viewMode: $articleViewMode
                )
                .padding(.top, 8)
                .padding(.horizontal, articleContentHorizontalPadding)

                Spacer()
                    .frame(height: 40)

                articleFooter(article: article)
            }
            #if os(iOS)
            .padding(.horizontal, articleCardOuterHorizontalPadding)
            .padding(.bottom, 20)
            #else
            .modifier(ArticleCardGlassModifier())
            .padding(.horizontal, articleCardOuterHorizontalPadding)
            .padding(.bottom, 20)
            #endif
        }
    }

    private func articleHeader(article: Article) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let url = article.url, let host = url.host {
                    DomainIconView(domain: host, size: 16)
                }
                Text(article.feedTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)

                if let author = article.author, !author.isEmpty {
                    Text("–")
                        .foregroundColor(.secondary)
                    Text(author)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(formattedDate(article.publishDate))
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, articleHeaderHorizontalPadding)
            .padding(.top, 24)
            .padding(.bottom, 16)

            if articleViewMode == .rss {
                Text(article.title)
                    .font(.system(size: articleDetailTitleSize, weight: .bold))
                    .lineSpacing(0)
                    .padding(.horizontal, articleHeaderHorizontalPadding)
                    .padding(.bottom, 30)
            }
        }
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
                    if shouldShowExplicitWebAIControls {
                        Button {
                            appState.requestWebSummary(for: article)
                        } label: {
                            Image(systemName: "globe")
                        }
                        .buttonStyle(LiquidGlassButtonStyle())
                        .help("Generate article summary with \(appState.settings.selectedWebAIProvider.displayName)")
                    }
                }
                let streamText = appState.mlxStreamingText
                if appState.settings.selectedSummaryProvider == .mlxLocal && !streamText.isEmpty {
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
                    if shouldShowExplicitWebAIControls {
                        Button {
                            appState.requestWebSummary(for: article)
                        } label: {
                            Image(systemName: "globe")
                        }
                        .buttonStyle(LiquidGlassButtonStyle())
                        .help("Generate article summary with \(appState.settings.selectedWebAIProvider.displayName)")
                    }
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
                    if shouldShowExplicitWebAIControls {
                        Button {
                            appState.requestWebSummary(for: article)
                        } label: {
                            Image(systemName: "globe")
                        }
                        .buttonStyle(LiquidGlassButtonStyle())
                        .help("Generate article summary with \(appState.settings.selectedWebAIProvider.displayName)")
                    }
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
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        appState.requestSummary(for: article)
                    } label: {
                        Label("Summarize Article", systemImage: "text.bubble")
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    .help("Generate article summary with \(appState.settings.selectedSummaryProvider.displayName)")

                    if shouldShowExplicitWebAIControls {
                        Button {
                            appState.requestWebSummary(for: article)
                        } label: {
                            Image(systemName: "globe")
                                .font(.subheadline)
                        }
                        .buttonStyle(LiquidGlassButtonStyle())
                        .help("Generate article summary with \(appState.settings.selectedWebAIProvider.displayName)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func qaSection(article: Article) -> some View {
        if qaState.showQAInterface {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ask a question about this article:")
                    .font(.headline)

                qaInputField(article: article)
                qaActionRow(article: article)
                qaAnswerContent()
                if !qaAnswerUnavailable {
                    qaUtilityButtons()
                }
                qaStatusIndicators()
            }
            .padding()
            .modifier(QuestionAnswerGlassModifier())
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func qaInputField(article: Article) -> some View {
        if #available(iOS 26.0, *) {
            TextField("Type your question...", text: $qaState.questionText)
                .textFieldStyle(LiquidGlassTextFieldStyle())
                .disabled(qaState.isProcessingQuestion)
                .onSubmit {
                    if !qaState.questionText.isEmpty && !qaState.isProcessingQuestion {
                        askQuestion(article: article)
                    }
                }
                .onAppear {
                    print("📱 ArticleDetailView: Q&A interface appeared")
                }
        } else {
            TextField("Type your question...", text: $qaState.questionText)
                .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(cornerRadius: 12, tintColor: .blue.opacity(0.3)))
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
            if appState.settings.selectedSummaryProvider == .mlxLocal && !qaStreamText.isEmpty {
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
        if (qaProvider == .mlxLocal || qaProvider == .appleLocal || qaProvider == .summarizeDaemon),
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
        let prompt = buildAskAISelectionPrompt(selectedText: selectedText, extractedContext: context)
        guard !prompt.isEmpty else { return }

        selectionAskAIPrompt = prompt
        selectionAskAIResponse = ""
        isAskingSelectionAI = true

        let finish: (String) -> Void = { answer in
            DispatchQueue.main.async {
                self.selectionAskAIResponse = cleanMarkdownArtifactsForDisplay(answer)
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
        if UIDevice.current.userInterfaceIdiom == .phone {
            HStack(spacing: 16) {
                Button(action: {
                    withAnimation(.easeInOut) {
                        proxy.scrollTo(articleTopAnchor, anchor: .top)
                    }
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(LiquidGlassButtonStyle())

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
            .animation(.easeInOut(duration: 0.2), value: showActionBar)
        }
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder
    private func phoneFloatingStatusOverlay() -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            ZStack {
                if appState.isLoading && appState.selectedArticle?.summary == nil {
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
            self.qaState.answerText = cleanMarkdownArtifactsForDisplay(answer)
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
            self.qaState.answerText = cleanMarkdownArtifactsForDisplay(answer)
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

struct ArticleContentRenderer: View {
    let content: String
    let baseURL: URL?
    let prefersCompactTitleSizing: Bool
    @Binding var viewMode: ViewMode

    enum ViewMode: String, CaseIterable {
        case reader = "Reader"
        case rss = "RSS"
    }

    @State private var contentHeight: CGFloat = 100
    @State private var isLoadingReader: Bool = false
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
            // Toggle buttons for Reader vs RSS mode
            HStack(spacing: 12) {
                Text("View Mode:")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)

                // Reader mode button - only enabled if we have a valid URL
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewMode = .reader
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.plaintext")
                            .renderingMode(.template)
                            .foregroundStyle(buttonTextColor(isActive: viewMode == .reader))
                            .foregroundColor(buttonTextColor(isActive: viewMode == .reader))
                        Text("Reader")
                            .foregroundStyle(buttonTextColor(isActive: viewMode == .reader))
                            .foregroundColor(buttonTextColor(isActive: viewMode == .reader))
                    }
                    .font(.system(size: 13, weight: viewMode == .reader ? .semibold : .medium))
                }
                .buttonStyle(LiquidGlassButtonStyle(isProminent: viewMode == .reader))
                .disabled(!hasArticleURL)
                .opacity(hasArticleURL ? 1.0 : 0.5)

                // RSS content mode button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewMode = .rss
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .renderingMode(.template)
                            .foregroundStyle(buttonTextColor(isActive: viewMode == .rss))
                            .foregroundColor(buttonTextColor(isActive: viewMode == .rss))
                        Text("RSS")
                            .foregroundStyle(buttonTextColor(isActive: viewMode == .rss))
                            .foregroundColor(buttonTextColor(isActive: viewMode == .rss))
                    }
                    .font(.system(size: 13, weight: viewMode == .rss ? .semibold : .medium))
                }
                .buttonStyle(LiquidGlassButtonStyle(isProminent: viewMode == .rss))

                Spacer()

                // Loading indicator for reader mode
                if isLoadingReader && viewMode == .reader {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                Color.black.opacity(0.05)
                    .overlay(
                        LinearGradient(
                            colors: [Color.white.opacity(0.1), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )

            Divider()

            // Conditional content based on mode
            if viewMode == .reader && hasArticleURL {
                // Reader mode - load article URL and apply Readability.js
                // Give explicit height since we're inside a parent ScrollView
                ArticleReaderWebView(
                    articleURL: baseURL!,
                    isLoading: $isLoadingReader,
                    readerModeAvailable: $readerModeAvailable,
                    useCompactTitleSizing: prefersCompactTitleSizing
                )
                .frame(maxWidth: .infinity)
                .frame(height: currentPlatformScreenHeight() - 200)
            } else {
                // RSS mode - show RSS content in WebView
                HTMLWebView(htmlContent: enhanceHTML(content), baseURL: baseURL, contentHeight: $contentHeight)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(contentHeight, 200))
            }
        }
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

    private static func conceal(_ webView: WKWebView) {
        webView.alphaValue = 0
    }

    private static func reveal(_ webView: WKWebView) {
        guard webView.alphaValue != 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            webView.animator().alphaValue = 1
        }
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

    private static func conceal(_ webView: WKWebView) {
        webView.alpha = 0
    }

    private static func reveal(_ webView: WKWebView) {
        guard webView.alpha != 1 else { return }
        UIView.animate(withDuration: 0.15) {
            webView.alpha = 1
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
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
        borderStyle: SummaryCardBorderStyle? = nil
    ) {
        self.summary = summary
        self.displaySummary = displaySummary ?? cleanMarkdownArtifactsForDisplay(summary)
        self.onAskAISelection = onAskAISelection
        self.onAskAIWebSelection = onAskAIWebSelection
        self.borderStyle = borderStyle
    }

    var body: some View {
        ArticleGlassySummaryContent(
            summary: summary,
            displaySummary: displaySummary,
            onAskAISelection: onAskAISelection,
            onAskAIWebSelection: onAskAIWebSelection,
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
        guard (provider == .mlxLocal || provider == .appleLocal || provider == .summarizeDaemon), !appState.mlxLastThroughput.isEmpty else {
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

                Button(action: speakSummary) {
                    Image(systemName: "speaker.wave.2")
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .ttsActiveGlow(isSynthesizingSpeech, color: .blue)
                .help("Read aloud (Cloud)")
                .disabled(isSynthesizingSpeech || isSpeakingLocally || summary.isEmpty)

                Button(action: stopArticleSummarySpeech) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .help("Stop speech")

                Button(action: speakSummaryLocally) {
                    Image(systemName: "speaker.wave.2.circle")
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .ttsActiveGlow(isSpeakingLocally || isPreparingLocalTTS, color: .green)
                .help("Read aloud (Local)")
                .disabled(isSynthesizingSpeech || summary.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Group {
                if onAskAISelection != nil || onAskAIWebSelection != nil {
                    SelectableText(
                        text: displaySummary,
                        onAskAI: onAskAISelection,
                        onAskAIWeb: onAskAIWebSelection,
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

private struct SidebarRowChromeModifier: ViewModifier {
    let backgroundColor: Color

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            .listRowBackground(backgroundColor)
    }
}

private struct SidebarSelectionBorderModifier: ViewModifier {
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let borderColor: Color = isSelected
            ? (colorScheme == .dark ? Color.black : Color.white)
            : Color.clear

        content
            .modifier(SidebarRowChromeModifier(backgroundColor: .clear))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderColor, lineWidth: isSelected ? 1.25 : 0)
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
    func systemEdgeBackSwipe(perform action: @escaping () -> Void) -> some View {
        #if os(iOS)
        self.overlay(alignment: .leading) {
            EdgeBackSwipeRecognizer(action: action)
                .frame(width: 72)                    // generous hot zone for reliable swipes in compact layouts
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .allowsHitTesting(true)
        }
        #else
        self
        #endif
    }
    
    @ViewBuilder
    func phoneStyleBackGestures(enabled: Bool, action: @escaping () -> Void) -> some View {
        #if os(iOS)
        if enabled {
            self
                .systemEdgeBackSwipe(perform: action)
                .enhancedSwipeBack(perform: action)
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
