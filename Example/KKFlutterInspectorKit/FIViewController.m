//
//  FIViewController.m
//  KKFlutterInspectorKit
//
//  Created by kriskice@gmail.com on 07/13/2026.
//  Copyright (c) 2026 kriskice@gmail.com. All rights reserved.
//

#import "FIViewController.h"

#import <Flutter/Flutter.h>
#import <KKFlutterInspectorKit/KKFlutterInspector.h>

#import "FIAppDelegate.h"
#import "FITreeDetailViewController.h"

@interface FIViewController ()

@property(nonatomic, strong) FlutterViewController *flutterViewController;
@property(nonatomic, strong) KKFlutterInspector *inspector;

@end

@implementation FIViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Flutter";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Tree"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(showTree:)];

    self.inspector = [[KKFlutterInspector alloc] init];
    self.inspector.excludedWidgetTypes = [NSSet setWithArray:@[
        @"RootWidget",
        @"InspectorExampleApp",
        @"MaterialApp",
        @"InspectorExamplePage",
    ]];
    FIAppDelegate *appDelegate = (FIAppDelegate *)UIApplication.sharedApplication.delegate;
    FlutterEngine *engine = appDelegate.flutterEngine;
    if (engine == nil) {
        return;
    }

    FlutterViewController *flutterViewController = [[FlutterViewController alloc]
        initWithEngine:engine
             nibName:nil
              bundle:nil];
    self.flutterViewController = flutterViewController;
    [self addChildViewController:flutterViewController];
    flutterViewController.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:flutterViewController.view];
    [NSLayoutConstraint activateConstraints:@[
        [flutterViewController.view.leadingAnchor
            constraintEqualToAnchor:self.view.leadingAnchor],
        [flutterViewController.view.trailingAnchor
            constraintEqualToAnchor:self.view.trailingAnchor],
        [flutterViewController.view.topAnchor
            constraintEqualToAnchor:self.view.topAnchor],
        [flutterViewController.view.bottomAnchor
            constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [flutterViewController didMoveToParentViewController:self];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.view.window != nil) {
        [self.inspector warmUpWindow:self.view.window];
    }
}

- (void)showTree:(id)sender {
    UIWindow *window = self.view.window;
    if (window == nil) {
        return;
    }

    FITreeDetailViewController *detailViewController =
        [[FITreeDetailViewController alloc] initWithInspector:self.inspector];
    CGSize rootSize = self.flutterViewController.view.bounds.size;
    __weak FITreeDetailViewController *weakDetail = detailViewController;
    [self.inspector fetchHierarchyForViewController:self.flutterViewController
                                   fallbackRootSize:rootSize
                                         completion:^(KKFIHierarchySnapshot *snapshot,
                                                      NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakDetail displaySnapshot:snapshot error:error];
        });
    }];
    [self.navigationController pushViewController:detailViewController animated:YES];
}

@end
