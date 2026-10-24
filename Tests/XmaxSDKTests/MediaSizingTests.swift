import CoreGraphics
import XCTest
@testable import XmaxSDK

final class MediaSizingTests: XCTestCase {
    func testLargeImagesAndVideosShareModelAreaLimitWithoutMatchingBuckets() throws {
        let service = MediaService()
        let cases = [
            (CGSize(width: 3840, height: 2160), CGSize(width: 1920, height: 1080)),
            (CGSize(width: 2160, height: 3840), CGSize(width: 1080, height: 1920)),
            (CGSize(width: 8000, height: 6000), CGSize(width: 1664, height: 1248)),
            (CGSize(width: 6000, height: 8000), CGSize(width: 1248, height: 1664))
        ]
        for source in [RealtimeMediaSource.image, .video] {
            for (original, expected) in cases {
                let size = try service.resolveMediaSize(original, source: source)
                XCTAssertEqual(size, expected)
                XCTAssertTrue(Int(size.width).isMultiple(of: 4))
                XCTAssertTrue(Int(size.height).isMultiple(of: 4))
                XCTAssertLessThanOrEqual(size.width * size.height, CGFloat(service.model.maximumInputPixels))
                XCTAssertEqual(size.width * original.height, size.height * original.width)
            }
        }
    }

    func testMediaSizePreservesValidInputsWithoutApplyingCanvasAlignment() throws {
        let service = MediaService()
        for source in [RealtimeMediaSource.image, .video] {
            for size in [CGSize(width: 1000, height: 500), CGSize(width: 1004, height: 600)] {
                XCTAssertEqual(try service.resolveMediaSize(size, source: source), size)
            }
            XCTAssertEqual(
                try service.resolveMediaSize(CGSize(width: 1001, height: 1000), source: source),
                CGSize(width: 1000, height: 1000)
            )
            XCTAssertEqual(
                try service.resolveMediaSize(CGSize(width: 1001, height: 600), source: source),
                CGSize(width: 1000, height: 600)
            )
        }
    }

    func testSmallMediaIsUpscaledForEveryNonCameraSource() throws {
        let cases = [
            (CGSize(width: 400, height: 752), CGSize(width: 400, height: 752)),
            (CGSize(width: 752, height: 400), CGSize(width: 752, height: 400)),
            (CGSize(width: 512, height: 960), CGSize(width: 512, height: 960)),
            (CGSize(width: 640, height: 480), CGSize(width: 640, height: 480)),
            (CGSize(width: 256, height: 480), CGSize(width: 352, height: 660)),
            (CGSize(width: 200, height: 200), CGSize(width: 448, height: 448)),
            (CGSize(width: 1, height: 1), CGSize(width: 448, height: 448))
        ]

        for model in RealtimeModel.allCases {
            let service = MediaService(model: model)
            XCTAssertEqual(model.minimumInputPixels, 200000)
            for source in [RealtimeMediaSource.image, .video, .external] {
                for (original, expected) in cases {
                    let size = try service.resolveMediaSize(
                        original,
                        source: source
                    )
                    XCTAssertEqual(size, expected)
                    XCTAssertGreaterThanOrEqual(size.width * size.height, CGFloat(model.minimumInputPixels))
                    XCTAssertLessThanOrEqual(size.width * size.height, CGFloat(model.maximumInputPixels))
                    XCTAssertEqual(size.width * original.height, size.height * original.width)
                    XCTAssertTrue(Int(size.width).isMultiple(of: 4))
                    XCTAssertTrue(Int(size.height).isMultiple(of: 4))
                }
                XCTAssertEqual(
                    try service.resolveMediaSize(CGSize(width: 1001, height: 500), source: source),
                    CGSize(width: 1000, height: 500)
                )
                XCTAssertEqual(
                    try service.resolveMediaSize(CGSize(width: 512, height: 1000), source: source),
                    CGSize(width: 512, height: 1000)
                )
            }
        }
    }

    func testMediaAlignmentKeepsTheMinimumWhenExactRatioCannotFit() throws {
        for model in RealtimeModel.allCases {
            let service = MediaService(model: model)
            for source in [RealtimeMediaSource.image, .video, .external] {
                for original in [
                    CGSize(width: 1001, height: 199),
                    CGSize(width: 999, height: 200),
                    CGSize(width: 1000, height: 200)
                ] {
                    for size in [original, CGSize(width: original.height, height: original.width)] {
                        let resolved = try service.resolveMediaSize(
                            size,
                            source: source
                        )
                        XCTAssertGreaterThanOrEqual(resolved.width * resolved.height, CGFloat(model.minimumInputPixels))
                        XCTAssertLessThanOrEqual(resolved.width * resolved.height, CGFloat(model.maximumInputPixels))
                        XCTAssertTrue(Int(resolved.width).isMultiple(of: 4))
                        XCTAssertTrue(Int(resolved.height).isMultiple(of: 4))
                        let ratioError = abs(resolved.width * size.height / (resolved.height * size.width) - 1)
                        XCTAssertLessThan(ratioError, 0.01)
                    }
                }
            }
        }
    }

    func testMediaAreaLimitsHoldForExtremeRatiosAndAlignmentBoundaries() throws {
        let cases = [
            CGSize(width: 1, height: 200001),
            CGSize(width: 447, height: 448),
            CGSize(width: 999, height: 501),
            CGSize(width: 1449, height: 1450),
            CGSize(width: 65535, height: 65537)
        ]

        for model in RealtimeModel.allCases {
            let service = MediaService(model: model)
            for original in cases {
                for size in [original, CGSize(width: original.height, height: original.width)] {
                    let resolved = try service.resolveMediaSize(
                        size,
                        source: .external
                    )
                    XCTAssertGreaterThanOrEqual(resolved.width * resolved.height, CGFloat(model.minimumInputPixels))
                    XCTAssertLessThanOrEqual(resolved.width * resolved.height, CGFloat(model.maximumInputPixels))
                    XCTAssertTrue(Int(resolved.width).isMultiple(of: 4))
                    XCTAssertTrue(Int(resolved.height).isMultiple(of: 4))
                }
            }
        }
    }

    func testUpscaledMediaDoesNotImposeTheInputMinimumOnTargetSize() throws {
        let service = MediaService()
        let media = try service.resolveMediaSize(
            CGSize(width: 200, height: 200),
            source: .video
        )
        let target = try service.resolveTargetSize(
            media,
            maximumSize: CGSize(width: media.width / 2, height: media.height / 2),
            frameInterpolationEnabled: false
        )

        XCTAssertEqual(media, CGSize(width: 448, height: 448))
        XCTAssertEqual(target, CGSize(width: 224, height: 224))
        XCTAssertLessThan(target.width * target.height, CGFloat(service.model.minimumInputPixels))
    }

    func testCameraBucketValidationOccursBeforeAreaScaling() {
        XCTAssertThrowsError(try MediaService().resolveMediaSize(CGSize(width: 2048, height: 3840), source: .camera)) { error in
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
    }

    func testMediaSizeRejectsInvalidDimensions() {
        for source in RealtimeMediaSource.allCases {
            for width: CGFloat in [.nan, .infinity, 0, -1, 100.5, CGFloat(Int.max)] {
                for size in [CGSize(width: width, height: 600), CGSize(width: 600, height: width)] {
                    XCTAssertThrowsError(try MediaService().resolveMediaSize(size, source: source))
                }
            }
        }
    }
}
