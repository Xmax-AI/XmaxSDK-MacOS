// Copyright (c) 2026 XMAX.AI PTE. LTD.

#import "BeautyProcessor.h"
#include <AgoraRtcKit/IAgoraService.h>
#include <AgoraRtcKit/NGIAgoraMediaNodeFactory.h>
#include <AgoraRtcKit/NGIAgoraMediaNode.h>
#include <AgoraRtcKit/NGIAgoraVideoTrack.h>
#include <AgoraRtcKit/AgoraRefCountedObject.h>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <vector>

using namespace agora;

namespace {
/// The registered native extension names, independent of RTC source selection.
constexpr auto provider = "agora_video_filters_clear_vision";
constexpr auto extensionName = "clear_vision";
constexpr auto trackName = "xmax-result-beauty";
// Matches the private BeautyWorkerFrameStatus.unavailable wire value.
constexpr NSInteger frameUnavailable = -10001;

/// Copies native callback pixels before Agora recycles its frame storage.
class BeautySink : public rtc::IVideoFilter {
public:
    std::mutex mutex;
    std::condition_variable ready;
    CVPixelBufferRef output = nullptr;
    CVPixelBufferPoolRef pool = nullptr;
    int width = 0;
    int height = 0;
    bool waiting = false;
    bool completed = false;
    bool supportedFrame = false;
    int outputType = 0;
    CVReturn allocationResult = kCVReturnSuccess;

    ~BeautySink() {
        if (output) CVPixelBufferRelease(output);
        if (pool) CVPixelBufferPoolRelease(pool);
    }

    bool adaptVideoFrame(const media::base::VideoFrame &frame, media::base::VideoFrame &adapted) override {
        adapted = frame;
        std::lock_guard<std::mutex> guard(mutex);
        if (!waiting) return true;
        waiting = false;
        completed = true;
        supportedFrame = false;
        outputType = frame.type;
        allocationResult = kCVReturnError;
        // Agora 4.6.2 filter callbacks label their three I420 planes as DEFAULT or I420.
        // Check all plane pointers and strides before copying either representation.
        if ((frame.type == media::base::VIDEO_PIXEL_I420 || frame.type == media::base::VIDEO_PIXEL_DEFAULT) && frame.width > 0 && frame.height > 0 &&
            frame.width % 2 == 0 && frame.height % 2 == 0 && frame.yBuffer && frame.uBuffer && frame.vBuffer &&
            frame.yStride >= frame.width && frame.uStride >= frame.width / 2 && frame.vStride >= frame.width / 2) {
            supportedFrame = true;
            if (width != frame.width || height != frame.height) {
                if (pool) CVPixelBufferPoolRelease(pool);
                pool = nullptr;
                width = frame.width;
                height = frame.height;
                NSDictionary *attributes = @{
                    (id)kCVPixelBufferWidthKey: @(width),
                    (id)kCVPixelBufferHeightKey: @(height),
                    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                    (id)kCVPixelBufferMetalCompatibilityKey: @YES
                };
                allocationResult = CVPixelBufferPoolCreate(nullptr, nullptr, (__bridge CFDictionaryRef)attributes, &pool);
            }
            NSDictionary *limit = @{(id)kCVPixelBufferPoolAllocationThresholdKey: @16};
            if (pool) allocationResult = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                nullptr, pool, (__bridge CFDictionaryRef)limit, &output);
            if (output && allocationResult == kCVReturnSuccess) {
                CVPixelBufferLockBaseAddress(output, 0);
                auto y = static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(output, 0));
                auto uv = static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(output, 1));
                const auto yStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0);
                const auto uvStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1);
                for (int row = 0; row < height; ++row)
                    memcpy(y + row * yStride, frame.yBuffer + row * frame.yStride, width);
                for (int row = 0; row < height / 2; ++row)
                    for (int column = 0; column < width / 2; ++column) {
                        uv[row * uvStride + column * 2] = frame.uBuffer[row * frame.uStride + column];
                        uv[row * uvStride + column * 2 + 1] = frame.vBuffer[row * frame.vStride + column];
                    }
                CVPixelBufferUnlockBaseAddress(output, 0);
                // ClearVision's I420 renderer uses video-range BT.709 output.
                CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey,
                                      kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
                CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey,
                                      kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
                CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey,
                                      kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
            }
        }
        ready.notify_one();
        return true;
    }
};

/// Owns a local-only media graph; it never creates an RTC connection or an RTC engine singleton.
struct BeautyContext {
    base::IAgoraService *service = nullptr;
    agora_refptr<rtc::IMediaNodeFactory> factory;
    agora_refptr<rtc::IVideoFrameSender> sender;
    agora_refptr<rtc::ILocalVideoTrack> track;
    agora_refptr<BeautySink> sink;
    std::vector<uint8_t> inputBytes;
    int64_t timestamp = 0;

    ~BeautyContext() {
        if (track) {
            track->setEnabled(false);
            if (sink) track->removeVideoFilter(sink, media::base::POSITION_POST_CAPTURER, "xmax-result-copy");
        }
        track = nullptr;
        sink = nullptr;
        sender = nullptr;
        factory = nullptr;
        if (service) service->release();
    }
};

/// Reports operation failures through Swift's throwing Objective-C bridge.
bool fail(NSError **error, NSString *message, NSInteger code = -1) {
    if (error) *error = [NSError errorWithDomain:@"ai.xmax.video-beauty" code:code
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    return false;
}
}

@implementation BeautyProcessor

- (instancetype)initWithAppID:(NSString *)appID options:(NSDictionary<NSString *, NSNumber *> *)options error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    auto context = new BeautyContext();
    _context = context;
    context->service = createAgoraService();
    if (!context->service) { fail(error, @"Unable to create the beauty media service"); return nil; }
    base::AgoraServiceConfiguration config;
    config.appId = appID.UTF8String;
    config.enableVideo = true;
    config.enableAudioDevice = false;
    config.enableAudioProcessor = false;
    int result = context->service->initialize(config);
    if (result != 0) { fail(error, @"Unable to initialize the beauty media service", result); return nil; }
    result = context->service->enableExtension(provider, extensionName, trackName, true);
    if (result != 0) { fail(error, @"ClearVision is unavailable on this device", result); return nil; }
    context->factory = context->service->createMediaNodeFactory();
    if (context->factory) context->sender = context->factory->createVideoFrameSender();
    if (context->sender) context->track = context->service->createCustomVideoTrack(context->sender, trackName);
    if (!context->track) { fail(error, @"Unable to create the beauty video track"); return nil; }
    context->sink = new RefCountedObject<BeautySink>();
    if (!context->track->addVideoFilter(context->sink, media::base::POSITION_POST_CAPTURER, "xmax-result-copy") ||
        context->track->setEnabled(true) != 0 || ![self updateOptions:options error:error]) {
        if (error && !*error) fail(error, @"Unable to start the beauty renderer");
        return nil;
    }
    return self;
}

- (BOOL)updateOptions:(NSDictionary<NSString *, NSNumber *> *)options error:(NSError **)error {
    auto context = static_cast<BeautyContext *>(_context);
    if (!context || !context->track) return fail(error, @"The beauty processor is closed");
    NSData *json = [NSJSONSerialization dataWithJSONObject:options options:0 error:error];
    if (!json) return NO;
    NSString *value = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    int result = context->track->setFilterProperty(context->service->getExtensionId(provider, extensionName),
                                                  "beauty_effect_option", value.UTF8String);
    return result == 0 || fail(error, @"Unable to apply beauty options", result);
}

- (CVPixelBufferRef)processPixelBuffer:(CVPixelBufferRef)input error:(NSError **)error {
    auto context = static_cast<BeautyContext *>(_context);
    if (!context) { fail(error, @"The beauty processor is closed"); return nullptr; }
    const size_t width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input);
    const OSType format = CVPixelBufferGetPixelFormatType(input);
    if (!width || !height || width % 2 || height % 2 || width > INT_MAX || height > INT_MAX ||
        (format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
         format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange && format != kCVPixelFormatType_32BGRA)) {
        fail(error, @"Beauty requires even-sized NV12 or BGRA frames"); return nullptr;
    }
    media::base::ExternalVideoFrame frame;
    frame.type = media::base::ExternalVideoFrame::VIDEO_BUFFER_RAW_DATA;
    frame.stride = static_cast<int>(width);
    frame.height = static_cast<int>(height);
    // A private monotonic submission clock avoids changing the public frame's original PTS.
    context->timestamp = std::max(context->timestamp + 1,
        static_cast<int64_t>(NSProcessInfo.processInfo.systemUptime * 1000));
    frame.timestamp = context->timestamp;
    frame.colorSpace.primaries = media::base::ColorSpace::PRIMARYID_BT709;
    frame.colorSpace.transfer = media::base::ColorSpace::TRANSFERID_BT709;
    frame.colorSpace.matrix = media::base::ColorSpace::MATRIXID_BT709;
    frame.colorSpace.range = format == kCVPixelFormatType_32BGRA
        ? media::base::ColorSpace::RANGEID_FULL : media::base::ColorSpace::RANGEID_LIMITED;
    if (CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        fail(error, @"Unable to read beauty input pixels"); return nullptr;
    }
    if (format == kCVPixelFormatType_32BGRA) {
        frame.format = media::base::VIDEO_PIXEL_BGRA;
        context->inputBytes.resize(width * height * 4);
        auto source = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(input));
        for (size_t row = 0; row < height; ++row)
            memcpy(context->inputBytes.data() + row * width * 4,
                   source + row * CVPixelBufferGetBytesPerRow(input), width * 4);
    } else {
        frame.format = media::base::VIDEO_PIXEL_NV12;
        context->inputBytes.resize(width * height * 3 / 2);
        auto y = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(input, 0));
        auto uv = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(input, 1));
        for (size_t row = 0; row < height; ++row)
            memcpy(context->inputBytes.data() + row * width,
                   y + row * CVPixelBufferGetBytesPerRowOfPlane(input, 0), width);
        for (size_t row = 0; row < height / 2; ++row)
            memcpy(context->inputBytes.data() + width * height + row * width,
                   uv + row * CVPixelBufferGetBytesPerRowOfPlane(input, 1), width);
        // Normalize full-range decoder output before the limited-range ClearVision graph.
        if (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            for (size_t index = 0; index < width * height; ++index)
                context->inputBytes[index] = 16 + (context->inputBytes[index] * 219 + 127) / 255;
            for (size_t index = width * height; index < context->inputBytes.size(); ++index)
                context->inputBytes[index] = (context->inputBytes[index] * 224 + 127) / 255 + 16;
        }
    }
    CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
    frame.buffer = context->inputBytes.data();
    auto sink = context->sink;
    {
        std::lock_guard<std::mutex> guard(sink->mutex);
        sink->completed = false;
        sink->waiting = true;
    }
    int result = context->sender->sendVideoFrame(frame);
    std::unique_lock<std::mutex> guard(sink->mutex);
    if (result != 0) {
        sink->waiting = false;
        fail(error, [NSString stringWithFormat:@"ClearVision rejected the beauty frame (%d)", result],
             frameUnavailable);
        return nullptr;
    }
    if (!sink->ready.wait_for(guard, std::chrono::milliseconds(150), [&] { return sink->completed; })) {
        sink->waiting = false;
        fail(error, @"ClearVision did not return a beauty frame within 150 ms", frameUnavailable);
        return nullptr;
    }
    CVPixelBufferRef output = sink->output;
    sink->output = nullptr;
    if (!output) {
        if (!sink->supportedFrame) {
            fail(error, [NSString stringWithFormat:@"Unsupported ClearVision output frame type: %d", sink->outputType]);
        } else {
            fail(error, [NSString stringWithFormat:@"Beauty output buffer allocation failed: %d", sink->allocationResult],
                 sink->allocationResult);
        }
    }
    return output;
}

- (void)close {
    delete static_cast<BeautyContext *>(_context);
    _context = nullptr;
}

- (void)dealloc { [self close]; }

@end
