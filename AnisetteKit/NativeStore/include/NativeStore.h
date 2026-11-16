#import <Foundation/Foundation.h>

/// Apple's own Store AMD proof (AMSAnisette type 2), not AuthKit's I-MD pair.
/// Returns nil if this private framework/API is unavailable on this iOS build.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> * _Nullable
StoreAMDHeaders(NSURL * _Nonnull url);
