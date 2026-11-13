import AVFoundation
import SwiftUI
import VisionKit

/// What the Scan screen can offer for the camera.
enum ScannerAvailability: Equatable {
    /// DataScanner supported and camera access granted.
    case available
    /// Supported, but the user has not been asked for camera access yet.
    case needsPermission
    /// Supported, but camera access is denied or restricted.
    case denied
    /// No DataScanner on this device (simulator, older hardware).
    case unsupported

    @MainActor static var current: ScannerAvailability {
        guard DataScannerViewController.isSupported else { return .unsupported }
        if DataScannerViewController.isAvailable { return .available }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return .needsPermission
        default: return .denied
        }
    }
}

/// Live barcode scanning (D-D): VisionKit's `DataScannerViewController`
/// reading EAN-13, EAN-8 and UPC-E. Unsupported on the simulator and
/// without camera permission (`isAvailable` is false then); the Scan
/// screen always offers the typed ISBN field too.
struct ISBNScannerView: UIViewControllerRepresentable {
    /// `model.isScannerActive`: true only while the screen is editing. The
    /// camera scans only while this is true.
    let isActive: Bool
    let onPayload: @MainActor (String) -> Void

    @MainActor static var isAvailable: Bool { ScannerAvailability.current == .available }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }

    /// Starts or stops scanning only when `isActive` changes (the
    /// coordinator keeps the last applied value). Any other update, such as
    /// a phase change while inactive, does nothing, so a barcode still in
    /// view cannot start a new import by itself (C2). A start that throws
    /// (e.g. the view is not in a window yet) is not recorded as applied
    /// and is retried a few times shortly after.
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onPayload = onPayload
        context.coordinator.wantsActive = isActive
        guard context.coordinator.appliedActive != isActive else { return }
        if isActive {
            context.coordinator.start(controller, attemptsLeft: Coordinator.startAttempts)
        } else {
            context.coordinator.cancelRetry()
            if controller.isScanning { controller.stopScanning() }
            context.coordinator.appliedActive = false
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        coordinator.cancelRetry()
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload)
    }

    /// The scanner's delegate (main actor): hands the first ISBN barcode to
    /// `onPayload` and stops scanning, so one book is not looked up twice.
    /// The model's guards (`didScan` only while editing, and the same
    /// payload ignored for its cooldown) back this up.
    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPayload: @MainActor (String) -> Void
        /// nil until the first update applies a value; true only once
        /// `startScanning()` succeeded.
        var appliedActive: Bool?
        /// The latest `isActive`; a pending retry gives up when it is false.
        var wantsActive = false
        private var retry: Task<Void, Never>?
        static let startAttempts = 4
        static let retryDelay: Duration = .milliseconds(400)

        init(onPayload: @escaping @MainActor (String) -> Void) {
            self.onPayload = onPayload
        }

        func start(_ controller: DataScannerViewController, attemptsLeft: Int) {
            cancelRetry()
            guard wantsActive else { return }
            if controller.isScanning {
                appliedActive = true
                return
            }
            do {
                try controller.startScanning()
                appliedActive = true
            } catch {
                Log.store.error("scanner start failed: \(error.localizedDescription, privacy: .public)")
                guard attemptsLeft > 1 else { return }
                retry = Task { [weak self, weak controller] in
                    try? await Task.sleep(for: Self.retryDelay)
                    guard !Task.isCancelled, let self, let controller else { return }
                    self.start(controller, attemptsLeft: attemptsLeft - 1)
                }
            }
        }

        func cancelRetry() {
            retry?.cancel()
            retry = nil
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in addedItems {
                guard let payload = barcode.payloadStringValue else { continue }
                onPayload(payload)
                if ISBN.fromBarcode(payload) != nil {
                    dataScanner.stopScanning()
                    appliedActive = false
                    return
                }
            }
        }
    }
}
