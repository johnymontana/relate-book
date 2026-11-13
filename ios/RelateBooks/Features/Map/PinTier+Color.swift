import MapKit
import UIKit

/// Marker styling per `PinTier` (spec B1). `MKMarkerAnnotationView` has a
/// fixed size, so emphasis comes from colour, glyph and priority.
extension PinTier {
    var markerColor: UIColor {
        switch self {
        case .birthplace: .systemPurple
        case .one: .systemTeal
        case .few: .systemBlue
        case .several: .systemOrange
        case .many: .systemRed
        }
    }

    /// An SF Symbol for the tiers that show no count.
    var glyphSymbol: String? {
        switch self {
        case .birthplace: "person.fill"
        case .one: "book.closed.fill"
        case .few, .several, .many: nil
        }
    }

    var displayPriority: MKFeatureDisplayPriority {
        switch self {
        case .birthplace, .one: .defaultLow
        case .few: .defaultHigh
        case .several, .many: .required
        }
    }

    /// Bigger tiers draw on top.
    var zPriority: MKAnnotationViewZPriority {
        MKAnnotationViewZPriority(rawValue: 300 + Float(rawValue) * 100)
    }
}
