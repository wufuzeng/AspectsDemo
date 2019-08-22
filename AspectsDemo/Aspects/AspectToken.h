//
//  AspectToken.h
//  TEST
//
//  Created by 吴福增 on 2018/12/20.
//  Copyright © 2018 吴福增. All rights reserved.
//

/**
    AspectToken - 用于注销 Hook
 */

#ifndef AspectToken_h
#define AspectToken_h


/// 不透明的 Aspect Token，用于注销 Hook
@protocol AspectToken <NSObject>

/// 注销一个界面
/// 返回 YES 表示注销成功，否则返回 NO
- (BOOL)remove;

@end


#endif /* AspectToken_h */
