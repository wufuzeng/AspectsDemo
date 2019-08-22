//
//  Aspects.m
//  Aspects - A delightful, simple library for aspect oriented programming.
//
//  Copyright (c) 2014 Peter Steinberger. Licensed under the MIT license.
//

#import "Aspects.h"
// 导入这个头文件是为了下面用到的自旋锁。
#import <libkern/OSAtomic.h>
// 使用Runtime的必备的两个头文件。
#import <objc/runtime.h>
#import <objc/message.h>


/**
    AspectIdentifier - 切面 ID，应该遵循 AspectToken 协议（作者漏掉了，已提 PR）
 
    Note: AspectIdentifier 实际上是添加切面的 Block 的第一个参数，其应该遵循 AspectToken 协议，事实上也的确如此，其提供了 remove 方法的实现。
 
    AspectIdentifier 内部需要注意的是由于使用 Block 来写 Hook 中我们加的料，这里生成了 blockSignature，在 AspectIdentifier 初始化的过程中会去判断 blockSignature 与入参 object 的 selector 得到的 methodSignature 的兼容性，兼容性判断成功才会顺利初始化。
 */

// Tracks a single aspect.
@interface AspectIdentifier : NSObject

/** 类方法创建 标识实例 */
+ (instancetype)identifierWithSelector:(SEL)selector object:(id)object options:(AspectOptions)options block:(id)block error:(NSError **)error;

/** 执行Aspect信息 */
- (BOOL)invokeWithInfo:(id<AspectInfo>)info;

/** 追踪的方法 */
@property (nonatomic, assign) SEL selector;
/** 钩子回调 */
@property (nonatomic, strong) id block;
/** 钩子回调Block的签名 */
@property (nonatomic, strong) NSMethodSignature *blockSignature;
/** 追踪方法的Target */
@property (nonatomic, weak  ) id object;
/** 钩子的位置 */
@property (nonatomic, assign) AspectOptions options;

@end



       NSString *const AspectErrorDomain = @"AspectErrorDomain";
/** 子类后缀 */
static NSString *const AspectsSubclassSuffix = @"_Aspects_";
/** 消息前缀 */
static NSString *const AspectsMessagePrefix = @"aspects_";

@implementation NSObject (Aspects)

#pragma mark - Public Aspects API --------
 
/// 返回一个允许稍后取消方面注册的令牌。
+ (id<AspectToken>)aspect_hookSelector:(SEL)selector
                      withOptions:(AspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return aspect_add((id)self, selector, options, block, error);
}

/// 返回一个允许稍后取消方面注册的令牌。
- (id<AspectToken>)aspect_hookSelector:(SEL)selector
                      withOptions:(AspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return aspect_add(self, selector, options, block, error);
}
 

#pragma mark - Private Helper---
/** 添加aspect函数 */
static id aspect_add(id self, SEL selector, AspectOptions options, id block, NSError **error) {
    //断言
    NSCParameterAssert(self);
    NSCParameterAssert(selector);
    NSCParameterAssert(block);

    __block AspectIdentifier *identifier = nil;
    aspect_performLocked(^{
        //验证该方法是否允许跟踪
        if (aspect_isSelectorAllowedAndTrack(self, selector, options, error)) {
            //获取带追踪方法的容器
            AspectsContainer *aspectContainer = aspect_getContainerForObject(self, selector);
            //根据跟踪踪方法返回Block 创建跟踪的标识
            identifier = [AspectIdentifier identifierWithSelector:selector object:self options:options block:block error:error];
            if (identifier) {
                // 添加标识到容器
                [aspectContainer addAspect:identifier withOptions:options];

                // 准备 类和方法钩子。
                aspect_prepareClassAndHookSelector(self, selector, error);
            }
        }
    });
    return identifier;
}
/** 移除aspect函数 */
static BOOL aspect_remove(AspectIdentifier *aspect, NSError **error) {
    NSCAssert([aspect isKindOfClass:AspectIdentifier.class], @"Must have correct type.");

    __block BOOL success = NO;
    aspect_performLocked(^{
        id self = aspect.object; // strongify
        if (self) {
            AspectsContainer *aspectContainer = aspect_getContainerForObject(self, aspect.selector);
            //容器移除该标识的跟踪方法
            success = [aspectContainer removeAspect:aspect];
            //清除指定类和跟踪方法钩子.
            aspect_cleanupHookedClassAndSelector(self, aspect.selector);
            // destroy token
            aspect.object = nil;
            aspect.block = nil;
            aspect.selector = NULL;
        }else {
            /** 无法取消注册钩子。对象已经收回 */            
            NSString *errrorDesc = [NSString stringWithFormat:@"Unable to deregister hook. Object already deallocated: %@", aspect];
            AspectError(AspectErrorRemoveObjectAlreadyDeallocated, errrorDesc);
        }
    });
    return success;
}
/** 线程锁函数 */
static void aspect_performLocked(dispatch_block_t block) {
    static OSSpinLock aspect_lock = OS_SPINLOCK_INIT;
    OSSpinLockLock(&aspect_lock);
    block();
    OSSpinLockUnlock(&aspect_lock);
}

/** 获取追踪方法的别名 */
static SEL aspect_aliasForSelector(SEL selector) {
    NSCParameterAssert(selector);
	return NSSelectorFromString([AspectsMessagePrefix stringByAppendingFormat:@"_%@", NSStringFromSelector(selector)]);
}

/**
  通过block参数生成跟踪返回Block的签名
 
  通过block参数生成了一个NSMethodSignature
 */
static NSMethodSignature *aspect_blockMethodSignature(id block, NSError **error) {
    /** 进行了转换处理 转为自定结构体类型 void指针是万能指针 */
    AspectBlockRef layout = (__bridge void *)block;
    
	if (!(layout->flags & AspectBlockFlagsHasSignature)) {
        /** flags 没有包含 AspectBlockFlagsHasSignature 类型 */
        /** 该Block 不包含一个类型签名 */
        NSString *description = [NSString stringWithFormat:@"The block %@ doesn't contain a type signature.", block];
        AspectError(AspectErrorMissingBlockSignature, description);
        return nil;
    }
    //指针运算
	void *desc = layout->descriptor;        //指向descriptor结构体
	desc += 2 * sizeof(unsigned long int);  //指向descriptor结构体的void (*copy)(void *dst, const void *src);类型
    
	if (layout->flags & AspectBlockFlagsHasCopyDisposeHelpers) {
        /** flags 没有包含 AspectBlockFlagsHasCopyDisposeHelpers 类型 */
		desc += 2 * sizeof(void *); //指向descriptor结构体的 signature
    }
    
	if (!desc) {
        //如果descriptor结构体的 signature  是一个空指针
        /** 该Block 不包含一个类型签名 */
        NSString *description = [NSString stringWithFormat:@"The block %@ doesn't has a type signature.", block];
        AspectError(AspectErrorMissingBlockSignature, description);
        return nil;
    }
    //descriptor结构体的 signature  不是一个空指针,取出该指针指向的存储空间的值 签名值
    /**
     desc   为指针     AspectBlockRef结构体对象内存空间中 signature 成员内存首地址
     * desc 为指针指向的内存空间。
     (const char *)   转字符类型
     (const char **)  转字符指针类型
     */
    const char *signature = (*(const char **)desc);
    //根据ObjcTypes 生成签名
	return [NSMethodSignature signatureWithObjCTypes:signature];
}
/** 检查block签名兼容性  */
static BOOL aspect_isCompatibleBlockSignature(NSMethodSignature *blockSignature, id object, SEL selector, NSError **error) {
    
    NSCParameterAssert(blockSignature);
    NSCParameterAssert(object);
    NSCParameterAssert(selector);
    //默认匹配
    BOOL signaturesMatch = YES;
    //获取方法签名
    NSMethodSignature *methodSignature = [[object class] instanceMethodSignatureForSelector:selector];
    
    if (blockSignature.numberOfArguments > methodSignature.numberOfArguments) {
        //若block签名的 参数的数量 大于 方法签名的参数的数量，返回不匹配
        signaturesMatch = NO;
    }else {
            // block: 'v' argument'@?''@"<AspectInfo>"'
            //method: 'v' argument:'@'':''@''@''@'
        if (blockSignature.numberOfArguments > 1) {
            //若block参数大于1(第一个参数是block，后面的都是传进block的参数)
            
            //取 传进block 的参数
            const char *blockType = [blockSignature getArgumentTypeAtIndex:1];
            if (blockType[0] != '@') {
                //若传进block 的参数首字符不是“@”,返回不匹配
                signaturesMatch = NO;
            }
        }
        // 参数0是self/block，参数1是SEL或id<AspectInfo>。我们从参数2开始比较。
        // Blok的参数可以比方法少，这没关系。
        if (signaturesMatch) {
            /** 从Block消息的第2参数开始遍历 */
            for (NSUInteger idx = 2; idx < blockSignature.numberOfArguments; idx++) {
                // 取 方法消息的第2个参数类型，即方法的第0个参数类型
                const char *methodType = [methodSignature getArgumentTypeAtIndex:idx];
                // 取 block消息的第2个参数类型，即block的第1个参数类型
                const char *blockType = [blockSignature getArgumentTypeAtIndex:idx];
                // 只比较参数类型，不比较可选类型数据。
                if (!methodType || !blockType || methodType[0] != blockType[0]) {
                    //若 方法参数类型为空 或 Block参数类型为空 或 方法参数类型与Block参数类型首字符不同,返回不匹配。
                    signaturesMatch = NO; break;
                }
            }
        }
    }

    if (!signaturesMatch) {
        /** 不匹配，抛出Block 签名 与 方法签名不匹配 */
        NSString *description = [NSString stringWithFormat:@"Block signature %@ doesn't match %@.", blockSignature, methodSignature];
        AspectError(AspectErrorIncompatibleBlockSignature, description);
        return NO;
    }
    return YES;
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Class + Selector Preparation
/** 是否是函数外部入口 */
static BOOL aspect_isMsgForwardIMP(IMP impl) {
    /**
     _objc_msgForward函数是什么？
     当对象没有实现某个方法 ，会调用这个函数进行方法转发。
     （某方法对应的IMP没找到，会返回这个函数的IMP去执行）
     */
    return impl == _objc_msgForward
#if !defined(__arm64__)
    || impl == (IMP)_objc_msgForward_stret
#endif
    ;
}
/** 获取消息 外部入口函数指针 */
static IMP aspect_getMsgForwardIMP(NSObject *self, SEL selector) {
    IMP msgForwardIMP = _objc_msgForward;
#if !defined(__arm64__)
    // As an ugly internal runtime implementation detail in the 32bit runtime, we need to determine of the method we hook returns a struct or anything larger than id.
    // https://developer.apple.com/library/mac/documentation/DeveloperTools/Conceptual/LowLevelABI/000-Introduction/introduction.html
    // https://github.com/ReactiveCocoa/ReactiveCocoa/issues/783
    // http://infocenter.arm.com/help/topic/com.arm.doc.ihi0042e/IHI0042E_aapcs.pdf (Section 5.4)
    
    //作为32位运行时中的一个丑陋的内部运行时实现细节，我们需要确定我们钩子的方法返回的是结构体或任何大于id的东西。
    Method method = class_getInstanceMethod(self.class, selector);
    const char *encoding = method_getTypeEncoding(method);
    //是否有返回值
    BOOL methodReturnsStructValue = encoding[0] == _C_STRUCT_B;
    
    if (methodReturnsStructValue) {
        @try {
            NSUInteger valueSize = 0;
            NSGetSizeAndAlignment(encoding, &valueSize, NULL);

            if (valueSize == 1 || valueSize == 2 || valueSize == 4 || valueSize == 8) {
                methodReturnsStructValue = NO;
            }
        } @catch (__unused NSException *e) {}
    }
    
    if (methodReturnsStructValue) {
        msgForwardIMP = (IMP)_objc_msgForward_stret;
    }
#endif
    return msgForwardIMP;
}
// 准备 类和方法钩子。
static void aspect_prepareClassAndHookSelector(NSObject *self, SEL selector, NSError **error) {
    
    NSCParameterAssert(selector);
    // 添加钩子的 类
    Class klass = aspect_hookClass(self, error);
    //取方法
    Method targetMethod = class_getInstanceMethod(klass, selector);
    //取方法实现指针
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    
    if (!aspect_isMsgForwardIMP(targetMethodIMP)) {
        // 为已存在方法实现的方法创建一个方法别名，它还没有被复制。
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        SEL aliasSelector = aspect_aliasForSelector(selector);
        // 实例是否响应 这个别名方法
        if (![klass instancesRespondToSelector:aliasSelector]) {
            //不响应就添加 跟踪方法的别名方法
            __unused BOOL addedAlias = class_addMethod(klass, aliasSelector, method_getImplementation(targetMethod), typeEncoding);
            
            NSCAssert(addedAlias, @"Original implementation for %@ is already copied to %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), klass);
        }

        //我们使用forwardInvocation来挂钩。
        class_replaceMethod(klass, selector, aspect_getMsgForwardIMP(self, selector), typeEncoding);
        
        AspectLog(@"Aspects: Installed hook for -[%@ %@].", klass, NSStringFromSelector(selector));
    }
}

// 清除指定类和跟踪方法钩子.
static void aspect_cleanupHookedClassAndSelector(NSObject *self, SEL selector) {
    NSCParameterAssert(self);
    NSCParameterAssert(selector);

	Class klass = object_getClass(self);
    BOOL isMetaClass = class_isMetaClass(klass);
    if (isMetaClass) {
        klass = (Class)self;
    }
    // 检查方法,该方法是否被标记为 转发 并 撤销 。
    Method targetMethod = class_getInstanceMethod(klass, selector);
    // 取跟踪方法实现。
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    
    if (aspect_isMsgForwardIMP(targetMethodIMP)) {
        // 恢复原来的方法实现。

        // 获取跟踪方法别名身份
        SEL aliasSelector = aspect_aliasForSelector(selector);
        // 获取跟踪方法别名Method实例。
        Method originalMethod = class_getInstanceMethod(klass, aliasSelector);
        // 获取跟踪方法别名的实现
        IMP originalIMP = method_getImplementation(originalMethod);
        // 找不到跟踪方法的原始实现
        NSCAssert(originalMethod, @"Original implementation for %@ not found %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), klass);
        
        // 获取跟踪方法编码类型
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        // 恢复跟踪方法原始实现
        class_replaceMethod(klass, selector, originalIMP, typeEncoding);
        // 移除跟踪方法的钩子
        AspectLog(@"Aspects: Removed hook for -[%@ %@].", klass, NSStringFromSelector(selector));
    }

    // 取消注册全局跟踪选择器
    aspect_deregisterTrackedSelector(self, selector);
    
    // 获取方面容器并检查 是否还有钩子剩余。如果没有清理干净
    // Get the aspect container and check if there are any hooks remaining. Clean up if there are not.
    AspectsContainer *container = aspect_getContainerForObject(self, selector);
    if (!container.hasAspects) {
        // 销毁容器
        aspect_destroyContainerForObject(self, selector);
        // 找出如何修改类,以实现撤消更改。
        NSString *className = NSStringFromClass(klass);
        if ([className hasSuffix:AspectsSubclassSuffix]) {
            Class originalClass = NSClassFromString([className stringByReplacingOccurrencesOfString:AspectsSubclassSuffix withString:@""]);
            //原始跟踪类必须存在。
            NSCAssert(originalClass != nil, @"Original class must exist");
            //恢复跟踪类isa指针
            object_setClass(self, originalClass);
            AspectLog(@"Aspects: %@ has been restored.", NSStringFromClass(originalClass));

            // 只有在能够确保使用子类不存在实例的情况下，我们才能释放类的内存。
            //由于我们没有在全局范围内跟踪它，所以我们不能确保这一点，但是保持它的开销也不大。
            //objc_disposeClassPair(object.class);
        }else {
            // 类最有可能在适当的位置被刷新。撤销。
            // Class is most likely swizzled in place. Undo that.
            if (isMetaClass) {
                aspect_undoSwizzleClassInPlace((Class)self);
            }else if (self.class != klass) {
            	aspect_undoSwizzleClassInPlace(klass);
            }
        }
    }
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Hook Class
/**
 Aspects 为了能区别 Class 和 Instance 的逻辑，实现了名为 aspect_hookClass 的方法
 
 Note: 其实这里的难点就在于对 .class 和 object_getClass 的区分。
    class 当 target 是 Instance 则返回 Class，当 target 是 Class 则返回自身
    object_getClass 返回 isa 指针的指向
 
 Note: (运行时)动态创建一个 Class 的完整步骤也是我们应该注意的。
    objc_allocateClassPair //1.为 “class pair” 创建存储空间
    class_addMethod        //2.为这个类添加所需的 methods
    class_addIvar          //3.为这个类添加所需的 ivars
    objc_registerClassPair //4.注册这个类
 
 */
static Class aspect_hookClass(NSObject *self, NSError **error) {
    // 断言 self
    NSCParameterAssert(self);
    // class (自己)
	Class statedClass = self.class;
    // isa (父类)
	Class baseClass = object_getClass(self);
	NSString *className = NSStringFromClass(baseClass);

    // 已经子类化过了
	if ([className hasSuffix:AspectsSubclassSuffix]) {
		return baseClass;
        /// 我们混写了一个 class 对象，而非一个单独的 object
	}else if (class_isMetaClass(baseClass)) {
        // baseClass 是元类，则 self 是 Class 或 MetaClass，混写 self
        return aspect_swizzleClassInPlace((Class)self);
        // 可能是一个 KVO'ed class。混写就位。也要混写 meta classes。
    }else if (statedClass != baseClass) {
        /**
         当消息对象为实例对象instance时，class与object_getClass返回的对象地址一样；
         当消息对象为类对象，或元类对象时，class返回的消息对象本身，
         而object_getClass返回的是下一个对象；
         原因：因为class返回的是self，而object_getClass返回的是isa指向的对象；
         */
        
        // 当 .class 和 isa 指向不同的情况，混写 baseClass
        return aspect_swizzleClassInPlace(baseClass);
    }

    // 默认情况下，动态创建子类
    // 拼接子类后缀 AspectsSubclassSuffix
	const char *subclassName = [className stringByAppendingString:AspectsSubclassSuffix].UTF8String;
	// 尝试用拼接后缀的名称获取 isa
    Class subclass = objc_getClass(subclassName);
    // 找不到 isa，代表还没有动态创建过这个子类
	if (subclass == nil) {
        // 创建一个 class pair，baseClass 作为新类的 superClass，类名为 subclassName
		subclass = objc_allocateClassPair(baseClass, subclassName, 0);
		if (subclass == nil) {// 返回 nil，即创建失败
            NSString *errrorDesc = [NSString stringWithFormat:@"objc_allocateClassPair failed to allocate class %s.", subclassName];
            AspectError(AspectErrorFailedToAllocateClassPair, errrorDesc);
            return nil;
        }
        // 混写 forwardInvocation:
		aspect_swizzleForwardInvocation(subclass);
        // subClass.class = statedClass
		aspect_hookedGetClass(subclass, statedClass);
        // subClass.isa.class = statedClass
		aspect_hookedGetClass(object_getClass(subclass), statedClass);
        // 注册新类
		objc_registerClassPair(subclass);
	}
    // 覆盖 isa
	object_setClass(self, subclass);
	return subclass;
}

/**
 Aspect 中 forwardInvocation 的方法实现 的新名字
 Aspect 混写 forwardInvocation 的实现，名字为原forwardInvocation：
    static void __ASPECTS_ARE_BEING_CALLED__(*self,selector,*invocation);
 */

static NSString *const AspectsForwardInvocationSelectorName = @"__aspects_forwardInvocation:";

/**
  替换 forwardInvocation:
 
  不论是 Class 还是 Instance，都会调用 aspect_swizzleForwardInvocation 方法
 */
static void aspect_swizzleForwardInvocation(Class klass) {
    // 断言 klass
    NSCParameterAssert(klass);
    // 替换类中 已有方法的实现,如果该方法不存在添加该方法
    // 如果没有 method，replace 实际上会像是 class_addMethod 一样
    IMP originalImplementation = class_replaceMethod(
                                                     klass,
                                                     @selector(forwardInvocation:),
                                                     (IMP)__ASPECTS_ARE_BEING_CALLED__,
                                                     "v@:@"
                                                     );
    // 拿到 originalImplementation 证明是 replace 而不是 add，情况少见
    if (originalImplementation) {
        // 添加 AspectsForwardInvocationSelectorName 的方法，IMP 为原生 forwardInvocation:
        /**
         * 向People类中添加 test:方法;函数签名为@@:@,
         *    第一个v表示返回值类型为void,
         *    第二个@表示的是函数的调用者类型,
         *    第三个:表示 SEL
         *    第四个@表示需要一个id类型的参数
         */
        class_addMethod(
                        klass,
                        NSSelectorFromString(AspectsForwardInvocationSelectorName),
                        originalImplementation,
                        "v@:@"
                        );
    }
    AspectLog(@"Aspects: %@ is now aspect aware.", NSStringFromClass(klass));
}
/** 移除混淆类 */
static void aspect_undoSwizzleForwardInvocation(Class klass) {
    NSCParameterAssert(klass);
    /** 取混淆的forwardInvocation： */
    Method originalMethod = class_getInstanceMethod(klass, NSSelectorFromString(AspectsForwardInvocationSelectorName));
    /** 取原forwardInvocation： */
    Method objectMethod = class_getInstanceMethod(NSObject.class, @selector(forwardInvocation:));
    // 这里没有class_removeMethod，所以我们能做的最好的事情就是重新抓取原始的实现，或者使用假的方法。
    // There is no class_removeMethod, so the best we can do is to retore the original implementation, or use a dummy.
    /** 取原forwardInvocation：实现 */
    IMP originalImplementation = method_getImplementation(originalMethod ?: objectMethod);
    
    /** 恢复原forwardInvocation：实现 */
    class_replaceMethod(klass, @selector(forwardInvocation:), originalImplementation, "v@:@");

    AspectLog(@"Aspects: %@ has been restored.", NSStringFromClass(klass));
}

static void aspect_hookedGetClass(Class class, Class statedClass) {
    NSCParameterAssert(class);
    NSCParameterAssert(statedClass);
	Method method = class_getInstanceMethod(class, @selector(class));
	IMP newIMP = imp_implementationWithBlock(^(id self) {
		return statedClass;
	});
	class_replaceMethod(class, @selector(class), newIMP, method_getTypeEncoding(method));
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Swizzle Class In Place
/**
 static NSMutableSet *swizzledClasses;
 在 Aspects 中担当记录已混写类的角色
 内部提供一个用于修改这个全局变量内容的方法
 Note: 注意 @synchronized(swizzledClasses)。
 这个全局变量记录了 forwardInvocation: 被混写的的类名称。
 Note: 注意在用途上与 static NSMutableDictionary *swizzledClassesDict; 区分理解。
 */
static void _aspect_modifySwizzledClasses(void (^block)(NSMutableSet *swizzledClasses)) {
    static NSMutableSet *swizzledClasses;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        /** 内部静态全局变量 */        
        swizzledClasses = [NSMutableSet new];
    });
    @synchronized(swizzledClasses) {
        block(swizzledClasses);
    }
}

static Class aspect_swizzleClassInPlace(Class klass) {
    NSCParameterAssert(klass);
    NSString *className = NSStringFromClass(klass);
    //所有混淆类集
    _aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        if (![swizzledClasses containsObject:className]) {
            aspect_swizzleForwardInvocation(klass);
            [swizzledClasses addObject:className];
        }
    });
    return klass;
}
/** 撤销 混写 类 */
static void aspect_undoSwizzleClassInPlace(Class klass) {
    NSCParameterAssert(klass);
    NSString *className = NSStringFromClass(klass);
    // 取 存全局混淆类 的变量
    _aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        if ([swizzledClasses containsObject:className]) {
            /** 移除混淆类 */
            aspect_undoSwizzleForwardInvocation(klass);
            [swizzledClasses removeObject:className];
        }
    });
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Aspect Invoke Point


/**
 这是Aspect混写forwardInvocation: 的具体实现
 
 用来替换替换 原生 forwardInvocation:
 */
static void __ASPECTS_ARE_BEING_CALLED__(__unsafe_unretained NSObject *self, SEL selector, NSInvocation *invocation) {
    // 断言 self, invocation
    NSCParameterAssert(self);
    NSCParameterAssert(invocation);
    // 从 invocation 可以拿到很多东西，比如 originalSelector
    SEL originalSelector = invocation.selector;
    // originalSelector 加前缀得到 aliasSelector
	SEL aliasSelector = aspect_aliasForSelector(invocation.selector);
    
    // 用 aliasSelector 替换 invocation.selector
    invocation.selector = aliasSelector;
    
    // Instance 的容器
    AspectsContainer *objectContainer = objc_getAssociatedObject(self, aliasSelector);
    // Class 的容器
    AspectsContainer *classContainer = aspect_getContainerForClass(object_getClass(self), aliasSelector);
    
    // 获取方法对象invacation 信息
    AspectInfo *info = [[AspectInfo alloc] initWithInstance:self invocation:invocation];
    NSArray *aspectsToRemove = nil;

    // 执行 类对象 前锋 钩子.
    aspect_invoke(classContainer.beforeAspects, info);
    // 执行 实例对象 前锋 钩子.
    aspect_invoke(objectContainer.beforeAspects, info);

    // 执行吧替换 钩子.
    // 默认能响应 别名方法。
    BOOL respondsToAlias = YES;
    if (objectContainer.insteadAspects.count || classContainer.insteadAspects.count) {
        // 如果有任何 insteadAspects 就直接替换了
        // 执行 类对象 前锋 钩子.
        aspect_invoke(classContainer.insteadAspects, info);
        // 执行 实例对象 前锋 钩子.
        aspect_invoke(objectContainer.insteadAspects, info);
    }else {// 否则正常执行 (即原 forwardInvocation: 的实现)
        
        // 遍历 invocation.target 及其 superClass 找到实例可以响应 aliasSelector 的点 invoke
        Class klass = object_getClass(invocation.target);
        do {
            if ((respondsToAlias = [klass instancesRespondToSelector:aliasSelector])) {
                [invocation invoke];
                //只要能响应 退出循环
                break;
            }
            //不能响应，就看超类是否能响应。 只要不能响应且超类存在，一直执行下去
        }while (!respondsToAlias && (klass = class_getSuperclass(klass)));
    }

    // 执行 类对象 后卫 钩子.
    aspect_invoke(classContainer.afterAspects, info);
    // 执行 实例对象 后卫 钩子
    aspect_invoke(objectContainer.afterAspects, info);

    // 如果没有 hook，则执行原始实现（通常会抛出异常）
    if (!respondsToAlias) {
        
        invocation.selector = originalSelector;
        SEL originalForwardInvocationSEL = NSSelectorFromString(AspectsForwardInvocationSelectorName);
        
        // 如果可以响应 originalForwardInvocationSEL，表示之前是 replace method 而非 add method
        if ([self respondsToSelector:originalForwardInvocationSEL]) {
            ((void( *)(id, SEL, NSInvocation *))objc_msgSend)(self, originalForwardInvocationSEL, invocation);
        }else {
            [self doesNotRecognizeSelector:invocation.selector];
        }
    }
    
    // 移除 aspectsToRemove 队列中的 AspectIdentifier，执行 remove
    [aspectsToRemove makeObjectsPerformSelector:@selector(remove)];
}
#undef aspect_invoke //Note: aspect_invoke 宏定义的作用域。





#pragma mark - Aspect Container Management -----------------

// 加载或创建Aspect容器，（关联对象：存放待替换方法的）。
static AspectsContainer *aspect_getContainerForObject(NSObject *self, SEL selector) {
    NSCParameterAssert(self);
    /** 获取追踪方法的别名 */
    SEL aliasSelector = aspect_aliasForSelector(selector);
    /** 添加关联对象 */
    AspectsContainer *aspectContainer = objc_getAssociatedObject(self, aliasSelector);
    if (!aspectContainer) {
        aspectContainer = [AspectsContainer new];
        objc_setAssociatedObject(self, aliasSelector, aspectContainer, OBJC_ASSOCIATION_RETAIN);
    }
    return aspectContainer;
}

static AspectsContainer *aspect_getContainerForClass(Class klass, SEL selector) {
    NSCParameterAssert(klass);
    AspectsContainer *classContainer = nil;
    do {
        classContainer = objc_getAssociatedObject(klass, selector);
        if (classContainer.hasAspects) break;
    }while ((klass = class_getSuperclass(klass)));

    return classContainer;
}

static void aspect_destroyContainerForObject(id<NSObject> self, SEL selector) {
    NSCParameterAssert(self);
    SEL aliasSelector = aspect_aliasForSelector(selector);
    objc_setAssociatedObject(self, aliasSelector, nil, OBJC_ASSOCIATION_RETAIN);
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Selector Blacklist Checking
/**
 static NSMutableDictionary *swizzledClassesDict;
 在 Aspects 中扮演着已混写类字典的角色，
 内部提供了专门访问这个全局字典的方法
 这个全局变量可以简单理解为记录整个 Hook 影响的 Class 包含其 SuperClass 的追踪记录的全局字典。
 */
static NSMutableDictionary *aspect_getSwizzledClassesDict() {
    static NSMutableDictionary *swizzledClassesDict;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        /** 内部静态全局变量 */
        swizzledClassesDict = [NSMutableDictionary new];
    });
    return swizzledClassesDict;
}
/**
 验证该方法是否允许跟踪
 
 1.若该方法别列入黑名单，拒绝。
 2.若是dealloc方法且不是钩子位置不是AspectPositionBefore，拒绝。
 3.若对象无法响应该方法，拒绝。
 4.若self是实例对象,接受。
 5.若self是类对象:
    A>.当前类、子类及超类存在追踪器时：
        a>.在子类中已经添加过钩子,拒绝。
        b>.当前类已存在方法追踪器，接受。
        c>.当前类超类已存在方法追踪器，拒绝。
    B>.当前类、子类及超类不存在追踪器时,创建追踪器后 接受
        a>.创建当前类的方法追踪器，并添加方法到追踪器
        b>.当前类超类存在，继续创建超类追踪器，并添加将该方法子类追踪器
 
 */
static BOOL aspect_isSelectorAllowedAndTrack(NSObject *self, SEL selector, AspectOptions options, NSError **error) {
    static NSSet *disallowedSelectorList;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        /** 黑名单全局变量 */
        disallowedSelectorList = [NSSet setWithObjects:@"retain", @"release", @"autorelease", @"forwardInvocation:", nil];
    });

    // 核对一下黑名单。
    NSString *selectorName = NSStringFromSelector(selector);
    if ([disallowedSelectorList containsObject:selectorName]) {
        /** 该方法被列入黑名单 */
        NSString *errorDescription = [NSString stringWithFormat:@"Selector %@ is blacklisted.", selectorName];
        AspectError(AspectErrorSelectorBlacklisted, errorDescription);
        return NO;
    }

    // 额外的检查。
    AspectOptions position = options & AspectPositionFilter;
    if ([selectorName isEqualToString:@"dealloc"] && position != AspectPositionBefore) {
        /** 钩 dealloc 方法 时 只有 AspectPositionBefore 是有效 */
        NSString *errorDesc = @"AspectPositionBefore is the only valid position when hooking dealloc.";
        AspectError(AspectErrorSelectorDeallocPosition, errorDesc);
        return NO;
    }
    /**
     实例无法响应该方法 &&
     类无法响应该方法
     */
    if (![self respondsToSelector:selector] &&
        ![self.class instancesRespondToSelector:selector]) {
        /** 是否能响应方法 */
        NSString *errorDesc = [NSString stringWithFormat:@"Unable to find selector -[%@ %@].", NSStringFromClass(self.class), selectorName];
        AspectError(AspectErrorDoesNotRespondToSelector, errorDesc);
        return NO;
    }
    // 如果要修饰类对象，请搜索当前类和类层次结构
    /**
     meta-class 是 Class 对象的类。
     每个 Class 都有个不同的自己的 meta-class（因此每个 Class 都可以有一个自己不同的方法列表）。
     也就是说每个类的 Class 不完全相同
     BOOL class_isMetaClass(Class cls);//判断给定的Class是否是一个元类
     
     当消息对象为实例对象instance时，class与object_getClass返回的对象地址一样；
     当消息对象为类对象，或元类对象时，class返回的消息对象本身，而object_getClass返回的是下一个对象；
     
     原因：因为class返回的是self，而object_getClass返回的是isa指向的对象；
     */
    if (class_isMetaClass(object_getClass(self))) {
        /** self 是类对象 */
        Class klass = [self class];
        /** 获取追踪类的全局字典 */
        NSMutableDictionary *swizzledClassesDict = aspect_getSwizzledClassesDict();
        Class currentClass = [self class];
        /** 取出类的追踪器 */        
        AspectTracker *tracker = swizzledClassesDict[currentClass];
        
        /** 判断指定方法是否已被子类追踪，若在子类已跟踪返回NO  */
        
        if ([tracker subclassHasHookedSelectorName:selectorName]) {
            /** 子类方法已被追踪，每个类的层次结构中一个方法只能连接一次。 */
            NSSet *subclassTracker = [tracker subclassTrackersHookingSelectorName:selectorName];
            NSSet *subclassNames = [subclassTracker valueForKey:@"trackedClassName"];
            NSString *errorDescription = [NSString stringWithFormat:@"Error: %@ already hooked subclasses: %@. A method can only be hooked once per class hierarchy.", selectorName, subclassNames];
            AspectError(AspectErrorSelectorAlreadyHookedInClassHierarchy, errorDescription);
            return NO;
        }
        /** 判断指定方法是否已被当前类或超类追踪，若当前类返回YES,若在父类已跟踪返回NO  */
        do {
            // 取追踪器
            tracker = swizzledClassesDict[currentClass];
            // 追踪器中是否已存在该方法
            if ([tracker.selectorNames containsObject:selectorName]) {
                if (klass == currentClass) {
                    // 已经被修饰，且是最顶层的!
                    return YES;
                }
                /** 该方法已在某个父类中被钩子，每个类的层次结构中一个方法只能连接一次。 */
                NSString *errorDescription = [NSString stringWithFormat:@"Error: %@ already hooked in %@. A method can only be hooked once per class hierarchy.", selectorName, NSStringFromClass(currentClass)];
                AspectError(AspectErrorSelectorAlreadyHookedInClassHierarchy, errorDescription);
                return NO;
            }
        } while ((currentClass = class_getSuperclass(currentClass)));

        // 正在添加一个被修改的方法。
        currentClass = klass;
        AspectTracker *subclassTracker = nil;
        do {
            //取当前类追踪器
            tracker = swizzledClassesDict[currentClass];
            if (!tracker) {
                //若当前类为添加追踪器，创建
                tracker = [[AspectTracker alloc] initWithTrackedClass:currentClass];
                //添加到类追踪器集
                swizzledClassesDict[(id<NSCopying>)currentClass] = tracker;
            }
            
            if (subclassTracker) {
                // 把子类的方法追踪器添加到父类中
                [tracker addSubclassTracker:subclassTracker hookingSelectorName:selectorName];
            } else {
                // 添加方法到追踪器
                [tracker.selectorNames addObject:selectorName];
            }
            // 所有父类都被标记为具有修改后的子类。
            subclassTracker = tracker;
        }while ((currentClass = class_getSuperclass(currentClass)));
        
	} else {
        /** self 实例对象 */
		return YES;
	}

    return YES;
}
/** 注销方法跟踪器 */
static void aspect_deregisterTrackedSelector(id self, SEL selector) {
    if (!class_isMetaClass(object_getClass(self))) return;

    NSMutableDictionary *swizzledClassesDict = aspect_getSwizzledClassesDict();
    NSString *selectorName = NSStringFromSelector(selector);
    Class currentClass = [self class];
    AspectTracker *subclassTracker = nil;
    do {
        AspectTracker *tracker = swizzledClassesDict[currentClass];
        if (subclassTracker) {
            [tracker removeSubclassTracker:subclassTracker hookingSelectorName:selectorName];
        } else {
            [tracker.selectorNames removeObject:selectorName];
        }
        if (tracker.selectorNames.count == 0 && tracker.selectorNamesToSubclassTrackers) {
            [swizzledClassesDict removeObjectForKey:currentClass];
        }
        subclassTracker = tracker;
    }while ((currentClass = class_getSuperclass(currentClass)));
}

  
@end





///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectIdentifier

@implementation AspectIdentifier
/** 根据跟踪踪方法返回Block 创建跟踪的标识 */
+ (instancetype)identifierWithSelector:(SEL)selector object:(id)object options:(AspectOptions)options block:(id)block error:(NSError **)error {
    NSCParameterAssert(block);
    NSCParameterAssert(selector);
    //通过block参数生成跟踪返回Block的签名
    NSMethodSignature *blockSignature = aspect_blockMethodSignature(block, error);
    // TODO: 检查签名兼容性等。
    if (!aspect_isCompatibleBlockSignature(blockSignature, object, selector, error)) {
        return nil;
    }
    
    AspectIdentifier *identifier = nil;
    if (blockSignature) {
        /** 创建标识 实例 */
        identifier = [AspectIdentifier new];
        identifier.selector = selector;
        identifier.block = block;
        identifier.blockSignature = blockSignature;
        identifier.options = options;
        identifier.object = object; // weak
    }
    return identifier;
}

/** 执行Aspect信息 */
- (BOOL)invokeWithInfo:(id<AspectInfo>)info {
    
    /** 由block签名生成invocation */
    NSInvocation *blockInvocation = [NSInvocation invocationWithMethodSignature:self.blockSignature];
    /** 获取跟踪方法的invocation */    
    NSInvocation *originalInvocation = info.originalInvocation;
    
    NSUInteger numberOfArguments = self.blockSignature.numberOfArguments;
    
    // 偏执。我们已经在 hook 注册的时候检查过了，（不过这里我们还要检查）。
    if (numberOfArguments > originalInvocation.methodSignature.numberOfArguments) {
        AspectLogError(@"Block has too many arguments. Not calling %@", info);
        return NO;
    }
    // block: 'v' argument: '@?' '@"<AspectInfo>"'
    //method: 'v' argument: '@'  ':'               '@'  '@'  '@'
    // block 的 `self` 将会是 AspectInfo。可选的。
    if (numberOfArguments > 1) {
        [blockInvocation setArgument:&info atIndex:1];
    }
    
    // 遍历历参数分配内存 argBuf 然后从 originalInvocation 取 argument 赋值给 blockInvocation
	void *argBuf = NULL;//参数内存指针
    for (NSUInteger idx = 2; idx < numberOfArguments; idx++) {
        // 取跟踪方法参数类型
        const char *type = [originalInvocation.methodSignature getArgumentTypeAtIndex:idx];
        
		NSUInteger argSize;//参数类型大小
        //获取编码类型的实际大小和对齐的大小(这里忽略了对齐大小)。
		NSGetSizeAndAlignment(type, &argSize, NULL);
        // reallocf 优点，如果创建内存失败会自动释放之前的内存，讲究
		if (!(argBuf = reallocf(argBuf, argSize))) {
            AspectLogError(@"Failed to allocate memory for block invocation.");
			return NO;
		}
        //取出跟踪方法的参数，放在指定中转内存中
		[originalInvocation getArgument:argBuf atIndex:idx];
        //取出指定中转内存参数，赋值给block的Invacotion对象
		[blockInvocation setArgument:argBuf atIndex:idx];
    }
    // 执行block的Invocation对象
    [blockInvocation invokeWithTarget:self.block];
    // 释放 argBuf
    if (argBuf != NULL) {
        free(argBuf);
    }
    return YES;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, SEL:%@ object:%@ options:%tu block:%@ (#%tu args)>", self.class, self, NSStringFromSelector(self.selector), self.object, self.options, self.block, self.blockSignature.numberOfArguments];
}

- (BOOL)remove {
    return aspect_remove(self, NULL);
}

@end



///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectInfo

