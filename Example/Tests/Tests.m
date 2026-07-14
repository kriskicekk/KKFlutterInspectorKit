//
//  KKFlutterInspectorKitTests.m
//  KKFlutterInspectorKitTests
//
//  Created by kriskice@gmail.com on 07/13/2026.
//  Copyright (c) 2026 kriskice@gmail.com. All rights reserved.
//

@import XCTest;
@import KKFlutterInspectorKit;

@interface Tests : XCTestCase

@end

@implementation Tests

- (void)setUp
{
    [super setUp];
    // Put setup code here. This method is called before the invocation of each test method in the class.
}

- (void)tearDown
{
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (void)testWarmUpWithoutFlutterRuntimeDoesNotFail
{
    KKFlutterInspector *inspector = [[KKFlutterInspector alloc] init];
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    window.rootViewController = [[UIViewController alloc] init];

    [inspector warmUpWindow:window];

    XCTAssertNotNil(inspector);
}

@end
