//
//  MapView.swift
//  Example
//
//  Created by Matheus Gois on 12/06/24.
//

#if os(iOS)
import SwiftUI
import MapKit
import CoreLocation

/// iOS only: MapKit has no Android counterpart in this app yet.
struct MapView: View {
    private var manager = MapViewManager()

    var body: some View {
        MapView17(manager: manager)
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
    }
}

@available(iOS 17.0, *)
struct MapView17: View {
    @State var position = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.507222, longitude: -0.1275),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
    )
    var manager: MapViewManager

    var body: some View {
        Map(position: $position) {
            // MapContentBuilder content can be added here
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onAppear {
            manager.start()
        }
    }
}

@available(iOS 14.0, *)
class MapViewManager: NSObject, CLLocationManagerDelegate {
    @State var locationManager = CLLocationManager()

    func start() {
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            break
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        @unknown default:
            fatalError("Unhandled case for location authorization status")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        print("""
            -----
            NEW LOCATION IS UPDATED, TO SHOW IN MAP, NEEDS RESTART THE APP

            \(locations)

            -----
            """)
    }
}

@available(iOS 14.0, *)
extension MapViewManager: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
        let region = MKCoordinateRegion(
            center: userLocation.coordinate,
            latitudinalMeters: 10000,
            longitudinalMeters: 10000
        )
        mapView.setRegion(region, animated: true)
    }
}
#endif
