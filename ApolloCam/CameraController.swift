import AVFoundation
import UIKit
import CoreImage
import Combine
import ImageIO

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "apollocam.session")
    private let analysisQueue = DispatchQueue(label: "apollocam.analysis", qos: .userInitiated)
    private let ciContext = CIContext()

    @Published var permissionDenied = false

    // MARK: Zoom
    //
    // Two different scales are in play and confusing them is the easy mistake here.
    //
    //  - DEVICE zoom is what `AVCaptureDevice.videoZoomFactor` takes. On a virtual
    //    multi-lens device (dual-wide / triple) its 1.0 is the *ultra-wide* lens,
    //    so the framing a user thinks of as "1×" sits at device zoom 2.0.
    //  - DISPLAY zoom is the number a person recognises: 0.5×, 1×, 2×, 3×, where
    //    1× is always the normal wide lens.
    //
    // Everything above this class — the UI, `ShotInfo.zoom`, the AI coach — speaks
    // display zoom only. `baseZoom` is the conversion factor between the two.

    /// Current zoom on the *display* scale (1.0 = normal wide lens).
    @Published private(set) var zoomFactor: CGFloat = 1.0
    /// Widest display zoom the hardware can reach — 0.5 where an ultra-wide exists, else 1.0.
    @Published private(set) var minZoom: CGFloat = 1.0
    /// Highest display zoom the active device supports (capped for usability).
    @Published private(set) var maxZoom: CGFloat = 5.0
    /// Preset stops for the zoom buttons, derived from the device's real lenses so
    /// they match what the phone's own camera app offers (e.g. [0.5, 1, 2, 5]).
    @Published private(set) var zoomStops: [CGFloat] = [1, 2]
    /// Device zoom factor corresponding to a displayed 1×.
    private var baseZoom: CGFloat = 1.0

    /// True while a sheet covers the camera — frames are dropped.
    @Published var isPaused = false
    private var configured = false
    /// 0 = perfectly still, higher = more movement. Updated ~5x/sec.
    @Published var motionLevel: Double = 1.0

    private var device: AVCaptureDevice?
    private var lastAnalysis = Date.distantPast
    private var previousLuma: [UInt8]?
    /// Small snapshot of the most recent analyzed frame (safe to hold — it's a copy, not a camera buffer)
    private(set) var latestSnapshot: UIImage?
    private let snapshotLock = NSLock()

    /// Called on the analysis queue with each throttled frame. Do NOT retain the buffer beyond this call.
    var onFrame: ((CVPixelBuffer) -> Void)?
    private var photoCompletion: ((UIImage?, ShotInfo?) -> Void)?

    func currentSnapshot() -> UIImage? {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return latestSnapshot
    }

    func configure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.setupSession() }
                else { DispatchQueue.main.async { self?.permissionDenied = true } }
            }
        default:
            permissionDenied = true
        }
    }

    /// Prefers the widest *virtual* device available, because only a virtual device
    /// can hand us the ultra-wide lens — a plain `.builtInWideAngleCamera` bottoms
    /// out at 1× and can never produce a real 0.5×. Falls back down the list on
    /// phones (and the simulator) that lack the richer camera stacks.
    private static func bestCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,     // ultra-wide + wide + tele
            .builtInDualWideCamera,   // ultra-wide + wide
            .builtInDualCamera,       // wide + tele
            .builtInWideAngleCamera   // wide only
        ]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    private func setupSession() {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            session.sessionPreset = .photo

            guard let cam = Self.bestCamera(),
                  let input = try? AVCaptureDeviceInput(device: cam),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }
            device = cam
            session.addInput(input)

            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

            session.commitConfiguration()
            configured = true

            let profile = Self.zoomProfile(for: cam)

            // Open at 1×, not at whatever the device defaults to. On a virtual
            // device `videoZoomFactor` starts at 1.0, which is the ultra-wide —
            // launching into a fisheye-looking frame nobody asked for.
            do {
                try cam.lockForConfiguration()
                cam.videoZoomFactor = profile.base
                cam.unlockForConfiguration()
            } catch {}

            // baseZoom is published to the main thread alongside the rest of the
            // profile so `setZoom` (main) never reads it mid-write from this queue.
            DispatchQueue.main.async {
                self.baseZoom = profile.base
                self.minZoom = profile.min
                self.maxZoom = profile.max
                self.zoomStops = profile.stops
                self.zoomFactor = 1.0
            }
            session.startRunning()
        }
    }

    /// Works out the display/device conversion and the button stops for a device.
    ///
    /// The stops deliberately mirror the stock camera app rather than a fixed list:
    /// they come from the lenses the phone actually has (`virtualDeviceSwitchOverVideoZoomFactors`
    /// marks where the hardware hands off from one lens to the next), so a 15 Pro
    /// offers 0.5/1/2/5 while a plain single-lens phone offers 1/2/3.
    private static func zoomProfile(for device: AVCaptureDevice)
        -> (base: CGFloat, min: CGFloat, max: CGFloat, stops: [CGFloat]) {

        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }

        // With an ultra-wide present, the first switch-over IS the ultra-wide→wide
        // boundary, i.e. exactly the device zoom that reads as 1×.
        let base = (hasUltraWide ? switchOvers.first : nil) ?? 1.0

        let minDisplay = round((device.minAvailableVideoZoomFactor / base) * 10) / 10
        let maxDisplay = min(device.activeFormat.videoMaxZoomFactor / base, 15)

        var stops: [CGFloat] = []
        if minDisplay < 0.95 { stops.append(minDisplay) }
        stops.append(1)

        // Remaining switch-overs are the telephoto hand-offs.
        for factor in switchOvers.dropFirst(hasUltraWide ? 1 : 0) {
            let display = round((factor / base) * 10) / 10
            if display > 1.05 && display <= maxDisplay { stops.append(display) }
        }

        // Stock camera always offers a mid stop even when no lens sits there (it's
        // a sensor crop, not a lens) — beginners reach for 2× constantly.
        if !stops.contains(where: { $0 > 1.05 && $0 < 2.6 }), maxDisplay >= 2 { stops.append(2) }
        if stops.count < 3, maxDisplay >= 3 { stops.append(3) }

        return (base, minDisplay, max(2, maxDisplay), stops.sorted())
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Suspend capture while a sheet covers the camera. Stops frame delivery, so
    /// detection, haptics and coach polling all go quiet and stop drawing power.
    func pause() {
        DispatchQueue.main.async { self.isPaused = true }
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func resume() {
        DispatchQueue.main.async { self.isPaused = false }
        sessionQueue.async { [self] in
            guard configured else { return }
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Sets zoom on the *display* scale (0.5 = ultra-wide, 1 = normal, 2 = 2× …).
    ///
    /// `animated` ramps the lens instead of jumping. Use it for anything the user
    /// didn't drag — stop buttons, the coach pulling back to the wide view — so the
    /// framing slides rather than snapping. Pinch and slider stay unanimated, since
    /// those are already continuous and a ramp would fight the finger.
    func setZoom(_ display: CGFloat, animated: Bool = false) {
        guard let device else { return }
        let clampedDisplay = max(minZoom, min(display, maxZoom))
        let target = max(device.minAvailableVideoZoomFactor,
                         min(clampedDisplay * baseZoom, device.activeFormat.videoMaxZoomFactor))
        do {
            try device.lockForConfiguration()
            if animated {
                device.cancelVideoZoomRamp()
                device.ramp(toVideoZoomFactor: target, withRate: 6)
            } else {
                device.videoZoomFactor = target
            }
            device.unlockForConfiguration()
            // Published immediately in both cases: the label should read the value
            // the user asked for, not chase the lens through the ramp.
            let settled = target / baseZoom
            if Thread.isMainThread { zoomFactor = settled }
            else { DispatchQueue.main.async { self.zoomFactor = settled } }
        } catch {}
    }

    func capturePhoto(completion: @escaping (UIImage?, ShotInfo?) -> Void) {
        photoCompletion = completion
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }
}

/// Technical facts about a captured frame, surfaced on the review screen.
struct ShotInfo {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var zoom: Double?
    var aperture: Double?      // f-number
    var shutter: Double?       // seconds
    var iso: Int?
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Throttle to ~4 fps: enough for guidance, keeps the phone cool.
        // Paused (a sheet is covering the camera) → do no work at all.
        guard !isPaused,
              Date().timeIntervalSince(lastAnalysis) > 0.25,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = Date()

        // 1. Motion level from a tiny luma grid (cheap, no buffer retained)
        updateMotion(from: buffer)

        // 2. Small snapshot COPY for AI partner / advice (never the raw buffer)
        makeSnapshot(from: buffer)

        // 3. Subject detection (Vision reads the buffer synchronously inside this call)
        onFrame?(buffer)
    }

    private func updateMotion(from buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let grid = 16
        var luma = [UInt8](repeating: 0, count: grid * grid)
        for gy in 0..<grid {
            for gx in 0..<grid {
                let x = (gx * width) / grid
                let y = (gy * height) / grid
                let o = y * stride + x * 4
                luma[gy * grid + gx] = UInt8((Int(ptr[o]) + Int(ptr[o + 1]) + Int(ptr[o + 2])) / 3)
            }
        }

        if let prev = previousLuma {
            var total = 0
            for i in 0..<luma.count { total += abs(Int(luma[i]) - Int(prev[i])) }
            let level = Double(total) / Double(luma.count) / 255.0
            DispatchQueue.main.async { self.motionLevel = level }
        }
        previousLuma = luma
    }

    private func makeSnapshot(from buffer: CVPixelBuffer) {
        let ci = CIImage(cvPixelBuffer: buffer)
        // Portrait orientation: camera buffers arrive rotated
        let oriented = ci.oriented(.right)
        let scale = 640.0 / max(oriented.extent.width, oriented.extent.height)
        let scaled = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        let image = UIImage(cgImage: cg)
        snapshotLock.lock()
        latestSnapshot = image
        snapshotLock.unlock()
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }

        var info = ShotInfo()
        info.zoom = Double(zoomFactor)
        if let px = photo.pixelBuffer {
            info.pixelWidth = CVPixelBufferGetWidth(px)
            info.pixelHeight = CVPixelBufferGetHeight(px)
        }
        let meta = photo.metadata
        if let w = meta[kCGImagePropertyPixelWidth as String] as? Int { info.pixelWidth = w }
        if let h = meta[kCGImagePropertyPixelHeight as String] as? Int { info.pixelHeight = h }
        if let img = image, info.pixelWidth == nil {
            info.pixelWidth = Int(img.size.width * img.scale)
            info.pixelHeight = Int(img.size.height * img.scale)
        }
        if let exif = meta[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let f = exif[kCGImagePropertyExifFNumber as String] as? Double { info.aperture = f }
            if let t = exif[kCGImagePropertyExifExposureTime as String] as? Double { info.shutter = t }
            if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], let iso = isoArr.first { info.iso = iso }
            else if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? Int { info.iso = iso }
        }

        DispatchQueue.main.async {
            self.photoCompletion?(image, info)
            self.photoCompletion = nil
        }
    }
}

import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
