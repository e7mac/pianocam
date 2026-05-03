//
//  ViewController.swift
//  samplecamera
//
//  Created by laurent denoue on 7/1/22.
//

import AVFoundation
import Cocoa
import Combine
import CoreImage
import CoreMediaIO
import SwiftUI
import SystemExtensions

class ViewController: NSViewController {

    private var needToStream: Bool = false
    private var mirrorCamera: Bool { hostState.mirrorCamera }
    private var image = NSImage(named: "cham-index")  // legacy fallback
    private var activating: Bool = false
    private let cameraCapture = CameraCapture()
    private var latestCameraFrame: CVPixelBuffer?
    private let frameLock = NSLock()
    private let pianoState = PianoState()
    private let midiInput = MIDIInput()
    private let previewLayer = AVSampleBufferDisplayLayer()
    private let hostState = HostState()
    private let audioDetector = AudioPitchDetector()
    private var readyToEnqueue = false
    private var enqueued = false
    private var _videoDescription: CMFormatDescription!
    private var _bufferPool: CVPixelBufferPool!
    private var _bufferAuxAttributes: NSDictionary!
    private var _whiteStripeStartRow: UInt32 = 0
    private var _whiteStripeIsAscending: Bool = false
    private var overlayMessage: Bool = false
    private var sequenceNumber = 0
    private var timer: Timer?
    private var propTimer: Timer?

    func activateCamera() {
        guard let extensionIdentifier = ViewController._extensionBundle().bundleIdentifier else {
            return
        }
        self.activating = true
        hostState.extensionStatus = .activating
        let activationRequest = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        activationRequest.delegate = self
        OSSystemExtensionManager.shared.submitRequest(activationRequest)
    }
    
    func deactivateCamera() {
        guard let extensionIdentifier = ViewController._extensionBundle().bundleIdentifier else {
            return
        }
        self.activating = false
        let deactivationRequest = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        deactivationRequest.delegate = self
        OSSystemExtensionManager.shared.submitRequest(deactivationRequest)
    }
    
    private class func _extensionBundle() -> Bundle {
        let extensionsDirectoryURL = URL(fileURLWithPath: "Contents/Library/SystemExtensions", relativeTo: Bundle.main.bundleURL)
        let extensionURLs: [URL]
        do {
            extensionURLs = try FileManager.default.contentsOfDirectory(at: extensionsDirectoryURL,
                                                                        includingPropertiesForKeys: nil,
                                                                        options: .skipsHiddenFiles)
        } catch let error {
            fatalError("Failed to get the contents of \(extensionsDirectoryURL.absoluteString): \(error.localizedDescription)")
        }
        
        guard let extensionURL = extensionURLs.first else {
            fatalError("Failed to find any system extensions")
        }
        guard let extensionBundle = Bundle(url: extensionURL) else {
            fatalError("Failed to find any system extensions")
        }
        return extensionBundle
    }
    
    func getJustProperty(streamId: CMIOStreamID) -> String? {
        let selector = FourCharCode("just")
        var address = CMIOObjectPropertyAddress(selector, .global, .main)
        let exists = CMIOObjectHasProperty(streamId, &address)
        if exists {
            var dataSize: UInt32 = 0
            var dataUsed: UInt32 = 0
            CMIOObjectGetPropertyDataSize(streamId, &address, 0, nil, &dataSize)
            var name: CFString = "" as NSString
            CMIOObjectGetPropertyData(streamId, &address, 0, nil, dataSize, &dataUsed, &name);
            return name as String
        } else {
            return nil
        }
    }

    func setJustProperty(streamId: CMIOStreamID, newValue: String) {
        let selector = FourCharCode("just")
        var address = CMIOObjectPropertyAddress(selector, .global, .main)
        let exists = CMIOObjectHasProperty(streamId, &address)
        if exists {
            var settable: DarwinBoolean = false
            CMIOObjectIsPropertySettable(streamId,&address,&settable)
            if settable == false {
                return
            }
            var dataSize: UInt32 = 0
            CMIOObjectGetPropertyDataSize(streamId, &address, 0, nil, &dataSize)
            var newName: CFString = newValue as NSString
            CMIOObjectSetPropertyData(streamId, &address, 0, nil, dataSize, &newName)
        }
    }

    func makeDevicesVisible(){
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow : UInt32 = 1
        let dataSize : UInt32 = 4
        let zero : UInt32 = 0
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, zero, nil, dataSize, &allow)
    }

    var sourceStream: CMIOStreamID?
    var sinkStream: CMIOStreamID?
    var sinkQueue: CMSimpleQueue?
    
    func initSink(deviceId: CMIODeviceID, sinkStream: CMIOStreamID) {
        let dims = CMVideoDimensions(width: fixedCamWidth, height: fixedCamHeight)
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: dims.width, height: dims.height, extensions: nil, formatDescriptionOut: &_videoDescription)
        
        var pixelBufferAttributes: NSDictionary!
           pixelBufferAttributes = [
                kCVPixelBufferWidthKey: dims.width,
                kCVPixelBufferHeightKey: dims.height,
                kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
        
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &_bufferPool)

        let pointerQueue = UnsafeMutablePointer<Unmanaged<CMSimpleQueue>?>.allocate(capacity: 1)
        // see https://stackoverflow.com/questions/53065186/crash-when-accessing-refconunsafemutablerawpointer-inside-cgeventtap-callback
        //let pointerRef = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())
        let pointerRef = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let result = CMIOStreamCopyBufferQueue(sinkStream, {
            (sinkStream: CMIOStreamID, buf: UnsafeMutableRawPointer?, refcon: UnsafeMutableRawPointer?) in
            let sender = Unmanaged<ViewController>.fromOpaque(refcon!).takeUnretainedValue()
            sender.readyToEnqueue = true
        },pointerRef,pointerQueue)
        if result != 0 {
            showMessage("error starting sink")
        } else {
            if let queue = pointerQueue.pointee {
                self.sinkQueue = queue.takeUnretainedValue()
            }
            let resultStart = CMIODeviceStartStream(deviceId, sinkStream) == 0
            if resultStart {
                showMessage("initSink started")
            } else {
                showMessage("initSink error startstream")
            }
        }
    }

    func getDevice(name: String) -> AVCaptureDevice? {
        print("getDevice name=", name)
        // Cover modern + legacy device-type names, and fall back to the
        // (deprecated) all-video API which lists virtual cameras regardless.
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .externalUnknown]
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.continuityCamera)
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                         mediaType: .video,
                                                         position: .unspecified)
        var devices: [AVCaptureDevice] = discovery.devices
        // Fallback for completeness — picks up virtual cameras that
        // discovery sometimes misses.
        let extra = AVCaptureDevice.devices(for: .video)
        for d in extra where !devices.contains(where: { $0.uniqueID == d.uniqueID }) {
            devices.append(d)
        }
        print("  candidates: \(devices.map { $0.localizedName })")
        return devices.first { $0.localizedName == name }
    }

    func getCMIODevice(uid: String) -> CMIOObjectID? {
        var dataSize: UInt32 = 0
        var devices = [CMIOObjectID]()
        var dataUsed: UInt32 = 0
        var opa = CMIOObjectPropertyAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices), .global, .main)
        CMIOObjectGetPropertyDataSize(CMIOObjectPropertySelector(kCMIOObjectSystemObject), &opa, 0, nil, &dataSize);
        let nDevices = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        devices = [CMIOObjectID](repeating: 0, count: Int(nDevices))
        CMIOObjectGetPropertyData(CMIOObjectPropertySelector(kCMIOObjectSystemObject), &opa, 0, nil, dataSize, &dataUsed, &devices);
        for deviceObjectID in devices {
            opa.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)
            CMIOObjectGetPropertyDataSize(deviceObjectID, &opa, 0, nil, &dataSize)
            var name: CFString = "" as NSString
            //CMIOObjectGetPropertyData(deviceObjectID, &opa, 0, nil, UInt32(MemoryLayout<CFString>.size), &dataSize, &name);
            CMIOObjectGetPropertyData(deviceObjectID, &opa, 0, nil, dataSize, &dataUsed, &name);
            if String(name) == uid {
                return deviceObjectID
            }
        }
        return nil
    }

    func getInputStreams(deviceId: CMIODeviceID) -> [CMIOStreamID]
    {
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        var opa = CMIOObjectPropertyAddress(CMIOObjectPropertySelector(kCMIODevicePropertyStreams), .global, .main)
        CMIOObjectGetPropertyDataSize(deviceId, &opa, 0, nil, &dataSize);
        let numberStreams = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streamIds = [CMIOStreamID](repeating: 0, count: numberStreams)
        CMIOObjectGetPropertyData(deviceId, &opa, 0, nil, dataSize, &dataUsed, &streamIds)
        return streamIds
    }
    func connectToCamera() {
        if let device = getDevice(name: cameraName), let deviceObjectId = getCMIODevice(uid: device.uniqueID) {
            let streamIds = getInputStreams(deviceId: deviceObjectId)
            if streamIds.count == 2 {
                sinkStream = streamIds[1]
                showMessage("found sink stream")
                initSink(deviceId: deviceObjectId, sinkStream: streamIds[1])
            }
            if let firstStream = streamIds.first {
                showMessage("found source stream")
                sourceStream = firstStream
            }
        }
    }
    
    @objc func activate(_ sender: Any? = nil) {
        activateCamera()
    }

    @objc func deactivate(_ sender: Any? = nil) {
        deactivateCamera()
    }

    @objc func reconnect(_ sender: Any? = nil) {
        sourceStream = nil
        sinkStream = nil
        sinkQueue = nil
        showMessage("retrying connection…")
        connectToCamera()
    }

    private var audioObservers: [AnyCancellable] = []
    private var bpSettingsObservers: [AnyCancellable] = []

    private func toggleAudio(_ on: Bool) {
        if on {
            audioDetector.onEvent = { [weak self] event in
                DispatchQueue.main.async {
                    self?.pianoState.handle(event)
                }
            }
            let chosen = hostState.audioInputs.first { $0.uniqueID == hostState.selectedAudioInputID }
            audioDetector.start(device: chosen)
            hostState.audioEnabled = true
            audioObservers = [
                audioDetector.$state.receive(on: DispatchQueue.main).sink { [weak self] s in
                    self?.hostState.audioStatus = Self.audioStatusText(for: s)
                },
                audioDetector.$inputLevel.receive(on: DispatchQueue.main).sink { [weak self] l in
                    self?.hostState.audioLevel = l
                }
            ]
        } else {
            audioDetector.stop()
            audioDetector.onEvent = nil
            audioObservers.removeAll()
            hostState.audioEnabled = false
            hostState.audioLevel = 0
            hostState.audioStatus = "Off"
        }
    }

    private static func audioStatusText(for state: AudioPitchDetector.State) -> String {
        switch state {
        case .idle: return "Off"
        case .running: return "Listening"
        case .unauthorized: return "Mic permission denied"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    func registerForDeviceNotifications() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name.AVCaptureDeviceWasConnected, object: nil, queue: nil) { (notif) -> Void in
            DispatchQueue.main.async {
                self.hostState.cameras = CameraCapture.availableDevices
                if self.sourceStream == nil {
                    self.connectToCamera()
                }
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        registerForDeviceNotifications()
        installSwiftUIPanel()

        // Seed initial UI state.
        hostState.cameras = CameraCapture.availableDevices
        hostState.selectedCameraID = hostState.cameras.first?.uniqueID
        hostState.audioInputs = AudioPitchDetector.availableInputs
        hostState.selectedAudioInputID = AVCaptureDevice.default(for: .audio)?.uniqueID
            ?? hostState.audioInputs.first?.uniqueID
        hostState.extensionStatus = .inactive

        self.makeDevicesVisible()
        connectToCamera()

        cameraCapture.onFrame = { [weak self] pb in
            guard let self else { return }
            self.frameLock.lock()
            self.latestCameraFrame = pb
            self.frameLock.unlock()
        }
        cameraCapture.start()

        midiInput.onEvent = { [weak self] event in
            self?.pianoState.handle(event)
        }

        // Push UI-tuned Basic Pitch settings into the detector live.
        bpSettingsObservers = [
            hostState.$bpOnsetThreshold.sink { [weak self] v in
                self?.audioDetector.basicPitchSettings.onsetThreshold = v
            },
            hostState.$bpFrameThreshold.sink { [weak self] v in
                self?.audioDetector.basicPitchSettings.frameThreshold = v
            },
            hostState.$bpSustainedFraction.sink { [weak self] v in
                self?.audioDetector.basicPitchSettings.sustainedFraction = v
            },
            hostState.$bpMinHoldSeconds.sink { [weak self] v in
                self?.audioDetector.basicPitchSettings.minHoldSeconds = v
            }
        ]
        midiInput.onSourcesChanged = { [weak self] names in
            self?.hostState.midiSources = names
        }
        midiInput.start()

        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: 1/30.0, target: self, selector: #selector(fireTimer), userInfo: nil, repeats: true)
        propTimer?.invalidate()
        propTimer = Timer.scheduledTimer(timeInterval: 2.0, target: self, selector: #selector(propertyTimer), userInfo: nil, repeats: true)
    }

    private func installSwiftUIPanel() {
        let actions = HostActions(
            activate: { [weak self] in self?.activateCamera() },
            deactivate: { [weak self] in self?.deactivateCamera() },
            reconnect: { [weak self] in self?.reconnect() },
            cameraSelected: { [weak self] device in self?.cameraCapture.setDevice(device) },
            audioToggled: { [weak self] on in self?.toggleAudio(on) },
            audioInputSelected: { [weak self] device in
                guard let self else { return }
                self.hostState.selectedAudioInputID = device.uniqueID
                if self.hostState.audioEnabled {
                    self.audioDetector.stop()
                    self.audioDetector.start(device: device)
                }
            },
            audioModeChanged: { [weak self] mode in
                guard let self else { return }
                self.hostState.audioMode = mode
                self.audioDetector.mode = mode
            }
        )
        let panel = ControlPanel(state: hostState, actions: actions, previewLayer: previewLayer)
        let host = NSHostingView(rootView: panel)
        host.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: self.view.topAnchor),
            host.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: self.view.trailingAnchor)
        ])
    }

    func showMessage(_ text: String) {
        hostState.log(text)
    }
    func enqueue(_ queue: CMSimpleQueue, _ image: CGImage) {
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
            print("error enqueuing")
            return
        }
        var err: OSStatus = 0
        var pixelBuffer: CVPixelBuffer?
        err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, self._bufferPool, self._bufferAuxAttributes, &pixelBuffer)
        if let pixelBuffer = pixelBuffer {
            
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            
            /*var bufferPtr = CVPixelBufferGetBaseAddress(pixelBuffer)!
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            memset(bufferPtr, 0, rowBytes * height)
            
            let whiteStripeStartRow = self._whiteStripeStartRow
            if self._whiteStripeIsAscending {
                self._whiteStripeStartRow = whiteStripeStartRow - 1
                self._whiteStripeIsAscending = self._whiteStripeStartRow > 0
            }
            else {
                self._whiteStripeStartRow = whiteStripeStartRow + 1
                self._whiteStripeIsAscending = self._whiteStripeStartRow >= (height - kWhiteStripeHeight)
            }
            bufferPtr += rowBytes * Int(whiteStripeStartRow)
            for _ in 0..<kWhiteStripeHeight {
                for _ in 0..<width {
                    var white: UInt32 = 0xFFFFFFFF
                    memcpy(bufferPtr, &white, MemoryLayout.size(ofValue: white))
                    bufferPtr += MemoryLayout.size(ofValue: white)
                }
            }*/
            let pixelData = CVPixelBufferGetBaseAddress(pixelBuffer)
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
            // optimizing context: interpolationQuality and bitmapInfo
            // see https://stackoverflow.com/questions/7560979/cgcontextdrawimage-is-extremely-slow-after-large-uiimage-drawn-into-it
            if let context = CGContext(data: pixelData,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: rgbColorSpace,
                                      //bitmapInfo: UInt32(CGImageAlphaInfo.noneSkipFirst.rawValue) | UInt32(CGImageByteOrderInfo.order32Little.rawValue))
                                       bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
            {
                context.interpolationQuality = .low
                if mirrorCamera {
                    context.translateBy(x: CGFloat(width), y: 0.0)
                    context.scaleBy(x: -1.0, y: 1.0)
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            
            var sbuf: CMSampleBuffer!
            var timingInfo = CMSampleTimingInfo()
            timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
            err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: self._videoDescription, sampleTiming: &timingInfo, sampleBufferOut: &sbuf)
            if err == 0 {
                if let sbuf = sbuf {
                    let pointerRef = UnsafeMutableRawPointer(Unmanaged.passRetained(sbuf).toOpaque())
                    CMSimpleQueueEnqueue(queue, element: pointerRef)
                }
            }
        } else {
            print("error getting pixel buffer")
        }
    }
    
    @objc func propertyTimer() {
        if let sourceStream = sourceStream {
            self.setJustProperty(streamId: sourceStream, newValue: "random")
            let just = self.getJustProperty(streamId: sourceStream)
            if let just = just {
                needToStream = (just == "sc=1")
            }
            hostState.streamingToConsumer = needToStream
            hostState.sinkConnected = (sinkQueue != nil)
        }
    }
    @objc func fireTimer() {
        let composite = makeCompositeFrame()
        if let composite { showPreview(composite) }

        guard needToStream,
              (enqueued == false || readyToEnqueue == true),
              let queue = self.sinkQueue else { return }
        enqueued = true
        readyToEnqueue = false
        if let composite {
            self.enqueue(queue, composite)
        } else if let image = image,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            self.enqueue(queue, cgImage)
        }
    }

    private func showPreview(_ cg: CGImage) {
        // Wrap the CGImage in a CMSampleBuffer so AVSampleBufferDisplayLayer can render it.
        let w = cg.width, h = cg.height
        let attrs = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ] as CFDictionary
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let buffer = pb else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                            width: w, height: h,
                            bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: cs,
                            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                      | CGImageAlphaInfo.premultipliedFirst.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: buffer,
                                                     formatDescriptionOut: &fd)
        guard let fd else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: buffer,
                                                 formatDescription: fd,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sb)
        if let sb {
            if previewLayer.requiresFlushToResumeDecoding { previewLayer.flush() }
            previewLayer.enqueue(sb)
            if let host = previewLayer.superlayer {
                previewLayer.frame = host.bounds
            }
        }
    }

    /// Builds a CGImage at the virtual camera's resolution, drawn as
    /// (latest webcam frame, aspect-fill) + (piano keyboard along the bottom).
    private func makeCompositeFrame() -> CGImage? {
        frameLock.lock()
        let frame = latestCameraFrame
        frameLock.unlock()
        guard let frame else { return nil }

        let w = Int(fixedCamWidth), h = Int(fixedCamHeight)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue
                   | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: bitmap) else { return nil }

        let dst = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(dst)

        // Camera occupies the top portion; piano sits in the bottom band.
        // Drawing the camera into a constrained region (instead of the full
        // frame) means the piano no longer covers part of the camera image.
        let pianoFraction: CGFloat = 0.30
        let camRegion = CGRect(x: 0, y: CGFloat(h) * pianoFraction,
                               width: CGFloat(w),
                               height: CGFloat(h) * (1 - pianoFraction))

        let cam = CIImage(cvPixelBuffer: frame)
        let camW = cam.extent.width, camH = cam.extent.height
        let scale = max(camRegion.width / camW, camRegion.height / camH)
        let scaledW = camW * scale, scaledH = camH * scale
        let drawRect = CGRect(
            x: camRegion.minX + (camRegion.width - scaledW) / 2,
            y: camRegion.minY + (camRegion.height - scaledH) / 2,
            width: scaledW,
            height: scaledH
        )
        if let cg = ViewController.ciContext.createCGImage(cam, from: cam.extent) {
            ctx.saveGState()
            ctx.clip(to: camRegion)
            if mirrorCamera {
                ctx.translateBy(x: 2 * camRegion.midX, y: 0)
                ctx.scaleBy(x: -1, y: 1)
            }
            ctx.draw(cg, in: drawRect)
            ctx.restoreGState()
        }

        // Piano + pedals along the bottom band.
        PianoOverlay.draw(into: ctx, rect: dst,
                          heightFraction: pianoFraction,
                          activeNotes: pianoState.activeVelocities,
                          pedals: pianoState.pedalsState)

        return ctx.makeImage()
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }


}

extension ViewController: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        showMessage("Replacing \(existing.bundleShortVersion) with \(ext.bundleShortVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        DispatchQueue.main.async {
            self.hostState.extensionStatus = .needsApproval
            self.showMessage("Extension needs user approval — System Settings → Privacy & Security")
        }
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        DispatchQueue.main.async {
            switch result {
            case .completed:
                self.hostState.extensionStatus = self.activating ? .active : .inactive
                self.showMessage(self.activating ? "Camera activated" : "Camera deactivated")
            case .willCompleteAfterReboot:
                self.hostState.extensionStatus = .needsApproval
                self.showMessage("Reboot to finish")
            @unknown default:
                self.showMessage("Request finished (\(result.rawValue))")
            }
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.hostState.extensionStatus = .failed
            self.showMessage("Failed: \(error.localizedDescription)")
        }
    }
}

extension FourCharCode: ExpressibleByStringLiteral {
    
    public init(stringLiteral value: StringLiteralType) {
        var code: FourCharCode = 0
        // Value has to consist of 4 printable ASCII characters, e.g. '420v'.
        // Note: This implementation does not enforce printable range (32-126)
        if value.count == 4 && value.utf8.count == 4 {
            for byte in value.utf8 {
                code = code << 8 + FourCharCode(byte)
            }
        }
        else {
            print("FourCharCode: Can't initialize with '\(value)', only printable ASCII allowed. Setting to '????'.")
            code = 0x3F3F3F3F // = '????'
        }
        self = code
    }
    
    public init(extendedGraphemeClusterLiteral value: String) {
        self = FourCharCode(stringLiteral: value)
    }
    
    public init(unicodeScalarLiteral value: String) {
        self = FourCharCode(stringLiteral: value)
    }
    
    public init(_ value: String) {
        self = FourCharCode(stringLiteral: value)
    }
    
    public var string: String? {
        let cString: [CChar] = [
            CChar(self >> 24 & 0xFF),
            CChar(self >> 16 & 0xFF),
            CChar(self >> 8 & 0xFF),
            CChar(self & 0xFF),
            0
        ]
        return String(cString: cString)
    }
}

public extension CMIOObjectPropertyAddress {
    init(_ selector: CMIOObjectPropertySelector,
         _ scope: CMIOObjectPropertyScope = .anyScope,
         _ element: CMIOObjectPropertyElement = .anyElement) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

public extension CMIOObjectPropertyScope {
    /// The CMIOObjectPropertyScope for properties that apply to the object as a whole.
    /// All CMIOObjects have a global scope and for some it is their only scope.
    static let global = CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal)
    
    /// The wildcard value for CMIOObjectPropertyScopes.
    static let anyScope = CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard)
    
    /// The CMIOObjectPropertyScope for properties that apply to the input signal paths of the CMIODevice.
    static let deviceInput = CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput)
    
    /// The CMIOObjectPropertyScope for properties that apply to the output signal paths of the CMIODevice.
    static let deviceOutput = CMIOObjectPropertyScope(kCMIODevicePropertyScopeOutput)
    
    /// The CMIOObjectPropertyScope for properties that apply to the play through signal paths of the CMIODevice.
    static let devicePlayThrough = CMIOObjectPropertyScope(kCMIODevicePropertyScopePlayThrough)
}

public extension CMIOObjectPropertyElement {
    /// The CMIOObjectPropertyElement value for properties that apply to the master element or to the entire scope.
    //static let master = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMaster)
    static let main = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    /// The wildcard value for CMIOObjectPropertyElements.
    static let anyElement = CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
}
