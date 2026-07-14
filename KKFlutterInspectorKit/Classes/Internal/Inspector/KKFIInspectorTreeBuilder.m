#import "KKFIInspectorTreeBuilder.h"

#import <math.h>

#import "KKFIInspectorJSON.h"
#import "../Model/KKFIInspectorModels.h"

static NSString *const KKFIInspectorTreeBuilderErrorDomain =
    @"KKFIInspectorTreeBuilderErrorDomain";

@implementation KKFIInspectorTreeBuilder

+ (KKFIHierarchySnapshot *)
    snapshotFromLayoutPayload:(NSDictionary *)layoutPayload
                widgetPayload:(id)widgetPayload
                 rootObjectID:(NSString *)rootObjectID
             fallbackRootSize:(CGSize)fallbackRootSize
                    isolateID:(NSString *)isolateID
                  objectGroup:(NSString *)objectGroup
                   snapshotID:(NSString *)snapshotID
          excludedWidgetTypes:(NSSet<NSString *> *)excludedWidgetTypes
                        error:(NSError **)error {
    if (rootObjectID.length == 0 || layoutPayload.count == 0) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:KKFIInspectorTreeBuilderErrorDomain
                           code:1
                       userInfo:@{NSLocalizedDescriptionKey :
                                      @"The Flutter hierarchy payload has no root object."}];
        }
        return nil;
    }

    NSMutableDictionary<NSString *, NSDictionary *> *metadata =
        [NSMutableDictionary dictionary];
    [self collectMetadataFromValue:widgetPayload into:metadata];
    NSMutableArray<NSDictionary *> *rootChildrenLayouts =
        [NSMutableArray array];

    NSArray<KKFIInspectorElement *> *roots =
        [self elementsFromLayoutNode:layoutPayload
                        metadataByID:metadata
                   accumulatedOffset:CGPointZero
                       forcedObjectID:rootObjectID
                           isolateID:isolateID
                         objectGroup:objectGroup
                          snapshotID:snapshotID
                 excludedWidgetTypes:excludedWidgetTypes
       childrenLayoutsForVisualParent:rootChildrenLayouts
                     layoutModifiers:@[]
                         interactions:@[]
                             semantics:@[]
                    fallbackRootSize:fallbackRootSize];
    KKFIInspectorElement *root = roots.firstObject;
    if (root == nil) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:KKFIInspectorTreeBuilderErrorDomain
                           code:2
                       userInfo:@{NSLocalizedDescriptionKey :
                                      @"The Flutter hierarchy did not contain an inspectable root."}];
        }
        return nil;
    }

    return [[KKFIHierarchySnapshot alloc] initWithSnapshotID:snapshotID
                                                  objectGroup:objectGroup
                                                    isolateID:isolateID
                                                  rootElement:root];
}

+ (NSArray<KKFIInspectorElement *> *)elementsFromLayoutNode:(NSDictionary *)layoutNode
                                               metadataByID:(NSDictionary<NSString *, NSDictionary *> *)metadataByID
                                          accumulatedOffset:(CGPoint)accumulatedOffset
                                             forcedObjectID:(NSString *)forcedObjectID
                                                  isolateID:(NSString *)isolateID
                                                objectGroup:(NSString *)objectGroup
                                                 snapshotID:(NSString *)snapshotID
                                        excludedWidgetTypes:(NSSet<NSString *> *)excludedWidgetTypes
                             childrenLayoutsForVisualParent:(NSMutableArray<NSDictionary *> *)childrenLayoutsForVisualParent
                                            layoutModifiers:(NSArray<NSDictionary *> *)layoutModifiers interactions:(NSArray<NSDictionary *> *)interactions
                                                  semantics:(NSArray<NSDictionary *> *)semantics
                                           fallbackRootSize:(CGSize)fallbackRootSize {
    BOOL foundOffset = NO;
    CGPoint localOffset = [self offsetFromNode:layoutNode found:&foundOffset];
    CGPoint combinedOffset = CGPointMake(accumulatedOffset.x + localOffset.x,
                                         accumulatedOffset.y + localOffset.y);
    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:layoutNode];
    if (objectID.length == 0) {
        objectID = forcedObjectID;
    }

    BOOL foundSize = NO;
    CGSize size = [self sizeFromNode:layoutNode found:&foundSize];
    if (!foundSize && forcedObjectID.length > 0 &&
        fallbackRootSize.width > 0 && fallbackRootSize.height > 0) {
        size = fallbackRootSize;
        foundSize = YES;
    }

    NSDictionary *metadata = objectID.length > 0 ? metadataByID[objectID] : nil;
    NSString *widgetType =
        [self widgetTypeFromNode:layoutNode metadata:metadata] ?: @"Unknown";
    NSString *baseWidgetType =
        [[widgetType componentsSeparatedByString:@"<"] firstObject] ?: widgetType;
    NSString *renderObjectType = [self renderObjectTypeFromNode:layoutNode];
    BOOL excluded = [excludedWidgetTypes containsObject:widgetType] ||
        [excludedWidgetTypes containsObject:baseWidgetType];
    NSString *hierarchyRole = excluded
        ? @"transparent"
        : [self hierarchyRoleForWidgetType:baseWidgetType
                          renderObjectType:renderObjectType];
    BOOL hasGeometry = objectID.length > 0 && foundSize && size.width > 0 &&
        size.height > 0;
    BOOL isVisual = hasGeometry && [hierarchyRole isEqualToString:@"visual"];

    NSDictionary *relation = [self relationForLayoutNode:layoutNode
                                                      type:baseWidgetType
                                          renderObjectType:renderObjectType];
    NSArray<NSDictionary *> *nextLayoutModifiers = layoutModifiers;
    NSArray<NSDictionary *> *nextInteractions = interactions;
    NSArray<NSDictionary *> *nextSemantics = semantics;
    if ([hierarchyRole isEqualToString:@"childrenLayout"]) {
        [childrenLayoutsForVisualParent addObject:relation];
    } else if ([hierarchyRole isEqualToString:@"layoutModifier"]) {
        nextLayoutModifiers =
            [layoutModifiers arrayByAddingObject:relation];
    } else if ([hierarchyRole isEqualToString:@"interaction"]) {
        nextInteractions = [interactions arrayByAddingObject:relation];
    } else if ([hierarchyRole isEqualToString:@"semantics"]) {
        nextSemantics = [semantics arrayByAddingObject:relation];
    }

    NSArray *childrenJSON = [layoutNode[@"children"] isKindOfClass:NSArray.class]
        ? layoutNode[@"children"]
        : @[];
    NSMutableArray<KKFIInspectorElement *> *children = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *childLayouts = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *nextChildrenLayouts =
        isVisual ? childLayouts : childrenLayoutsForVisualParent;
    CGPoint nextAccumulatedOffset = isVisual ? CGPointZero : combinedOffset;
    NSArray<NSDictionary *> *childLayoutModifiers =
        isVisual ? @[] : nextLayoutModifiers;
    NSArray<NSDictionary *> *childInteractions =
        isVisual ? @[] : nextInteractions;
    NSArray<NSDictionary *> *childSemantics = isVisual ? @[] : nextSemantics;
    for (id value in childrenJSON) {
        if (![value isKindOfClass:NSDictionary.class]) {
            continue;
        }
        [children addObjectsFromArray:
            [self elementsFromLayoutNode:value
                            metadataByID:metadataByID
                       accumulatedOffset:nextAccumulatedOffset
                           forcedObjectID:nil
                               isolateID:isolateID
                              objectGroup:objectGroup
                             snapshotID:snapshotID
                    excludedWidgetTypes:excludedWidgetTypes
          childrenLayoutsForVisualParent:nextChildrenLayouts
                        layoutModifiers:childLayoutModifiers
                            interactions:childInteractions
                                semantics:childSemantics
                        fallbackRootSize:CGSizeZero]];
    }

    if (!isVisual) {
        return children.copy;
    }

    NSString *description =
        [layoutNode[@"description"] isKindOfClass:NSString.class]
            ? layoutNode[@"description"]
            : ([metadata[@"description"] isKindOfClass:NSString.class]
                   ? metadata[@"description"]
                   : widgetType);
    description = description ?: @"";
    NSString *nodeKind = [self kindForVisualType:baseWidgetType];
    NSString *paintRole = [self paintRoleForWidgetType:baseWidgetType
                                      renderObjectType:renderObjectType];
    NSDictionary *nativeDecoration =
        [self nativeDecorationFromLayoutNode:layoutNode
                            renderObjectType:renderObjectType];
    NSString *textPreview =
        [metadata[@"textPreview"] isKindOfClass:NSString.class]
            ? metadata[@"textPreview"]
            : ([layoutNode[@"textPreview"] isKindOfClass:NSString.class]
                   ? layoutNode[@"textPreview"]
                   : nil);
    BOOL captureEligible = YES;
    NSString *renderStrategy = children.count == 0
        ? @"flutterLeafScreenshot"
        : @"flutterSubtreeScreenshot";
    if ([paintRole isEqualToString:@"layoutOnly"]) {
        renderStrategy = @"layoutOnly";
        captureEligible = NO;
    } else if (nativeDecoration != nil) {
        renderStrategy = @"nativeViewDecoration";
        captureEligible = NO;
    } else if (children.count > 0 &&
               ([paintRole isEqualToString:@"selfPaint"] ||
                [paintRole isEqualToString:@"paintEffect"])) {
        // Inspector screenshots include the complete render subtree. If this
        // node paints but its own pixels cannot be reconstructed from a
        // conservative nativeDecoration, keep the subtree atomic in preview.
        renderStrategy = @"atomicSubtreeScreenshot";
    }
    NSArray<NSString *> *capabilities =
        [self capabilitiesForWidgetType:baseWidgetType
                       renderObjectType:renderObjectType
                              paintRole:paintRole
                       nativeDecoration:nativeDecoration];
    KKFIElementReference *reference = [[KKFIElementReference alloc]
        initWithObjectID:objectID
             objectGroup:objectGroup
               isolateID:isolateID
              snapshotID:snapshotID];
    KKFIInspectorElement *element = [[KKFIInspectorElement alloc]
        initWithReference:reference
               widgetType:widgetType
       elementDescription:description
         renderObjectType:renderObjectType
                  nodeKind:nodeKind
                 paintRole:paintRole
            renderStrategy:renderStrategy
           captureEligible:captureEligible
               textPreview:textPreview
          nativeDecoration:nativeDecoration
             capabilities:capabilities
                    frame:CGRectMake(combinedOffset.x, combinedOffset.y,
                                     size.width, size.height)
                 hasFrame:YES
                  rawJSON:layoutNode
           childrenLayouts:childLayouts
           layoutModifiers:nextLayoutModifiers
              interactions:nextInteractions
                  semantics:nextSemantics
                 children:children];
    return @[ element ];
}

+ (void)collectMetadataFromValue:(id)value
                            into:(NSMutableDictionary<NSString *, NSDictionary *> *)metadata {
    if ([value isKindOfClass:NSArray.class]) {
        for (id child in value) {
            [self collectMetadataFromValue:child into:metadata];
        }
        return;
    }
    if (![value isKindOfClass:NSDictionary.class]) {
        return;
    }

    NSDictionary *node = value;
    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:node];
    if (objectID.length > 0) {
        NSMutableDictionary *merged =
            [metadata[objectID] mutableCopy] ?: [NSMutableDictionary dictionary];
        for (NSString *key in @[
                 @"widgetRuntimeType", @"runtimeType", @"type", @"description",
                 @"textPreview", @"createdByLocalProject"
             ]) {
            if (node[key] != nil && node[key] != NSNull.null) {
                merged[key] = node[key];
            }
        }
        metadata[objectID] = merged;
    }

    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        [self collectMetadataFromValue:child into:metadata];
    }
}

+ (NSString *)widgetTypeFromNode:(NSDictionary *)node
                         metadata:(NSDictionary *)metadata {
    for (id value in @[
             metadata[@"widgetRuntimeType"] ?: NSNull.null,
             metadata[@"runtimeType"] ?: NSNull.null,
             node[@"widgetRuntimeType"] ?: NSNull.null,
             node[@"runtimeType"] ?: NSNull.null,
             node[@"type"] ?: NSNull.null
         ]) {
        if ([value isKindOfClass:NSString.class] && [value length] > 0) {
            return value;
        }
    }
    return @"Unknown";
}

+ (NSString *)hierarchyRoleForWidgetType:(NSString *)widgetType
                         renderObjectType:(NSString *)renderObjectType {
    static NSSet<NSString *> *childrenLayouts;
    static NSSet<NSString *> *layoutModifiers;
    static NSSet<NSString *> *spacingWidgets;
    static NSSet<NSString *> *interactionWrappers;
    static NSSet<NSString *> *semanticWrappers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        childrenLayouts = [NSSet setWithArray:@[
            @"Column", @"Row", @"Flex", @"Stack", @"IndexedStack", @"Wrap",
            @"Flow", @"Table", @"ListBody", @"CustomMultiChildLayout",
        ]];
        layoutModifiers = [NSSet setWithArray:@[
            @"Align", @"Center", @"Padding", @"SafeArea", @"Expanded",
            @"Flexible", @"Positioned", @"PositionedDirectional", @"FittedBox",
            @"FractionallySizedBox", @"AspectRatio", @"ConstrainedBox",
            @"UnconstrainedBox", @"LimitedBox", @"OverflowBox", @"Baseline",
            @"IntrinsicWidth", @"IntrinsicHeight", @"SliverPadding",
            @"SliverToBoxAdapter",
        ]];
        spacingWidgets = [NSSet setWithArray:@[
            @"SizedBox", @"Spacer",
        ]];
        interactionWrappers = [NSSet setWithArray:@[
            @"GestureDetector", @"RawGestureDetector", @"Listener", @"MouseRegion",
            @"Focus", @"FocusScope", @"FocusableActionDetector", @"Actions",
            @"Shortcuts", @"CallbackShortcuts", @"TapRegion", @"IgnorePointer",
            @"AbsorbPointer", @"ModalBarrier",
        ]];
        semanticWrappers = [NSSet setWithArray:@[
            @"Semantics", @"MergeSemantics", @"ExcludeSemantics", @"BlockSemantics",
        ]];
    });

    if ([spacingWidgets containsObject:widgetType]) {
        return @"visual";
    }
    if ([childrenLayouts containsObject:widgetType]) {
        return @"childrenLayout";
    }
    if ([layoutModifiers containsObject:widgetType]) {
        return @"layoutModifier";
    }
    if ([interactionWrappers containsObject:widgetType]) {
        return @"interaction";
    }
    if ([semanticWrappers containsObject:widgetType]) {
        return @"semantics";
    }
    if (renderObjectType.length > 0 &&
        ![renderObjectType isEqualToString:@"Unknown"]) {
        return @"visual";
    }
    return @"transparent";
}

+ (NSString *)kindForVisualType:(NSString *)type {
    static NSSet<NSString *> *textTypes;
    static NSSet<NSString *> *layoutTypes;
    static NSSet<NSString *> *boxTypes;
    static NSSet<NSString *> *imageTypes;
    static NSSet<NSString *> *controlTypes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        textTypes = [NSSet setWithArray:@[
            @"Text", @"RichText", @"SelectableText", @"EditableText",
        ]];
        layoutTypes = [NSSet setWithArray:@[
            @"Align", @"AspectRatio", @"Center", @"Column",
            @"ConstrainedBox", @"Expanded", @"FittedBox", @"Flex",
            @"Flexible", @"GridView", @"IntrinsicHeight", @"IntrinsicWidth",
            @"LimitedBox", @"ListView", @"OverflowBox", @"Padding",
            @"Positioned", @"Row", @"SafeArea", @"SingleChildScrollView",
            @"SizedBox", @"Spacer", @"Stack", @"Wrap",
        ]];
        boxTypes = [NSSet setWithArray:@[
            @"AppBar", @"Card", @"ColoredBox", @"Container",
            @"CupertinoNavigationBar", @"DecoratedBox", @"Material",
            @"PhysicalModel", @"Scaffold", @"ClipOval", @"ClipPath",
            @"ClipRect", @"ClipRRect", @"Opacity", @"Transform",
        ]];
        imageTypes = [NSSet setWithArray:@[
            @"CircleAvatar", @"FadeInImage", @"FlutterLogo", @"Image",
            @"RawImage",
        ]];
        controlTypes = [NSSet setWithArray:@[
            @"Checkbox", @"CupertinoButton", @"ElevatedButton",
            @"FloatingActionButton", @"GestureDetector", @"IconButton",
            @"InkWell", @"OutlinedButton", @"Radio", @"Slider", @"Switch",
            @"TextButton",
        ]];
    });

    if ([textTypes containsObject:type]) {
        return @"text";
    }
    if ([layoutTypes containsObject:type]) {
        return @"layout";
    }
    if ([boxTypes containsObject:type]) {
        return @"box";
    }
    if ([imageTypes containsObject:type]) {
        return @"image";
    }
    if ([type isEqualToString:@"Icon"]) {
        return @"icon";
    }
    if ([controlTypes containsObject:type] || [type hasSuffix:@"Button"]) {
        return @"control";
    }
    if ([type isEqualToString:@"CustomPaint"]) {
        return @"canvas";
    }
    return @"custom";
}

+ (NSArray<NSString *> *)capabilitiesForWidgetType:(NSString *)widgetType
                                  renderObjectType:(NSString *)renderObjectType
                                         paintRole:(NSString *)paintRole
                                  nativeDecoration:(NSDictionary *)decoration {
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    if (renderObjectType.length > 0 &&
        ![renderObjectType isEqualToString:@"Unknown"]) {
        [result addObject:@"layout"];
    }
    if ([paintRole isEqualToString:@"selfPaint"]) {
        [result addObject:@"paint"];
    }
    if ([paintRole isEqualToString:@"paintEffect"]) {
        [result addObject:@"effect"];
    }
    if (decoration != nil) {
        [result addObject:@"decoration"];
    }
    if ([widgetType containsString:@"Clip"] ||
        [renderObjectType containsString:@"Clip"]) {
        [result addObject:@"clip"];
    }
    if ([widgetType containsString:@"Opacity"] ||
        [widgetType containsString:@"Filter"] ||
        [renderObjectType containsString:@"Opacity"] ||
        [renderObjectType containsString:@"Filter"]) {
        [result addObject:@"compositing"];
    }
    if ([widgetType containsString:@"Transform"] ||
        [renderObjectType containsString:@"Transform"]) {
        [result addObject:@"transform"];
    }
    if ([widgetType containsString:@"Scroll"] ||
        [widgetType containsString:@"ListView"] ||
        [widgetType containsString:@"GridView"] ||
        [widgetType containsString:@"PageView"] ||
        [renderObjectType containsString:@"Viewport"] ||
        [renderObjectType containsString:@"Sliver"]) {
        [result addObject:@"scroll"];
    }
    if ([widgetType containsString:@"PlatformView"] ||
        [widgetType isEqualToString:@"UiKitView"] ||
        [renderObjectType containsString:@"UiKitView"] ||
        [renderObjectType containsString:@"PlatformView"]) {
        [result addObject:@"platformView"];
    }
    return result.array;
}

+ (NSString *)paintRoleForWidgetType:(NSString *)widgetType
                    renderObjectType:(NSString *)renderObjectType {
    static NSSet<NSString *> *selfPaintingRenderObjects;
    static NSSet<NSString *> *effectRenderObjects;
    static NSSet<NSString *> *layoutOnlyRenderObjects;
    static NSSet<NSString *> *selfPaintingWidgets;
    static NSSet<NSString *> *effectWidgets;
    static NSSet<NSString *> *layoutOnlyWidgets;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        selfPaintingRenderObjects = [NSSet setWithArray:@[
            @"RenderParagraph", @"RenderEditable", @"RenderImage",
            @"RenderDecoratedBox", @"_RenderColoredBox", @"RenderPhysicalModel",
            @"RenderPhysicalShape", @"RenderCustomPaint", @"RenderFlutterLogo",
            @"RenderErrorBox", @"RenderPerformanceOverlay", @"RenderTextureBox",
            @"RenderAndroidView", @"RenderUiKitView", @"RenderPlatformView",
        ]];
        effectRenderObjects = [NSSet setWithArray:@[
            @"RenderOpacity", @"RenderAnimatedOpacity", @"RenderTransform",
            @"RenderClipRect", @"RenderClipRRect", @"RenderClipOval",
            @"RenderClipPath", @"RenderBackdropFilter", @"RenderShaderMask",
            @"RenderColorFiltered", @"RenderImageFiltered", @"RenderFittedBox",
            @"RenderFractionalTranslation", @"RenderRotatedBox",
            @"RenderLeaderLayer", @"RenderFollowerLayer", @"RenderOffstage",
            @"RenderAnimatedSize",
        ]];
        layoutOnlyRenderObjects = [NSSet setWithArray:@[
            @"RenderPadding", @"RenderPositionedBox", @"RenderFlex",
            @"RenderConstrainedBox", @"RenderAspectRatio",
            @"RenderIntrinsicWidth", @"RenderIntrinsicHeight",
            @"RenderLimitedBox", @"RenderSizedOverflowBox",
            @"RenderUnconstrainedBox", @"RenderBaseline", @"RenderStack",
            @"RenderIndexedStack", @"RenderWrap", @"RenderListBody",
            @"RenderSemanticsAnnotations", @"RenderExcludeSemantics",
            @"RenderMergeSemantics", @"RenderBlockSemantics",
            @"RenderIgnorePointer", @"RenderAbsorbPointer",
            @"RenderMouseRegion", @"RenderPointerListener", @"RenderTapRegion",
            @"RenderSliverPadding", @"RenderSliverToBoxAdapter",
            @"RenderProxyBox", @"RenderProxySliver", @"RenderRepaintBoundary",
        ]];
        selfPaintingWidgets = [NSSet setWithArray:@[
            @"AppBar", @"Text", @"RichText", @"SelectableText",
            @"EditableText", @"Image", @"RawImage", @"Icon", @"FlutterLogo",
            @"CustomPaint", @"Scaffold", @"Material", @"Card",
            @"PhysicalModel", @"ColoredBox", @"DecoratedBox", @"Checkbox",
            @"CupertinoButton", @"CupertinoNavigationBar", @"ElevatedButton",
            @"FloatingActionButton", @"IconButton", @"OutlinedButton", @"Radio",
            @"Slider", @"Switch", @"TextButton",
        ]];
        effectWidgets = [NSSet setWithArray:@[
            @"Opacity", @"Transform", @"ClipOval", @"ClipPath", @"ClipRect",
            @"ClipRRect", @"FittedBox", @"BackdropFilter", @"ShaderMask",
            @"ColorFiltered", @"ImageFiltered", @"RotatedBox",
            @"FractionalTranslation", @"Offstage", @"InkWell",
        ]];
        layoutOnlyWidgets = [NSSet setWithArray:@[
            @"Align", @"AspectRatio", @"Center", @"Column", @"ConstrainedBox",
            @"Expanded", @"Flex", @"Flexible", @"GridView",
            @"IntrinsicHeight", @"IntrinsicWidth", @"LimitedBox", @"ListView",
            @"OverflowBox", @"Padding", @"Positioned", @"Row", @"SafeArea",
            @"SingleChildScrollView", @"SizedBox", @"Spacer", @"Stack",
            @"Wrap", @"GestureDetector",
        ]];
    });

    if ([selfPaintingRenderObjects containsObject:renderObjectType]) {
        return @"selfPaint";
    }
    if ([effectRenderObjects containsObject:renderObjectType] ||
        [effectWidgets containsObject:widgetType]) {
        return @"paintEffect";
    }
    if ([selfPaintingWidgets containsObject:widgetType]) {
        return @"selfPaint";
    }
    if ([layoutOnlyRenderObjects containsObject:renderObjectType] ||
        [layoutOnlyWidgets containsObject:widgetType]) {
        return @"layoutOnly";
    }
    if ([widgetType isEqualToString:@"Container"]) {
        return @"selfPaint";
    }
    return @"unknown";
}

+ (NSDictionary *)relationForLayoutNode:(NSDictionary *)layoutNode
                                    type:(NSString *)type
                        renderObjectType:(NSString *)renderObjectType {
    NSMutableDictionary *relation = [@{
        @"type" : type ?: @"Unknown",
        @"renderObjectType" : renderObjectType ?: @"Unknown",
    } mutableCopy];
    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:layoutNode];
    if (objectID.length > 0) {
        relation[@"objectId"] = objectID;
    }
    if ([layoutNode[@"description"] isKindOfClass:NSString.class]) {
        relation[@"description"] = layoutNode[@"description"];
    }

    NSDictionary *renderObject =
        [layoutNode[@"renderObject"] isKindOfClass:NSDictionary.class]
            ? layoutNode[@"renderObject"]
            : nil;
    if ([renderObject[@"properties"] isKindOfClass:NSArray.class]) {
        relation[@"properties"] = renderObject[@"properties"];
    }

    NSArray *children = [layoutNode[@"children"] isKindOfClass:NSArray.class]
        ? layoutNode[@"children"]
        : @[];
    NSMutableArray<NSDictionary *> *managedChildren = [NSMutableArray array];
    for (id value in children) {
        if (![value isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSDictionary *child = value;
        NSMutableDictionary *managedChild = [NSMutableDictionary dictionary];
        NSString *childID = [KKFIInspectorJSON nodeIDFromDictionary:child];
        if (childID.length > 0) {
            managedChild[@"objectId"] = childID;
        }
        NSString *childType = [self widgetTypeFromNode:child metadata:nil];
        if (childType.length > 0) {
            managedChild[@"type"] = childType;
        }
        if (managedChild.count > 0) {
            [managedChildren addObject:managedChild];
        }
    }
    relation[@"managedChildren"] = managedChildren.copy;

    BOOL foundSize = NO;
    CGSize size = [self sizeFromNode:layoutNode found:&foundSize];
    if (foundSize) {
        relation[@"size"] = @{
            @"width" : @(size.width),
            @"height" : @(size.height),
        };
    }
    return relation.copy;
}

+ (NSDictionary *)nativeDecorationFromLayoutNode:(NSDictionary *)layoutNode
                                 renderObjectType:(NSString *)renderObjectType {
    NSDictionary *renderObject =
        [layoutNode[@"renderObject"] isKindOfClass:NSDictionary.class]
            ? layoutNode[@"renderObject"]
            : nil;
    NSArray *properties =
        [renderObject[@"properties"] isKindOfClass:NSArray.class]
            ? renderObject[@"properties"]
            : @[];

    if ([renderObjectType isEqualToString:@"RenderDecoratedBox"]) {
        NSDictionary *decoration =
            [self diagnosticPropertyNamed:@"decoration" inProperties:properties];
        NSArray *decorationProperties =
            [decoration[@"properties"] isKindOfClass:NSArray.class]
                ? decoration[@"properties"]
                : @[];
        if (decorationProperties.count == 0) {
            return nil;
        }

        NSDictionary *image =
            [self diagnosticPropertyNamed:@"image"
                              inProperties:decorationProperties];
        NSDictionary *gradient =
            [self diagnosticPropertyNamed:@"gradient"
                              inProperties:decorationProperties];
        if ([self diagnosticPropertyHasValue:image] ||
            [self diagnosticPropertyHasValue:gradient]) {
            return nil;
        }

        NSMutableDictionary *result = [@{
            @"kind" : @"boxDecoration",
            @"shape" : @"rectangle",
        } mutableCopy];
        NSDictionary *color = [self colorDictionaryFromProperty:
            [self diagnosticPropertyNamed:@"color"
                              inProperties:decorationProperties]];
        if (color != nil) {
            result[@"backgroundColor"] = color;
        }

        NSString *shapeDescription = [self diagnosticDescription:
            [self diagnosticPropertyNamed:@"shape"
                              inProperties:decorationProperties]];
        if ([shapeDescription containsString:@"circle"]) {
            result[@"shape"] = @"circle";
        }

        NSDictionary *radiusProperty =
            [self diagnosticPropertyNamed:@"borderRadius"
                              inProperties:decorationProperties];
        if ([self diagnosticPropertyHasValue:radiusProperty]) {
            NSNumber *radius = [self uniformRadiusFromDescription:
                [self diagnosticDescription:radiusProperty]];
            if (radius == nil) {
                return nil;
            }
            result[@"cornerRadius"] = radius;
        }

        NSDictionary *borderProperty =
            [self diagnosticPropertyNamed:@"border"
                              inProperties:decorationProperties];
        if ([self diagnosticPropertyHasValue:borderProperty]) {
            NSDictionary *border = [self borderDictionaryFromDescription:
                [self diagnosticDescription:borderProperty]];
            if (border == nil) {
                return nil;
            }
            result[@"border"] = border;
        }

        NSDictionary *shadowProperty =
            [self diagnosticPropertyNamed:@"boxShadow"
                              inProperties:decorationProperties];
        if ([self diagnosticPropertyHasValue:shadowProperty]) {
            NSArray *shadows =
                [self shadowDictionariesFromProperty:shadowProperty];
            if (shadows == nil) {
                return nil;
            }
            result[@"shadows"] = shadows;
        }
        return result.count > 2 ? result.copy : nil;
    }

    if ([renderObjectType isEqualToString:@"_RenderColoredBox"]) {
        NSDictionary *color = [self colorDictionaryFromProperty:
            [self diagnosticPropertyNamed:@"color" inProperties:properties]];
        return color == nil ? nil : @{
            @"kind" : @"solidColor",
            @"shape" : @"rectangle",
            @"backgroundColor" : color,
        };
    }

    if ([renderObjectType isEqualToString:@"RenderPhysicalModel"]) {
        NSDictionary *color = [self colorDictionaryFromProperty:
            [self diagnosticPropertyNamed:@"color" inProperties:properties]];
        if (color == nil) {
            return nil;
        }
        NSMutableDictionary *result = [@{
            @"kind" : @"physicalModel",
            @"shape" : @"rectangle",
            @"backgroundColor" : color,
        } mutableCopy];
        NSString *shapeDescription = [self diagnosticDescription:
            [self diagnosticPropertyNamed:@"shape" inProperties:properties]];
        if ([shapeDescription containsString:@"circle"]) {
            result[@"shape"] = @"circle";
        }
        NSDictionary *radiusProperty =
            [self diagnosticPropertyNamed:@"borderRadius"
                              inProperties:properties];
        if ([self diagnosticPropertyHasValue:radiusProperty]) {
            NSNumber *radius = [self uniformRadiusFromDescription:
                [self diagnosticDescription:radiusProperty]];
            if (radius == nil) {
                return nil;
            }
            result[@"cornerRadius"] = radius;
        }
        NSNumber *elevation = [self numberFromDiagnosticProperty:
            [self diagnosticPropertyNamed:@"elevation"
                              inProperties:properties]];
        if (elevation.doubleValue > 0) {
            result[@"elevation"] = elevation;
            NSDictionary *shadowColor = [self colorDictionaryFromProperty:
                [self diagnosticPropertyNamed:@"shadowColor"
                                  inProperties:properties]];
            if (shadowColor != nil) {
                result[@"shadowColor"] = shadowColor;
            }
        }
        return result.copy;
    }
    return nil;
}

+ (NSDictionary *)diagnosticPropertyNamed:(NSString *)name
                              inProperties:(NSArray *)properties {
    for (id value in properties) {
        if ([value isKindOfClass:NSDictionary.class] &&
            [value[@"name"] isEqual:name]) {
            return value;
        }
    }
    return nil;
}

+ (NSString *)diagnosticDescription:(NSDictionary *)property {
    return [property[@"description"] isKindOfClass:NSString.class]
        ? property[@"description"]
        : @"";
}

+ (BOOL)diagnosticPropertyHasValue:(NSDictionary *)property {
    if (property == nil || property[@"value"] == NSNull.null) {
        return NO;
    }
    NSString *description = [self diagnosticDescription:property];
    return description.length > 0 &&
        ![description isEqualToString:@"null"];
}

+ (NSNumber *)numberFromDiagnosticProperty:(NSDictionary *)property {
    NSNumber *value =
        [KKFIInspectorJSON numberFromValue:property[@"value"]];
    if (value != nil) {
        return value;
    }
    return [KKFIInspectorJSON
        numberFromValue:property[@"numberToString"] ?:
            [self diagnosticDescription:property]];
}

+ (NSDictionary *)colorDictionaryFromProperty:(NSDictionary *)property {
    NSDictionary *components =
        [property[@"valueProperties"] isKindOfClass:NSDictionary.class]
            ? property[@"valueProperties"]
            : nil;
    NSNumber *red = [KKFIInspectorJSON numberFromValue:components[@"red"]];
    NSNumber *green = [KKFIInspectorJSON numberFromValue:components[@"green"]];
    NSNumber *blue = [KKFIInspectorJSON numberFromValue:components[@"blue"]];
    NSNumber *alpha = [KKFIInspectorJSON numberFromValue:components[@"alpha"]];
    if (red != nil && green != nil && blue != nil && alpha != nil) {
        return @{
            @"red" : red,
            @"green" : green,
            @"blue" : blue,
            @"alpha" : alpha,
        };
    }
    return [self colorDictionaryFromDescription:
        [self diagnosticDescription:property]];
}

+ (NSDictionary *)colorDictionaryFromDescription:(NSString *)description {
    if (description.length == 0) {
        return nil;
    }
    NSRegularExpression *componentsRegex = [NSRegularExpression
        regularExpressionWithPattern:
            @"Color\\(alpha:\\s*([0-9.]+),\\s*red:\\s*([0-9.]+),\\s*green:"
             @"\\s*([0-9.]+),\\s*blue:\\s*([0-9.]+)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match =
        [componentsRegex firstMatchInString:description
                                    options:0
                                      range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges == 5) {
        double alpha =
            [[description substringWithRange:[match rangeAtIndex:1]] doubleValue];
        double red =
            [[description substringWithRange:[match rangeAtIndex:2]] doubleValue];
        double green =
            [[description substringWithRange:[match rangeAtIndex:3]] doubleValue];
        double blue =
            [[description substringWithRange:[match rangeAtIndex:4]] doubleValue];
        return @{
            @"red" : @(round(red * 255.0)),
            @"green" : @(round(green * 255.0)),
            @"blue" : @(round(blue * 255.0)),
            @"alpha" : @(round(alpha * 255.0)),
        };
    }

    NSRegularExpression *hexRegex = [NSRegularExpression
        regularExpressionWithPattern:@"Color\\(0x([0-9A-Fa-f]{8})\\)"
                             options:0
                               error:nil];
    match = [hexRegex firstMatchInString:description
                                 options:0
                                   range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges == 2) {
        NSString *hex = [description substringWithRange:[match rangeAtIndex:1]];
        unsigned long long argb = 0;
        [[NSScanner scannerWithString:hex] scanHexLongLong:&argb];
        return @{
            @"alpha" : @((argb >> 24) & 0xff),
            @"red" : @((argb >> 16) & 0xff),
            @"green" : @((argb >> 8) & 0xff),
            @"blue" : @(argb & 0xff),
        };
    }
    return nil;
}

+ (NSNumber *)uniformRadiusFromDescription:(NSString *)description {
    if (description.length == 0 || [description isEqualToString:@"null"]) {
        return nil;
    }
    if ([description containsString:@"zero"]) {
        return @0;
    }
    if ([description containsString:@"topLeft"] ||
        [description containsString:@"topRight"] ||
        [description containsString:@"bottomLeft"] ||
        [description containsString:@"bottomRight"] ||
        [description containsString:@"elliptical"]) {
        return nil;
    }
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:
            @"(?:BorderRadius\\.circular|Radius\\.circular)\\(\\s*([-+0-9.eE]+)"
             @"\\s*\\)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match =
        [regex firstMatchInString:description
                          options:0
                            range:NSMakeRange(0, description.length)];
    return match.numberOfRanges == 2
        ? @([[description substringWithRange:[match rangeAtIndex:1]] doubleValue])
        : nil;
}

+ (NSDictionary *)borderDictionaryFromDescription:(NSString *)description {
    if ([description containsString:@"BorderSide.none"] ||
        [description containsString:@"BorderStyle.none"]) {
        return @{ @"width" : @0 };
    }
    if (![description containsString:@"Border.all("]) {
        return nil;
    }
    NSDictionary *color = [self colorDictionaryFromDescription:description];
    NSRegularExpression *widthRegex = [NSRegularExpression
        regularExpressionWithPattern:@"width:\\s*([-+0-9.eE]+)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match =
        [widthRegex firstMatchInString:description
                               options:0
                                 range:NSMakeRange(0, description.length)];
    if (color == nil || match.numberOfRanges != 2) {
        return nil;
    }
    return @{
        @"width" : @([[description substringWithRange:[match rangeAtIndex:1]]
            doubleValue]),
        @"color" : color,
        @"style" : @"solid",
    };
}

+ (NSArray *)shadowDictionariesFromProperty:(NSDictionary *)property {
    NSArray *values = [property[@"values"] isKindOfClass:NSArray.class]
        ? property[@"values"]
        : nil;
    if (values.count == 0) {
        NSString *description = [self diagnosticDescription:property];
        values = description.length > 0 ? @[ description ] : @[];
    }
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:values.count];
    NSRegularExpression *numbersRegex = [NSRegularExpression
        regularExpressionWithPattern:
            @"Offset\\(\\s*([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)\\s*\\)\\s*,"
             @"\\s*([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)"
                             options:0
                               error:nil];
    for (id value in values) {
        NSString *description =
            [value isKindOfClass:NSString.class] ? value : nil;
        NSDictionary *color =
            [self colorDictionaryFromDescription:description];
        NSTextCheckingResult *match =
            [numbersRegex firstMatchInString:description ?: @""
                                     options:0
                                       range:NSMakeRange(0, description.length)];
        if (color == nil || match.numberOfRanges != 5 ||
            ([description containsString:@"BlurStyle."] &&
             ![description containsString:@"BlurStyle.normal"])) {
            return nil;
        }
        [result addObject:@{
            @"color" : color,
            @"offsetX" : @([[description
                substringWithRange:[match rangeAtIndex:1]] doubleValue]),
            @"offsetY" : @([[description
                substringWithRange:[match rangeAtIndex:2]] doubleValue]),
            @"blurRadius" : @([[description
                substringWithRange:[match rangeAtIndex:3]] doubleValue]),
            @"spreadRadius" : @([[description
                substringWithRange:[match rangeAtIndex:4]] doubleValue]),
        }];
    }
    return result.copy;
}

+ (NSString *)renderObjectTypeFromNode:(NSDictionary *)node {
    NSDictionary *renderObject =
        [node[@"renderObject"] isKindOfClass:NSDictionary.class]
            ? node[@"renderObject"]
            : nil;
    NSString *description =
        [renderObject[@"description"] isKindOfClass:NSString.class]
            ? renderObject[@"description"]
            : nil;
    if (description.length == 0) {
        return @"Unknown";
    }

    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"^([_A-Za-z][_A-Za-z0-9]*)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match =
        [regex firstMatchInString:description
                          options:0
                            range:NSMakeRange(0, description.length)];
    return match.numberOfRanges == 2
        ? [description substringWithRange:[match rangeAtIndex:1]]
        : @"Unknown";
}

+ (CGSize)sizeFromNode:(NSDictionary *)node found:(BOOL *)found {
    NSDictionary *size = [node[@"size"] isKindOfClass:NSDictionary.class]
        ? node[@"size"]
        : nil;
    NSNumber *width = [KKFIInspectorJSON numberFromValue:size[@"width"]];
    NSNumber *height = [KKFIInspectorJSON numberFromValue:size[@"height"]];
    BOOL hasSize = width != nil && height != nil;
    if (found != NULL) {
        *found = hasSize;
    }
    return hasSize ? CGSizeMake(width.doubleValue, height.doubleValue)
                   : CGSizeZero;
}

+ (CGPoint)offsetFromNode:(NSDictionary *)node found:(BOOL *)found {
    NSDictionary *parentData =
        [node[@"parentData"] isKindOfClass:NSDictionary.class]
            ? node[@"parentData"]
            : nil;
    NSNumber *x = [KKFIInspectorJSON numberFromValue:parentData[@"offsetX"]];
    NSNumber *y = [KKFIInspectorJSON numberFromValue:parentData[@"offsetY"]];
    if (x != nil && y != nil) {
        if (found != NULL) {
            *found = YES;
        }
        return CGPointMake(x.doubleValue, y.doubleValue);
    }

    NSString *description = [self parentDataDescriptionInValue:node[@"renderObject"]];
    if (description.length > 0) {
        NSRegularExpression *regex = [NSRegularExpression
            regularExpressionWithPattern:
                @"offset=Offset\\(\\s*([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)\\s*\\)"
                                 options:0
                                   error:nil];
        NSTextCheckingResult *match =
            [regex firstMatchInString:description
                              options:0
                                range:NSMakeRange(0, description.length)];
        if (match.numberOfRanges == 3) {
            double parsedX =
                [[description substringWithRange:[match rangeAtIndex:1]] doubleValue];
            double parsedY =
                [[description substringWithRange:[match rangeAtIndex:2]] doubleValue];
            if (isfinite(parsedX) && isfinite(parsedY)) {
                if (found != NULL) {
                    *found = YES;
                }
                return CGPointMake(parsedX, parsedY);
            }
        }
    }

    if (found != NULL) {
        *found = NO;
    }
    return CGPointZero;
}

+ (NSString *)parentDataDescriptionInValue:(id)value {
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        if ([dictionary[@"name"] isEqual:@"parentData"] &&
            [dictionary[@"description"] isKindOfClass:NSString.class]) {
            return dictionary[@"description"];
        }
        for (id child in dictionary.allValues) {
            NSString *result = [self parentDataDescriptionInValue:child];
            if (result.length > 0) {
                return result;
            }
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id child in value) {
            NSString *result = [self parentDataDescriptionInValue:child];
            if (result.length > 0) {
                return result;
            }
        }
    }
    return nil;
}

@end
