import Darwin
import Foundation

enum RawPinchDirection: Hashable {
    case inward
    case outward
}

struct RawPinchDetector {
    private(set) var expectedFingerCount = 0
    private(set) var progress: Double = 0
    private var sessionPointIDs: [Int32] = []
    private var sessionStartedAt: TimeInterval = 0
    private var lastCompleteFrameAt: TimeInterval = 0
    private var largestSpread: Double = 0
    private var smallestSpread: Double = .greatestFiniteMagnitude
    private var stableFrameCount = 0
    private var triggeredDirections: Set<RawPinchDirection> = []

    private let missingFrameGrace: TimeInterval = 0.12
    private let maximumSessionDuration: TimeInterval = 2.4

    mutating func configure(fingerCount: Int) {
        expectedFingerCount = fingerCount
        resetSession()
    }

    mutating func consume(points: [(x: Double, y: Double)],
                          timestamp: TimeInterval) -> RawPinchDirection? {
        let identifiedPoints = points.enumerated().map {
            (id: Int32($0.offset), x: $0.element.x, y: $0.element.y)
        }
        return consume(identifiedPoints: identifiedPoints, timestamp: timestamp)
    }

    mutating func consume(identifiedPoints: [(id: Int32, x: Double, y: Double)],
                          timestamp: TimeInterval) -> RawPinchDirection? {
        guard expectedFingerCount > 0 else {
            resetSession()
            return nil
        }

        var selectedPoints: [(id: Int32, x: Double, y: Double)]
        if sessionPointIDs.isEmpty {
            selectedPoints = Array(
                identifiedPoints.sorted { $0.id < $1.id }.prefix(expectedFingerCount)
            )
        } else {
            let pointsByID = Dictionary(uniqueKeysWithValues: identifiedPoints.map {
                ($0.id, $0)
            })
            selectedPoints = sessionPointIDs.compactMap { pointsByID[$0] }
            // Drivers can recycle one contact ID mid-gesture. Adopt a new
            // touching contact instead of throwing away the accumulated
            // scale history; this is especially common with four fingers.
            if selectedPoints.count < expectedFingerCount {
                let selectedIDs = Set(selectedPoints.map(\.id))
                let replacements = identifiedPoints
                    .filter { !selectedIDs.contains($0.id) }
                    .sorted { $0.id < $1.id }
                selectedPoints.append(contentsOf: replacements.prefix(
                    expectedFingerCount - selectedPoints.count
                ))
                if selectedPoints.count == expectedFingerCount {
                    sessionPointIDs = selectedPoints.map(\.id)
                }
            }
        }

        guard selectedPoints.count == expectedFingerCount else {
            // Fingers normally arrive one by one and the driver can omit a
            // contact for a single frame. Keep an established gesture alive
            // briefly instead of throwing away all of its scale history.
            if !sessionPointIDs.isEmpty,
               timestamp - lastCompleteFrameAt <= missingFrameGrace {
                return nil
            }
            resetSession()
            return nil
        }

        if sessionPointIDs.isEmpty || timestamp - sessionStartedAt > maximumSessionDuration {
            resetSession()
            sessionPointIDs = selectedPoints.map(\.id)
            sessionStartedAt = timestamp
        }

        lastCompleteFrameAt = timestamp

        // Mean pairwise distance measures scale without being affected by the
        // whole hand moving across the trackpad during the pinch.
        var totalDistance = 0.0
        var pairCount = 0
        for firstIndex in 0..<(selectedPoints.count - 1) {
            for secondIndex in (firstIndex + 1)..<selectedPoints.count {
                let first = selectedPoints[firstIndex]
                let second = selectedPoints[secondIndex]
                totalDistance += hypot(first.x - second.x, first.y - second.y)
                pairCount += 1
            }
        }
        let spread = pairCount > 0 ? totalDistance / Double(pairCount) : 0

        stableFrameCount += 1
        largestSpread = max(largestSpread, spread)
        smallestSpread = min(smallestSpread, spread)
        let inwardDistance = largestSpread - spread
        let inwardRatio = largestSpread > 0.10
            ? inwardDistance / largestSpread
            : 0
        let outwardDistance = spread - smallestSpread
        let outwardRatio = smallestSpread > 0.10
            ? outwardDistance / smallestSpread
            : 0
        let triggerRatio = expectedFingerCount == 4 ? 0.075 : 0.09
        let triggerDistance = expectedFingerCount == 4 ? 0.012 : 0.016
        let inwardProgress = min(max(inwardRatio / triggerRatio, 0), 1)
        let outwardProgress = min(max(outwardRatio / triggerRatio, 0), 1)
        progress = inwardProgress >= outwardProgress ? inwardProgress : -outwardProgress

        guard stableFrameCount >= 2 else { return nil }
        if inwardRatio >= triggerRatio,
           inwardDistance >= triggerDistance,
           !triggeredDirections.contains(.inward) {
            triggeredDirections.insert(.inward)
            progress = 1
            return .inward
        }
        if outwardRatio >= triggerRatio,
           outwardDistance >= triggerDistance,
           !triggeredDirections.contains(.outward) {
            triggeredDirections.insert(.outward)
            progress = -1
            return .outward
        }
        return nil
    }

    mutating func resetSession() {
        progress = 0
        sessionPointIDs = []
        sessionStartedAt = 0
        lastCompleteFrameAt = 0
        largestSpread = 0
        smallestSpread = .greatestFiniteMagnitude
        stableFrameCount = 0
        triggeredDirections.removeAll()
    }
}

/// Observes raw trackpad contact frames for four/five-finger pinch gestures.
/// The private framework is loaded at runtime, so failure remains a graceful
/// feature fallback instead of preventing LaunchPoint from starting.
final class RawTrackpadMonitor {
    static let shared = RawTrackpadMonitor()

    private struct MTPoint {
        var x: Float
        var y: Float
    }

    private struct MTVector {
        var position: MTPoint
        var velocity: MTPoint
    }

    private struct MTTouch {
        var frame: Int32
        var timestamp: Double
        var pathIndex: Int32
        var state: UInt32
        var fingerID: Int32
        var handID: Int32
        var normalizedVector: MTVector
        var zTotal: Float
        var pressure: Float
        var angle: Float
        var majorAxis: Float
        var minorAxis: Float
        var absoluteVector: MTVector
        var field14: Int32
        var field15: Int32
        var zDensity: Float
    }

    private typealias DeviceRef = UnsafeMutableRawPointer
    private typealias ContactCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeRawPointer?, Int, Double, Int,
        UnsafeMutableRawPointer?
    ) -> Void
    private typealias CreateDefaultFunction = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias CreateListFunction = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterFunction = @convention(c) (
        UnsafeMutableRawPointer?, ContactCallback?, UnsafeMutableRawPointer?
    ) -> Void
    private typealias UnregisterFunction = @convention(c) (
        UnsafeMutableRawPointer?, ContactCallback?
    ) -> Void
    private typealias StartFunction = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias StopFunction = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias ReleaseFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private static let callback: ContactCallback = { device, rawTouches, count, _, _, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<RawTrackpadMonitor>.fromOpaque(refcon).takeUnretainedValue()
        let touches = rawTouches?.assumingMemoryBound(to: MTTouch.self)
        monitor.consume(device: device, touches: touches, count: count)
    }

    private let lock = NSLock()
    private var frameworkHandle: UnsafeMutableRawPointer?
    private var devices: [DeviceRef] = []
    private var retainedDeviceList: CFArray?
    private var ownedDefaultDevice: DeviceRef?
    private var unregisterFunction: UnregisterFunction?
    private var stopFunction: StopFunction?
    private var releaseFunction: ReleaseFunction?
    private var expectedFingerCount = 0
    private var inwardHandler: (() -> Void)?
    private var outwardHandler: (() -> Void)?
    private var contactHandler: ((Int) -> Void)?
    private var progressHandler: ((Double) -> Void)?
    private var detectors: [UInt: RawPinchDetector] = [:]
    private var lastReportedContactCount = -1
    private var lastContactReportTime: TimeInterval = 0
    private var lastReportedProgress: Double = -1
    private var refreshTimer: DispatchSourceTimer?

    private init() {}

    deinit {
        stop()
    }

    /// Returns true when the raw device callback was successfully started.
    @discardableResult
    func start(fingerCount: Int,
               onContactCount: @escaping (Int) -> Void = { _ in },
               onProgress: @escaping (Double) -> Void = { _ in },
               onPinchIn: @escaping () -> Void,
               onPinchOut: @escaping () -> Void) -> Bool {
        guard fingerCount == 4 || fingerCount == 5 else {
            stop()
            return false
        }

        lock.lock()
        if !devices.isEmpty, expectedFingerCount == fingerCount {
            inwardHandler = onPinchIn
            outwardHandler = onPinchOut
            contactHandler = onContactCount
            progressHandler = onProgress
            lock.unlock()
            return true
        }
        lock.unlock()
        stop()

        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return false }
        let createDefault: CreateDefaultFunction? = symbol("MTDeviceCreateDefault", in: handle)
        let createList: CreateListFunction? = symbol("MTDeviceCreateList", in: handle)
        guard let register: RegisterFunction = symbol(
                "MTRegisterContactFrameCallbackWithRefcon", in: handle
              ),
              let unregister: UnregisterFunction = symbol(
                "MTUnregisterContactFrameCallback", in: handle
              ),
              let startDevice: StartFunction = symbol("MTDeviceStart", in: handle),
              let stopDevice: StopFunction = symbol("MTDeviceStop", in: handle),
              let releaseDevice: ReleaseFunction = symbol("MTDeviceRelease", in: handle) else {
            dlclose(handle)
            return false
        }

        var retainedList: CFArray?
        var candidateDevices: [DeviceRef] = []
        if let list = createList?()?.takeRetainedValue() {
            retainedList = list
            let count = CFArrayGetCount(list)
            candidateDevices.reserveCapacity(count)
            for index in 0..<count {
                if let value = CFArrayGetValueAtIndex(list, index) {
                    candidateDevices.append(UnsafeMutableRawPointer(mutating: value))
                }
            }
        }

        var defaultDevice: DeviceRef?
        if candidateDevices.isEmpty, let created = createDefault?() {
            defaultDevice = created
            candidateDevices.append(created)
        }

        guard !candidateDevices.isEmpty else {
            dlclose(handle)
            return false
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var startedDevices: [DeviceRef] = []
        for device in candidateDevices {
            register(device, Self.callback, refcon)
            if startDevice(device, 0) == 0 {
                startedDevices.append(device)
            } else {
                unregister(device, Self.callback)
            }
        }
        guard !startedDevices.isEmpty else {
            if let defaultDevice { releaseDevice(defaultDevice) }
            dlclose(handle)
            return false
        }

        lock.lock()
        frameworkHandle = handle
        devices = startedDevices
        retainedDeviceList = retainedList
        ownedDefaultDevice = defaultDevice
        unregisterFunction = unregister
        stopFunction = stopDevice
        releaseFunction = releaseDevice
        expectedFingerCount = fingerCount
        inwardHandler = onPinchIn
        outwardHandler = onPinchOut
        contactHandler = onContactCount
        progressHandler = onProgress
        detectors = Dictionary(uniqueKeysWithValues: startedDevices.map { device in
            var detector = RawPinchDetector()
            detector.configure(fingerCount: fingerCount)
            return (UInt(bitPattern: device), detector)
        })
        lastReportedContactCount = -1
        lastContactReportTime = 0
        lastReportedProgress = -1
        lock.unlock()
        startDeviceRefreshTimer()
        return true
    }

    func stop() {
        refreshTimer?.cancel()
        refreshTimer = nil
        lock.lock()
        let handle = frameworkHandle
        let devices = devices
        let retainedDeviceList = retainedDeviceList
        let ownedDefaultDevice = ownedDefaultDevice
        let unregister = unregisterFunction
        let stopDevice = stopFunction
        let releaseDevice = releaseFunction
        frameworkHandle = nil
        self.devices = []
        self.retainedDeviceList = nil
        self.ownedDefaultDevice = nil
        unregisterFunction = nil
        stopFunction = nil
        releaseFunction = nil
        expectedFingerCount = 0
        inwardHandler = nil
        outwardHandler = nil
        contactHandler = nil
        progressHandler = nil
        detectors.removeAll()
        lastReportedContactCount = -1
        lastContactReportTime = 0
        lastReportedProgress = -1
        lock.unlock()

        for device in devices {
            unregister?(device, Self.callback)
            _ = stopDevice?(device)
        }
        if let ownedDefaultDevice { releaseDevice?(ownedDefaultDevice) }
        // Keep the CFArray (and its device objects) retained until every
        // callback has been unregistered and every device has stopped.
        _ = retainedDeviceList
        if let handle { dlclose(handle) }
    }

    private func startDeviceRefreshTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.refreshDevicesIfNeeded()
        }
        refreshTimer = timer
        timer.resume()
    }

    private func refreshDevicesIfNeeded() {
        lock.lock()
        guard let handle = frameworkHandle,
              let createList: CreateListFunction = symbol("MTDeviceCreateList", in: handle),
              let register: RegisterFunction = symbol(
                "MTRegisterContactFrameCallbackWithRefcon", in: handle
              ),
              let startDevice: StartFunction = symbol("MTDeviceStart", in: handle),
              let unregister = unregisterFunction,
              let stopDevice = stopFunction else {
            lock.unlock()
            return
        }
        let oldDevices = devices
        let oldIDs = Set(oldDevices.map { UInt(bitPattern: $0) })
        let fingerCount = expectedFingerCount
        lock.unlock()

        guard let newList = createList()?.takeRetainedValue() else { return }
        var newDevices: [DeviceRef] = []
        for index in 0..<CFArrayGetCount(newList) {
            if let value = CFArrayGetValueAtIndex(newList, index) {
                newDevices.append(UnsafeMutableRawPointer(mutating: value))
            }
        }
        let newIDs = Set(newDevices.map { UInt(bitPattern: $0) })
        guard oldIDs != newIDs else { return }

        let removed = oldDevices.filter { !newIDs.contains(UInt(bitPattern: $0)) }
        for device in removed {
            unregister(device, Self.callback)
            _ = stopDevice(device)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var activeDevices = newDevices.filter { oldIDs.contains(UInt(bitPattern: $0)) }
        for device in newDevices where !oldIDs.contains(UInt(bitPattern: device)) {
            register(device, Self.callback, refcon)
            if startDevice(device, 0) == 0 {
                activeDevices.append(device)
            } else {
                unregister(device, Self.callback)
            }
        }

        lock.lock()
        guard frameworkHandle == handle else {
            lock.unlock()
            for device in activeDevices where !oldIDs.contains(UInt(bitPattern: device)) {
                unregister(device, Self.callback)
                _ = stopDevice(device)
            }
            return
        }
        devices = activeDevices
        retainedDeviceList = newList
        detectors = Dictionary(uniqueKeysWithValues: activeDevices.map { device in
            let id = UInt(bitPattern: device)
            if let detector = detectors[id] { return (id, detector) }
            var detector = RawPinchDetector()
            detector.configure(fingerCount: fingerCount)
            return (id, detector)
        })
        lock.unlock()
    }

    private func consume(device: DeviceRef?,
                         touches: UnsafePointer<MTTouch>?, count: Int) {
        guard let device else { return }
        let deviceID = UInt(bitPattern: device)
        guard let touches, count > 0 else {
            lock.lock()
            detectors[deviceID]?.resetSession()
            let contactCallback = lastReportedContactCount == 0 ? nil : contactHandler
            let progressCallback = lastReportedProgress == 0 ? nil : progressHandler
            lastReportedContactCount = 0
            lastReportedProgress = 0
            lock.unlock()
            if let contactCallback { DispatchQueue.main.async { contactCallback(0) } }
            if let progressCallback { DispatchQueue.main.async { progressCallback(0) } }
            return
        }

        var points: [(id: Int32, x: Double, y: Double)] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let touch = touches[index]
            // Include BreakTouch for its final coordinate. Hovering and
            // out-of-range contacts must never participate in recognition.
            guard touch.state == 3 || touch.state == 4 || touch.state == 5 else { continue }
            points.append((touch.fingerID,
                           Double(touch.normalizedVector.position.x),
                           Double(touch.normalizedVector.position.y)))
        }

        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        var detector = detectors[deviceID] ?? {
            var detector = RawPinchDetector()
            detector.configure(fingerCount: expectedFingerCount)
            return detector
        }()
        let direction = detector.consume(identifiedPoints: points, timestamp: now)
        let progress = detector.progress
        detectors[deviceID] = detector
        let callback: (() -> Void)?
        switch direction {
        case .inward: callback = inwardHandler
        case .outward: callback = outwardHandler
        case nil: callback = nil
        }
        let shouldReportContacts = points.count != lastReportedContactCount
            || now - lastContactReportTime >= 0.10
        let contactCallback = shouldReportContacts ? contactHandler : nil
        let shouldReportProgress = abs(progress - lastReportedProgress) >= 0.04
            || direction != nil
            || now - lastContactReportTime >= 0.10
        let progressCallback = shouldReportProgress ? progressHandler : nil
        if shouldReportContacts {
            lastReportedContactCount = points.count
            lastContactReportTime = now
        }
        if shouldReportProgress { lastReportedProgress = progress }
        lock.unlock()

        if let contactCallback {
            DispatchQueue.main.async {
                contactCallback(points.count)
            }
        }
        if let progressCallback {
            DispatchQueue.main.async { progressCallback(progress) }
        }
        if let callback {
            DispatchQueue.main.async(execute: callback)
        }
    }

    private func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
