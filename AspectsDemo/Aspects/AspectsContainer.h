//
//  AspectsContainer.h
//  TEST
//
//  Created by 吴福增 on 2018/12/20.
//  Copyright © 2018 吴福增. All rights reserved.
//

/**
    AspectsContainer - 切面容器
 
 AspectsContainer 作为切面的容器类，关联指定对象的指定方法，内部有三个切面队列，分别容纳关联指定对象的指定方法中相对应 AspectOption 的 Hook：
 
 1.NSArray *beforeAspects; - AspectPositionBefore
 2.NSArray *insteadAspects; - AspectPositionInstead
 3.NSArray *afterAspects; - AspectPositionAfter
 
 为什么要说关联呢？因为 AspectsContainer 是在 NSObject 分类中通过 AssociatedObject 方法与当前要 Hook 的目标关联在一起的。
 Note: 关联目标是 Hook 之后的 Selector，即 aliasSelector（原始 SEL 名称加 aspects_ 前缀对应的 SEL）。
 */

#import <Foundation/Foundation.h>

#import "AspectsConstant.h"

NS_ASSUME_NONNULL_BEGIN

@class AspectIdentifier;

// 跟踪对象/类的所有Aspect。
@interface AspectsContainer : NSObject

/** 所有 发送前跟踪 */
@property (atomic, copy) NSArray *beforeAspects;
/** 所有 发送替换跟踪 */
@property (atomic, copy) NSArray *insteadAspects;
/** 所有 发送后跟踪 */
@property (atomic, copy) NSArray *afterAspects;


/** 是否存在跟踪 */
- (BOOL)hasAspects;

/** 添加跟踪标识 */
- (void)addAspect:(AspectIdentifier *)aspect withOptions:(AspectOptions)injectPosition;
/** 移除跟踪标识 */
- (BOOL)removeAspect:(id)aspect;



@end

NS_ASSUME_NONNULL_END
