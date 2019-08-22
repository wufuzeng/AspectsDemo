//
//  AspectsConstant.h
//  TEST
//
//  Created by 吴福增 on 2018/12/20.
//  Copyright © 2018 吴福增. All rights reserved.
//

#ifndef AspectsConstant_h
#define AspectsConstant_h

#define AspectLog(...)
//#define AspectLog(...) do { NSLog(__VA_ARGS__); }while(0)

#define AspectLogError(...) \
do { \
    NSLog(__VA_ARGS__);\
}while(0)

#define AspectPositionFilter 0x07

#define AspectError(errorCode, errorDescription) \
do { \
    AspectLogError(@"Aspects: %@", errorDescription); \
    if (error) { \
        *error = [NSError errorWithDomain:AspectErrorDomain code:errorCode userInfo:@{NSLocalizedDescriptionKey: errorDescription}];\
    }\
}while(0)

// 宏定义，以便于我们有一个更明晰的 stack trace
// aspect_invoke 中 aspectsToRemove 是一个 NSArray，里面容纳着需要被销户的 Hook，即 AspectIdentifier（之后会调用 remove 移除）。
#define aspect_invoke(aspects, info) \
for (AspectIdentifier *aspect in aspects) {\
    [aspect invokeWithInfo:info];\
    if (aspect.options & AspectOptionAutomaticRemoval) {\
        aspectsToRemove = [aspectsToRemove?:@[] arrayByAddingObject:aspect]; \
    } \
}

extern NSString *const AspectErrorDomain;


typedef NS_ENUM(NSUInteger, AspectErrorCode) {
    AspectErrorSelectorBlacklisted,                   /// 像release, retain, autorelease这样的选择器都被列入黑名单。
    AspectErrorDoesNotRespondToSelector,              /// 找不到选择器。
    AspectErrorSelectorDeallocPosition,               /// 在挂钩dealloc时，只允许使用AspectPositionBefore。
    AspectErrorSelectorAlreadyHookedInClassHierarchy, /// 不允许在子类中静态地链接相同的方法。
    AspectErrorFailedToAllocateClassPair,             /// 运行时未能创建类对。
    AspectErrorMissingBlockSignature,                 /// Block编译时丢失签名信息，无法调用。
    AspectErrorIncompatibleBlockSignature,            /// Block签名与方法不匹配或太长。
    
    AspectErrorRemoveObjectAlreadyDeallocated = 100   /// (用于移除)已解除锁定的对象。
};


/** 可以指定 Hook 的点，以及是否执行一次之后就撤销 Hook */
typedef NS_OPTIONS(NSUInteger, AspectOptions) {
    AspectPositionAfter   = 0,            /// 在原始实现之后调用(默认)
    AspectPositionInstead = 1,            /// 将取代原来的实现。
    AspectPositionBefore  = 2,            /// 在原始实现之前调用。
    
    AspectOptionAutomaticRemoval = 1 << 3 /// 将在第一次执行之后删除钩子。
};

// Block internals.
/**
 定义了AspectBlockFlags，这是一个flag，用来标记两种情况，
 是否需要Copy和Dispose的Helpers，
 是否需要方法签名Signature 。
 */
typedef NS_OPTIONS(int, AspectBlockFlags) {
    AspectBlockFlagsHasCopyDisposeHelpers = (1 << 25),
    AspectBlockFlagsHasSignature          = (1 << 30)
};


/**
    AspectBlockRef - 即 _AspectBlock，充当内部 Block
    Note: __unused 宏定义实际上是 __attribute__((unused)) GCC 定语，旨在告诉编译器“如果我  没有在后面使用到这个变量也别警告我”。
 
    Block其实是一个对象,但这个对象究竟是啥呢？得益于runtime的开源，我们可以知道其实他是一个结构体.
    而Aspects文件也定义了一个叫AspectBlockRef的结构体，这个结构体是Block的结构体形式相同，可以用来解析block的内部数据。
 */
typedef struct _AspectBlock {
    __unused Class   isa;      //
    AspectBlockFlags flags;    //int
    __unused int     reserved; //int
    /** 函数指针 */
    void (__unused *invoke)(struct _AspectBlock *block, ...);
    struct {
        unsigned long int reserved;
        unsigned long int size;
        // 要求flags是AspectBlockFlagsHasCopyDisposeHelpers
        void (*copy)(void *dst, const void *src);
        void (*dispose)(const void *);
        // 要求flags是 AspectBlockFlagsHasSignature
        const char *signature;
        const char *layout;
    } *descriptor; //Block描述
    // 导入 变量
} *AspectBlockRef;


/**
    block会在编译过程中，会被当做结构体进行处理。
 
    struct Block_literal_1 {
        void *isa; // initialized to &_NSConcreteStackBlock or &_NSConcreteGlobalBlock
        int flags;
        int reserved;
        void (*invoke)(void *, ...);
        struct Block_descriptor_1 {
            unsigned long int reserved;         // NULL
            unsigned long int size;         // sizeof(struct Block_literal_1)
            // optional helper functions
            void (*copy_helper)(void *dst, void *src);     // IFF (1<<25)
            void (*dispose_helper)(void *src);             // IFF (1<<25)
            // required ABI.2010.3.16
            const char *signature;                         // IFF (1<<30)
        } *descriptor;
        // imported variables
    };```

    isa 指针会指向 block 所属的类型，用于帮助运行时系统进行处理。
    Block 常见的类型有三种，分别是
        ` _NSConcreteStackBlock `
        ` _NSConcreteMallocBlock`
        `_NSConcreteGlobalBlock` 。
    另外还包括只在GC环境下使用的
        `_NSConcreteFinalizingBlock`
        `_NSConcreteAutoBlock`
        `_NSConcreteWeakBlockVariable`。
*/


#endif /* AspectsConstant_h */
