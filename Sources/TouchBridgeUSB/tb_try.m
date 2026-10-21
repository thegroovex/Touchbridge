#import "tb_try.h"
NSString * _Nullable tb_try(void (NS_NOESCAPE ^block)(void)) {
    @try { block(); return nil; }
    @catch (NSException *e) {
        NSString *s = [NSString stringWithFormat:@"%@: %@\n%@", e.name, e.reason ?: @"", [[e.callStackSymbols subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)12, e.callStackSymbols.count))] componentsJoinedByString:@"\n"]];
        NSLog(@"TouchBridge exception: %@", s);
        return s;
    }
}
