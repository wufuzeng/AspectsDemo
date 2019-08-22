//
//  AspectTracker.h
//  TEST
//
//  Created by 吴福增 on 2018/12/20.
//  Copyright © 2018 吴福增. All rights reserved.
//


/**
    AspectTracker - 切面跟踪器
 
    AspectTracker 作为切面追踪器，原理大致如下：
 
 
 // Add the selector as being modified.
 currentClass = klass;
 AspectTracker *parentTracker = nil;
 do {
     AspectTracker *tracker = swizzledClassesDict[currentClass];
     if (!tracker) {
         tracker = [[AspectTracker alloc] initWithTrackedClass:currentClass parent:parentTracker];
         swizzledClassesDict[(id)currentClass] = tracker;
     }
     [tracker.selectorNames addObject:selectorName];
     // All superclasses get marked as having a subclass that is modified.
     parentTracker = tracker;
 }while ((currentClass = class_getSuperclass(currentClass)));
 
 Note: 聪明的你应该已经注意到了全局变量 swizzledClassesDict 中的 value 对应着 AspectTracker 指针。
 就是说 AspectTracker 是从下而上追踪，最底层的 parentEntry 为 nil，父类的 parentEntry 为子类的 tracker。
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AspectTracker : NSObject
/** 实例化 */
- (id)initWithTrackedClass:(Class)trackedClass;
/** 当前类 */
@property (nonatomic, strong) Class trackedClass;
/**  */
@property (nonatomic, readonly) NSString *trackedClassName;
/** 当前类追踪的 方法集 */
@property (nonatomic, strong) NSMutableSet *selectorNames;
/** 当前类子类的方法的 追踪器集 */
@property (nonatomic, strong) NSMutableDictionary *selectorNamesToSubclassTrackers;
/** 添加子类方法的 追踪器 */
- (void)addSubclassTracker:(AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName;
/** 移除子类方法的 追踪器 */
- (void)removeSubclassTracker:(AspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName;
/** 判断子类指定方法是否有钩子 */
- (BOOL)subclassHasHookedSelectorName:(NSString *)selectorName;
/** 获取子类指定方法的跟踪器 集 */
- (NSSet *)subclassTrackersHookingSelectorName:(NSString *)selectorName;

@end


NS_ASSUME_NONNULL_END
