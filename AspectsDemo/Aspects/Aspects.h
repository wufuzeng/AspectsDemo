//
//  Aspects.h
//  Aspects - A delightful, simple library for aspect oriented programming.
//
//  Copyright (c) 2014 Peter Steinberger. Licensed under the MIT license.
//

#import <Foundation/Foundation.h>

#import "AspectsConstant.h"

#import "AspectInfo.h"
#import "AspectToken.h"
#import "AspectTracker.h"
#import "AspectsContainer.h"

#import "NSInvocation+Aspects.h"



/**
 Aspects利用的OC的消息转发机制，hook消息。这样会有一些性能开销。不要把Aspects加到经常被使用的方法里面。Aspects是用来设计给view/controller 代码使用的，而不是用来hook每秒调用1000次的方法的。

 添加Aspects之后，会返回一个隐式的token，这个token会被用来注销hook方法的。所有的调用都是线程安全的。
 */
@interface NSObject (Aspects)

/// Adds a block of code before/instead/after the current `selector` for a specific class.
///
/// @param block Aspects replicates the type signature of the method being hooked.
/// The first parameter will be `id<AspectInfo>`, followed by all parameters of the method.
/// These parameters are optional and will be filled to match the block signature.
/// You can even use an empty block, or one that simple gets `id<AspectInfo>`.
///
/// @note Hooking static methods is not supported.
/// @return A token which allows to later deregister the aspect.

/**
 通过在 NSObject (Aspects) 分类中暴露出的两个接口分别提供了对实例和 Class 的 Hook 实现
 
 作为使用者无需进行更多的操作即可 Hook 指定实例或者 Class 的指定 SEL
 */


/**
 方法里面有4个入参。
 第一个selector是要给它增加切面的原方法。
 第二个参数是AspectOptions类型，是代表这个切片增加在原方法的before / instead / after。
 第三个入参block。重点的就是这个block复制了正在被hook的方法的签名signature类型。block遵循AspectInfo协议。我们甚至可以使用一个空的block。AspectInfo协议里面的参数是可选的，主要是用来匹配block签名的。
 第四个参数是返回的错误。
 
 注意，Aspects是不支持hook 静态static方法的
 */

+ (id<AspectToken>)aspect_hookSelector:(SEL)selector
                           withOptions:(AspectOptions)options
                            usingBlock:(id)block
                                 error:(NSError **)error;

/// Adds a block of code before/instead/after the current `selector` for a specific instance.
- (id<AspectToken>)aspect_hookSelector:(SEL)selector
                           withOptions:(AspectOptions)options
                            usingBlock:(id)block
                                 error:(NSError **)error;

@end





