import SwiftUI
import CoreLocation

// 全局主题（对齐小程序 #2f6b4f）
enum Theme {
    static let primary = Color(red: 0x2f/255.0, green: 0x6b/255.0, blue: 0x4f/255.0)
    static let excellent = Color(red: 0x2c/255.0, green: 0x9e/255.0, blue: 0x5f/255.0)
    static let bad = Color(red: 0xc0/255.0, green: 0x50/255.0, blue: 0x4d/255.0)
    static let border = Color(red: 0xe0/255.0, green: 0xe0/255.0, blue: 0xe0/255.0)
    static let listBackground = Color(red: 0.96, green: 0.96, blue: 0.97)
}

// 拍摄时间元数据（EXIF 风格，对齐小程序）
func nowTakenAt() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return f.string(from: Date())
}

// 一次性定位（对齐 wx.getLocation；iOS 为 WGS84 原始坐标）
@MainActor
final class LocationOnce: NSObject, CLLocationManagerDelegate {
    struct Result { let lat: Double; let lng: Double }
    private let manager = CLLocationManager()
    private var cont: CheckedContinuation<Result?, Never>?
    private var requested = false

    static func fetch() async -> Result? {
        guard CLLocationManager.locationServicesEnabled() else { return nil }
        let locator = LocationOnce()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                locator.cont = continuation
                locator.manager.delegate = locator
                locator.manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                if Task.isCancelled { locator.finish(nil) }
                else { locator.authorize() }
                // 硬超时兜底：授权弹窗被转场吞掉、系统回调丢失时，定位绝不能卡住保存流程
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak locator] in locator?.finish(nil) }
            }
        }, onCancel: { Task { @MainActor in locator.finish(nil) } })
    }

    private func authorize() {
        guard cont != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            if !requested { requested = true; manager.requestLocation() }
        default: finish(nil)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { authorize() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last.map { Result(lat: $0.coordinate.latitude, lng: $0.coordinate.longitude) })
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(nil) }

    private func finish(_ result: Result?) {
        let continuation = cont
        cont = nil
        manager.delegate = nil
        manager.stopUpdatingLocation()
        continuation?.resume(returning: result)
    }
}

// 远端图片加载：内存/磁盘缓存 + 后台解码（对齐原 ImageLoader；断网可用磁盘缓存展示）
@MainActor
final class RemoteImageModel {
    static let shared = RemoteImageModel()
    private let cache = NSCache<NSURL, UIImage>()

    func load(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        if let img = cache.object(forKey: url as NSURL) { return img }
        let diskImage = await Task.detached(priority: .utility) {
            if url.isFileURL { return UIImage(contentsOfFile: url.path)?.preparingForDisplay() }
            return OfflineStore.cachedImageData(for: url).flatMap(Self.decoded)
        }.value
        if let img = diskImage {
            cache.setObject(img, forKey: url as NSURL)
            return img
        }
        guard !url.isFileURL else { return nil }
        do {
            let (data, response) = try await API.session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let decoded = await Task.detached(priority: .utility) {
                OfflineStore.cacheImage(data, for: url)
                return Self.decoded(data)
            }.value
            guard let img = decoded else { return nil }
            cache.setObject(img, forKey: url as NSURL)
            return img
        } catch {
            return nil
        }
    }

    nonisolated private static func decoded(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}

// 远端图片视图：task 取图，占位符兜底（断网/404）
struct RemoteImage: View {
    let path: String?
    var cornerRadius: CGFloat = 10

    var body: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.93))
            if let img = current {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").resizable().scaledToFit().padding(14).foregroundStyle(.blue)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: path) {
            current = nil
            let image = await RemoteImageModel.shared.load(API.imageUrl(path))
            guard !Task.isCancelled else { return }
            current = image
        }
    }

    @State private var current: UIImage?
}

extension Notification.Name {
    static let myfoodDataSynced = Notification.Name("myfood.dataSynced")
}

// 轻提示（对齐原 Toast）
struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(minWidth: 120, minHeight: 36)
                    .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 80)
                    .task {
                        try? await Task.sleep(for: .seconds(1.5))
                        self.message = nil
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
    }
}

extension View {
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

// 类别/原料 chip
struct ChipView: View {
    let text: String
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.primary.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }
}

// 自适应换行 chips（类别建议/原料列表）
struct FlowChips: View {
    let items: [String]
    var action: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                ChipView(text: item) { action(item) }
            }
        }
    }
}

// 记录卡片（历史页）
struct RecordCardView: View {
    let record: DecoratedRecord

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(path: record.imagePath)
                .frame(width: 80, height: 80)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(UIColor.label))
                    .lineLimit(1)
                if !record.flavorLabels.isEmpty {
                    Text("味道：" + record.flavorLabels.joined(separator: " "))
                        .font(.system(size: 12)).foregroundStyle(Theme.primary).lineLimit(1)
                }
                if !record.ingredientLabels.isEmpty {
                    Text("材料：" + record.ingredientLabels.joined(separator: " "))
                        .font(.system(size: 12)).foregroundStyle(Theme.primary).lineLimit(1)
                }
                if record.repurchase > 0 {
                    Text("复购\(record.repurchase)次").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(record.prefColor ?? Theme.border).frame(width: 4)
        }
    }
}
