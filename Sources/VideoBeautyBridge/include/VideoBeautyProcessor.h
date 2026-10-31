// Copyright (c) 2026 XMAX.AI PTE. LTD.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// An offline Agora media service, confined to its caller's serial worker queue.
@interface VideoBeautyProcessor : NSObject {
@private
    void *_context;
}

/// Creates a private, unpublished video track with no audio or physical capture devices.
- (nullable instancetype)initWithAppID:(NSString *)appID
                                 options:(NSDictionary<NSString *, NSNumber *> *)options
                                  error:(NSError **)error;

/// Updates the ClearVision strengths without replacing the video track.
- (BOOL)updateOptions:(NSDictionary<NSString *, NSNumber *> *)options error:(NSError **)error;

/// Copies the processed pixels into a bounded NV12 pool; input ownership stays with the caller.
/// A timeout invalidates this processor; the caller must close it before further processing.
/// Pool exhaustion returns kCVReturnWouldExceedAllocationThreshold and permits retry after held outputs are released.
- (nullable CVPixelBufferRef)processPixelBuffer:(CVPixelBufferRef)input
                                        error:(NSError **)error CF_RETURNS_RETAINED;

/// Waits for native media cleanup. Safe to repeat on the serial worker queue.
- (void)close;

@end

NS_ASSUME_NONNULL_END
