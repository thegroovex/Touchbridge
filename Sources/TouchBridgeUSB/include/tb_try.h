#ifndef TB_TRY_H
#define TB_TRY_H
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Runs block; returns nil on success or "Name: reason" if an Objective-C exception was raised.
NSString * _Nullable tb_try(void (NS_NOESCAPE ^block)(void));
NS_ASSUME_NONNULL_END
#endif
#ifndef TB_DESCRIBE_H
#define TB_DESCRIBE_H
#import <Foundation/Foundation.h>
/// Calls a zero-argument getter safely (NSInvocation inside @try) and describes the result:
/// "<type encoding> = <value>" (objects via description, numbers as numbers, structs as hex bytes).
NSString * _Nonnull tb_describe_getter(id _Nonnull obj, NSString * _Nonnull selectorName);
#endif
