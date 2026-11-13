#if canImport(CoreLocation)
import CoreLocation
import Foundation

/// Apple's forward geocoder (D-F, D15). Each call creates a new
/// `CLGeocoder` with `preferredLocale: en_US`, so field values come back in
/// English ("The Hague", not "Den Haag") and match the English headings.
///
/// - Placemarks are mapped to `GeocodeCandidate`s inside the completion
///   handler; placemarks without a location are dropped.
/// - `kCLErrorGeocodeFoundNoResult` → []. Any other error is thrown (a
///   cancelled request throws CancellationError).
/// - Task cancellation calls `cancelGeocode()`.
///
/// CLGeocoder is deprecated in the iOS 26 SDK in favour of MapKit's
/// `MKGeocodingRequest`; with the iOS 18 deployment target it compiles
/// without a warning, and migrating is a phase 6 candidate (§0.10).
/// Calls are serialised by `PlaceLocator`'s gate (Apple throttles bursts).
final class CLPlaceGeocoder: PlaceGeocoder, @unchecked Sendable {
    let sourceName = "clgeocoder"

    init() {}

    func geocode(_ query: String) async throws -> [GeocodeCandidate] {
        let box = GeocoderBox(CLGeocoder())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[GeocodeCandidate], Error>) in
                box.geocoder.geocodeAddressString(query, in: nil, preferredLocale: Locale(identifier: "en_US")) { placemarks, error in
                    if let error {
                        switch (error as? CLError)?.code {
                        case .geocodeFoundNoResult?:
                            continuation.resume(returning: [])
                        case .geocodeCanceled?:
                            continuation.resume(throwing: CancellationError())
                        default:
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    continuation.resume(returning: (placemarks ?? []).compactMap(CLPlaceGeocoder.candidate))
                }
            }
        } onCancel: {
            box.geocoder.cancelGeocode()
        }
    }

    static func candidate(_ placemark: CLPlacemark) -> GeocodeCandidate? {
        guard let location = placemark.location else { return nil }
        return GeocodeCandidate(
            coordinate: GeoCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
            name: placemark.name, locality: placemark.locality, subLocality: placemark.subLocality,
            administrativeArea: placemark.administrativeArea, subAdministrativeArea: placemark.subAdministrativeArea,
            country: placemark.country, isoCountryCode: placemark.isoCountryCode,
            ocean: placemark.ocean, inlandWater: placemark.inlandWater,
            areasOfInterest: placemark.areasOfInterest ?? [])
    }
}

/// Lets the cancellation handler (a `@Sendable` closure) reach the
/// geocoder. `cancelGeocode()` may be called from any thread.
private final class GeocoderBox: @unchecked Sendable {
    let geocoder: CLGeocoder
    init(_ geocoder: CLGeocoder) { self.geocoder = geocoder }
}
#endif
