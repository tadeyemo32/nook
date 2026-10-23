import AVFoundation
import SwiftUI

struct MirrorView: View {
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        switch access {
        case .authorized:
            CameraPreview()
        case .notDetermined:
            Color.white.opacity(0.06).overlay(ProgressView().controlSize(.small)).task {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                access = AVCaptureDevice.authorizationStatus(for: .video)
            }
        default:
            Color.white.opacity(0.06).overlay {
                VStack(spacing: 6) {
                    Image(systemName: "video.slash.fill").font(.system(size: 20))
                    Text("Allow Nook to use the camera in System Settings → Privacy & Security → Camera")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: 280)
                }
            }
        }
    }
}

private struct CameraPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> PreviewView { PreviewView() }
    func updateNSView(_ nsView: PreviewView, context: Context) {}
    static func dismantleNSView(_ nsView: PreviewView, coordinator: ()) { nsView.stop() }
}

private final class PreviewView: NSView {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "nook.mirror")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.connection?.automaticallyAdjustsVideoMirroring = false
        preview.connection?.isVideoMirrored = true
        layer = preview

        let session = session
        queue.async {
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input)
            else { return }
            session.sessionPreset = .medium
            session.addInput(input)
            session.startRunning()
            DispatchQueue.main.async {
                preview.connection?.automaticallyAdjustsVideoMirroring = false
                preview.connection?.isVideoMirrored = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func stop() {
        let session = session
        queue.async { session.stopRunning() }
    }
}
