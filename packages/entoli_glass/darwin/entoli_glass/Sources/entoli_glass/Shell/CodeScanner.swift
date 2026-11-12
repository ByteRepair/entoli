#if os(iOS)
  import SwiftUI
  import VisionKit

  /// The camera pointed at a pairing code another screen shows, the first
  /// code read answering Dart: the system's own live scanner.
  struct CodeScanner: View {
    let model: ShellModel

    var body: some View {
      NavigationStack {
        Group {
          if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            Scanner { model.scanned($0) }.ignoresSafeArea()
          } else {
            ContentUnavailableView(
              "No Camera", systemImage: "camera",
              description: Text("Type the code shown on the other screen instead."))
          }
        }
        .navigationTitle("Scan Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { model.scanned(nil) }
          }
        }
      }
    }
  }

  private struct Scanner: UIViewControllerRepresentable {
    let read: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
      let scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: [.qr])],
        isHighlightingEnabled: true)
      scanner.delegate = context.coordinator
      try? scanner.startScanning()
      return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(read: read) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
      let read: (String) -> Void
      private var done = false

      init(read: @escaping (String) -> Void) { self.read = read }

      func dataScanner(
        _ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
        allItems: [RecognizedItem]
      ) {
        guard !done else { return }
        for item in items {
          if case .barcode(let code) = item, let text = code.payloadStringValue {
            done = true
            scanner.stopScanning()
            read(text)
            return
          }
        }
      }
    }
  }
#endif
