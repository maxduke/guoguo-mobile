import Flutter
import UIKit
import AVKit
import GuoguoMobile

public class GuoguoCorePlugin: NSObject, FlutterPlugin {
    private var client: MobileClient?
    private let queue = DispatchQueue(label: "guoguo.providers", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "guoguo/core", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(GuoguoCorePlugin(), channel: channel)
        registrar.register(AirPlayFactory(), withId: "guoguo/airplay")
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        queue.async { [self] in
            do {
                switch call.method {
                case "initialize":
                    guard let args = call.arguments as? [String: Any], let path = args["directory"] as? String else {
                        throw NSError(domain: "Guoguo", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少数据目录"])
                    }
                    lock.lock()
                    defer { lock.unlock() }
                    if client == nil {
                        var error: NSError?
                        client = MobileNewClient(path, &error)
                        if let error = error { throw error }
                        guard client != nil else { throw NSError(domain: "Guoguo", code: 2) }
                    }
                    DispatchQueue.main.async { result(nil) }
                case "call":
                    lock.lock()
                    let activeClient = client
                    lock.unlock()
                    guard let client = activeClient, let request = call.arguments as? String else {
                        throw NSError(domain: "Guoguo", code: 3, userInfo: [NSLocalizedDescriptionKey: "站源尚未初始化"])
                    }
                    var error: NSError?
                    let response = client.call(request, error: &error)
                    if let error = error { throw error }
                    DispatchQueue.main.async { result(response) }
                default:
                    DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
                }
            } catch {
                DispatchQueue.main.async { result(FlutterError(code: "provider", message: error.localizedDescription, details: nil)) }
            }
        }
    }
    deinit { client?.close() }
}

private class AirPlayFactory: NSObject, FlutterPlatformViewFactory {
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return AirPlayView(frame: frame)
    }
}
private class AirPlayView: NSObject, FlutterPlatformView {
    private let picker: AVRoutePickerView
    init(frame: CGRect) {
        picker = AVRoutePickerView(frame: frame)
        picker.tintColor = .white
        picker.activeTintColor = UIColor(red: 0.62, green: 0.8, blue: 0.69, alpha: 1)
        picker.prioritizesVideoDevices = true
        super.init()
    }
    func view() -> UIView { picker }
}
