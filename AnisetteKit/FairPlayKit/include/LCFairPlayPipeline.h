//
//  LCFairPlayPipeline.h
//  LiveContainerSwiftUI
//
//  FairPlay staging/decryption pipeline derived from FairPlayed.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const LCFairPlayErrorDomain;
FOUNDATION_EXPORT NSString *const LCFairPlayDiagnosticsKey;
FOUNDATION_EXPORT NSString *const LCFairPlayAttemptedRootsKey;

typedef NS_ERROR_ENUM(LCFairPlayErrorDomain, LCFairPlayErrorCode) {
    LCFairPlayErrorUnsupportedPlatform = 1,
    LCFairPlayErrorInvalidIPA,
    LCFairPlayErrorExtraction,
    LCFairPlayErrorManifest,
    LCFairPlayErrorStaging,
    LCFairPlayErrorDecryption,
    LCFairPlayErrorVerification,
    LCFairPlayErrorArchive,
};

typedef void (^LCFairPlayProgressHandler)(NSString *phase, NSUInteger completed, NSUInteger total);

@interface LCFairPlayPipeline : NSObject

/// Decrypts an App Store IPA into a new IPA. Each staging root is tried with a
/// fresh extraction because fairplayd path visibility differs by container.
/// mainSinf and metadataPlist come from ipatool-ios' download response.
/// This method is synchronous and must be called off the main thread.
+ (nullable NSURL *)decryptIPAAtURL:(NSURL *)ipaURL
                      stagingRoots:(NSArray<NSURL *> *)stagingRoots
                         outputURL:(NSURL *)outputURL
                          mainSinf:(nullable NSData *)mainSinf
                     metadataPlist:(nullable NSData *)metadataPlist
                          progress:(nullable LCFairPlayProgressHandler)progress
                             error:(NSError **)error
    NS_SWIFT_NAME(decryptIPA(at:stagingRoots:outputURL:mainSinf:metadataPlist:progress:));

/// Convenience overload for IPAs that already contain their FairPlay SINF.
+ (nullable NSURL *)decryptIPAAtURL:(NSURL *)ipaURL
                      stagingRoots:(NSArray<NSURL *> *)stagingRoots
                         outputURL:(NSURL *)outputURL
                          progress:(nullable LCFairPlayProgressHandler)progress
                             error:(NSError **)error;

/// Decrypts an already-installed App Store bundle directly from its system
/// container. The caller must keep any sandbox extension granting access to
/// appURL alive until this synchronous method returns.
+ (nullable NSURL *)decryptInstalledAppAtURL:(NSURL *)appURL
                                  outputURL:(NSURL *)outputURL
                                   progress:(nullable LCFairPlayProgressHandler)progress
                                      error:(NSError **)error
    NS_SWIFT_NAME(decryptInstalledApp(at:outputURL:progress:));

@end

NS_ASSUME_NONNULL_END
