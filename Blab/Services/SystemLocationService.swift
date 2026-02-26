import Combine
import CoreLocation
import Foundation

@MainActor
final class SystemLocationService: NSObject, ObservableObject {
    enum ServiceError: LocalizedError {
        case servicesDisabled
        case authorizationDenied
        case authorizationRestricted
        case requestInProgress
        case locationUnavailable
        case timeout
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .servicesDisabled:
                return "系统定位服务不可用，请先在 macOS 设置中开启定位服务。"
            case .authorizationDenied:
                return "定位权限被拒绝，请在系统设置中允许 Blab 使用定位。"
            case .authorizationRestricted:
                return "当前设备限制了定位权限。"
            case .requestInProgress:
                return "正在获取定位，请稍候。"
            case .locationUnavailable:
                return "未获取到有效定位，请重试。"
            case .timeout:
                return "定位超时，请检查网络或定位权限后重试。"
            case .underlying(let error):
                return "定位失败：\(error.localizedDescription)"
            }
        }
    }

    @Published private(set) var isRequesting = false

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D, Error>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestCurrentCoordinate() async throws -> CLLocationCoordinate2D {
        guard CLLocationManager.locationServicesEnabled() else {
            throw ServiceError.servicesDisabled
        }
        guard continuation == nil else {
            throw ServiceError.requestInProgress
        }

        switch manager.authorizationStatus {
        case .denied:
            throw ServiceError.authorizationDenied
        case .restricted:
            throw ServiceError.authorizationRestricted
        case .authorizedAlways, .authorizedWhenInUse, .notDetermined:
            break
        @unknown default:
            break
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            isRequesting = true
            beginTimeoutCountdown()

            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied:
                finish(with: .failure(ServiceError.authorizationDenied))
            case .restricted:
                finish(with: .failure(ServiceError.authorizationRestricted))
            @unknown default:
                manager.requestWhenInUseAuthorization()
            }
        }
    }

    private func beginTimeoutCountdown() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.finish(with: .failure(ServiceError.timeout))
        }
    }

    private func finish(with result: Result<CLLocationCoordinate2D, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        isRequesting = false

        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

extension SystemLocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied:
            finish(with: .failure(ServiceError.authorizationDenied))
        case .restricted:
            finish(with: .failure(ServiceError.authorizationRestricted))
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else {
            finish(with: .failure(ServiceError.locationUnavailable))
            return
        }
        finish(with: .success(coordinate))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain,
           nsError.code == CLError.locationUnknown.rawValue {
            return
        }
        finish(with: .failure(ServiceError.underlying(error)))
    }
}
