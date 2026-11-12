// Copyright (c) 2026 XMAX.AI PTE. LTD.

import Foundation
import IOSurface

/// Private frame statuses transmitted by the worker.
public enum BeautyWorkerFrameStatus: Int {
    /// The native graph could not deliver this frame and must be recreated before reuse.
    case unavailable = -10001
}

/// The private, parent-only XPC contract for an unpublished offline processing service.
@objc public protocol BeautyWorkerProtocol {

    /// Initializes or updates the worker's media graph; replies with a recoverable error description.
    func configure(
        _ appID: String,
        options: [String: NSNumber],
        reply: @escaping @Sendable (String?) -> Void
    )

    /// Processes an IOSurface without serializing its pixel bytes through XPC.
    /// The returned lease keeps the native pool buffer alive until explicitly released.
    /// Error codes distinguish output pool pressure and missed frames from other failures.
    func process(
        _ surface: IOSurface,
        reply: @escaping @Sendable (IOSurface?, UInt64, Int, String?) -> Void
    )

    /// Releases one native pool buffer after all host consumers release the corresponding CVPixelBuffer.
    func releaseFrame(
        _ lease: UInt64
    )
}

/// Creates identical secure-coding interface rules in the host and the worker.
public enum BeautyWorkerInterface {

    /// Allows IOSurface objects in the processing request and reply.
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: BeautyWorkerProtocol.self)
        interface.setClasses(NSSet(array: [IOSurface.self]) as! Set<AnyHashable>, for: #selector(BeautyWorkerProtocol.process(_:reply:)),
                             argumentIndex: 0, ofReply: false)
        interface.setClasses(NSSet(array: [IOSurface.self]) as! Set<AnyHashable>, for: #selector(BeautyWorkerProtocol.process(_:reply:)),
                             argumentIndex: 0, ofReply: true)
        return interface
    }
}
