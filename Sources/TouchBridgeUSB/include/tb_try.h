#ifndef TB_TRY_H
#define TB_TRY_H
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Runs block; returns nil on success or "Name: reason" if an Objective-C exception was raised.
NSString * _Nullable tb_try(void (NS_NOESCAPE ^block)(void));
NS_ASSUME_NONNULL_END
#endif
