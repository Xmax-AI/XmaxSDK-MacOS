//
//  GenerationSizingTests.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import XCTest
@testable import XmaxSDK

final class GenerationSizingTests: XCTestCase {
    func testCappedMediaSizeBecomesUplinkBaselineWithoutChangingGenerationBucket() throws {
        let service = MediaService()
        let mediaSize = try service.resolveMediaSize(CGSize(width: 3840, height: 2160), source: .video)
        let baseline = RealtimeVideoFormat(width: Int(mediaSize.width), height: Int(mediaSize.height), fps: 30)

        XCTAssertEqual(mediaSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(QualityVideoFormat.resolve(baseline, level: 2, downlink: false).size, CGSize(width: 1728, height: 972))
        XCTAssertEqual(QualityVideoFormat.resolve(baseline, level: 5, downlink: false).size, CGSize(width: 960, height: 540))
        XCTAssertEqual(try service.resolveGenerationSize(mediaSize), CGSize(width: 1920, height: 1024))
    }

    func testGenerationCanvasUsesNearestBucketWithoutValidatingMediaAsBucket() throws {
        let service = MediaService()
        XCTAssertEqual(try service.resolveGenerationSize(CGSize(width: 1080, height: 1920)), CGSize(width: 1024, height: 1920))
        XCTAssertEqual(try service.resolveGenerationSize(CGSize(width: 3840, height: 2160)), CGSize(width: 1920, height: 1024))
        XCTAssertEqual(try service.resolveGenerationSize(CGSize(width: 640, height: 480)), CGSize(width: 1920, height: 1024))
        XCTAssertThrowsError(try service.resolveMediaSize(CGSize(width: 1080, height: 1920), source: .camera))
        XCTAssertThrowsError(try service.resolveGenerationSize(.zero))
    }

    func testInterpolationAndNetworkLimitsAreCombinedNotMultiplied() throws {
        let baseline = RealtimeVideoFormat(width: 1024, height: 1920, fps: 30)
        let limit = try targetFormat(baseline, level: 1, interpolation: true).size
        XCTAssertEqual(limit, CGSize(width: 672, height: 1260))
        let expected = [limit, limit, limit, CGSize(width: 608, height: 1140), CGSize(width: 512, height: 960)]
        for level in 1...5 {
            let format = try targetFormat(baseline, level: level, interpolation: true)
            XCTAssertEqual(format.size, expected[level - 1])
            XCTAssertLessThanOrEqual(format.width * format.height, 900000)
            XCTAssertEqual(format.width * baseline.height, format.height * baseline.width)
        }
        let disabled = try targetFormat(baseline, level: 4, interpolation: false)
        XCTAssertEqual(disabled.size, CGSize(width: 608, height: 1140))
        XCTAssertEqual(try targetFormat(baseline, level: 1, interpolation: false).size, baseline.size)
    }

    func testReturnSizeUsesVideoSourceNotGenerationCanvas() throws {
        let source = RealtimeVideoFormat(width: 1080, height: 1920, fps: 30)
        let service = MediaService()
        let canvas = try service.resolveGenerationSize(source.size)
        XCTAssertEqual(canvas.width, 1024)
        let normal = try targetFormat(source, level: 2, interpolation: false)
        XCTAssertEqual(normal.size, CGSize(width: 972, height: 1728))
        let interpolated = try targetFormat(source, level: 2, interpolation: true)
        XCTAssertEqual(interpolated.size, CGSize(width: 684, height: 1216))
        XCTAssertEqual(interpolated.width * 16, interpolated.height * 9)
    }

    func testUplinkAndReturnSizeBothFallBackToFourAlignment() throws {
        let source = RealtimeVideoFormat(width: 802, height: 600, fps: 30)
        let target = try targetFormat(source, level: 1, interpolation: false)
        XCTAssertEqual(target.size, CGSize(width: 800, height: 600))
        XCTAssertEqual(QualityVideoFormat.resolve(source, level: 1, downlink: false).size, CGSize(width: 800, height: 600))
    }

    func testReturnSizeRemainsAlignedAndWithinLimitsAcrossTiersAndOrientations() throws {
        let sizes = [(720, 1280), (832, 1472), (1024, 1920), (1922, 1080), (802, 600), (160, 120)]
        for (width, height) in sizes {
            for (w, h) in [(width, height), (height, width)] {
                let source = RealtimeVideoFormat(width: w, height: h, fps: 30)
                for level in 1...5 {
                    let network = QualityVideoFormat.resolveDownlinkMaximumSize(source, level: level)
                    for interpolation in [false, true] {
                        let target = try targetFormat(source, level: level, interpolation: interpolation)
                        XCTAssertTrue(target.width.isMultiple(of: 4))
                        XCTAssertTrue(target.height.isMultiple(of: 4))
                        XCTAssertGreaterThanOrEqual(target.width, 4)
                        XCTAssertGreaterThanOrEqual(target.height, 4)
                        XCTAssertLessThanOrEqual(Double(target.width), network.width)
                        XCTAssertLessThanOrEqual(Double(target.height), network.height)
                        XCTAssertLessThanOrEqual(target.width, source.width)
                        XCTAssertLessThanOrEqual(target.height, source.height)
                        let ratioError = abs(Double(target.width) * Double(h) / (Double(target.height) * Double(w)) - 1)
                        XCTAssertLessThan(ratioError, 0.01)
                        if interpolation {
                            XCTAssertLessThanOrEqual(target.width * target.height, 900000)
                        }
                    }
                }
            }
        }
    }

    func testReturnSizeRejectsDimensionsThatCannotFitFourPixels() {
        for size in [(2, 600), (600, 2)] {
            let source = RealtimeVideoFormat(width: size.0, height: size.1, fps: 30)
            XCTAssertThrowsError(try targetFormat(source, level: 1, interpolation: false)) { error in
                XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
            }
        }
    }
    func testLowerTierWithinBudgetDoesNotShrinkForInterpolation() throws {
        let source = RealtimeVideoFormat(width: 1922, height: 1080, fps: 30)
        for level in [4, 5] {
            let plain = try targetFormat(source, level: level, interpolation: false)
            let interpolated = try targetFormat(source, level: level, interpolation: true)
            XCTAssertEqual(plain.size, interpolated.size)
        }
    }

    func testDownlinkBoundsRemainUnalignedUntilTargetSizeResolution() throws {
        let source = RealtimeVideoFormat(width: 1024, height: 1920, fps: 30)
        let bounds = QualityVideoFormat.resolveDownlinkMaximumSize(source, level: 2)
        XCTAssertEqual(bounds.width, 921.6, accuracy: 0.0001)
        XCTAssertEqual(bounds.height, 1728, accuracy: 0.0001)
        XCTAssertEqual(try targetFormat(source, level: 2, interpolation: false).size, CGSize(width: 896, height: 1680))
    }

    func testUplinkTiersPreserveMinimumAreaAndFourPixelAlignment() throws {
        let minimum = 200000
        XCTAssertEqual(RealtimeModel.x2_1_1_preview_cn.minimumInputPixels, minimum)
        for (width, height) in [(1024, 1920), (1920, 1024), (1000, 600), (640, 480), (448, 448), (500, 400)] {
            let baseline = RealtimeVideoFormat(width: width, height: height, fps: 30)
            for level in 1...5 {
                let uplink = QualityVideoFormat.resolve(baseline, level: level, downlink: false, minimumInputPixels: minimum)
                XCTAssertGreaterThanOrEqual(uplink.width * uplink.height, minimum)
                XCTAssertLessThanOrEqual(uplink.width, width)
                XCTAssertLessThanOrEqual(uplink.height, height)
                XCTAssertTrue(uplink.width.isMultiple(of: 4))
                XCTAssertTrue(uplink.height.isMultiple(of: 4))
            }
        }
        let baseline = RealtimeVideoFormat(width: 1024, height: 1920, fps: 30)
        let expected = [(1024, 1920, 30), (896, 1680, 24), (768, 1440, 24), (608, 1140, 20), (512, 960, 16)]
        for (index, size) in expected.enumerated() {
            let format = QualityVideoFormat.resolve(baseline, level: index + 1, downlink: false, minimumInputPixels: minimum)
            XCTAssertEqual(format.size, CGSize(width: size.0, height: size.1))
            XCTAssertEqual(format.fps, size.2)
        }
        let small = RealtimeVideoFormat(width: 640, height: 480, fps: 30)
        let downlink = QualityVideoFormat.resolve(small, level: 5, downlink: true, minimumInputPixels: minimum)
        XCTAssertLessThan(downlink.width * downlink.height, minimum)
    }

    func testQualityControllerRetainsModelMinimumAfterDowngrading() throws {
        let name = "XmaxSizingTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = QualityController(rtcManager: RtcManagingStub(), historyDefaults: defaults)
        for model in RealtimeModel.allCases {
            let initial = controller.prepareQuality(
                baseline: RealtimeVideoFormat(width: 640, height: 480, fps: 30), model: model.rawValue
            )
            XCTAssertEqual(initial.minimumInputPixels, 200000)
            controller.completeQuality(downlink: false, level: 5, success: true)
            controller.completeQuality(downlink: true, level: 5, success: true)
            let configuration = try XCTUnwrap(controller.qualityConfiguration)
            XCTAssertEqual(configuration.minimumInputPixels, 200000)
            XCTAssertEqual(configuration.uplink.size, CGSize(width: 528, height: 396))
            XCTAssertLessThan(configuration.downlink.width * configuration.downlink.height, 200000)
        }
    }

    func testGenerationSizeDispatchesToCustomMediaService() throws {
        let expected = CGSize(width: 1280, height: 720)
        let service: any MediaServicing = MediaServicingStub(resolvedSize: expected, resolvedGenerationSize: expected)
        XCTAssertEqual(try service.resolveGenerationSize(CGSize(width: 1920, height: 1080)), expected)
    }

    private func targetFormat(_ baseline: RealtimeVideoFormat, level: Int, interpolation: Bool) throws -> RealtimeVideoFormat {
        let maximumSize = QualityVideoFormat.resolveDownlinkMaximumSize(baseline, level: level)
        let target = try MediaService().resolveTargetSize(
            baseline.size,
            maximumSize: maximumSize,
            frameInterpolationEnabled: interpolation
        )
        return QualityVideoFormat.resolve(baseline, level: level, downlink: true)
            .resized(width: Int(target.width), height: Int(target.height))
    }

}
