//
//  VimbaBridge.mm
//
//  Objective-C++ implementation of the Vimba X wrapper. This file links
//  against libVmbC (installed with the Allied Vision Vimba X SDK).
//
//  Build requirements:
//    - HEADER_SEARCH_PATHS must include <VmbC/VmbC.h>
//    - LIBRARY_SEARCH_PATHS must include libVmbC.dylib
//    - OTHER_LDFLAGS += -lVmbC
//

#import "VimbaBridge.h"

#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <Accelerate/Accelerate.h>

#include <VmbC/VmbC.h>
#include <VmbImageTransform/VmbTransform.h>

#include <atomic>
#include <mutex>
#include <string>
#include <vector>

static NSString *const kVimbaErrorDomain = @"com.mri.pseudohaptic.vimba";

static NSError *VimbaError(VmbError_t code, NSString *context) {
    NSString *msg = [NSString stringWithFormat:@"%@ (VmbError=%d)", context, (int)code];
    return [NSError errorWithDomain:kVimbaErrorDomain
                               code:(NSInteger)code
                           userInfo:@{ NSLocalizedDescriptionKey: msg }];
}

#pragma mark - VimbaCameraInfo

@implementation VimbaCameraInfo
- (instancetype)initWithId:(NSString *)cameraId
                     model:(NSString *)modelName
                    serial:(NSString *)serial
               interfaceId:(NSString *)interfaceId {
    if ((self = [super init])) {
        _cameraId = [cameraId copy];
        _modelName = [modelName copy];
        _serialNumber = [serial copy];
        _interfaceId = [interfaceId copy];
    }
    return self;
}
@end

#pragma mark - VimbaBridge

@interface VimbaBridge () {
    VmbHandle_t _cameraHandle;
    std::vector<VmbFrame_t> _frames;
    std::vector<std::vector<uint8_t>> _frameBuffers;
    std::atomic<bool> _streaming;
    std::mutex _handlerMutex;
    CVPixelBufferPoolRef _pixelBufferPool;
    int _frameWidth;
    int _frameHeight;
    VmbPixelFormat_t _pixelFormat;
}
@property (nonatomic, copy) NSString *cameraId;
@property (nonatomic, copy) VimbaFrameHandler frameHandler;
@end

@implementation VimbaBridge

static std::atomic<int> gStartupCount{0};

+ (BOOL)startupWithError:(NSError **)error {
    if (gStartupCount.fetch_add(1) > 0) {
        return YES;
    }
    VmbError_t err = VmbStartup(nullptr);
    if (err != VmbErrorSuccess) {
        gStartupCount.store(0);
        if (error) *error = VimbaError(err, @"VmbStartup failed");
        return NO;
    }
    return YES;
}

+ (void)shutdown {
    if (gStartupCount.fetch_sub(1) == 1) {
        VmbShutdown();
    } else if (gStartupCount.load() < 0) {
        gStartupCount.store(0);
    }
}

+ (NSArray<VimbaCameraInfo *> *)availableCameras {
    VmbUint32_t count = 0;
    VmbError_t err = VmbCamerasList(nullptr, 0, &count, sizeof(VmbCameraInfo_t));
    if (err != VmbErrorSuccess || count == 0) {
        return @[];
    }
    std::vector<VmbCameraInfo_t> infos(count);
    err = VmbCamerasList(infos.data(), count, &count, sizeof(VmbCameraInfo_t));
    if (err != VmbErrorSuccess) {
        return @[];
    }
    NSMutableArray<VimbaCameraInfo *> *result = [NSMutableArray arrayWithCapacity:count];
    for (VmbUint32_t i = 0; i < count; ++i) {
        const VmbCameraInfo_t &info = infos[i];
        NSString *cameraId = info.cameraIdString ? @(info.cameraIdString) : @"";
        NSString *model = info.modelName ? @(info.modelName) : @"";
        NSString *serial = info.serialString ? @(info.serialString) : @"";
        NSString *interfaceId = info.interfaceIdString ? @(info.interfaceIdString) : @"";
        [result addObject:[[VimbaCameraInfo alloc] initWithId:cameraId
                                                         model:model
                                                        serial:serial
                                                   interfaceId:interfaceId]];
    }
    return result;
}

- (instancetype)initWithCameraId:(NSString *)cameraId {
    if ((self = [super init])) {
        _cameraId = [cameraId copy];
        _cameraHandle = nullptr;
        _streaming = false;
        _pixelBufferPool = nullptr;
        _frameWidth = 0;
        _frameHeight = 0;
        _pixelFormat = VmbPixelFormatMono8;
    }
    return self;
}

- (void)dealloc {
    [self stopStreaming];
    [self close];
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = nullptr;
    }
}

#pragma mark - Open / Close

- (BOOL)openAndConfigureWithError:(NSError **)error {
    VmbError_t err = VmbCameraOpen([_cameraId UTF8String],
                                   VmbAccessModeFull,
                                   &_cameraHandle);
    if (err != VmbErrorSuccess) {
        if (error) *error = VimbaError(err, @"VmbCameraOpen failed");
        return NO;
    }

    // Prefer BGR8 if the camera offers it, otherwise fall back to Mono8.
    // BayerRG8 is debayered on the host via VmbImageTransform.
    const char *desiredFormats[] = { "BGR8Packed", "RGB8Packed", "BayerRG8", "Mono8" };
    for (auto *fmt : desiredFormats) {
        if (VmbFeatureEnumSet(_cameraHandle, "PixelFormat", fmt) == VmbErrorSuccess) {
            break;
        }
    }

    // Read current geometry.
    VmbInt64_t width = 0, height = 0;
    VmbFeatureIntGet(_cameraHandle, "Width", &width);
    VmbFeatureIntGet(_cameraHandle, "Height", &height);
    _frameWidth = (int)width;
    _frameHeight = (int)height;
    _sensorWidth = (NSInteger)width;
    _sensorHeight = (NSInteger)height;

    const char *pixelFormatName = nullptr;
    if (VmbFeatureEnumGet(_cameraHandle, "PixelFormat", &pixelFormatName) == VmbErrorSuccess
        && pixelFormatName != nullptr) {
        if (strcmp(pixelFormatName, "BGR8Packed") == 0) {
            _pixelFormat = VmbPixelFormatBgr8;
        } else if (strcmp(pixelFormatName, "RGB8Packed") == 0) {
            _pixelFormat = VmbPixelFormatRgb8;
        } else if (strcmp(pixelFormatName, "BayerRG8") == 0) {
            _pixelFormat = VmbPixelFormatBayerRG8;
        } else {
            _pixelFormat = VmbPixelFormatMono8;
        }
    }

    // Enable continuous acquisition at the maximum rate supported.
    VmbFeatureEnumSet(_cameraHandle, "AcquisitionMode", "Continuous");
    VmbFeatureEnumSet(_cameraHandle, "TriggerMode", "Off");
    VmbFeatureBoolSet(_cameraHandle, "AcquisitionFrameRateEnable", true);
    // GigE-specific: try to set a sensible streaming packet size.
    VmbFeatureCommandRun(_cameraHandle, "GVSPAdjustPacketSize");

    double frameRate = 0.0;
    VmbFeatureFloatGet(_cameraHandle, "AcquisitionFrameRate", &frameRate);
    _acquisitionFrameRate = frameRate;

    // Build a reusable CVPixelBufferPool for BGRA output.
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(_frameWidth),
        (id)kCVPixelBufferHeightKey: @(_frameHeight),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVReturn cvErr = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                             nullptr,
                                             (__bridge CFDictionaryRef)attrs,
                                             &_pixelBufferPool);
    if (cvErr != kCVReturnSuccess) {
        if (error) *error = [NSError errorWithDomain:kVimbaErrorDomain
                                                 code:(NSInteger)cvErr
                                             userInfo:@{ NSLocalizedDescriptionKey: @"CVPixelBufferPoolCreate failed" }];
        return NO;
    }

    return YES;
}

- (void)close {
    if (_cameraHandle) {
        VmbCameraClose(_cameraHandle);
        _cameraHandle = nullptr;
    }
}

#pragma mark - Streaming

static void VMB_CALL frameCallback(const VmbHandle_t cameraHandle,
                                   const VmbHandle_t streamHandle,
                                   VmbFrame_t *frame) {
    (void)streamHandle;
    if (frame == nullptr) return;
    VimbaBridge *bridge = (__bridge VimbaBridge *)frame->context[0];
    [bridge handleIncomingFrame:frame];
    VmbCaptureFrameQueue(cameraHandle, frame, &frameCallback);
}

- (BOOL)startStreamingWithHandler:(VimbaFrameHandler)frameHandler
                            error:(NSError **)error {
    if (_streaming.load()) {
        return YES;
    }
    {
        std::lock_guard<std::mutex> lock(_handlerMutex);
        self.frameHandler = frameHandler;
    }

    VmbInt64_t payloadSize = 0;
    VmbError_t err = VmbPayloadSizeGet(_cameraHandle, &payloadSize);
    if (err != VmbErrorSuccess || payloadSize <= 0) {
        if (error) *error = VimbaError(err, @"VmbPayloadSizeGet failed");
        return NO;
    }

    constexpr size_t kNumBuffers = 5;
    _frames.assign(kNumBuffers, VmbFrame_t{});
    _frameBuffers.assign(kNumBuffers, std::vector<uint8_t>(payloadSize));

    for (size_t i = 0; i < kNumBuffers; ++i) {
        _frames[i].buffer = _frameBuffers[i].data();
        _frames[i].bufferSize = payloadSize;
        _frames[i].context[0] = (__bridge void *)self;
        err = VmbFrameAnnounce(_cameraHandle, &_frames[i], sizeof(VmbFrame_t));
        if (err != VmbErrorSuccess) {
            if (error) *error = VimbaError(err, @"VmbFrameAnnounce failed");
            return NO;
        }
    }

    err = VmbCaptureStart(_cameraHandle);
    if (err != VmbErrorSuccess) {
        if (error) *error = VimbaError(err, @"VmbCaptureStart failed");
        return NO;
    }

    for (size_t i = 0; i < kNumBuffers; ++i) {
        err = VmbCaptureFrameQueue(_cameraHandle, &_frames[i], &frameCallback);
        if (err != VmbErrorSuccess) {
            if (error) *error = VimbaError(err, @"VmbCaptureFrameQueue failed");
            return NO;
        }
    }

    err = VmbFeatureCommandRun(_cameraHandle, "AcquisitionStart");
    if (err != VmbErrorSuccess) {
        if (error) *error = VimbaError(err, @"AcquisitionStart failed");
        return NO;
    }

    _streaming.store(true);
    return YES;
}

- (void)stopStreaming {
    if (!_streaming.load()) {
        return;
    }
    _streaming.store(false);

    VmbFeatureCommandRun(_cameraHandle, "AcquisitionStop");
    VmbCaptureEnd(_cameraHandle);
    VmbCaptureQueueFlush(_cameraHandle);
    VmbFrameRevokeAll(_cameraHandle);

    _frames.clear();
    _frameBuffers.clear();

    {
        std::lock_guard<std::mutex> lock(_handlerMutex);
        self.frameHandler = nil;
    }
}

#pragma mark - Frame conversion

- (void)handleIncomingFrame:(VmbFrame_t *)frame {
    if (frame->receiveStatus != VmbFrameStatusComplete) {
        if (self.errorHandler) {
            NSError *e = VimbaError((VmbError_t)frame->receiveStatus,
                                    @"Dropped or incomplete frame");
            self.errorHandler(e);
        }
        return;
    }

    CVPixelBufferRef pixelBuffer = [self pixelBufferFromFrame:frame];
    if (!pixelBuffer) {
        return;
    }

    VimbaFrameHandler handler;
    {
        std::lock_guard<std::mutex> lock(_handlerMutex);
        handler = self.frameHandler;
    }
    if (handler) {
        CMTime pts = CMTimeMake((int64_t)frame->timestamp, 1000000000);
        handler(pixelBuffer, pts);
    }
    CVPixelBufferRelease(pixelBuffer);
}

/// Converts an incoming VmbFrame into a BGRA CVPixelBuffer pulled from
/// the reusable pool. Uses VmbImageTransform for anything non-BGRA and
/// vImage for efficient copies. Returns a +1 retained pixel buffer.
- (CVPixelBufferRef)pixelBufferFromFrame:(VmbFrame_t *)frame {
    if (_pixelBufferPool == nullptr) return nullptr;

    CVPixelBufferRef outBuffer = nullptr;
    CVReturn cvErr = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                        _pixelBufferPool,
                                                        &outBuffer);
    if (cvErr != kCVReturnSuccess || outBuffer == nullptr) {
        return nullptr;
    }

    CVPixelBufferLockBaseAddress(outBuffer, 0);
    uint8_t *dstBase = (uint8_t *)CVPixelBufferGetBaseAddress(outBuffer);
    size_t dstStride = CVPixelBufferGetBytesPerRow(outBuffer);
    size_t width = CVPixelBufferGetWidth(outBuffer);
    size_t height = CVPixelBufferGetHeight(outBuffer);

    // Describe the source image.
    VmbImage src{};
    src.Size = sizeof(src);
    src.Data = frame->buffer;
    VmbSetImageInfoFromPixelFormat(frame->pixelFormat, (VmbUint32_t)width, (VmbUint32_t)height, &src);

    // Describe the destination (BGRA).
    VmbImage dst{};
    dst.Size = sizeof(dst);
    dst.Data = dstBase;
    VmbSetImageInfoFromString("BGRA8", 5, (VmbUint32_t)width, (VmbUint32_t)height, &dst);
    dst.ImageInfo.Stride = (VmbUint32_t)dstStride;

    VmbError_t err = VmbImageTransform(&src, &dst, nullptr, 0);
    if (err != VmbErrorSuccess && self.errorHandler) {
        self.errorHandler(VimbaError(err, @"VmbImageTransform failed"));
    }

    CVPixelBufferUnlockBaseAddress(outBuffer, 0);
    return outBuffer;
}

@end
