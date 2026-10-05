import AVFoundation
import AVKit
import Flutter
import UIKit

/// A separate AVKit presentation owns AirPlay. BetterPlayer remains local-only.
final class AirPlayBridge: NSObject {
    private let channel: FlutterMethodChannel
    private weak var registrar: FlutterPluginRegistrar?
    private var session: AirPlayNativeSession?
    private var routeObserver: NSObjectProtocol?
    private var routeController: UIViewController?

    static var routed: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    init(channel: FlutterMethodChannel, registrar: FlutterPluginRegistrar) {
        self.channel = channel
        self.registrar = registrar
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { result(FlutterError(code: "airplay_closed", message: "播放器已关闭", details: nil)); return }
            self.handle(call, result: result)
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if let session = self.session {
                session.routeChanged()
            } else {
                self.channel.invokeMethod("state", arguments: self.idleState)
            }
        }
    }

    private var idleState: [String: Any] {
        ["sessionId": "", "sequence": 0, "routed": Self.routed, "active": false, "closed": true]
    }

    private func presenter() -> UIViewController? {
        // Scene-based Flutter registers plugins before a view is necessarily
        // attached. Resolve the current engine's view when presenting.
        var host = registrar?.viewController
        while let presented = host?.presentedViewController { host = presented }
        guard host?.viewIfLoaded?.window != nil, host?.isBeingDismissed != true,
              host?.isBeingPresented != true else { return nil }
        return host
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        dispatchPrecondition(condition: .onQueue(.main))
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "getState":
            result(session?.snapshot() ?? idleState)
        case "showRoutes":
            guard session == nil, routeController == nil, let host = presenter() else {
                result(FlutterError(code: "airplay_busy", message: "请先关闭当前播放界面", details: nil)); return
            }
            // A real, visible public route picker. No private view traversal or
            // synthesized taps; the user chooses the phone/TV in Apple's UI.
            let controller = AirPlayRouteController()
            routeController = controller
            controller.onClose = { [weak self, weak controller] in
                guard let self, self.routeController === controller else { return }
                self.routeController = nil
                self.channel.invokeMethod("state", arguments: self.idleState)
            }
            host.present(controller, animated: true) { result(nil) }
        case "open":
            guard let id = args["sessionId"] as? String, !id.isEmpty,
                  let itemArgs = args["item"] as? [String: Any], let item = AirPlayMedia(itemArgs) else {
                result(FlutterError(code: "airplay_arguments", message: "投放视频地址无效", details: nil)); return
            }
            if let existing = session {
                if existing.id == id && !existing.closing { result(nil) }
                else { result(FlutterError(code: "airplay_busy", message: "上一次播放尚未关闭", details: nil)) }
                return
            }
            guard routeController == nil, let host = presenter() else {
                result(FlutterError(code: "airplay_unavailable", message: "无法打开系统播放器", details: nil)); return
            }
            let position = max(0, (args["positionMs"] as? NSNumber)?.int64Value ?? 0)
            let speed = (args["speed"] as? NSNumber)?.floatValue ?? 1
            guard speed.isFinite, speed > 0, speed <= 2 else {
                result(FlutterError(code: "airplay_arguments", message: "播放倍速无效", details: nil)); return
            }
            let next = AirPlayNativeSession(id: id, media: item, position: position,
                playing: args["playing"] as? Bool ?? true, speed: speed,
                emit: { [weak self] method, state in self?.channel.invokeMethod(method, arguments: state) })
            session = next
            next.didClose = { [weak self, weak next] in
                guard let self, self.session === next else { return }
                self.session = nil
            }
            next.present(from: host, completion: result)
        case "append":
            guard let id = args["sessionId"] as? String, let current = session, current.id == id, !current.closing,
                  let after = args["afterId"] as? String,
                  let itemArgs = args["item"] as? [String: Any], let item = AirPlayMedia(itemArgs) else {
                result(FlutterError(code: "airplay_session", message: "播放会话已变化", details: nil)); return
            }
            result(current.append(item, after: after))
        case "reportError":
            guard let id = args["sessionId"] as? String, let current = session, current.id == id, !current.closing,
                  let message = args["message"] as? String else {
                result(FlutterError(code: "airplay_session", message: "播放会话已变化", details: nil)); return
            }
            current.reportError(String(message.prefix(200)))
            result(nil)
        case "close":
            guard let id = args["sessionId"] as? String else {
                result(FlutterError(code: "airplay_arguments", message: "缺少播放会话", details: nil)); return
            }
            guard let current = session, current.id == id else { result(nil); return }
            current.close { result(nil) }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    func shutdown() {
        channel.setMethodCallHandler(nil)
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        routeController?.dismiss(animated: false)
        routeController = nil
        session?.close(animated: false) {}
    }
}

private struct AirPlayMedia {
    let id: String
    let url: URL
    let title: String
    let hasNext: Bool
    init?(_ args: [String: Any]) {
        guard let id = args["id"] as? String, !id.isEmpty,
              let address = args["url"] as? String, let url = URL(string: address),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              host != "localhost", host != "::1", host != "[::1]", !host.hasPrefix("127.") else { return nil }
        self.id = id
        self.url = url
        title = args["title"] as? String ?? "视频"
        hasNext = args["hasNext"] as? Bool ?? true
    }
}

private final class AirPlayNavigationController: UINavigationController {
    var disappeared: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil { disappeared?() }
    }
}

private final class AirPlayRouteController: UIViewController {
    var onClose: (() -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let message = UILabel()
        message.text = "点按下方投放按钮，选择 iPhone 后返回手机播放。"
        message.numberOfLines = 0
        message.textAlignment = .center
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let close = UIButton(type: .system)
        close.setTitle("完成", for: .normal)
        close.addTarget(self, action: #selector(done), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [message, picker, close])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
    @objc private func done() { dismiss(animated: true) }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil { onClose?() }
    }
}

private final class AirPlayNativeSession: NSObject {
    let id: String
    private(set) var closing = false
    var didClose: (() -> Void)?
    private let emit: (String, [String: Any]) -> Void
    private var player = AVQueuePlayer()
    private let controller: AVPlayerViewController
    private let navigation: AirPlayNavigationController
    private let errorLabel = UILabel()
    private var nextButton: UIBarButtonItem?
    private var queue: AirPlayQueueState
    private var firstID: String
    private var failedItemID: String?
    private var rejectedItemID: String?
    private var currentFailed = false
    private var retryPlaying = false
    private var retryButton: UIBarButtonItem?
    private var lastCurrent: ObjectIdentifier?
    private weak var readyHandledItem: AVPlayerItem?
    private var records: [ObjectIdentifier: (AVPlayerItem, AirPlayMedia)] = [:]
    private var itemObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var connectionDeadline: Timer?
    private var deadlineItem: ObjectIdentifier?
    private var initialPosition: Int64?
    private var seeking = false
    private var presented = false
    private var ownsLocalExclusion = false
    private var presentationStarted = false
    private var dismissing = false
    private var closed = false
    private var closeCompletions: [() -> Void] = []
    private var sequence: Int64 = 0
    private var positionMs: Int64 = 0
    private var durationMs: Int64 = 0
    private var error: String?
    private let speed: Float

    init(id: String, media: AirPlayMedia, position: Int64, playing: Bool, speed: Float,
         emit: @escaping (String, [String: Any]) -> Void) {
        self.id = id
        self.emit = emit
        self.speed = speed
        queue = AirPlayQueueState(id: media.id, playing: playing)
        firstID = media.id
        initialPosition = position
        positionMs = position
        let videoController = AVPlayerViewController()
        controller = videoController
        navigation = AirPlayNavigationController(rootViewController: videoController)
        super.init()
        player.allowsExternalPlayback = true
        player.actionAtItemEnd = .advance
        controller.updatesNowPlayingInfoCenter = false
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        navigation.modalPresentationStyle = .fullScreen
        controller.title = media.title
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(done))
        let picker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.prioritizesVideoDevices = true
        let next = UIBarButtonItem(title: "下一集", style: .plain, target: self, action: #selector(nextEpisode))
        next.isEnabled = media.hasNext
        nextButton = next
        controller.navigationItem.rightBarButtonItems = [next, UIBarButtonItem(customView: picker)]
        navigation.disappeared = { [weak self] in self?.close(animated: false) {} }
        installObservers()
        let first = makeItem(media)
        player.insert(first, after: nil)
    }

    func present(from host: UIViewController, completion: @escaping FlutterResult) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            close(animated: false) {}
            completion(FlutterError(code: "airplay_audio", message: "无法启用系统播放器音频", details: nil))
            return
        }
        ownsLocalExclusion = true
        NotificationCenter.default.post(name: Notification.Name("guoguoAirPlaySessionDidBegin"), object: nil)
        controller.updatesNowPlayingInfoCenter = true
        presentationStarted = true
        host.present(navigation, animated: true) { [weak self] in
            guard let self else { return }
            self.presented = true
            if self.closing {
                self.finishDismissal(animated: false)
                completion(FlutterError(code: "airplay_closed", message: "播放已取消", details: nil))
                return
            }
            self.installErrorLabel()
            self.ready(self.player.currentItem)
            self.sendState()
            completion(nil)
        }
    }

    private func installErrorLabel() {
        guard let overlay = controller.contentOverlayView else { return }
        errorLabel.numberOfLines = 0
        errorLabel.textColor = .white
        errorLabel.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        errorLabel.textAlignment = .center
        errorLabel.text = error
        errorLabel.isHidden = error == nil
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.leadingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            errorLabel.centerYAnchor.constraint(equalTo: overlay.centerYAnchor)
        ])
    }

    private func makeItem(_ media: AirPlayMedia) -> AVPlayerItem {
        let item = AVPlayerItem(url: media.url)
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = media.title as NSString
        title.extendedLanguageTag = "und"
        item.externalMetadata = [title]
        let key = ObjectIdentifier(item)
        records[key] = (item, media)
        itemObservations[key] = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, !self.closing, let item, self.records[ObjectIdentifier(item)] != nil else { return }
                self.ready(item)
            }
        }
        return item
    }

    private func installObservers() {
        observations.append(player.observe(\.status, options: [.new]) { [weak self] observed, _ in
            DispatchQueue.main.async { [weak self, weak observed] in
                guard let self, let observed, self.player === observed, !self.closing,
                      observed.status == .failed,
                      let item = observed.currentItem ?? self.records.values.first(where: { $0.1.id == self.queue.currentID })?.0 else { return }
                self.itemFailed(item, stage: "player.status", underlying: observed.error as NSError?)
            }
        })
        observations.append(player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.currentChanged() }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let item = player.currentItem
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                self.playbackChanged()
            }
        })
        observations.append(player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.routeChanged() }
        })
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let self, !self.closing, let item = notification.object as? AVPlayerItem,
                  let record = self.records[ObjectIdentifier(item)] else { return }
            if self.queue.finished(record.1.id) {
                self.positionMs = self.milliseconds(item.currentTime())
                self.durationMs = self.milliseconds(item.duration)
                if self.durationMs > 0 { self.positionMs = self.durationMs }
            }
            // AVQueuePlayer advances itself; never double-advance from this
            // notification, which may arrive before or after currentItem KVO.
            self.currentChanged()
        }
        failedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let self, !self.closing, let item = notification.object as? AVPlayerItem,
                  self.records[ObjectIdentifier(item)] != nil else { return }
            self.itemFailed(item, stage: "item.end", underlying: notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            guard let self, !self.closing else { return }
            self.capturePosition()
            self.confirmHandoff()
            self.checkConnection()
            self.sendState()
        }
    }

    private func ready(_ item: AVPlayerItem?) {
        guard !closing, let item else { return }
        if item.status == .failed { itemFailed(item, stage: "item.load", underlying: item.error as NSError?); return }
        guard presented, player.currentItem === item else { return }
        guard item.status == .readyToPlay else { return }
        if let requested = initialPosition {
            guard !seeking else { return }
            seeking = true
            let duration = milliseconds(item.duration)
            let target = duration > 0 ? min(requested, duration) : requested
            player.seek(to: CMTime(value: target, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] finished in
                DispatchQueue.main.async {
                    guard let self, !self.closing, let item, self.player.currentItem === item else { return }
                    self.seeking = false
                    self.initialPosition = nil
                    if !finished { self.fail("无法恢复视频进度，请关闭后重试"); return }
                    self.capturePosition()
                    self.startIfIntended()
                    self.sendState()
                }
            }
        } else {
            startIfIntended()
        }
    }

    private func currentChanged() {
        guard !closing else { return }
        if let current = player.currentItem, let record = records[ObjectIdentifier(current)] {
            let changed = lastCurrent != ObjectIdentifier(current)
            lastCurrent = ObjectIdentifier(current)
            if record.1.id != firstID {
                initialPosition = nil
                seeking = false
            }
            if record.1.id != queue.currentID {
                queue.becameCurrent(record.1.id)
                clearItemFailure()
                positionMs = 0
                durationMs = 0
                error = nil
                errorLabel.isHidden = true
                controller.navigationItem.prompt = nil
                cancelConnectionDeadline()
            }
            controller.title = record.1.title
            nextButton?.isEnabled = record.1.hasNext
            if changed { ready(current) }
        }
        releaseDetachedItems()
        capturePosition()
        checkConnection()
        sendState()
    }

    private func releaseDetachedItems() {
        let retained = Set(player.items().map { ObjectIdentifier($0) })
        for key in Array(records.keys) where !retained.contains(key) {
            guard let record = records[key] else { continue }
            // Current identity survives an empty queue at EOF. Keep every
            // outgoing URL until the latest successor advances on the TV;
            // rapid Next taps may promote another item before the first handoff.
            if record.1.id == queue.currentID || queue.outgoingIDs.contains(record.1.id) { continue }
            if record.1.id == queue.nextID {
                // AVFoundation may remove a failed queued item before its
                // status callback reaches main. Reconcile the slot before
                // invalidating observers, or that callback would be lost.
                itemFailed(record.0, stage: "queue.removed", underlying: record.0.error as NSError?)
                continue
            }
            discardItem(record.0)
        }
    }

    private func discardItem(_ item: AVPlayerItem) {
        let key = ObjectIdentifier(item)
        itemObservations.removeValue(forKey: key)?.invalidate()
        item.cancelPendingSeeks()
        item.asset.cancelLoading()
        records.removeValue(forKey: key)
    }

    private func confirmHandoff() {
        guard let current = player.currentItem, let record = records[ObjectIdentifier(current)],
              player.timeControlStatus == .playing,
              !AirPlayBridge.routed || player.isExternalPlaybackActive else { return }
        queue.confirmedPlayback(record.1.id, advanced: milliseconds(current.currentTime()) > 0)
        releaseDetachedItems()
    }

    private func itemFailed(_ item: AVPlayerItem, stage: String, underlying: NSError?) {
        guard !closing, let record = records[ObjectIdentifier(item)] else { return }
        if player.currentItem === item && record.1.id != queue.currentID {
            // Failure KVO may beat promotion KVO. Commit the transition before
            // pausing so it cannot erase the failed item's retry/play intent.
            currentChanged()
        }
        let message = "视频播放失败（\(stage)/\(AirPlayFailure.code(underlying))）。"
        if player.currentItem === item || record.1.id == queue.currentID {
            if !currentFailed { retryPlaying = queue.wantsPlayback }
            currentFailed = true
            failedItemID = record.1.id
            if retryButton == nil {
                let button = UIBarButtonItem(title: "重试本集", style: .plain, target: self, action: #selector(retryCurrent))
                retryButton = button
                controller.navigationItem.rightBarButtonItems?.insert(button, at: 0)
            }
            fail(message + "请点重试本集；若仍失败请重新选择电视。")
        } else if queue.rejectNext(record.1.id) {
            rejectedItemID = record.1.id
            player.remove(item)
            discardItem(item)
            if currentFailed { sendState() }
            else { reportError(message + "下一集未就绪，请点下一集重试。") }
        }
    }

    private func clearItemFailure() {
        currentFailed = false
        failedItemID = nil
        rejectedItemID = nil
        if let retryButton {
            controller.navigationItem.rightBarButtonItems?.removeAll { $0 === retryButton }
        }
        retryButton = nil
    }

    @objc private func retryCurrent() {
        guard !closing, currentFailed,
              let media = records.values.first(where: { $0.1.id == queue.currentID })?.1 else { return }
        capturePosition()
        let resume = positionMs
        let next = records.values.first(where: { $0.1.id == queue.nextID })?.1
        // AVPlayer's failed status is terminal. A new queue is required; simply
        // reinserting an item into the failed player cannot recover playback.
        stopObserving()
        player.pause()
        player.removeAllItems()
        for record in Array(records.values) { discardItem(record.0) }
        player = AVQueuePlayer()
        player.allowsExternalPlayback = true
        player.actionAtItemEnd = .advance
        controller.player = player
        queue.retryCurrent(playing: retryPlaying)
        firstID = media.id
        initialPosition = resume
        seeking = false
        lastCurrent = nil
        readyHandledItem = nil
        clearItemFailure()
        error = nil
        errorLabel.isHidden = true
        controller.navigationItem.prompt = nil
        installObservers()
        player.insert(makeItem(media), after: nil)
        if let next { player.insert(makeItem(next), after: nil) }
        currentChanged()
    }

    private func playbackChanged() {
        guard !closing, presented, initialPosition == nil, !seeking,
              let item = player.currentItem, item.status == .readyToPlay else { return }
        if lastCurrent != ObjectIdentifier(item) || records[ObjectIdentifier(item)]?.1.id != queue.currentID {
            currentChanged()
            return
        }
        // A new queue item can report paused/ready before its status callback
        // reaches main. Apply retained intent once before treating zero rate as
        // a user pause; otherwise a late successor would remain paused at zero.
        if readyHandledItem !== item {
            ready(item)
            return
        }
        if player.timeControlStatus == .playing {
            queue.wantsPlayback = true
            error = nil
            errorLabel.isHidden = true
            controller.navigationItem.prompt = nil
        } else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            queue.wantsPlayback = true
        } else if player.timeControlStatus == .paused && !queue.ended && !reachedEnd(item) {
            queue.wantsPlayback = false
        }
        capturePosition()
        checkConnection()
        sendState()
    }

    private func startIfIntended() {
        guard !closing, presented, initialPosition == nil, !seeking,
              let current = player.currentItem,
              records[ObjectIdentifier(current)]?.1.id == queue.currentID,
              current.status == .readyToPlay, !queue.ended else { return }
        readyHandledItem = current
        if queue.wantsPlayback {
            if #available(iOS 16.0, *) { player.defaultRate = speed }
            if player.rate == 0 { player.playImmediately(atRate: speed) }
        } else {
            player.pause()
        }
        checkConnection()
    }

    func append(_ media: AirPlayMedia, after: String) -> FlutterError? {
        currentChanged()
        guard player.status != .failed else {
            return FlutterError(code: "airplay_player_failed", message: "请先重试本集", details: nil)
        }
        let previousQueue = queue
        switch queue.append(id: media.id, after: after) {
        case .duplicate: return nil
        case .stale: return FlutterError(code: "airplay_stale", message: "当前分集已变化", details: nil)
        case .full: return FlutterError(code: "airplay_queue_full", message: "下一集已准备好", details: nil)
        case .queued, .advance: break
        }
        rejectedItemID = nil
        if !currentFailed {
            failedItemID = nil
            error = nil
            errorLabel.isHidden = true
            controller.navigationItem.prompt = nil
        }
        let item = makeItem(media)
        // A nil predecessor appends to the queue without retaining an item
        // that AVFoundation could remove concurrently at its natural end.
        guard player.canInsert(item, after: nil) else {
            queue = previousQueue
            discardItem(item)
            return FlutterError(code: "airplay_queue", message: "无法加入下一集，请重试", details: nil)
        }
        // Inserting into an empty queue makes the late successor current.
        player.insert(item, after: nil)
        if queue.advanceRequested, player.currentItem !== item {
            capturePosition()
            player.advanceToNextItem()
        }
        currentChanged()
        return nil
    }

    @objc private func nextEpisode() {
        guard !closing else { return }
        currentChanged()
        guard nextButton?.isEnabled == true else { return }
        // Manual Next after a terminal player error must rebuild the player
        // before either advancing its queued item or accepting a late append.
        if player.status == .failed { retryCurrent() }
        else if currentFailed { queue.wantsPlayback = retryPlaying }
        queue.requestNext()
        if queue.nextID != nil {
            capturePosition()
            player.advanceToNextItem()
            currentChanged()
        } else {
            emit("requestNext", ["sessionId": id, "afterId": queue.currentID])
            sendState()
        }
    }

    @objc private func done() { close {} }

    func routeChanged() {
        guard !closing else { return }
        checkConnection()
        sendState()
    }

    private func checkConnection() {
        guard !closing, AirPlayBridge.routed, !player.isExternalPlaybackActive,
              queue.wantsPlayback, let item = player.currentItem else {
            cancelConnectionDeadline()
            return
        }
        let identity = ObjectIdentifier(item)
        guard deadlineItem != identity else { return }
        cancelConnectionDeadline()
        deadlineItem = identity
        connectionDeadline = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self, weak item] _ in
            guard let self, !self.closing, let item, self.player.currentItem === item,
                  self.queue.wantsPlayback, AirPlayBridge.routed, !self.player.isExternalPlaybackActive else { return }
            self.fail("电视未接管视频（route.video_timeout）。请重新选择电视，再点播放重试。")
        }
    }

    private func cancelConnectionDeadline() {
        connectionDeadline?.invalidate()
        connectionDeadline = nil
        deadlineItem = nil
    }

    func reportError(_ message: String) {
        guard !closing else { return }
        // Preparation of the successor must not interrupt a valid current item.
        error = message
        errorLabel.text = message
        errorLabel.isHidden = false
        controller.navigationItem.prompt = message
        sendState()
    }

    private func fail(_ message: String) {
        queue.wantsPlayback = false
        player.pause()
        cancelConnectionDeadline()
        error = message
        errorLabel.text = message
        errorLabel.isHidden = false
        controller.navigationItem.prompt = message
        sendState()
    }

    private func milliseconds(_ time: CMTime) -> Int64 {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(min(seconds * 1000, Double(Int64.max - 1024)))
    }

    private func reachedEnd(_ item: AVPlayerItem) -> Bool {
        let duration = milliseconds(item.duration)
        return duration > 0 && milliseconds(item.currentTime()) >= duration
    }

    private func capturePosition() {
        let last = records.values.first { $0.1.id == queue.currentID }
        guard let item = player.currentItem ?? last?.0,
              let record = records[ObjectIdentifier(item)] else { return }
        // Only currentChanged commits identity/promotion and its lifecycle.
        // A snapshot must not silently consume the transition before KVO.
        guard record.1.id == queue.currentID else { return }
        if initialPosition == nil { positionMs = milliseconds(item.currentTime()) }
        let duration = milliseconds(item.duration)
        if duration > 0 { durationMs = duration }
    }

    func snapshot() -> [String: Any] {
        capturePosition()
        var state: [String: Any] = [
            "sessionId": id, "sequence": sequence, "itemId": queue.currentID,
            "positionMs": positionMs, "durationMs": durationMs,
            "playing": queue.wantsPlayback && !queue.ended,
            "active": !closed && player.isExternalPlaybackActive,
            "routed": AirPlayBridge.routed, "ended": queue.ended, "closed": closed,
            "needsNext": !closing && queue.needsNext,
            "retainedItemIds": records.values.map { $0.1.id }
        ]
        if let error { state["error"] = error }
        if let failedItemID { state["failedItemId"] = failedItemID }
        if let rejectedItemID { state["rejectedItemId"] = rejectedItemID }
        return state
    }

    private func sendState() {
        sequence += 1
        emit("state", snapshot())
    }

    private func stopObserving() {
        cancelConnectionDeadline()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        itemObservations.values.forEach { $0.invalidate() }
        itemObservations.removeAll()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        endObserver = nil
        failedObserver = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    func close(animated: Bool = true, completion: @escaping () -> Void) {
        if closed { completion(); return }
        closeCompletions.append(completion)
        if closing { return }
        closing = true
        capturePosition()
        cancelConnectionDeadline()
        stopObserving()
        player.pause()
        let oldItems = records.values.map { $0.0 }
        oldItems.forEach { $0.cancelPendingSeeks() }
        player.removeAllItems()
        oldItems.forEach { $0.asset.cancelLoading() }
        records.removeAll()
        controller.updatesNowPlayingInfoCenter = false
        controller.player = nil
        if ownsLocalExclusion {
            ownsLocalExclusion = false
            NotificationCenter.default.post(name: Notification.Name("guoguoAirPlaySessionDidEnd"), object: nil)
        }
        navigation.disappeared = nil
        // If presentation is in flight, its completion finishes dismissal.
        if presented || !presentationStarted {
            finishDismissal(animated: animated)
        }
    }

    private func finishDismissal(animated: Bool) {
        guard !dismissing, !closed else { return }
        dismissing = true
        let finish: () -> Void = { [self] in
            closed = true
            sendState()
            didClose?()
            didClose = nil
            let completions = closeCompletions
            closeCompletions.removeAll()
            completions.forEach { $0() }
        }
        if navigation.presentingViewController != nil {
            navigation.dismiss(animated: animated, completion: finish)
        } else {
            finish()
        }
    }
}
