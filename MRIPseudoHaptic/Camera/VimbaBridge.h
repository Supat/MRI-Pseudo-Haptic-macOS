//
//  VimbaBridge.h
//
//  Thin Objective-C facade over the Allied Vision Vimba X C API (VmbC).
//  Swift talks to this class; the implementation file is Objective-C++
//  so it can include <VmbC/VmbC.h> directly.
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Delivered whenever a new frame is converted to a BGRA CVPixelBuffer.
/// The buffer is retained for the duration of the call; the receiver must
/// retain it explicitly if it needs to hold on longer.
typedef void (^VimbaFrameHandler)(CVPixelBufferRef pixelBuffer,
                                  CMTime presentationTime);

/// Delivered on any asynchronous error from the transport layer.
typedef void (^VimbaErrorHandler)(NSError *error);

/// Minimal camera description surfaced to Swift.
@interface VimbaCameraInfo : NSObject
@property (nonatomic, readonly, copy) NSString *cameraId;
@property (nonatomic, readonly, copy) NSString *modelName;
@property (nonatomic, readonly, copy) NSString *serialNumber;
@property (nonatomic, readonly, copy) NSString *interfaceId;
- (instancetype)initWithId:(NSString *)cameraId
                     model:(NSString *)modelName
                    serial:(NSString *)serial
               interfaceId:(NSString *)interfaceId;
@end

@interface VimbaBridge : NSObject

/// Starts the Vimba system (loads transport layers). Safe to call repeatedly.
+ (BOOL)startupWithError:(NSError * _Nullable * _Nullable)error;

/// Shuts the Vimba system down. Must be called from the app's terminate hook.
+ (void)shutdown;

/// Enumerates every camera currently visible to the transport layer.
+ (NSArray<VimbaCameraInfo *> *)availableCameras;

- (instancetype)init NS_UNAVAILABLE;

/// Creates an unopened handle for the camera with the given ID.
- (instancetype)initWithCameraId:(NSString *)cameraId NS_DESIGNATED_INITIALIZER;

/// Opens the camera and configures BayerRG8 / Mono8 / BGR8 → BGRA conversion.
/// Returns NO and populates `error` on failure.
- (BOOL)openAndConfigureWithError:(NSError * _Nullable * _Nullable)error;

/// Begins asynchronous streaming. Frames are delivered on a private queue
/// that is safe to block briefly; expensive work should be dispatched off it.
- (BOOL)startStreamingWithHandler:(VimbaFrameHandler)frameHandler
                            error:(NSError * _Nullable * _Nullable)error;

/// Stops streaming and releases the frame buffers.
- (void)stopStreaming;

/// Closes the camera. Leaves the Vimba system running.
- (void)close;

/// Handler for transport-layer errors (dropped frames, lost link, etc).
@property (nonatomic, copy, nullable) VimbaErrorHandler errorHandler;

/// Current acquisition frame rate (Hz), read from the camera. 0 if unknown.
@property (nonatomic, readonly) double acquisitionFrameRate;

/// Reported sensor width/height in pixels.
@property (nonatomic, readonly) NSInteger sensorWidth;
@property (nonatomic, readonly) NSInteger sensorHeight;

@end

NS_ASSUME_NONNULL_END
