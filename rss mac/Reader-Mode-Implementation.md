# Reader Mode Implementation Guide

## Overview
This guide explains how to implement a reader mode that extracts both text and images from HTML content, displaying them in a native SwiftUI ScrollView. This approach solves WebView scrolling issues while maintaining visual content.

## Key Components

### 1. Content Model
First, create an enum to represent different types of content elements:

```swift
enum ReaderContentElement {
    case text(String)
    case image(String) // URL string
}
```

### 2. HTML Parsing Function
The core parsing function extracts images and text while maintaining their relative positions:

```swift
private func parseContentForReader(_ html: String) -> [ReaderContentElement] {
    var elements: [ReaderContentElement] = []
    var workingHTML = html
    
    // Step 1: Extract all img tags and replace with placeholders
    let imgPattern = "<img[^>]*src\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>"
    var imageURLs: [String] = []
    
    if let regex = try? NSRegularExpression(pattern: imgPattern, options: .caseInsensitive) {
        let matches = regex.matches(in: workingHTML, options: [], 
                                   range: NSRange(workingHTML.startIndex..., in: workingHTML))
        
        // Extract in reverse order to maintain string indices
        for match in matches.reversed() {
            if let urlRange = Range(match.range(at: 1), in: workingHTML) {
                let imageURL = String(workingHTML[urlRange])
                imageURLs.insert(imageURL, at: 0)
                
                // Replace img tag with placeholder
                if let fullRange = Range(match.range, in: workingHTML) {
                    workingHTML.replaceSubrange(fullRange, 
                                              with: "[[IMAGE_PLACEHOLDER_\(imageURLs.count - 1)]]")
                }
            }
        }
    }
    
    // Step 2: Clean HTML to get text with placeholders
    let textWithPlaceholders = cleanTextFromHTML(workingHTML)
    
    // Step 3: Split by placeholders and build elements array
    let placeholderPattern = "\\[\\[IMAGE_PLACEHOLDER_(\\d+)\\]\\]"
    if let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern, options: []) {
        var lastIndex = textWithPlaceholders.startIndex
        let matches = placeholderRegex.matches(in: textWithPlaceholders, options: [], 
                                              range: NSRange(textWithPlaceholders.startIndex..., 
                                                           in: textWithPlaceholders))
        
        for match in matches {
            if let range = Range(match.range, in: textWithPlaceholders),
               let indexRange = Range(match.range(at: 1), in: textWithPlaceholders),
               let imageIndex = Int(textWithPlaceholders[indexRange]) {
                
                // Add text before image
                let textBefore = String(textWithPlaceholders[lastIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !textBefore.isEmpty {
                    elements.append(.text(textBefore))
                }
                
                // Add image
                if imageIndex < imageURLs.count {
                    elements.append(.image(imageURLs[imageIndex]))
                }
                
                lastIndex = range.upperBound
            }
        }
        
        // Add remaining text after last image
        let remainingText = String(textWithPlaceholders[lastIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainingText.isEmpty {
            elements.append(.text(remainingText))
        }
    }
    
    return elements
}
```

### 3. HTML Cleaning Helper
Remove HTML tags and decode entities:

```swift
private func cleanTextFromHTML(_ html: String) -> String {
    // Remove all HTML tags
    let pattern = "<[^>]+>"
    let stripped = html.replacingOccurrences(of: pattern, with: "", 
                                            options: .regularExpression, range: nil)
    
    // Decode common HTML entities
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
    
    // Clean up whitespace
    let lines = decoded.components(separatedBy: .newlines)
    let cleanedLines = lines
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    
    return cleanedLines.joined(separator: "\n\n")
}
```

### 4. SwiftUI View Implementation
Display the parsed content with proper styling:

```swift
ScrollView {
    VStack(alignment: .leading, spacing: 20) {
        ForEach(Array(parseContentForReader(htmlContent).enumerated()), id: \.offset) { _, element in
            switch element {
            case .text(let text):
                Text(text)
                    .font(.system(size: 17))
                    .lineSpacing(8)
                    .padding(.horizontal, 24)
                    .textSelection(.enabled)
                    
            case .image(let urlString):
                if let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .frame(height: 200)
                                .padding(.horizontal, 24)
                                
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .cornerRadius(12)
                                .shadow(radius: 8, y: 4)
                                .padding(.horizontal, 24)
                                
                        case .failure:
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 100)
                                .overlay(
                                    Image(systemName: "photo")
                                        .foregroundColor(.gray)
                                )
                                .cornerRadius(8)
                                .padding(.horizontal, 24)
                                
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .padding(.vertical, 20)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}
```

### 5. Mode Toggle with Glassy Style
Implement a toggle between reader and web modes:

```swift
@State private var useReaderMode = true

var body: some View {
    VStack {
        // Toggle buttons
        HStack(spacing: 12) {
            Text("View Mode:")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    useReaderMode = true
                }
            }) {
                Label("Reader", systemImage: "doc.plaintext")
                    .font(.system(size: 13, weight: useReaderMode ? .semibold : .medium))
                    .foregroundColor(useReaderMode ? .white : .primary)
            }
            .buttonStyle(LiquidGlassButtonStyle(isProminent: useReaderMode))
            
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    useReaderMode = false
                }
            }) {
                Label("Web", systemImage: "globe")
                    .font(.system(size: 13, weight: !useReaderMode ? .semibold : .medium))
                    .foregroundColor(!useReaderMode ? .white : .primary)
            }
            .buttonStyle(LiquidGlassButtonStyle(isProminent: !useReaderMode))
            
            Spacer()
        }
        .padding()
        
        // Content area
        if useReaderMode {
            // Reader mode content (see above)
        } else {
            // WebView content
        }
    }
}
```

## How It Works

1. **Image Extraction**: Uses regex to find all `<img>` tags and extract their `src` attributes
2. **Placeholder System**: Replaces images with temporary placeholders to maintain position
3. **Text Cleaning**: Strips HTML tags and decodes entities from the remaining content
4. **Element Assembly**: Splits the text by placeholders and rebuilds as an array of text/image elements
5. **SwiftUI Rendering**: Displays each element with appropriate styling

## Benefits

- **No WebView Issues**: Native SwiftUI scrolling works perfectly at any window size
- **Better Performance**: No WebView overhead, faster rendering
- **Full Control**: Can style text and images exactly as needed
- **Accessibility**: Native text selection and VoiceOver support
- **Responsive Images**: AsyncImage handles loading states and errors gracefully

## Usage in Other Projects

To implement this in your own code:

1. Copy the `ReaderContentElement` enum
2. Add the parsing functions (`parseContentForReader` and `cleanTextFromHTML`)
3. Create a SwiftUI view that renders the elements
4. Optionally add a toggle for switching between modes

## Customization Options

- **Text Styling**: Adjust font size, line spacing, and padding
- **Image Display**: Change corner radius, shadows, and maximum dimensions
- **Entity Decoding**: Add more HTML entities to the replacement list
- **Error Handling**: Customize placeholder views for failed image loads
- **Animation**: Add transitions when switching between modes

## Example: Applying to a Blog Reader

```swift
struct BlogPostView: View {
    let htmlContent: String
    @State private var readerMode = true
    
    var body: some View {
        VStack {
            // Mode toggle
            Picker("Mode", selection: $readerMode) {
                Text("Reader").tag(true)
                Text("Original").tag(false)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()
            
            // Content
            if readerMode {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(parseContentForReader(htmlContent).enumerated()), 
                               id: \.offset) { _, element in
                            // Render elements (same as above)
                        }
                    }
                }
            } else {
                WebView(html: htmlContent) // Your existing WebView
            }
        }
    }
}
```

This implementation provides a clean, native reading experience while avoiding all WebView-related scrolling and sizing issues.