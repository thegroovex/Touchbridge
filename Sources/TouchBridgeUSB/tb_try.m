#import "tb_try.h"
NSString * _Nullable tb_try(void (NS_NOESCAPE ^block)(void)) {
    @try { block(); return nil; }
    @catch (NSException *e) {
        NSString *s = [NSString stringWithFormat:@"%@: %@\n%@", e.name, e.reason ?: @"", [[e.callStackSymbols subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)12, e.callStackSymbols.count))] componentsJoinedByString:@"\n"]];
        NSLog(@"TouchBridge exception: %@", s);
        return s;
    }
}

NSString *tb_describe_getter(id obj, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:sel]) return @"not available";
    @try {
        NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments != 2) return @"not a getter";
        const char *t = sig.methodReturnType;
        NSUInteger len = sig.methodReturnLength;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.selector = sel; inv.target = obj;
        [inv invoke];
        NSString *enc = [NSString stringWithUTF8String:t];
        if (len == 0) return [enc stringByAppendingString:@" (void)"];
        if (t[0] == '@') {
            __unsafe_unretained id v = nil; [inv getReturnValue:&v];
            return [NSString stringWithFormat:@"%@ = %@", enc, v ? [[v description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] : @"nil"];
        }
        NSMutableData *buf = [NSMutableData dataWithLength:len];
        [inv getReturnValue:buf.mutableBytes];
        const unsigned char *b = buf.bytes;
        long long n = 0;
        switch (t[0]) {
            case 'c': n = *(signed char *)b; break; case 'C': case 'B': n = *(unsigned char *)b; break;
            case 's': n = *(short *)b; break; case 'S': n = *(unsigned short *)b; break;
            case 'i': n = *(int *)b; break; case 'I': n = *(unsigned int *)b; break;
            case 'l': case 'q': n = *(long long *)b; break;
            case 'L': case 'Q': return [NSString stringWithFormat:@"%@ = %llu (0x%llx)", enc, *(unsigned long long *)b, *(unsigned long long *)b];
            case 'd': return [NSString stringWithFormat:@"%@ = %g", enc, *(double *)b];
            case 'f': return [NSString stringWithFormat:@"%@ = %g", enc, *(float *)b];
            default: {
                NSMutableString *hex = [NSMutableString string];
                for (NSUInteger i = 0; i < len; i++) [hex appendFormat:@"%02x", b[i]];
                return [NSString stringWithFormat:@"%@ = 0x%@", enc, hex];
            }
        }
        return [NSString stringWithFormat:@"%@ = %lld", enc, n];
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"exception %@: %@", e.name, e.reason ?: @""];
    }
}
