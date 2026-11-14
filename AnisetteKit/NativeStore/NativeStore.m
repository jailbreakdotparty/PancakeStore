#import "NativeStore.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <stdio.h>

NSDictionary<NSString *, NSString *> *StoreAMDHeaders(NSURL *url) {
    static void *framework;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/AppleMediaServices.framework/AppleMediaServices", RTLD_NOW | RTLD_LOCAL);
    });
    if (!framework) {
        printf("[StoreAMD] AppleMediaServices unavailable\n");
        return nil;
    }
    Class cls = objc_getClass("AMSAnisette");
    SEL selector = sel_registerName("_headersForRequest:account:type:");
    Method method = cls ? class_getClassMethod(cls, selector) : NULL;
    if (!method) {
        printf("[StoreAMD] AMSAnisette type-2 API unavailable\n");
        return nil;
    }
    char argumentType[32] = {0};
    method_getArgumentType(method, 4, argumentType, sizeof(argumentType));
    printf("[StoreAMD] type argument encoding: %s\n", argumentType);
    if (argumentType[0] != 'q' && argumentType[0] != 'Q' && argumentType[0] != 'i' && argumentType[0] != 'I') {
        printf("[StoreAMD] unexpected type argument ABI; refusing call\n");
        return nil;
    }
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    // Type 2 is Store AMD. Type 0/1 is AuthKit anisette, not interchangeable.
    id (*message)(id, SEL, NSURLRequest *, id, long long) = (void *)objc_msgSend;
    id result = message(cls, selector, request, nil, 2);
    if (![result isKindOfClass:[NSDictionary class]]) {
        printf("[StoreAMD] Type-2 API returned no header dictionary\n");
        return nil;
    }
    NSString *amd = result[@"X-Apple-AMD"];
    NSString *machine = result[@"X-Apple-AMD-M"];
    if (![amd isKindOfClass:[NSString class]] || ![machine isKindOfClass:[NSString class]] ||
        amd.length == 0 || machine.length == 0) {
        printf("[StoreAMD] Type-2 API returned incomplete proof\n");
        return nil;
    }
    return @{@"X-Apple-AMD": amd, @"X-Apple-AMD-M": machine};
}
