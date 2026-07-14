//
//  KKFlutterInspector.h
//  Pods
//
//  Created by kris cheng on 2026/7/13.
//

#ifndef KKFlutterInspector_h
#define KKFlutterInspector_h

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKFlutterInspector : NSObject

/// Asynchronously discovers Flutter engines attached to the supplied window
/// and establishes reusable VM Service sessions for them.
///
/// This method never fetches an Element tree and never blocks the caller.
- (void)warmUpWindow:(UIWindow *)window;

@end

NS_ASSUME_NONNULL_END

#endif /* KKFlutterInspector_h */
