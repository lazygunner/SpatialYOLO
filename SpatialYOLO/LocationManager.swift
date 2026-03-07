import Foundation
import CoreLocation
import Combine

@Observable
class LocationManager: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    
    var currentLocationName: String = "未知地点"
    var isFetching: Bool = false
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }
    
    func requestLocation() {
        isFetching = true
        let status = locationManager.authorizationStatus
        
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse {
            locationManager.requestLocation()
        } else {
            isFetching = false
            print("[Location] Location access denied")
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else {
            isFetching = false
            return
        }
        
        // 逆地理编码获取 POI
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            defer { self?.isFetching = false }
            
            if let error = error {
                print("[Location] Geocoding error: \(error.localizedDescription)")
                return
            }
            
            if let placemark = placemarks?.first {
                // 优先使用 name (通常是 POI 名称)，如果没有则使用格式化的地址描述
                let name = placemark.name ?? placemark.thoroughfare ?? "未知地点"
                self?.currentLocationName = name
                print("[Location] Found POI: \(name)")
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isFetching = false
        print("[Location] Failed to get location: \(error.localizedDescription)")
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse {
            locationManager.requestLocation()
        }
    }
}
