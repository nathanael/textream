import AVFoundation
import Vision
import AppKit

@Observable
class HandGestureController: NSObject {
    var isHandRaised: Bool = false
    var handHeight: Float = 0.0  // 0.0 = just above threshold, 1.0 = top of frame

    private var captureSession: AVCaptureSession?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "com.textream.handgesture", qos: .userInteractive)
    private let handPoseRequest = VNDetectHumanHandPoseRequest()

    private let raiseThreshold: Float = 0.6  // wrist Y must exceed this to count as raised
    private var recentWristY: [Float] = []   // rolling buffer for smoothing
    private let smoothingWindow = 4

    private var isRunning = false

    override init() {
        super.init()
        handPoseRequest.maximumHandCount = 2
    }

    func start() {
        guard !isRunning else { return }

        // Check camera permission
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async { self?.setupAndStart() }
                }
            }
        default:
            // Permission denied or restricted — silently disable
            return
        }
    }

    func stop() {
        guard isRunning else { return }
        captureSession?.stopRunning()
        isRunning = false
        isHandRaised = false
        handHeight = 0.0
        recentWristY = []
    }

    private func setupAndStart() {
        let session = AVCaptureSession()
        session.sessionPreset = .low  // ~640x480, minimal resource usage

        // Find front-facing camera
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video) else {
            // No camera available — silently disable
            return
        }

        guard let input = try? AVCaptureDeviceInput(device: camera) else { return }
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else { return }
        session.addOutput(videoOutput)

        // Limit frame rate to ~15fps to save CPU
        if let connection = videoOutput.connection(with: .video) {
            connection.isEnabled = true
        }
        try? camera.lockForConfiguration()
        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
        camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
        camera.unlockForConfiguration()

        captureSession = session

        processingQueue.async {
            session.startRunning()
        }
        isRunning = true
    }
}

extension HandGestureController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([handPoseRequest])

        guard let results = handPoseRequest.results, !results.isEmpty else {
            DispatchQueue.main.async {
                self.updateWristPosition(nil)
            }
            return
        }

        // Find the hand with the highest wrist Y
        var highestWristY: Float = 0
        for hand in results {
            if let wrist = try? hand.recognizedPoint(.wrist),
               wrist.confidence > 0.3 {
                let y = Float(wrist.location.y)  // Vision coords: 0=bottom, 1=top
                if y > highestWristY {
                    highestWristY = y
                }
            }
        }

        DispatchQueue.main.async {
            self.updateWristPosition(highestWristY > 0 ? highestWristY : nil)
        }
    }

    private func updateWristPosition(_ wristY: Float?) {
        guard let y = wristY else {
            // No hand detected — decay smoothly
            recentWristY = []
            isHandRaised = false
            handHeight = 0.0
            return
        }

        // Smooth with rolling average
        recentWristY.append(y)
        if recentWristY.count > smoothingWindow {
            recentWristY.removeFirst()
        }
        let smoothed = recentWristY.reduce(0, +) / Float(recentWristY.count)

        if smoothed > raiseThreshold {
            isHandRaised = true
            // Map threshold..1.0 → 0.0..1.0
            handHeight = min(1.0, (smoothed - raiseThreshold) / (1.0 - raiseThreshold))
        } else {
            isHandRaised = false
            handHeight = 0.0
        }
    }
}
