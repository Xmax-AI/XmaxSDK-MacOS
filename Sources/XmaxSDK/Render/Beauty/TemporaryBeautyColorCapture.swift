#if DEBUG
import CoreGraphics
import CoreVideo
import Foundation

/// Saves one local diagnostic pair for the currently investigated result-color mismatch.
enum TemporaryBeautyColorCapture {

    /// Writes original, prepared and processed frames without changing processing success or pixels.
    static func save(
        original: RealtimeVideoFrame,
        prepared: RealtimeVideoFrame,
        output: CVPixelBuffer,
        options: RealtimeVideoBeautyOptions
    ) {
        guard options == RealtimeVideoBeautyOptions() else { return }
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "XmaxBeautyColorCapture-\(ProcessInfo.processInfo.processIdentifier)"
            )
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) else { return }
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var frames: [String: Any] = [:]
            for (name, buffer) in [("original", original.pixelBuffer), ("prepared", prepared.pixelBuffer), ("beauty", output)] {
                let locked = CVPixelBufferLockBaseAddress(buffer, .readOnly)
                guard locked == kCVReturnSuccess else { throw CocoaError(.fileReadUnknown) }
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                let planar = CVPixelBufferIsPlanar(buffer)
                let width = CVPixelBufferGetWidth(buffer)
                let height = CVPixelBufferGetHeight(buffer)
                var planes: [[String: Any]] = []
                for plane in 0..<(planar ? CVPixelBufferGetPlaneCount(buffer) : 1) {
                    let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, plane) : CVPixelBufferGetBaseAddress(buffer)
                    guard let base else { throw CocoaError(.fileReadUnknown) }
                    let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) : CVPixelBufferGetBytesPerRow(buffer)
                    let rows = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : height
                    let rowBytes = planar ? width : width * 4
                    var data = Data(capacity: rowBytes * rows)
                    for row in 0..<rows {
                        data.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: rowBytes)
                    }
                    let filename = "\(name)-\(plane).bin"
                    try data.write(to: root.appendingPathComponent(filename), options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(filename).path)
                    planes.append(["file": filename, "rowBytes": rowBytes, "height": rows])
                }
                let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] ?? [:]
                var metadata: [String: Any] = [
                    "width": width, "height": height, "format": CVPixelBufferGetPixelFormatType(buffer),
                    "planes": planes, "attachments": attachments.mapValues { String(describing: $0) }
                ]
                if let value = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil),
                    CFGetTypeID(value) == CGColorSpace.typeID {
                    let color = value as! CGColorSpace
                    metadata["cgColorSpaceName"] = color.name as String?
                    metadata["cgColorSpaceICC"] = (color.copyICCData() as Data?)?.base64EncodedString()
                }
                frames[name] = metadata
            }
            let manifest: [String: Any] = ["app": Bundle.main.bundlePath, "frames": frames]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            let target = root.appendingPathComponent("manifest.json")
            try data.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            NSLog("XMAX_BEAUTY_COLOR_CAPTURE %@", root.path)
        } catch {
            NSLog("XMAX_BEAUTY_COLOR_CAPTURE_FAILED %@", error.localizedDescription)
        }
    }
}
#endif
