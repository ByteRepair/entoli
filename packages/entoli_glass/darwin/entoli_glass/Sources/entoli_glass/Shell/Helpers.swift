import ImageIO
import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// Puts [text] on the clipboard.
func copyToPasteboard(_ text: String) {
  #if os(iOS)
    UIPasteboard.general.string = text
  #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  #endif
}

/// [data] — a PNG, a JPEG — decoded, or nil where it is not a picture.
func decodedImage(_ data: Data) -> CGImage? {
  guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
  return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

extension Image {
  /// [data] as the platform's image reads it, at the size it says it is.
  init?(picture data: Data) {
    #if os(iOS)
      guard let image = UIImage(data: data) else { return nil }
      self.init(uiImage: image)
    #else
      guard let image = NSImage(data: data) else { return nil }
      self.init(nsImage: image)
    #endif
  }
}

#if os(iOS)
  /// A text view on TextKit 1, made through the designated initializer:
  /// UIKit's `init(usingTextLayoutManager:)` is a class factory, and a
  /// subclass's instance it makes has its Swift properties unset — an array
  /// among them reads as a null pointer.
  class TextKit1View: UITextView {
    /// Holds the layout manager, which holds the container the view holds.
    private let storage = NSTextStorage()

    init() {
      let layout = NSLayoutManager()
      storage.addLayoutManager(layout)
      let container = NSTextContainer(
        size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
      container.widthTracksTextView = true
      layout.addTextContainer(container)
      super.init(frame: .zero, textContainer: container)
    }

    required init?(coder: NSCoder) { nil }
  }
#endif

/// A search's words: what is found holds every one of them, in any order.
struct SearchWords {
  private let words: [String]

  init(_ query: String) {
    words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
  }

  var isEmpty: Bool { words.isEmpty }

  /// Whether [text], already lowercased, holds every word.
  func found(in text: String) -> Bool { words.allSatisfy(text.contains) }
}

extension Binding where Value == Bool {
  /// Whether [value] is set: what presents a sheet or alert over it, and
  /// clears it once that is dismissed.
  static func present<T>(_ value: Binding<T?>) -> Binding<Bool> {
    Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
  }
}
