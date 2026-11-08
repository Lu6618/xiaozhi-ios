//
//  Untitled.swift
//  xiaozhi
//
//  Created by Lee on 2025/11/30.
//

import CoreLocation
import Foundation
import CoreLocation
import Combine


enum LocationError: Error {
    case timeout
}

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    
    static let shared = LocationManager()
    
    private let locationManager = CLLocationManager()
    
    @Published var currentLocation: CLLocationCoordinate2D?
    @Published var currentCity: String = "成都"
    
    // 存储等待回调的 continuation 数组
    private var pendingContinuations: [CheckedContinuation<CLLocationCoordinate2D, Error>] = []
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }
    
    // 公开的请求定位方法
    func requestLocation() {
        locationManager.requestLocation()
    }
    
    // ✅ 核心修复：异步等待位置（带真实超时；旧版 timeout 参数传进来根本没用上，拿不到位置会一直挂起）
    func awaitCurrentLocation(timeout: TimeInterval = 6.0) async throws -> CLLocationCoordinate2D {
        // 1. 如果已有位置，直接返回
        if let loc = currentLocation {
            return loc
        }
        
        print(">>> 📍 位置为空，开始异步等待...")
        
        // 2. 触发系统定位
        locationManager.requestLocation()
        
        // 3. 超时保护：timeout 秒后还没拿到位置，让等待的任务抛超时错误
        // （与 delegate 回调都在主队列串行，不会重复唤醒同一个 continuation）
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self else { return }
            DispatchQueue.main.async {
                if !self.pendingContinuations.isEmpty {
                    self.pendingContinuations.forEach { $0.resume(throwing: LocationError.timeout) }
                    self.pendingContinuations.removeAll()
                }
            }
        }
        
        // 4. 挂起等待
        // 我们利用 withCheckedThrowingContinuation 来挂起当前任务
        return try await withCheckedThrowingContinuation { continuation in
            // 将 continuation 加入队列，等待 Delegate 回调唤醒
            self.pendingContinuations.append(continuation)
        }
    }
    
    // MARK: - Delegate
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        DispatchQueue.main.async {
            self.currentLocation = location.coordinate
            // print(">>> 📍 定位更新: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            
            // ✅ 唤醒所有等待的任务
            if !self.pendingContinuations.isEmpty {
                print(">>> 📍 唤醒 \(self.pendingContinuations.count) 个等待任务")
                self.pendingContinuations.forEach { $0.resume(returning: location.coordinate) }
                self.pendingContinuations.removeAll()
            }
            
            self.fetchCityName(from: location)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print(">>> ❌ 定位失败: \(error.localizedDescription)")
        
        DispatchQueue.main.async {
            // 让等待的任务抛出错误
            if !self.pendingContinuations.isEmpty {
                self.pendingContinuations.forEach { $0.resume(throwing: error) }
                self.pendingContinuations.removeAll()
            }
        }
    }
    
    private func fetchCityName(from location: CLLocation) {
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            if let city = placemarks?.first?.locality {
                DispatchQueue.main.async {
                    self?.currentCity = city
                }
            }
        }
    }
}
