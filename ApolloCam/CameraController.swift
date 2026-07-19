import AVFoundation
import UIKit
import Combine

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "apollocam.session")
    private let analysisQueue = DispatchQueue(label: "apollocam.analysis", qos: .userInitiated)

    @Published var permissionDenied = false
    @Published var capturedImage: UIImage?
    @Published var zoomFactor: CGFloat = 1.0

    private var device: AVCaptureDevice?
    private var lastAnalysis = Date.distantPast
    var onFrame: ((CVPixelBuffer) -> Void)?
    private var photoContinuation: ((UIImage?) -> Void)?

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
        photoContinuation = completion
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Throttle analysis to ~3 fps to keep the phone cool
        guard Date().timeIntervalSince(lastAnalysis) > 0.33,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = Date()
        onFrame?(buffer)
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        DispatchQueue.main.async {
            self.capturedImage = image
            self.photoContinuation?(image)
            self.photoContinuation = nil
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
