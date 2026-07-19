import AVFoundation
import UIKit
import CoreImage
import Combine

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "apollocam.session")
    private let analysisQueue = DispatchQueue(label: "apollocam.analysis", qos: .userInitiated)
    private let ciContext = CIContext()

    @Published var permissionDenied = false
    @Published var zoomFactor: CGFloat = 1.0
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
    private var photoCompletion: ((UIImage?) -> Void)?

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

    private func setupSession() {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            session.sessionPreset = .photo

            guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
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
            session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func setZoom(_ factor: CGFloat) {
        guard let device else { return }
        let clamped = max(1.0, min(factor, min(device.activeFormat.videoMaxZoomFactor, 10)))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.zoomFactor = clamped }
        } catch {}
    }

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        photoCompletion = completion
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Throttle to ~4 fps: enough for guidance, keeps the phone cool.
        guard Date().timeIntervalSince(lastAnalysis) > 0.25,
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
        DispatchQueue.main.async {
            self.photoCompletion?(image)
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
