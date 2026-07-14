#import "KKFIInspectorSession.h"

#import "../Connection/KKFIVMServiceClient.h"

static NSString *const KKFIInspectorSessionErrorDomain =
    @"KKFIInspectorSessionErrorDomain";

typedef NS_ENUM(NSInteger, KKFIInspectorSessionErrorCode) {
    KKFIInspectorSessionErrorEngineReleased = 1,
    KKFIInspectorSessionErrorTimedOut,
    KKFIInspectorSessionErrorInvalidated,
};

typedef NS_ENUM(NSUInteger, KKFIInspectorSessionState) {
    KKFIInspectorSessionStateIdle,
    KKFIInspectorSessionStateConnecting,
    KKFIInspectorSessionStateConnected,
};

@interface KKFIInspectorSession ()

@property(nonatomic, weak) FlutterEngine *engine;
@property(nonatomic) dispatch_queue_t stateQueue;
@property(nonatomic) KKFIInspectorSessionState state;
@property(nonatomic) NSUInteger attemptID;
@property(nonatomic, strong, nullable) KKFIVMServiceClient *serviceClient;
@property(nonatomic, strong)
    NSMutableArray<KKFIInspectorConnectionCompletion> *connectionWaiters;

@end

@implementation KKFIInspectorSession

- (instancetype)initWithEngine:(FlutterEngine *)engine {
    self = [super init];
    if (self) {
        _engine = engine;
        _stateQueue = dispatch_queue_create(
            "com.kkflutterinspector.inspector-session", DISPATCH_QUEUE_SERIAL);
        _state = KKFIInspectorSessionStateIdle;
        _connectionWaiters = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    [_serviceClient close];
}

- (void)ensureConnectedWithTimeout:(NSTimeInterval)timeout
                        completion:(KKFIInspectorConnectionCompletion)completion {
    KKFIInspectorConnectionCompletion completionCopy = [completion copy];
    dispatch_async(self.stateQueue, ^{
        if (self.state == KKFIInspectorSessionStateConnected) {
            if (completionCopy != nil) {
                completionCopy(nil);
            }
            return;
        }

        if (completionCopy != nil) {
            [self.connectionWaiters addObject:completionCopy];
        }

        if (self.state == KKFIInspectorSessionStateConnecting) {
            return;
        }

        self.state = KKFIInspectorSessionStateConnecting;
        NSUInteger attemptID = ++self.attemptID;
        [self scheduleTimeout:MAX(timeout, 0.1) attemptID:attemptID];
        [self tryConnectWithAttemptID:attemptID];
    });
}

- (void)tryConnectWithAttemptID:(NSUInteger)attemptID {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) {
            return;
        }

        FlutterEngine *engine = self.engine;
        BOOL engineAvailable = engine != nil;
        NSURL *serviceURL = engine.vmServiceUrl;
        NSString *isolateID = [engine.isolateId copy];

        dispatch_async(self.stateQueue, ^{
            if (self.state != KKFIInspectorSessionStateConnecting ||
                self.attemptID != attemptID) {
                return;
            }

            if (!engineAvailable) {
                [self finishAttempt:attemptID
                              error:[self.class
                                  errorWithCode:KKFIInspectorSessionErrorEngineReleased
                                     description:@"The Flutter engine was released before the VM Service connected."]];
                return;
            }

            if (serviceURL == nil || isolateID.length == 0) {
                [self clearConnection];
                [self scheduleRetryForAttemptID:attemptID];
                return;
            }

            // A retry can already be queued when a new handshake starts. Let
            // the in-flight getVM request finish instead of creating a second
            // WebSocket for the same attempt.
            if (self.serviceClient != nil) {
                return;
            }

            NSError *clientError = nil;
            KKFIVMServiceClient *client = [[KKFIVMServiceClient alloc]
                initWithServiceURI:serviceURL.absoluteString
                     callbackQueue:self.stateQueue
                             error:&clientError];
            if (client == nil) {
                [self finishAttempt:attemptID error:clientError];
                return;
            }

            self.serviceClient = client;

            __weak typeof(self) weakSession = self;
            __weak KKFIVMServiceClient *weakClient = client;
            client.disconnectHandler = ^(__unused NSError *error) {
                __strong typeof(weakSession) self = weakSession;
                KKFIVMServiceClient *disconnectedClient = weakClient;
                if (self == nil || disconnectedClient == nil ||
                    self.serviceClient != disconnectedClient) {
                    return;
                }

                [self clearConnection];
                if (self.state == KKFIInspectorSessionStateConnecting &&
                    self.attemptID == attemptID) {
                    [self scheduleRetryForAttemptID:attemptID];
                } else {
                    self.state = KKFIInspectorSessionStateIdle;
                }
            };

            [client connect];
            [client callMethod:@"getVM"
                        params:nil
                    completion:^(__unused NSDictionary *response,
                                 NSError *error) {
                __strong typeof(weakSession) self = weakSession;
                KKFIVMServiceClient *completedClient = weakClient;
                if (self == nil || completedClient == nil ||
                    self.state != KKFIInspectorSessionStateConnecting ||
                    self.attemptID != attemptID ||
                    self.serviceClient != completedClient) {
                    return;
                }

                if (error != nil) {
                    [self clearConnection];
                    [self scheduleRetryForAttemptID:attemptID];
                    return;
                }

                [self finishAttempt:attemptID error:nil];
            }];
        });
    });
}

- (void)scheduleRetryForAttemptID:(NSUInteger)attemptID {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.15 * NSEC_PER_SEC)),
                   self.stateQueue, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil ||
            self.state != KKFIInspectorSessionStateConnecting ||
            self.attemptID != attemptID) {
            return;
        }
        [self tryConnectWithAttemptID:attemptID];
    });
}

- (void)scheduleTimeout:(NSTimeInterval)timeout
               attemptID:(NSUInteger)attemptID {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(timeout * NSEC_PER_SEC)),
                   self.stateQueue, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil ||
            self.state != KKFIInspectorSessionStateConnecting ||
            self.attemptID != attemptID) {
            return;
        }
        [self finishAttempt:attemptID
                      error:[self.class
                          errorWithCode:KKFIInspectorSessionErrorTimedOut
                             description:@"Timed out while establishing the Flutter VM Service session."]];
    });
}

- (void)finishAttempt:(NSUInteger)attemptID error:(NSError *)error {
    if (self.state != KKFIInspectorSessionStateConnecting ||
        self.attemptID != attemptID) {
        return;
    }

    if (error == nil) {
        self.state = KKFIInspectorSessionStateConnected;
    } else {
        [self clearConnection];
        self.state = KKFIInspectorSessionStateIdle;
    }

    NSArray<KKFIInspectorConnectionCompletion> *waiters =
        self.connectionWaiters.copy;
    [self.connectionWaiters removeAllObjects];
    for (KKFIInspectorConnectionCompletion waiter in waiters) {
        waiter(error);
    }
}

- (void)invalidate {
    dispatch_async(self.stateQueue, ^{
        self.attemptID += 1;
        self.state = KKFIInspectorSessionStateIdle;
        [self clearConnection];

        NSError *error = [self.class
            errorWithCode:KKFIInspectorSessionErrorInvalidated
               description:@"The Flutter Inspector session was invalidated."];
        NSArray<KKFIInspectorConnectionCompletion> *waiters =
            self.connectionWaiters.copy;
        [self.connectionWaiters removeAllObjects];
        for (KKFIInspectorConnectionCompletion waiter in waiters) {
            waiter(error);
        }
    });
}

- (void)clearConnection {
    [self.serviceClient close];
    self.serviceClient = nil;
}

+ (NSError *)errorWithCode:(KKFIInspectorSessionErrorCode)code
                description:(NSString *)description {
    return [NSError errorWithDomain:KKFIInspectorSessionErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

@end
