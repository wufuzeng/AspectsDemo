//
//  AspectInfo.h
//  TEST
//
//  Created by 吴福增 on 2018/12/20.
//  Copyright © 2018 吴福增. All rights reserved.

/**
    AspectInfo协议 - 嵌入 Hook 中的 Block 首位参数
 
    AspectInfo类 - 切面信息，遵循 AspectInfo 协议
 */



#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AspectInfo 协议是我们块语法的第一个参数。
@protocol AspectInfo <NSObject>

/// The instance that is currently hooked.
- (id)instance;

/// 被 Hook 方法的原始 invocation
- (NSInvocation *)originalInvocation;

/// 所有方法参数（装箱之后的）惰性执行 Note: 装箱是一个开销昂贵操作，所以用到再去执行。
- (NSArray *)arguments;


@end

/**
 Note: 关于装箱，对于提供一个 NSInvocation 就可以拿到其 arguments 这一点上，
 ReactiveCocoa 团队提供了很大贡献（细节见 Aspects 内部 NSInvocation 分类）。 */

/**
 AspectInfo 比较简单，参考 ReactiveCocoa 团队提供的 NSInvocation 参数通用方法可将参数装箱为 NSValue，简单来说 AspectInfo 扮演了一个提供 Hook 信息的角色。
 */
@interface AspectInfo : NSObject <AspectInfo>
- (id)initWithInstance:(__unsafe_unretained id)instance invocation:(NSInvocation *)invocation;
// 调用方法的实例对象
@property (nonatomic, unsafe_unretained, readonly) id instance;
// 方法参数
@property (nonatomic, strong, readonly) NSArray *arguments;
// 方法对象实例
@property (nonatomic, strong, readonly) NSInvocation *originalInvocation;
@end

NS_ASSUME_NONNULL_END
