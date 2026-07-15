//
//  KKFIHierarchyEnricher.m
//  KKFlutterInspectorKit
//
//  Created by kris cheng on 2026/7/15.
//

#import "KKFIHierarchyEnricher.h"

#import <math.h>

#import "../Connection/KKFIVMServiceClient.h"
#import "../Inspector/KKFIInspectorJSON.h"

@implementation KKFIHierarchyEnricher

- (void)enrichLayoutPayload:(NSDictionary *)layoutPayload
                     client:(KKFIVMServiceClient *)client
                  isolateID:(NSString *)isolateID
                objectGroup:(NSString *)objectGroup
                 completion:(KKFIHierarchyEnrichmentCompletion)completion {
    NSMutableOrderedSet<NSString *> *objectIDs = [NSMutableOrderedSet orderedSet];
    NSMutableSet<NSString *> *cardObjectIDs = [NSMutableSet set];
    NSMutableSet<NSString *> *containerObjectIDs = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSSet<NSString *> *> *listViewChildObjectIDsByID =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSSet<NSString *> *> *customScrollTargetObjectIDsByID =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSSet<NSString *> *> *offsetBridgeChildObjectIDsByID =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *offsetBridgeRenderObjectIDsByID =
        [NSMutableDictionary dictionary];
    [self collectLayoutPropertyObjectIDsFromValue:layoutPayload
                                             into:objectIDs
                                    cardObjectIDs:cardObjectIDs
                               containerObjectIDs:containerObjectIDs
                       listViewChildObjectIDsByID:listViewChildObjectIDsByID
                  customScrollTargetObjectIDsByID:customScrollTargetObjectIDsByID
                    offsetBridgeChildObjectIDsByID:offsetBridgeChildObjectIDsByID
                    offsetBridgeRenderObjectIDsByID:offsetBridgeRenderObjectIDsByID];
    if (objectIDs.count == 0) {
        completion(@{}, @{});
        return;
    }

    NSMutableDictionary<NSString *, NSArray *> *propertiesByID =
        [NSMutableDictionary dictionaryWithCapacity:objectIDs.count];
    NSMutableDictionary<NSString *, NSValue *> *resolvedOffsetsByID =
        [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *offsetBridgeTargetObjectIDs =
        [NSMutableSet set];
    for (NSSet<NSString *> *targetObjectIDs in
         offsetBridgeChildObjectIDsByID.allValues) {
        [offsetBridgeTargetObjectIDs unionSet:targetObjectIDs];
    }
    NSDictionary<NSString *, NSValue *> *offsetBridgeLocalOffsetsByID =
        [self directOffsetsForTargetObjectIDs:offsetBridgeTargetObjectIDs
                                inLayoutValue:layoutPayload];
    __block NSUInteger remaining = objectIDs.count;
    for (NSString *objectID in objectIDs) {
        BOOL isCard = [cardObjectIDs containsObject:objectID];
        BOOL isContainer = [containerObjectIDs containsObject:objectID];
        NSSet<NSString *> *listViewChildObjectIDs =
            listViewChildObjectIDsByID[objectID];
        BOOL isListView = listViewChildObjectIDs.count > 0;
        NSSet<NSString *> *customScrollTargetObjectIDs =
            customScrollTargetObjectIDsByID[objectID];
        BOOL isCustomScrollView = customScrollTargetObjectIDs.count > 0;
        NSSet<NSString *> *offsetBridgeChildObjectIDs =
            offsetBridgeChildObjectIDsByID[objectID];
        BOOL isOffsetBridgeRoot = offsetBridgeChildObjectIDs.count > 0;
        BOOL needsDetailsSubtree =
            isCard || isContainer || isListView || isCustomScrollView ||
            isOffsetBridgeRoot;
        NSString *method = needsDetailsSubtree
            ? @"ext.flutter.inspector.getDetailsSubtree"
            : @"ext.flutter.inspector.getProperties";
        NSDictionary *params = needsDetailsSubtree
            ? @{
                @"isolateId" : isolateID,
                @"arg" : objectID,
                @"objectGroup" : objectGroup,
                @"subtreeDepth" : isOffsetBridgeRoot
                    ? @"32"
                    : ((isListView || isCustomScrollView) ? @"16" : @"4"),
            }
            : @{
                @"isolateId" : isolateID,
                @"arg" : objectID,
                @"objectGroup" : objectGroup,
            };
        [client callMethod:method
                    params:params
                completion:^(NSDictionary *response, NSError *error) {
            if (error == nil) {
                id payload = [KKFIInspectorJSON normalizedPayloadFromResponse:response];
                NSArray *properties = nil;
                if (isOffsetBridgeRoot) {
                    NSDictionary<NSString *, NSValue *> *offsets =
                        [self resolvedOffsetsForTargetObjectIDs:offsetBridgeChildObjectIDs
                                            rootRenderObjectID:offsetBridgeRenderObjectIDsByID[objectID]
                                                detailsPayload:payload
                                          targetLocalOffsets:offsetBridgeLocalOffsetsByID];
                    [resolvedOffsetsByID addEntriesFromDictionary:offsets];
                    properties =
                        [self resolvedMaterialPropertiesFromDetailsPayload:payload];
                } else if (isCustomScrollView) {
                    NSDictionary<NSString *, NSValue *> *offsets =
                        [self resolvedOffsetsForCustomScrollTargetObjectIDs:
                            customScrollTargetObjectIDs
                                                           detailsPayload:payload];
                    [resolvedOffsetsByID addEntriesFromDictionary:offsets];
                } else if (isListView) {
                    NSDictionary<NSString *, NSValue *> *offsets =
                        [self resolvedOffsetsForListViewTargetObjectIDs:
                            listViewChildObjectIDs
                                                          detailsPayload:payload];
                    [resolvedOffsetsByID addEntriesFromDictionary:offsets];
                    if ([payload isKindOfClass:NSDictionary.class]) {
                        properties = [payload[@"properties"] isKindOfClass:NSArray.class]
                            ? payload[@"properties"]
                            : nil;
                    }
                } else if (isCard) {
                    properties = [self resolvedCardPropertiesFromDetailsPayload:payload];
                } else if (isContainer &&
                           [payload isKindOfClass:NSDictionary.class]) {
                    properties = [payload[@"properties"] isKindOfClass:NSArray.class]
                        ? payload[@"properties"]
                        : nil;
                } else if ([payload isKindOfClass:NSArray.class]) {
                    properties = payload;
                }
                if (properties.count > 0) {
                    propertiesByID[objectID] = properties;
                }
            }

            remaining -= 1;
            if (remaining == 0) {
                completion(propertiesByID.copy, resolvedOffsetsByID.copy);
            }
        }];
    }
}

- (NSDictionary<NSString *, NSValue *> *)
    directOffsetsForTargetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                       inLayoutValue:(id)value {
    if (targetObjectIDs.count == 0) {
        return @{};
    }
    NSMutableDictionary<NSString *, NSValue *> *result =
        [NSMutableDictionary dictionary];
    [self collectDirectOffsetsInLayoutValue:value
                            targetObjectIDs:targetObjectIDs
                                     result:result];
    return result.copy;
}

- (void)collectDirectOffsetsInLayoutValue:(id)value
                          targetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                                   result:(NSMutableDictionary<NSString *, NSValue *> *)result {
    if (![value isKindOfClass:NSDictionary.class] ||
        result.count == targetObjectIDs.count) {
        return;
    }

    NSDictionary *node = value;
    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:node];
    if ([targetObjectIDs containsObject:objectID]) {
        BOOL foundOffset = NO;
        CGPoint offset = CGPointZero;
        NSDictionary *parentData =
            [node[@"parentData"] isKindOfClass:NSDictionary.class]
                ? node[@"parentData"]
                : nil;
        NSNumber *offsetX =
            [KKFIInspectorJSON numberFromValue:parentData[@"offsetX"]];
        NSNumber *offsetY =
            [KKFIInspectorJSON numberFromValue:parentData[@"offsetY"]];
        if (offsetX != nil && offsetY != nil) {
            offset = CGPointMake(offsetX.doubleValue, offsetY.doubleValue);
            foundOffset = YES;
        } else {
            NSDictionary *renderObject =
                [self renderObjectPropertyFromInspectorNode:node];
            offset = [self parentDataOffsetFromValue:renderObject
                                               found:&foundOffset];
        }
        if (foundOffset) {
            result[objectID] = [NSValue valueWithCGPoint:offset];
        }
    }

    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        [self collectDirectOffsetsInLayoutValue:child
                                targetObjectIDs:targetObjectIDs
                                         result:result];
    }
}

- (void)collectLayoutPropertyObjectIDsFromValue:(id)value
                                            into:(NSMutableOrderedSet<NSString *> *)objectIDs
                                   cardObjectIDs:(NSMutableSet<NSString *> *)cardObjectIDs
                              containerObjectIDs:(NSMutableSet<NSString *> *)containerObjectIDs
                      listViewChildObjectIDsByID:(NSMutableDictionary<NSString *, NSSet<NSString *> *> *)listViewChildObjectIDsByID
                 customScrollTargetObjectIDsByID:(NSMutableDictionary<NSString *, NSSet<NSString *> *> *)customScrollTargetObjectIDsByID
                   offsetBridgeChildObjectIDsByID:(NSMutableDictionary<NSString *, NSSet<NSString *> *> *)offsetBridgeChildObjectIDsByID
                   offsetBridgeRenderObjectIDsByID:(NSMutableDictionary<NSString *, NSString *> *)offsetBridgeRenderObjectIDsByID {
    if (![value isKindOfClass:NSDictionary.class]) {
        return;
    }

    NSDictionary *node = value;
    NSString *widgetType = [node[@"widgetRuntimeType"] isKindOfClass:NSString.class]
        ? node[@"widgetRuntimeType"]
        : ([node[@"description"] isKindOfClass:NSString.class]
               ? node[@"description"]
               : nil);
    NSString *baseWidgetType =
        [[widgetType componentsSeparatedByString:@"<"] firstObject];
    static NSSet<NSString *> *offsetBridgeRootTypes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        offsetBridgeRootTypes = [NSSet setWithArray:@[
            @"AppBar", @"CheckboxListTile", @"CupertinoButton",
            @"ElevatedButton", @"FilledButton", @"FloatingActionButton",
            @"IconButton", @"OutlinedButton", @"SwitchListTile",
            @"TextButton", @"TextField",
        ]];
    });
    BOOL isOffsetBridgeRoot =
        [offsetBridgeRootTypes containsObject:baseWidgetType];
    if ([baseWidgetType isEqualToString:@"ListView"] ||
        [baseWidgetType isEqualToString:@"CustomScrollView"] ||
        [baseWidgetType isEqualToString:@"Card"] ||
        [baseWidgetType isEqualToString:@"Container"] ||
        isOffsetBridgeRoot) {
        NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:node];
        if (objectID.length > 0) {
            if ([baseWidgetType isEqualToString:@"Card"]) {
                [objectIDs addObject:objectID];
                [cardObjectIDs addObject:objectID];
            } else if ([baseWidgetType isEqualToString:@"Container"]) {
                [objectIDs addObject:objectID];
                [containerObjectIDs addObject:objectID];
            } else if ([baseWidgetType isEqualToString:@"ListView"]) {
                NSMutableSet<NSString *> *childObjectIDs = [NSMutableSet set];
                NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
                    ? node[@"children"]
                    : @[];
                for (id childValue in children) {
                    if (![childValue isKindOfClass:NSDictionary.class]) {
                        continue;
                    }
                    NSString *childObjectID =
                        [KKFIInspectorJSON nodeIDFromDictionary:childValue];
                    if (childObjectID.length > 0) {
                        [childObjectIDs addObject:childObjectID];
                    }
                }
                [objectIDs addObject:objectID];
                if (childObjectIDs.count > 0) {
                    listViewChildObjectIDsByID[objectID] = childObjectIDs.copy;
                }
            } else if ([baseWidgetType isEqualToString:@"CustomScrollView"]) {
                NSMutableSet<NSString *> *targetObjectIDs = [NSMutableSet set];
                NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
                    ? node[@"children"]
                    : @[];
                for (id child in children) {
                    if ([child isKindOfClass:NSDictionary.class]) {
                        [self collectCustomScrollTargetObjectIDsFromLayoutNode:child
                                                                          into:targetObjectIDs];
                    }
                }
                [objectIDs addObject:objectID];
                if (targetObjectIDs.count > 0) {
                    customScrollTargetObjectIDsByID[objectID] =
                        targetObjectIDs.copy;
                }
            } else if (isOffsetBridgeRoot) {
                NSMutableSet<NSString *> *childObjectIDs = [NSMutableSet set];
                NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
                    ? node[@"children"]
                    : @[];
                for (id childValue in children) {
                    if (![childValue isKindOfClass:NSDictionary.class]) {
                        continue;
                    }
                    NSString *childObjectID =
                        [KKFIInspectorJSON nodeIDFromDictionary:childValue];
                    if (childObjectID.length > 0) {
                        [childObjectIDs addObject:childObjectID];
                    }
                }
                if (childObjectIDs.count > 0) {
                    [objectIDs addObject:objectID];
                    offsetBridgeChildObjectIDsByID[objectID] = childObjectIDs.copy;
                    NSDictionary *renderObject =
                        [node[@"renderObject"] isKindOfClass:NSDictionary.class]
                            ? node[@"renderObject"]
                            : nil;
                    NSString *renderObjectID =
                        [renderObject[@"valueId"] isKindOfClass:NSString.class]
                            ? renderObject[@"valueId"]
                            : nil;
                    if (renderObjectID.length > 0) {
                        offsetBridgeRenderObjectIDsByID[objectID] = renderObjectID;
                    }
                }
            }
        }
    }

    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        [self collectLayoutPropertyObjectIDsFromValue:child
                                                 into:objectIDs
                                        cardObjectIDs:cardObjectIDs
                                   containerObjectIDs:containerObjectIDs
                           listViewChildObjectIDsByID:listViewChildObjectIDsByID
                      customScrollTargetObjectIDsByID:customScrollTargetObjectIDsByID
                        offsetBridgeChildObjectIDsByID:offsetBridgeChildObjectIDsByID
                        offsetBridgeRenderObjectIDsByID:offsetBridgeRenderObjectIDsByID];
    }
}

- (void)collectCustomScrollTargetObjectIDsFromLayoutNode:(NSDictionary *)node
                                                    into:(NSMutableSet<NSString *> *)objectIDs {
    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:node];
    if (objectID.length > 0) {
        [objectIDs addObject:objectID];
    }

    NSString *widgetType = [node[@"widgetRuntimeType"] isKindOfClass:NSString.class]
        ? node[@"widgetRuntimeType"]
        : ([node[@"description"] isKindOfClass:NSString.class]
               ? node[@"description"]
               : nil);
    NSString *baseWidgetType =
        [[widgetType componentsSeparatedByString:@"<"] firstObject];
    NSSet<NSString *> *nestedBoxScrollViews = [NSSet setWithArray:@[
        @"ListView", @"GridView", @"PageView", @"SingleChildScrollView",
        @"CustomScrollView",
    ]];
    if ([nestedBoxScrollViews containsObject:baseWidgetType]) {
        return;
    }

    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        if ([child isKindOfClass:NSDictionary.class]) {
            [self collectCustomScrollTargetObjectIDsFromLayoutNode:child
                                                               into:objectIDs];
        }
    }
}

- (NSDictionary<NSString *, NSValue *> *)
    resolvedOffsetsForCustomScrollTargetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                                    detailsPayload:(id)payload {
    if (![payload isKindOfClass:NSDictionary.class] ||
        targetObjectIDs.count == 0) {
        return @{};
    }

    NSMutableDictionary<NSString *, NSValue *> *result =
        [NSMutableDictionary dictionary];
    [self collectCustomScrollResolvedOffsetsInDetailsNode:payload
                                           targetObjectIDs:targetObjectIDs
                                            axisDirection:nil
                                              scrollOffset:0
                                                    result:result];
    return result.copy;
}

- (void)collectCustomScrollResolvedOffsetsInDetailsNode:(NSDictionary *)node
                                         targetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                                          axisDirection:(NSString *)axisDirection
                                            scrollOffset:(CGFloat)scrollOffset
                                                  result:(NSMutableDictionary<NSString *, NSValue *> *)result {
    NSString *nextAxisDirection = axisDirection;
    CGFloat nextScrollOffset = scrollOffset;
    BOOL isSliverRenderObject = [self sliverContextFromInspectorNode:node
                                                        axisDirection:&nextAxisDirection
                                                          scrollOffset:&nextScrollOffset];

    NSString *targetObjectID = nil;
    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:node];
    if ([targetObjectIDs containsObject:objectID]) {
        targetObjectID = objectID;
    }

    if (isSliverRenderObject) {
        BOOL foundPaintOffset = NO;
        CGPoint paintOffset = [self sliverPaintOffsetFromInspectorNode:node
                                                                 found:&foundPaintOffset];
        if (foundPaintOffset) {
            if (targetObjectID.length == 0) {
                targetObjectID = [self firstTargetObjectID:targetObjectIDs
                                              inDetailsNode:node];
            }
            if (targetObjectID.length > 0 && result[targetObjectID] == nil) {
                result[targetObjectID] = [NSValue valueWithCGPoint:paintOffset];
            }
        }
    }

    BOOL foundLayoutOffset = NO;
    CGFloat layoutOffset = [self sliverLayoutOffsetFromInspectorNode:node
                                                               found:&foundLayoutOffset];
    if (foundLayoutOffset &&
        ([nextAxisDirection isEqualToString:@"down"] ||
         [nextAxisDirection isEqualToString:@"right"])) {
        BOOL foundCrossAxisOffset = NO;
        CGFloat crossAxisOffset =
            [self sliverCrossAxisOffsetFromInspectorNode:node
                                                   found:&foundCrossAxisOffset];
        if (!foundCrossAxisOffset) {
            crossAxisOffset = 0;
        }
        if (targetObjectID.length == 0) {
            targetObjectID = [self firstTargetObjectID:targetObjectIDs
                                          inDetailsNode:node];
        }
        if (targetObjectID.length > 0 && result[targetObjectID] == nil) {
            CGFloat mainAxisOffset = layoutOffset - nextScrollOffset;
            CGPoint offset = [nextAxisDirection isEqualToString:@"down"]
                ? CGPointMake(crossAxisOffset, mainAxisOffset)
                : CGPointMake(mainAxisOffset, crossAxisOffset);
            result[targetObjectID] = [NSValue valueWithCGPoint:offset];
        }
    }

    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        if ([child isKindOfClass:NSDictionary.class]) {
            [self collectCustomScrollResolvedOffsetsInDetailsNode:child
                                                   targetObjectIDs:targetObjectIDs
                                                    axisDirection:nextAxisDirection
                                                      scrollOffset:nextScrollOffset
                                                            result:result];
        }
    }
}

- (BOOL)sliverContextFromInspectorNode:(NSDictionary *)node
                         axisDirection:(NSString **)axisDirection
                           scrollOffset:(CGFloat *)scrollOffset {
    NSDictionary *renderObject = [self renderObjectPropertyFromInspectorNode:node];
    NSArray *properties = [renderObject[@"properties"] isKindOfClass:NSArray.class]
        ? renderObject[@"properties"]
        : @[];
    NSDictionary *constraints = [self inspectorPropertyNamed:@"constraints"
                                                 inProperties:properties];
    NSString *description = [self inspectorDescriptionForProperty:constraints];
    if (![description containsString:@"SliverConstraints("]) {
        return NO;
    }

    NSRegularExpression *axisRegex = [NSRegularExpression
        regularExpressionWithPattern:@"AxisDirection\\.(down|right|up|left)"
                             options:0
                               error:nil];
    NSTextCheckingResult *axisMatch =
        [axisRegex firstMatchInString:description
                              options:0
                                range:NSMakeRange(0, description.length)];
    NSRegularExpression *scrollRegex = [NSRegularExpression
        regularExpressionWithPattern:@"scrollOffset:\\s*([-+0-9.eE]+)"
                             options:0
                               error:nil];
    NSTextCheckingResult *scrollMatch =
        [scrollRegex firstMatchInString:description
                                options:0
                                  range:NSMakeRange(0, description.length)];
    if (axisMatch.numberOfRanges != 2 || scrollMatch.numberOfRanges != 2) {
        return NO;
    }

    CGFloat parsedScrollOffset = [[description substringWithRange:
        [scrollMatch rangeAtIndex:1]] doubleValue];
    if (!isfinite(parsedScrollOffset)) {
        return NO;
    }
    if (axisDirection != NULL) {
        *axisDirection = [description substringWithRange:[axisMatch rangeAtIndex:1]];
    }
    if (scrollOffset != NULL) {
        *scrollOffset = parsedScrollOffset;
    }
    return YES;
}

- (CGPoint)sliverPaintOffsetFromInspectorNode:(NSDictionary *)node
                                         found:(BOOL *)found {
    NSDictionary *renderObject = [self renderObjectPropertyFromInspectorNode:node];
    NSString *description = [self parentDataDescriptionInValue:renderObject];
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:
            @"paintOffset=Offset\\(\\s*([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)\\s*\\)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:description ?: @""
                                                   options:0
                                                     range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges == 3) {
        CGFloat x = [[description substringWithRange:[match rangeAtIndex:1]]
            doubleValue];
        CGFloat y = [[description substringWithRange:[match rangeAtIndex:2]]
            doubleValue];
        if (isfinite(x) && isfinite(y)) {
            if (found != NULL) {
                *found = YES;
            }
            return CGPointMake(x, y);
        }
    }
    if (found != NULL) {
        *found = NO;
    }
    return CGPointZero;
}

- (CGFloat)sliverCrossAxisOffsetFromInspectorNode:(NSDictionary *)node
                                             found:(BOOL *)found {
    NSDictionary *renderObject = [self renderObjectPropertyFromInspectorNode:node];
    NSString *description = [self parentDataDescriptionInValue:renderObject];
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"crossAxisOffset=\\s*([-+0-9.eE]+)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:description ?: @""
                                                   options:0
                                                     range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges == 2) {
        CGFloat value = [[description substringWithRange:[match rangeAtIndex:1]]
            doubleValue];
        if (isfinite(value)) {
            if (found != NULL) {
                *found = YES;
            }
            return value;
        }
    }
    if (found != NULL) {
        *found = NO;
    }
    return 0;
}

- (NSDictionary<NSString *, NSValue *> *)
    resolvedOffsetsForListViewTargetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                                detailsPayload:(id)payload {
    if (![payload isKindOfClass:NSDictionary.class] ||
        targetObjectIDs.count == 0) {
        return @{};
    }

    NSDictionary *root = payload;
    NSArray *properties = [root[@"properties"] isKindOfClass:NSArray.class]
        ? root[@"properties"]
        : @[];
    NSDictionary *axisProperty =
        [self inspectorPropertyNamed:@"scrollDirection"
                        inProperties:properties];
    NSString *axisDirection =
        [self inspectorDescriptionForProperty:axisProperty];
    if (![axisDirection isEqualToString:@"vertical"] &&
        ![axisDirection isEqualToString:@"horizontal"]) {
        return @{};
    }

    NSDictionary *reverseProperty =
        [self inspectorPropertyNamed:@"reverse" inProperties:properties];
    if ([[self inspectorDescriptionForProperty:reverseProperty]
            isEqualToString:@"true"]) {
        return @{};
    }

    UIEdgeInsets padding = UIEdgeInsetsZero;
    NSDictionary *paddingProperty =
        [self inspectorPropertyNamed:@"padding" inProperties:properties];
    if (paddingProperty != nil &&
        ![self edgeInsetsFromInspectorProperty:paddingProperty value:&padding]) {
        return @{};
    }

    BOOL foundScrollOffset = NO;
    CGFloat scrollOffset =
        [self listViewScrollOffsetFromValue:payload found:&foundScrollOffset];
    if (!foundScrollOffset) {
        return @{};
    }

    NSMutableDictionary<NSString *, NSValue *> *result =
        [NSMutableDictionary dictionary];
    [self collectListViewResolvedOffsetsInDetailsNode:root
                                      targetObjectIDs:targetObjectIDs
                                              padding:padding
                                         scrollOffset:scrollOffset
                                         axisDirection:axisDirection
                                               result:result];
    return result.copy;
}

- (void)collectListViewResolvedOffsetsInDetailsNode:(NSDictionary *)node
                                    targetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                                            padding:(UIEdgeInsets)padding
                                       scrollOffset:(CGFloat)scrollOffset
                                      axisDirection:(NSString *)axisDirection
                                             result:(NSMutableDictionary<NSString *, NSValue *> *)result {
    BOOL foundLayoutOffset = NO;
    CGFloat layoutOffset =
        [self sliverLayoutOffsetFromInspectorNode:node
                                           found:&foundLayoutOffset];
    if (foundLayoutOffset) {
        NSString *targetObjectID =
            [self firstTargetObjectID:targetObjectIDs inDetailsNode:node];
        if (targetObjectID.length > 0 && result[targetObjectID] == nil) {
            BOOL foundCrossAxisOffset = NO;
            CGFloat crossAxisOffset =
                [self sliverCrossAxisOffsetFromInspectorNode:node
                                                       found:&foundCrossAxisOffset];
            if (!foundCrossAxisOffset) {
                crossAxisOffset = 0;
            }
            CGPoint offset = [axisDirection isEqualToString:@"vertical"]
                ? CGPointMake(padding.left + crossAxisOffset,
                              padding.top + layoutOffset - scrollOffset)
                : CGPointMake(padding.left + layoutOffset - scrollOffset,
                              padding.top + crossAxisOffset);
            result[targetObjectID] = [NSValue valueWithCGPoint:offset];
            return;
        }
    }

    if (result.count == targetObjectIDs.count) {
        return;
    }
    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        if (![child isKindOfClass:NSDictionary.class]) {
            continue;
        }
        [self collectListViewResolvedOffsetsInDetailsNode:child
                                          targetObjectIDs:targetObjectIDs
                                                  padding:padding
                                             scrollOffset:scrollOffset
                                            axisDirection:axisDirection
                                                   result:result];
    }
}

- (NSString *)firstTargetObjectID:(NSSet<NSString *> *)targetObjectIDs
                     inDetailsNode:(NSDictionary *)node {
    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:node];
    if ([targetObjectIDs containsObject:objectID]) {
        return objectID;
    }

    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        if (![child isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *match = [self firstTargetObjectID:targetObjectIDs
                                      inDetailsNode:child];
        if (match.length > 0) {
            return match;
        }
    }
    return nil;
}

- (CGFloat)sliverLayoutOffsetFromInspectorNode:(NSDictionary *)node
                                         found:(BOOL *)found {
    NSDictionary *renderObject =
        [self renderObjectPropertyFromInspectorNode:node];
    NSString *description = [self parentDataDescriptionInValue:renderObject];
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"layoutOffset=\\s*([-+0-9.eE]+)"
                             options:0
                               error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:description ?: @""
                                                   options:0
                                                     range:NSMakeRange(0, description.length)];
    if (match.numberOfRanges == 2) {
        CGFloat value = [[description substringWithRange:[match rangeAtIndex:1]]
            doubleValue];
        if (isfinite(value)) {
            if (found != NULL) {
                *found = YES;
            }
            return value;
        }
    }
    if (found != NULL) {
        *found = NO;
    }
    return 0;
}

- (CGFloat)listViewScrollOffsetFromValue:(id)value found:(BOOL *)found {
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        if ([dictionary[@"propertyType"] isEqual:@"ViewportOffset"] &&
            [dictionary[@"description"] isKindOfClass:NSString.class]) {
            NSString *description = dictionary[@"description"];
            NSRegularExpression *regex = [NSRegularExpression
                regularExpressionWithPattern:@"\\boffset:\\s*([-+0-9.eE]+)"
                                     options:0
                                       error:nil];
            NSTextCheckingResult *match =
                [regex firstMatchInString:description
                                  options:0
                                    range:NSMakeRange(0, description.length)];
            if (match.numberOfRanges == 2) {
                CGFloat offset = [[description substringWithRange:
                    [match rangeAtIndex:1]] doubleValue];
                if (isfinite(offset)) {
                    if (found != NULL) {
                        *found = YES;
                    }
                    return offset;
                }
            }
        }
        for (id child in dictionary.allValues) {
            BOOL childFound = NO;
            CGFloat offset = [self listViewScrollOffsetFromValue:child
                                                            found:&childFound];
            if (childFound) {
                if (found != NULL) {
                    *found = YES;
                }
                return offset;
            }
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id child in value) {
            BOOL childFound = NO;
            CGFloat offset = [self listViewScrollOffsetFromValue:child
                                                            found:&childFound];
            if (childFound) {
                if (found != NULL) {
                    *found = YES;
                }
                return offset;
            }
        }
    }

    if (found != NULL) {
        *found = NO;
    }
    return 0;
}

- (NSDictionary *)inspectorPropertyNamed:(NSString *)name
                             inProperties:(NSArray *)properties {
    for (id value in properties) {
        if ([value isKindOfClass:NSDictionary.class] &&
            [value[@"name"] isEqual:name]) {
            return value;
        }
    }
    return nil;
}

- (NSString *)inspectorDescriptionForProperty:(NSDictionary *)property {
    if ([property[@"description"] isKindOfClass:NSString.class]) {
        return property[@"description"];
    }
    if ([property[@"value"] isKindOfClass:NSString.class]) {
        return property[@"value"];
    }
    return nil;
}

- (BOOL)edgeInsetsFromInspectorProperty:(NSDictionary *)property
                                  value:(UIEdgeInsets *)value {
    NSString *description = [self inspectorDescriptionForProperty:property];
    if (description.length == 0 ||
        [description isEqualToString:@"null"] ||
        [description isEqualToString:@"EdgeInsets.zero"]) {
        if (value != NULL) {
            *value = UIEdgeInsetsZero;
        }
        return YES;
    }

    NSRegularExpression *allRegex = [NSRegularExpression
        regularExpressionWithPattern:@"^EdgeInsets\\.all\\(\\s*([-+0-9.eE]+)\\s*\\)$"
                             options:0
                               error:nil];
    NSTextCheckingResult *allMatch =
        [allRegex firstMatchInString:description
                             options:0
                               range:NSMakeRange(0, description.length)];
    if (allMatch.numberOfRanges == 2) {
        CGFloat inset = [[description substringWithRange:
            [allMatch rangeAtIndex:1]] doubleValue];
        if (isfinite(inset)) {
            if (value != NULL) {
                *value = UIEdgeInsetsMake(inset, inset, inset, inset);
            }
            return YES;
        }
    }

    NSRegularExpression *fourValueRegex = [NSRegularExpression
        regularExpressionWithPattern:
            @"^EdgeInsets(?:\\.fromLTRB)?\\(\\s*([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)\\s*,\\s*([-+0-9.eE]+)\\s*\\)$"
                             options:0
                               error:nil];
    NSTextCheckingResult *fourValueMatch =
        [fourValueRegex firstMatchInString:description
                                   options:0
                                     range:NSMakeRange(0, description.length)];
    if (fourValueMatch.numberOfRanges == 5) {
        CGFloat left = [[description substringWithRange:
            [fourValueMatch rangeAtIndex:1]] doubleValue];
        CGFloat top = [[description substringWithRange:
            [fourValueMatch rangeAtIndex:2]] doubleValue];
        CGFloat right = [[description substringWithRange:
            [fourValueMatch rangeAtIndex:3]] doubleValue];
        CGFloat bottom = [[description substringWithRange:
            [fourValueMatch rangeAtIndex:4]] doubleValue];
        if (isfinite(left) && isfinite(top) && isfinite(right) &&
            isfinite(bottom)) {
            if (value != NULL) {
                *value = UIEdgeInsetsMake(top, left, bottom, right);
            }
            return YES;
        }
    }

    if ([description containsString:@"EdgeInsets.symmetric("]) {
        CGFloat horizontal = 0;
        CGFloat vertical = 0;
        NSRegularExpression *horizontalRegex = [NSRegularExpression
            regularExpressionWithPattern:@"horizontal:\\s*([-+0-9.eE]+)"
                                 options:0
                                   error:nil];
        NSRegularExpression *verticalRegex = [NSRegularExpression
            regularExpressionWithPattern:@"vertical:\\s*([-+0-9.eE]+)"
                                 options:0
                                   error:nil];
        NSTextCheckingResult *horizontalMatch =
            [horizontalRegex firstMatchInString:description
                                         options:0
                                           range:NSMakeRange(0, description.length)];
        NSTextCheckingResult *verticalMatch =
            [verticalRegex firstMatchInString:description
                                       options:0
                                         range:NSMakeRange(0, description.length)];
        if (horizontalMatch.numberOfRanges == 2) {
            horizontal = [[description substringWithRange:
                [horizontalMatch rangeAtIndex:1]] doubleValue];
        }
        if (verticalMatch.numberOfRanges == 2) {
            vertical = [[description substringWithRange:
                [verticalMatch rangeAtIndex:1]] doubleValue];
        }
        if (isfinite(horizontal) && isfinite(vertical)) {
            if (value != NULL) {
                *value = UIEdgeInsetsMake(vertical, horizontal,
                                          vertical, horizontal);
            }
            return YES;
        }
    }

    if ([description containsString:@"EdgeInsets.only("]) {
        CGFloat insets[4] = {0, 0, 0, 0};
        NSArray<NSString *> *edges = @[@"left", @"top", @"right", @"bottom"];
        BOOL matchedEdge = NO;
        for (NSUInteger index = 0; index < edges.count; index++) {
            NSString *pattern = [NSString stringWithFormat:
                @"%@:\\s*([-+0-9.eE]+)", edges[index]];
            NSRegularExpression *regex = [NSRegularExpression
                regularExpressionWithPattern:pattern options:0 error:nil];
            NSTextCheckingResult *match =
                [regex firstMatchInString:description
                                  options:0
                                    range:NSMakeRange(0, description.length)];
            if (match.numberOfRanges != 2) {
                continue;
            }
            CGFloat inset = [[description substringWithRange:
                [match rangeAtIndex:1]] doubleValue];
            if (!isfinite(inset)) {
                return NO;
            }
            insets[index] = inset;
            matchedEdge = YES;
        }
        if (matchedEdge) {
            if (value != NULL) {
                *value = UIEdgeInsetsMake(insets[1], insets[0],
                                          insets[3], insets[2]);
            }
            return YES;
        }
    }
    return NO;
}

- (NSDictionary<NSString *, NSValue *> *)
    resolvedOffsetsForTargetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                   rootRenderObjectID:(NSString *)rootRenderObjectID
                       detailsPayload:(id)payload
                  targetLocalOffsets:(NSDictionary<NSString *, NSValue *> *)targetLocalOffsets {
    if (![payload isKindOfClass:NSDictionary.class] ||
        targetObjectIDs.count == 0) {
        return @{};
    }

    NSDictionary *root = payload;
    NSMutableSet<NSString *> *rootRenderObjectIDs = [NSMutableSet set];
    NSDictionary *rootRenderObject =
        [self renderObjectPropertyFromInspectorNode:root];
    NSString *detailsRootRenderObjectID =
        [rootRenderObject[@"valueId"] isKindOfClass:NSString.class]
            ? rootRenderObject[@"valueId"]
            : nil;
    if (rootRenderObjectID.length > 0) {
        [rootRenderObjectIDs addObject:rootRenderObjectID];
    }
    if (detailsRootRenderObjectID.length > 0) {
        [rootRenderObjectIDs addObject:detailsRootRenderObjectID];
    }

    NSMutableDictionary<NSString *, NSValue *> *result =
        [NSMutableDictionary dictionary];
    NSArray *children = [root[@"children"] isKindOfClass:NSArray.class]
        ? root[@"children"]
        : @[];
    for (id child in children) {
        if (![child isKindOfClass:NSDictionary.class]) {
            continue;
        }
        [self collectResolvedOffsetsInDetailsNode:child
                                  targetObjectIDs:targetObjectIDs
                                 cumulativeOffset:CGPointZero
                             hasNonZeroBridgeOffset:NO
                              seenRenderObjectIDs:rootRenderObjectIDs
                              targetLocalOffsets:targetLocalOffsets
                                           result:result];
    }
    return result.copy;
}

- (void)collectResolvedOffsetsInDetailsNode:(NSDictionary *)node
                            targetObjectIDs:(NSSet<NSString *> *)targetObjectIDs
                           cumulativeOffset:(CGPoint)cumulativeOffset
                       hasNonZeroBridgeOffset:(BOOL)hasNonZeroBridgeOffset
                        seenRenderObjectIDs:(NSSet<NSString *> *)seenRenderObjectIDs
                       targetLocalOffsets:(NSDictionary<NSString *, NSValue *> *)targetLocalOffsets
                                     result:(NSMutableDictionary<NSString *, NSValue *> *)result {
    CGPoint nextOffset = cumulativeOffset;
    BOOL nextHasNonZeroBridgeOffset = hasNonZeroBridgeOffset;
    NSMutableSet<NSString *> *nextSeenRenderObjectIDs =
        [seenRenderObjectIDs mutableCopy];
    NSDictionary *renderObject =
        [self renderObjectPropertyFromInspectorNode:node];
    NSString *renderObjectID =
        [renderObject[@"valueId"] isKindOfClass:NSString.class]
            ? renderObject[@"valueId"]
            : nil;
    BOOL foundRenderOffset = NO;
    CGPoint renderOffset = CGPointZero;
    if (renderObjectID.length > 0 &&
        ![nextSeenRenderObjectIDs containsObject:renderObjectID]) {
        [nextSeenRenderObjectIDs addObject:renderObjectID];
        renderOffset = [self parentDataOffsetFromValue:renderObject
                                                 found:&foundRenderOffset];
        if (foundRenderOffset) {
            nextOffset.x += renderOffset.x;
            nextOffset.y += renderOffset.y;
            if (fabs(renderOffset.x) > 0.01 || fabs(renderOffset.y) > 0.01) {
                nextHasNonZeroBridgeOffset = YES;
            }
        }
    }

    NSString *objectID = [KKFIInspectorJSON nodeIDFromDictionary:node];
    if (hasNonZeroBridgeOffset &&
        [targetObjectIDs containsObject:objectID]) {
        // getDetailsSubtree often stops at the public Widget node. In that
        // shape the accumulated value contains the hidden Row/Padding bridge,
        // while the target's own RenderObject parentData is only present in
        // getLayoutExplorerNode. Add that final local segment so siblings such
        // as a button Icon and Text do not collapse onto the same origin.
        CGPoint targetOffset = cumulativeOffset;
        NSValue *targetLocalOffsetValue = targetLocalOffsets[objectID];
        if (targetLocalOffsetValue != nil) {
            CGPoint targetLocalOffset = targetLocalOffsetValue.CGPointValue;
            targetOffset.x += targetLocalOffset.x;
            targetOffset.y += targetLocalOffset.y;
        } else if (foundRenderOffset) {
            targetOffset.x += renderOffset.x;
            targetOffset.y += renderOffset.y;
        }
        result[objectID] = [NSValue valueWithCGPoint:targetOffset];
    }

    if (result.count == targetObjectIDs.count) {
        return;
    }
    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        if (![child isKindOfClass:NSDictionary.class]) {
            continue;
        }
        [self collectResolvedOffsetsInDetailsNode:child
                                  targetObjectIDs:targetObjectIDs
                                 cumulativeOffset:nextOffset
                             hasNonZeroBridgeOffset:nextHasNonZeroBridgeOffset
                              seenRenderObjectIDs:nextSeenRenderObjectIDs
                              targetLocalOffsets:targetLocalOffsets
                                           result:result];
    }
}

- (NSDictionary *)renderObjectPropertyFromInspectorNode:(NSDictionary *)node {
    if ([node[@"renderObject"] isKindOfClass:NSDictionary.class]) {
        return node[@"renderObject"];
    }
    NSArray *properties = [node[@"properties"] isKindOfClass:NSArray.class]
        ? node[@"properties"]
        : @[];
    for (id value in properties) {
        if ([value isKindOfClass:NSDictionary.class] &&
            [value[@"name"] isEqual:@"renderObject"]) {
            return value;
        }
    }
    return nil;
}

- (CGPoint)parentDataOffsetFromValue:(id)value found:(BOOL *)found {
    NSString *description = [self parentDataDescriptionInValue:value];
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
            double x = [[description substringWithRange:
                [match rangeAtIndex:1]] doubleValue];
            double y = [[description substringWithRange:
                [match rangeAtIndex:2]] doubleValue];
            if (isfinite(x) && isfinite(y)) {
                if (found != NULL) {
                    *found = YES;
                }
                return CGPointMake(x, y);
            }
        }
    }

    if (found != NULL) {
        *found = NO;
    }
    return CGPointZero;
}

- (NSString *)parentDataDescriptionInValue:(id)value {
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        if ([dictionary[@"name"] isEqual:@"parentData"] &&
            [dictionary[@"description"] isKindOfClass:NSString.class]) {
            return dictionary[@"description"];
        }
        for (id child in dictionary.allValues) {
            NSString *description =
                [self parentDataDescriptionInValue:child];
            if (description.length > 0) {
                return description;
            }
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id child in value) {
            NSString *description =
                [self parentDataDescriptionInValue:child];
            if (description.length > 0) {
                return description;
            }
        }
    }
    return nil;
}

- (NSArray *)resolvedCardPropertiesFromDetailsPayload:(id)payload {
    if (![payload isKindOfClass:NSDictionary.class]) {
        return @[];
    }

    NSDictionary *paddingNode = [self firstInspectorNodeWithWidgetType:@"Padding"
                                                                inValue:payload];
    NSMutableArray *result = [NSMutableArray array];

    NSArray *paddingProperties =
        [paddingNode[@"properties"] isKindOfClass:NSArray.class]
            ? paddingNode[@"properties"]
            : @[];
    for (id value in paddingProperties) {
        if (![value isKindOfClass:NSDictionary.class] ||
            ![value[@"name"] isEqual:@"padding"]) {
            continue;
        }
        NSMutableDictionary *marginProperty = [value mutableCopy];
        marginProperty[@"name"] = @"margin";
        [result addObject:marginProperty.copy];
        break;
    }

    [result addObjectsFromArray:
        [self resolvedMaterialPropertiesFromDetailsPayload:payload]];
    return result.copy;
}

- (NSArray *)resolvedMaterialPropertiesFromDetailsPayload:(id)payload {
    if (![payload isKindOfClass:NSDictionary.class]) {
        return @[];
    }
    NSDictionary *materialNode = [self firstInspectorNodeWithWidgetType:@"Material"
                                                                 inValue:payload];
    NSSet<NSString *> *materialPropertyNames = [NSSet setWithArray:@[
        @"color", @"shadowColor", @"surfaceTintColor", @"elevation", @"shape",
    ]];
    NSArray *materialProperties =
        [materialNode[@"properties"] isKindOfClass:NSArray.class]
            ? materialNode[@"properties"]
            : @[];
    NSMutableArray *result = [NSMutableArray array];
    for (id value in materialProperties) {
        if ([value isKindOfClass:NSDictionary.class] &&
            [materialPropertyNames containsObject:value[@"name"]]) {
            [result addObject:value];
        }
    }
    return result.copy;
}

- (NSDictionary *)firstInspectorNodeWithWidgetType:(NSString *)widgetType
                                            inValue:(id)value {
    if (![value isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    NSDictionary *node = value;
    NSString *candidate = [node[@"widgetRuntimeType"] isKindOfClass:NSString.class]
        ? node[@"widgetRuntimeType"]
        : ([node[@"description"] isKindOfClass:NSString.class]
               ? node[@"description"]
               : nil);
    if ([candidate isEqualToString:widgetType]) {
        return node;
    }
    NSArray *children = [node[@"children"] isKindOfClass:NSArray.class]
        ? node[@"children"]
        : @[];
    for (id child in children) {
        NSDictionary *match = [self firstInspectorNodeWithWidgetType:widgetType
                                                              inValue:child];
        if (match != nil) {
            return match;
        }
    }
    return nil;
}


@end

