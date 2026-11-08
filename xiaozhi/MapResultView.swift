//
//  MapResultView.swift
//  xiaozhi
//
//  Created by Lee on 2025/11/30.
//

// 文件: MapResultView.swift

import SwiftUI
import MapKit

struct MapResultView: View {
    // 接收参数：可能是点列表，也可能是路线
    let pois: [AmapPOI]?
    let route: AmapRoute?
    
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                // 1. 地图层 (使用 UIKit 封装)
                MapViewWrapper(pois: pois ?? [], routePolyline: route?.polyline)
                    .ignoresSafeArea(edges: .bottom)
                
                // 2. 底部信息卡片
                VStack {
                    // 情况A：显示路线信息
                    if let route = route {
                        VStack(alignment: .leading, spacing: 8) {
                            // ✅ 修改：美化起点名称
                            let displayOrigin = isCoordinate(route.originName) ? "我的位置" : route.originName
                            Text("\(displayOrigin) ➔ \(route.destName)")
                                .font(.headline)
                            HStack {
                                Label("\(route.duration)分钟", systemImage: "clock")
                                    .foregroundColor(.blue)
                                Spacer()
                                Label("\(route.distance)公里", systemImage: "car")
                                    .foregroundColor(.gray)
                            }
                            
                            Button(action: {
                                // 优先高德地图导航（按名字规划路线），未装高德时回退 Apple Maps
                                AmapNavigationService.openRouteToName(route.destName)
                            }) {
                                Text("开始导航")
                                    .bold()
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                            }
                        }
                        .padding()
                        .background(Color.white)
                        .cornerRadius(16)
                        .shadow(radius: 10)
                        .padding()
                    }
                    
                    // 情况B：显示 POI 列表 (左右滑动)
                    else if let pois = pois, !pois.isEmpty {
                        TabView {
                            ForEach(pois) { poi in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(poi.name).font(.headline)
                                        Text(poi.address).font(.caption).foregroundColor(.gray)
                                    }
                                    Spacer()
                                    Button(action: {
                                        // 优先高德地图导航（有坐标直接开始导航），未装高德时回退 Apple Maps
                                        AmapNavigationService.openPOINavigation(poi: poi)
                                    }) {
                                        Image(systemName: "car.fill")
                                            .padding()
                                            .background(Color.blue)
                                            .foregroundColor(.white)
                                            .clipShape(Circle())
                                    }
                                }
                                .padding()
                                .background(Color.white)
                                .cornerRadius(16)
                                .padding()
                            }
                        }
                        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                        .frame(height: 140)
                    }
                }
            }
            .navigationTitle(route != nil ? "路线规划" : "周边搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("关闭") { dismiss() }
            }
        }
    }
    
    // 判断字符串是否看起来像坐标
    func isCoordinate(_ str: String) -> Bool {
        return str.contains(",") && str.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: "").allSatisfy({ $0.isNumber })
    }
}

// MARK: - MapKit 封装 (支持画线)
struct MapViewWrapper: UIViewRepresentable {
    let pois: [AmapPOI]
    let routePolyline: String?
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true // 显示蓝点
        return mapView
    }
    
    func updateUIView(_ view: MKMapView, context: Context) {
        // 清理旧的
        view.removeAnnotations(view.annotations)
        view.removeOverlays(view.overlays)
        
        // 1. 画点 (POI)
        if !pois.isEmpty {
            for poi in pois {
                let ann = MKPointAnnotation()
                ann.coordinate = poi.coordinate
                ann.title = poi.name
                view.addAnnotation(ann)
            }
            // 聚焦到第一个点
            if let first = pois.first {
                let region = MKCoordinateRegion(center: first.coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000)
                view.setRegion(region, animated: true)
            }
        }
        
        // 2. 画线 (Route)
        if let polyStr = routePolyline {
            let coords = parsePolyline(polyStr)
            if !coords.isEmpty {
                let polyline = MKPolyline(coordinates: coords, count: coords.count)
                view.addOverlay(polyline)
                
                // 自动缩放以显示全路线
                let rect = polyline.boundingMapRect
                view.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 50, left: 50, bottom: 200, right: 50), animated: true)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        // 渲染线条颜色
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 6
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
    
    // 解析高德坐标串 "104.1,30.1;104.2,30.2"
    private func parsePolyline(_ str: String) -> [CLLocationCoordinate2D] {
        var coords: [CLLocationCoordinate2D] = []
        let points = str.split(separator: ";")
        for p in points {
            let parts = p.split(separator: ",")
            if parts.count == 2, let lon = Double(parts[0]), let lat = Double(parts[1]) {
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
        return coords
    }
}
