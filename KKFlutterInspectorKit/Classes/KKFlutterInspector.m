//
//  KKFlutterInspector.m
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/13.
//

#import "KKFlutterInspector.h"

#import "Internal/Runtime/KKFIFlutterPageLocator.h"
#import "Internal/Session/KKFIInspectorSession.h"

@interface KKFlutterInspector ()

@property(nonatomic, strong) KKFIFlutterPageLocator *pageLocator;
@property(nonatomic, strong)
    NSMapTable<FlutterEngine *, KKFIInspectorSession *> *sessions;

@end

@implementation KKFlutterInspector

- (instancetype)init {
    self = [super init];
    if (self) {
        _pageLocator = [[KKFIFlutterPageLocator alloc] init];
        // Engines are owned by the host application. A weak key lets the
        // corresponding session disappear when its engine is released, while
        // the strong value keeps a successfully warmed session alive.
        _sessions = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

- (void)dealloc {
    for (KKFIInspectorSession *session in self.sessions.objectEnumerator) {
        [session invalidate];
    }
}

- (void)warmUpWindow:(UIWindow *)window {
    dispatch_block_t discover = ^{
        NSArray<FlutterEngine *> *engines =
            [self.pageLocator flutterEnginesInWindow:window];
        for (FlutterEngine *engine in engines) {
            KKFIInspectorSession *session = [self sessionForEngine:engine];
            [session ensureConnectedWithTimeout:2.5
                                     completion:^(NSError *error) {
#if DEBUG
                if (error != nil) {
                    NSLog(@"[KKFlutterInspectorKit] Session warm-up failed: %@",
                          error.localizedDescription);
                }
#endif
            }];
        }
    };

    if (NSThread.isMainThread) {
        discover();
    } else {
        dispatch_async(dispatch_get_main_queue(), discover);
    }
}

- (KKFIInspectorSession *)sessionForEngine:(FlutterEngine *)engine {
    NSAssert(NSThread.isMainThread,
             @"Flutter session lookup must run on the main thread.");
    KKFIInspectorSession *session = [self.sessions objectForKey:engine];
    if (session == nil) {
        session = [[KKFIInspectorSession alloc] initWithEngine:engine];
        [self.sessions setObject:session forKey:engine];
    }
    return session;
}

@end
