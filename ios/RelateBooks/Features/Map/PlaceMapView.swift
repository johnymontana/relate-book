import MapKit
import SwiftUI

/// `MKMapView` behind the Map tab. One annotation per `PlacePin` (one pin
/// per `geocoded_label`), diffed by label; book pins and birthplace pins
/// cluster separately. The view reports settled regions to `MapModel` and
/// performs its fly-to requests. All logic stays in `MapModel` (core).
struct PlaceMapView: UIViewRepresentable {
    let model: MapModel
    /// `model.displayedPins`, passed in so SwiftUI re-runs `updateUIView`.
    let pins: [PlacePin]
    let focus: MapFocus?
    /// The sheet's label: that marker is highlighted.
    let selectedLabel: String?

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.accessibilityIdentifier = "map.view"
        map.pointOfInterestFilter = .excludingAll
        map.showsUserLocation = false
        map.delegate = context.coordinator
        map.register(PlaceMarkerView.self, forAnnotationViewWithReuseIdentifier: PlaceMarkerView.reuseIdentifier)
        map.register(PlaceClusterView.self,
                     forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        // The model's last region (the initial region on first show), so a
        // re-created view comes back where the user left it.
        map.setRegion(MKCoordinateRegion(model.visibleBox), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.sync(pins, on: map)
        if let focus { coordinator.apply(focus, sheetOpen: selectedLabel != nil, on: map) }
        coordinator.select(selectedLabel, on: map)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var model: MapModel
        private var annotations: [String: PlaceAnnotation] = [:]
        private var lastPins: [PlacePin] = []
        private var handledFocus: Int?
        private var appliedSelection: String?
        /// A label to highlight once its marker is on screen and unclustered.
        private var pendingSelection: String?
        private var selectingProgrammatically = false

        init(model: MapModel) {
            self.model = model
        }

        // MARK: Annotations

        /// Diff, don't rebuild: remove gone labels, add new ones, replace an
        /// annotation whose counts changed.
        func sync(_ pins: [PlacePin], on map: MKMapView) {
            guard pins != lastPins else { return }
            lastPins = pins
            var wanted = Dictionary(pins.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
            var removed: [PlaceAnnotation] = []
            var added: [PlaceAnnotation] = []
            for (label, annotation) in annotations {
                if let pin = wanted.removeValue(forKey: label) {
                    if pin != annotation.pin {
                        removed.append(annotation)
                        let fresh = PlaceAnnotation(pin: pin, standsAlone: annotation.standsAlone)
                        annotations[label] = fresh
                        added.append(fresh)
                    }
                } else {
                    removed.append(annotation)
                    annotations[label] = nil
                }
            }
            for pin in wanted.values {
                let fresh = PlaceAnnotation(pin: pin, standsAlone: pin.label == appliedSelection)
                annotations[pin.label] = fresh
                added.append(fresh)
            }
            if !removed.isEmpty { map.removeAnnotations(removed) }
            if !added.isEmpty { map.addAnnotations(added) }
        }

        // MARK: Focus and selection

        /// Flies to `focus` once. With the sheet open the place is framed in
        /// the part of the map above the medium detent.
        func apply(_ focus: MapFocus, sheetOpen: Bool, on map: MKMapView, attempt: Int = 0) {
            guard focus.id != handledFocus else { return }
            guard map.bounds.width > 0, map.bounds.height > 0 else {
                // Not laid out yet (the tab is appearing): retry shortly.
                guard attempt < 20 else { return }
                Task { @MainActor [weak self, weak map] in
                    try? await Task.sleep(for: .milliseconds(50))
                    guard let self, let map else { return }
                    self.apply(focus, sheetOpen: sheetOpen, on: map, attempt: attempt + 1)
                }
                return
            }
            handledFocus = focus.id
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: focus.center.latitude, longitude: focus.center.longitude),
                span: MKCoordinateSpan(latitudeDelta: focus.latitudeDelta, longitudeDelta: focus.longitudeDelta))
            if sheetOpen, let rect = MKMapRect(region) {
                let insets = UIEdgeInsets(top: 120, left: 24, bottom: map.bounds.height * 0.5, right: 24)
                map.setVisibleMapRect(rect, edgePadding: insets, animated: true)
            } else {
                map.setRegion(region, animated: true)
            }
            let model = self.model
            Task { @MainActor in model.focusHandled(focus.id) }
        }

        func select(_ label: String?, on map: MKMapView) {
            guard label != appliedSelection else { return }
            let previous = appliedSelection
            appliedSelection = label
            if let previous { setStandsAlone(false, label: previous, on: map) }
            if let label {
                setStandsAlone(true, label: label, on: map)
                pendingSelection = label
                trySelectPending(on: map)
            } else {
                pendingSelection = nil
                for annotation in map.selectedAnnotations {
                    map.deselectAnnotation(annotation, animated: false)
                }
            }
        }

        /// The selected place leaves its cluster (its marker is re-added
        /// without a clustering identifier), so it can be highlighted.
        private func setStandsAlone(_ standsAlone: Bool, label: String, on map: MKMapView) {
            guard let old = annotations[label], old.standsAlone != standsAlone else { return }
            let fresh = PlaceAnnotation(pin: old.pin, standsAlone: standsAlone)
            annotations[label] = fresh
            map.removeAnnotation(old)
            map.addAnnotation(fresh)
        }

        /// Highlights the pending label when its marker exists and is not
        /// inside a cluster (selecting a clustered member would select the
        /// cluster).
        private func trySelectPending(on map: MKMapView) {
            guard let label = pendingSelection, let annotation = annotations[label] else { return }
            if map.selectedAnnotations.contains(where: { $0 === annotation }) {
                pendingSelection = nil
                return
            }
            guard let view = map.view(for: annotation), view.cluster == nil else { return }
            selectingProgrammatically = true
            map.selectAnnotation(annotation, animated: false)
            selectingProgrammatically = false
            pendingSelection = nil
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            model.regionDidChange(GeoBox(
                center: GeoCoordinate(latitude: region.center.latitude, longitude: region.center.longitude),
                latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta))
            trySelectPending(on: mapView)
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            if pendingSelection != nil { trySelectPending(on: mapView) }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case is PlaceAnnotation:
                mapView.dequeueReusableAnnotationView(withIdentifier: PlaceMarkerView.reuseIdentifier, for: annotation)
            case is MKClusterAnnotation:
                mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: annotation)
            default:
                nil
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                mapView.deselectAnnotation(cluster, animated: false)
                guard !selectingProgrammatically else { return }
                // Zoom to the cluster's members.
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
            } else if let place = view.annotation as? PlaceAnnotation {
                guard !selectingProgrammatically else { return }
                // updateUIView then sees the new sheet label and marks the
                // marker as standing alone; it is already selected.
                model.select(label: place.pin.label)
            }
        }
    }
}

/// One map pin: every `Place` node that shares a `geocoded_label`.
final class PlaceAnnotation: NSObject, MKAnnotation {
    let pin: PlacePin
    /// The selected place: never clustered.
    let standsAlone: Bool
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?

    init(pin: PlacePin, standsAlone: Bool = false) {
        self.pin = pin
        self.standsAlone = standsAlone
        self.coordinate = CLLocationCoordinate2D(latitude: pin.coordinate.latitude, longitude: pin.coordinate.longitude)
        self.title = pin.label
        self.subtitle = pin.countsText
    }
}

/// A place marker: tint, glyph and priority from `PinTier`; book pins
/// cluster as "places", birthplace-only pins as "birthplaces".
final class PlaceMarkerView: MKMarkerAnnotationView {
    static let reuseIdentifier = "place"

    override var annotation: (any MKAnnotation)? {
        didSet { configure() }
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        configure()
    }

    private func configure() {
        guard let place = annotation as? PlaceAnnotation else { return }
        let pin = place.pin
        let tier = pin.tier
        clusteringIdentifier = place.standsAlone ? nil : (pin.isBirthplaceOnly ? "birthplaces" : "places")
        markerTintColor = tier.markerColor
        if let symbol = tier.glyphSymbol {
            glyphText = nil
            glyphImage = UIImage(systemName: symbol)
        } else {
            glyphImage = nil
            glyphText = "\(pin.books)"
        }
        displayPriority = place.standsAlone ? .required : tier.displayPriority
        zPriority = place.standsAlone ? .max : tier.zPriority
        canShowCallout = false
        isAccessibilityElement = true
        accessibilityIdentifier = "map.pin.\(pin.label)"
        accessibilityLabel = pin.isBirthplaceOnly
            ? "\(pin.label), \(PlaceText.authors(pin.authors)) born here"
            : "\(pin.label), \(PlaceText.books(pin.books))"
    }
}

/// A cluster: glyph = summed books (summed authors for a birthplace
/// cluster), tint = the tier of that sum, title "N places".
final class PlaceClusterView: MKMarkerAnnotationView {
    override var annotation: (any MKAnnotation)? {
        didSet { configure() }
    }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        configure()
    }

    private func configure() {
        guard let cluster = annotation as? MKClusterAnnotation else { return }
        let members = cluster.memberAnnotations.compactMap { ($0 as? PlaceAnnotation)?.pin }
        let birthplaces = !members.isEmpty && members.allSatisfy(\.isBirthplaceOnly)
        let books = members.reduce(0) { $0 + $1.books }
        let authors = members.reduce(0) { $0 + $1.authors }
        let value = birthplaces ? authors : books
        let tier = birthplaces ? PinTier.birthplace : PinTier(books: books)
        markerTintColor = tier.markerColor
        glyphImage = nil
        glyphText = value > 999 ? "999+" : "\(value)"
        displayPriority = .required
        zPriority = MKAnnotationViewZPriority(rawValue: 900)
        canShowCallout = false
        let places = PlaceText.places(members.count)
        let counts = birthplaces ? "\(PlaceText.authors(authors)) born there" : PlaceText.books(books)
        cluster.title = places
        cluster.subtitle = counts
        subtitleVisibility = .hidden
        isAccessibilityElement = true
        accessibilityIdentifier = "map.cluster"
        accessibilityLabel = "\(places), \(counts)"
    }
}

extension MKCoordinateRegion {
    init(_ box: GeoBox) {
        let center = box.center
        self.init(center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
                  span: MKCoordinateSpan(latitudeDelta: max(box.latitudeSpan, 0.01),
                                         longitudeDelta: min(max(box.longitudeSpan, 0.01), 360)))
    }
}

extension MKMapRect {
    /// The map rect of a region that does not cross the antimeridian or the
    /// Mercator limits; nil otherwise (the caller falls back to setRegion).
    init?(_ region: MKCoordinateRegion) {
        let c = region.center, s = region.span
        let north = c.latitude + s.latitudeDelta / 2, south = c.latitude - s.latitudeDelta / 2
        let west = c.longitude - s.longitudeDelta / 2, east = c.longitude + s.longitudeDelta / 2
        guard north <= 85, south >= -85, west >= -180, east <= 180 else { return nil }
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: north, longitude: west))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: south, longitude: east))
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
