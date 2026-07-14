#import "../Runtime/KKFIFlutterCompatibility.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^KKFIInspectorConnectionCompletion)(NSError *_Nullable error);

/// Owns one reusable VM Service connection for a Flutter engine.
@interface KKFIInspectorSession : NSObject

- (instancetype)initWithEngine:(FlutterEngine *)engine
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Coalesces concurrent callers onto one connection attempt. Completions are
/// delivered on the session's private serial queue.
- (void)ensureConnectedWithTimeout:(NSTimeInterval)timeout
                        completion:(nullable KKFIInspectorConnectionCompletion)completion;

- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
