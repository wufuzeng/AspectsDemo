//
//  ViewController.m
//  AspectsDemo
//
//  Created by 吴福增 on 2019/8/21.
//  Copyright © 2019 吴福增. All rights reserved.
//

#import "ViewController.h"
#import "Aspects.h"
@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self aspect_hookSelector:@selector(testWithParam1:param2:param3:) withOptions:AspectPositionInstead usingBlock:^(id<AspectInfo> info ,id param1,id param2,id param3){
        
                NSLog(@"%@",info.description);
        
                //调用的实例对象
                __unused id instance = info.instance;
        
                //原始的方法
                id invocation = info.originalInvocation;
        
                /**
                 return value: {v} void
                 target: {@} 0x7ffd9e4133a0
                 selector: {:} aspects__testWithParam1:param2:param3:
                 argument 2: {@} 0x1015477b0
                 argument 3: {@} 0x1015477d0
                 argument 4: {@} 0x1015477f0
                 */
        
                //参数
                __unused id arguments = info.arguments;
        
                //原始的方法，再次调用
                [invocation invoke]; 
            } error:nil];
}


@end
