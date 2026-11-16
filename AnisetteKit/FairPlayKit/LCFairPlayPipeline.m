//
//  LCFairPlayPipeline.m
//  LiveContainerSwiftUI
//
//  Integrates FairPlayed's fpcore/zipio without its standalone application UI.
//

#import "LCFairPlayPipeline.h"
#import "fpcore.h"
#import "zipio.h"

#import <TargetConditionals.h>

NSErrorDomain const LCFairPlayErrorDomain = @"com.kdt.livecontainer.fairplay";
NSString *const LCFairPlayDiagnosticsKey = @"LCFairPlayDiagnostics";
NSString *const LCFairPlayAttemptedRootsKey = @"LCFairPlayAttemptedRoots";

static NSError *LCFairPlayMakeError(LCFairPlayErrorCode code,
                                    NSString *description,
                                    NSArray<NSString *> *diagnostics,
                                    NSArray<NSString *> *roots,
                                    NSError *underlyingError) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:description
                                                                        forKey:NSLocalizedDescriptionKey];
    if (diagnostics.count) {
        userInfo[LCFairPlayDiagnosticsKey] = diagnostics;
    }
    if (roots.count) {
        userInfo[LCFairPlayAttemptedRootsKey] = roots;
    }
    if (underlyingError) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:LCFairPlayErrorDomain code:code userInfo:userInfo];
}

static void LCFairPlayCoreLog(void *context, const char *message) {
    if (!context || !message) {
        return;
    }
    NSMutableArray<NSString *> *diagnostics = (__bridge NSMutableArray<NSString *> *)context;
    NSString *line = [NSString stringWithUTF8String:message];
    if (line) {
        [diagnostics addObject:line];
    }
}

static BOOL LCFairPlayIsSafeRelativePath(NSString *path) {
    if (!path.length || path.isAbsolutePath) {
        return NO;
    }
    for (NSString *component in path.pathComponents) {
        if ([component isEqualToString:@".."] || [component isEqualToString:@"/"]) {
            return NO;
        }
    }
    return YES;
}

static BOOL LCFairPlayURLIsBelowRoot(NSURL *url, NSURL *root) {
    NSString *rootPath = root.URLByStandardizingPath.path;
    NSString *candidatePath = url.URLByStandardizingPath.path;
    if ([candidatePath isEqualToString:rootPath]) {
        return YES;
    }
    NSString *prefix = [rootPath stringByAppendingString:@"/"];
    return [candidatePath hasPrefix:prefix];
}

static BOOL LCFairPlayInstallMainSinf(NSData *mainSinf,
                                      NSURL *appURL,
                                      NSMutableArray<NSString *> *diagnostics,
                                      NSError **error) {
    if (!mainSinf.length) {
        return YES;
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSURL *manifestURL = [appURL URLByAppendingPathComponent:@"SC_Info/Manifest.plist"];
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfURL:manifestURL];
    NSArray *sinfPaths = [manifest[@"SinfPaths"] isKindOfClass:NSArray.class] ? manifest[@"SinfPaths"] : @[];
    NSString *targetPath = [sinfPaths.firstObject isKindOfClass:NSString.class] ? sinfPaths.firstObject : nil;

    if (!targetPath.length) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[appURL URLByAppendingPathComponent:@"Info.plist"]];
        NSString *executable = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class] ? info[@"CFBundleExecutable"] : nil;
        if (executable.length) {
            targetPath = [NSString stringWithFormat:@"SC_Info/%@.sinf", executable];
        }
    }

    if (!LCFairPlayIsSafeRelativePath(targetPath)) {
        if (error) {
            *error = LCFairPlayMakeError(LCFairPlayErrorManifest,
                                         @"The IPA does not declare a safe destination for its FairPlay SINF.",
                                         diagnostics, @[], nil);
        }
        return NO;
    }

    NSURL *targetURL = [appURL URLByAppendingPathComponent:targetPath];
    if (!LCFairPlayURLIsBelowRoot(targetURL, appURL)) {
        if (error) {
            *error = LCFairPlayMakeError(LCFairPlayErrorManifest,
                                         @"The main FairPlay SINF path escapes the app bundle.",
                                         diagnostics, @[], nil);
        }
        return NO;
    }

    NSError *fileError = nil;
    if (![fileManager createDirectoryAtURL:targetURL.URLByDeletingLastPathComponent
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:&fileError] ||
        ![mainSinf writeToURL:targetURL options:NSDataWritingAtomic error:&fileError]) {
        if (error) {
            *error = LCFairPlayMakeError(LCFairPlayErrorManifest,
                                         @"Could not write the FairPlay SINF returned by ipatool-ios.",
                                         diagnostics, @[], fileError);
        }
        return NO;
    }

    [diagnostics addObject:[NSString stringWithFormat:@"Installed the ipatool-ios SINF at %@.", targetPath]];
    return YES;
}

static BOOL LCFairPlayReplicateSinf(NSURL *appURL,
                                    NSMutableArray<NSString *> *diagnostics,
                                    NSError **error) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSURL *manifestURL = [appURL URLByAppendingPathComponent:@"SC_Info/Manifest.plist"];
    if (![fileManager fileExistsAtPath:manifestURL.path]) {
        [diagnostics addObject:@"No SC_Info/Manifest.plist; no nested SINF replication requested."];
        return YES;
    }

    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfURL:manifestURL];
    if (![manifest isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = LCFairPlayMakeError(LCFairPlayErrorManifest,
                                         @"The IPA contains an unreadable SC_Info manifest.",
                                         diagnostics, @[], nil);
        }
        return NO;
    }

    NSArray *sinfPaths = [manifest[@"SinfPaths"] isKindOfClass:NSArray.class] ? manifest[@"SinfPaths"] : @[];
    NSArray *replicationPaths = [manifest[@"SinfReplicationPaths"] isKindOfClass:NSArray.class] ? manifest[@"SinfReplicationPaths"] : @[];
    if (!replicationPaths.count) {
        return YES;
    }

    NSString *mainSinfPath = [sinfPaths.firstObject isKindOfClass:NSString.class] ? sinfPaths.firstObject : nil;
    if (!LCFairPlayIsSafeRelativePath(mainSinfPath)) {
        if (error) {
            *error = LCFairPlayMakeError(LCFairPlayErrorManifest,
                                         @"The IPA declares nested SINF paths without a safe main SINF path.",
                                         diagnostics, @[], nil);
        }
        return NO;
    }

    NSURL *mainSinfURL = [appURL URLByAppendingPathComponent:mainSinfPath];
    if (![fileManager isReadableFileAtPath:mainSinfURL.path]) {
        if (error) {
            *error = LCFairPlayMakeError(LCFairPlayErrorManifest,
                                         @"The main FairPlay SINF is missing or unreadable.",
                                         diagnostics, @[], nil);
        }
        return NO;
    }

    NSUInteger replicated = 0;
    for (id value in replicationPaths) {
        if (![value isKindOfClass:NSString.class]) {
            continue;
        }
        NSString *relativePath = value;
        if ([relativePath hasPrefix:@"Watch/"]) {
            continue;
        }
        if (!LCFairPlayIsSafeRelativePath(relativePath)) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorManifest,
                                             [NSString stringWithFormat:@"Unsafe SINF replication path: %@", relativePath],
                                             diagnostics, @[], nil);
            }
            return NO;
        }

        NSURL *destinationURL = [appURL URLByAppendingPathComponent:relativePath];
        if (!LCFairPlayURLIsBelowRoot(destinationURL, appURL)) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorManifest,
                                             [NSString stringWithFormat:@"SINF path escapes the app bundle: %@", relativePath],
                                             diagnostics, @[], nil);
            }
            return NO;
        }
        if ([fileManager fileExistsAtPath:destinationURL.path]) {
            continue;
        }

        NSError *fileError = nil;
        if (![fileManager createDirectoryAtURL:destinationURL.URLByDeletingLastPathComponent
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:&fileError] ||
            ![fileManager copyItemAtURL:mainSinfURL toURL:destinationURL error:&fileError]) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorManifest,
                                             [NSString stringWithFormat:@"Could not replicate SINF to %@.", relativePath],
                                             diagnostics, @[], fileError);
            }
            return NO;
        }
        replicated += 1;
    }

    [diagnostics addObject:[NSString stringWithFormat:@"Replicated the main SINF to %lu nested location(s).",
                            (unsigned long)replicated]];
    return YES;
}

static BOOL LCFairPlayCopyTreeWithoutSCInfo(NSURL *sourceURL, NSURL *destinationURL, NSError **error) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (![fileManager createDirectoryAtURL:destinationURL
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:error]) {
        return NO;
    }

    __block NSError *enumerationFailure = nil;
    NSDirectoryEnumerator<NSURL *> *enumerator = [fileManager enumeratorAtURL:sourceURL
                                                   includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey]
                                                                      options:0
                                                                 errorHandler:^BOOL(NSURL *url, NSError *enumerationError) {
        (void)url;
        enumerationFailure = enumerationError;
        return NO;
    }];

    for (NSURL *sourceItemURL in enumerator) {
        NSString *relativePath = [sourceItemURL.path substringFromIndex:sourceURL.path.length];
        if ([relativePath hasPrefix:@"/"]) {
            relativePath = [relativePath substringFromIndex:1];
        }
        if ([sourceItemURL.lastPathComponent isEqualToString:@"SC_Info"]) {
            [enumerator skipDescendants];
            continue;
        }

        NSURL *destinationItemURL = [destinationURL URLByAppendingPathComponent:relativePath];
        NSNumber *isDirectory = nil;
        NSNumber *isSymbolicLink = nil;
        NSError *resourceError = nil;
        if (![sourceItemURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:&resourceError] ||
            ![sourceItemURL getResourceValue:&isSymbolicLink forKey:NSURLIsSymbolicLinkKey error:&resourceError]) {
            if (error) {
                *error = resourceError;
            }
            return NO;
        }

        if (isDirectory.boolValue) {
            if (![fileManager createDirectoryAtURL:destinationItemURL
                       withIntermediateDirectories:YES
                                        attributes:nil
                                             error:error]) {
                return NO;
            }
        } else if (isSymbolicLink.boolValue) {
            NSString *target = [fileManager destinationOfSymbolicLinkAtPath:sourceItemURL.path error:error];
            if (!target || ![fileManager createSymbolicLinkAtPath:destinationItemURL.path
                                               withDestinationPath:target
                                                             error:error]) {
                return NO;
            }
        } else {
            if (![fileManager copyItemAtURL:sourceItemURL toURL:destinationItemURL error:error]) {
                return NO;
            }
        }
    }
    if (enumerationFailure) {
        if (error) {
            *error = enumerationFailure;
        }
        return NO;
    }
    return YES;
}

static NSArray<NSString *> *LCFairPlayMachORelativePaths(NSURL *appURL) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSDirectoryEnumerator<NSString *> *enumerator = [fileManager enumeratorAtPath:appURL.path];
    for (NSString *relativePath in enumerator) {
        NSString *path = [appURL.path stringByAppendingPathComponent:relativePath];
        NSDictionary<NSFileAttributeKey, id> *attributes = [fileManager attributesOfItemAtPath:path error:nil];
        if (![attributes.fileType isEqualToString:NSFileTypeRegular]) {
            continue;
        }
        if (fp_is_macho(path.fileSystemRepresentation)) {
            [paths addObject:relativePath];
        }
    }
    return paths;
}

static NSURL *LCFairPlayFindOnlyApp(NSURL *payloadURL, NSError **error) {
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:payloadURL
                                                            includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                 error:error];
    NSMutableArray<NSURL *> *apps = [NSMutableArray array];
    for (NSURL *url in contents) {
        NSNumber *isDirectory = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        if (isDirectory.boolValue && [url.pathExtension.lowercaseString isEqualToString:@"app"]) {
            [apps addObject:url];
        }
    }
    if (apps.count != 1) {
        if (error) {
            *error = LCFairPlayMakeError(LCFairPlayErrorInvalidIPA,
                                         @"The IPA must contain exactly one Payload/*.app bundle.",
                                         @[], @[], nil);
        }
        return nil;
    }
    return apps.firstObject;
}

static BOOL LCFairPlayVerifyDecryptedMachOs(NSURL *appURL,
                                            NSMutableArray<NSString *> *diagnostics,
                                            NSError **error) {
    for (NSString *relativePath in LCFairPlayMachORelativePaths(appURL)) {
        NSString *path = [appURL.path stringByAppendingPathComponent:relativePath];
        fp_slice_t slices[FP_MAX_SLICES];
        int count = 0;
        char parseError[256] = {0};
        if (fp_parse(path.fileSystemRepresentation, slices, FP_MAX_SLICES, &count,
                     parseError, sizeof(parseError)) != 0) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorVerification,
                                             [NSString stringWithFormat:@"Could not verify %@: %s", relativePath, parseError],
                                             diagnostics, @[], nil);
            }
            return NO;
        }
        for (int index = 0; index < count; index++) {
            if (slices[index].has_enc && slices[index].cryptid != 0) {
                if (error) {
                    *error = LCFairPlayMakeError(LCFairPlayErrorVerification,
                                                 [NSString stringWithFormat:@"%@ still contains an encrypted slice.", relativePath],
                                                 diagnostics, @[], nil);
                }
                return NO;
            }
        }
    }
    return YES;
}

static NSURL *LCFairPlayRunAttempt(NSURL *ipaURL,
                                   NSURL *stagingRoot,
                                   NSURL *outputURL,
                                   NSData *mainSinf,
                                   NSData *metadataPlist,
                                   LCFairPlayProgressHandler progress,
                                   NSMutableArray<NSString *> *diagnostics,
                                   NSError **error) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *operationID = NSUUID.UUID.UUIDString;
    NSURL *stagingDirectory = [[stagingRoot URLByAppendingPathComponent:@"AppStoreDecrypt" isDirectory:YES]
                               URLByAppendingPathComponent:operationID isDirectory:YES];
    NSURL *sourceRoot = [stagingDirectory URLByAppendingPathComponent:@"Source" isDirectory:YES];
    NSURL *resultRoot = [[fileManager.temporaryDirectory URLByAppendingPathComponent:@"LiveContainer-AppStore" isDirectory:YES]
                         URLByAppendingPathComponent:operationID isDirectory:YES];
    NSURL *payloadURL = [sourceRoot URLByAppendingPathComponent:@"Payload" isDirectory:YES];
    NSURL *resultPayloadURL = [resultRoot URLByAppendingPathComponent:@"Payload" isDirectory:YES];
    NSURL *temporaryIPAURL = [outputURL.URLByDeletingLastPathComponent
                              URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.tmp.ipa", operationID]];

    [fileManager removeItemAtURL:stagingDirectory error:nil];
    [fileManager removeItemAtURL:resultRoot error:nil];
    [fileManager removeItemAtURL:temporaryIPAURL error:nil];

    @try {
        NSError *fileError = nil;
        if (![fileManager createDirectoryAtURL:sourceRoot withIntermediateDirectories:YES attributes:nil error:&fileError] ||
            ![fileManager createDirectoryAtURL:resultPayloadURL withIntermediateDirectories:YES attributes:nil error:&fileError] ||
            ![fileManager createDirectoryAtURL:outputURL.URLByDeletingLastPathComponent
                   withIntermediateDirectories:YES attributes:nil error:&fileError]) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorStaging,
                                             @"Could not create FairPlay work directories.",
                                             diagnostics, @[stagingRoot.path], fileError);
            }
            return nil;
        }

        if (progress) {
            progress(@"extracting", 0, 1);
        }
        char zipError[512] = {0};
        if (zip_extract_all(ipaURL.path.fileSystemRepresentation,
                            sourceRoot.path.fileSystemRepresentation,
                            zipError, sizeof(zipError)) != 0) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorExtraction,
                                             [NSString stringWithFormat:@"Could not extract the IPA: %s", zipError],
                                             diagnostics, @[stagingRoot.path], nil);
            }
            return nil;
        }

        NSURL *sourceAppURL = LCFairPlayFindOnlyApp(payloadURL, &fileError);
        if (!sourceAppURL) {
            if (error) {
                *error = fileError;
            }
            return nil;
        }

        [fileManager removeItemAtURL:[sourceAppURL URLByAppendingPathComponent:@"Watch" isDirectory:YES] error:nil];
        if (!LCFairPlayInstallMainSinf(mainSinf, sourceAppURL, diagnostics, &fileError)) {
            if (error) {
                *error = fileError;
            }
            return nil;
        }
        if (!LCFairPlayReplicateSinf(sourceAppURL, diagnostics, &fileError)) {
            if (error) {
                *error = fileError;
            }
            return nil;
        }

        NSURL *resultAppURL = [resultPayloadURL URLByAppendingPathComponent:sourceAppURL.lastPathComponent isDirectory:YES];
        if (!LCFairPlayCopyTreeWithoutSCInfo(sourceAppURL, resultAppURL, &fileError)) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorStaging,
                                             @"Could not create the decrypted app copy.",
                                             diagnostics, @[stagingRoot.path], fileError);
            }
            return nil;
        }
        if (metadataPlist.length &&
            ![metadataPlist writeToURL:[resultRoot URLByAppendingPathComponent:@"iTunesMetadata.plist"]
                               options:NSDataWritingAtomic
                                 error:&fileError]) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorStaging,
                                             @"Could not write iTunesMetadata.plist.",
                                             diagnostics, @[stagingRoot.path], fileError);
            }
            return nil;
        }

        NSArray<NSString *> *machOs = LCFairPlayMachORelativePaths(sourceAppURL);
        if (!machOs.count) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorInvalidIPA,
                                             @"No Mach-O binaries were found in the app bundle.",
                                             diagnostics, @[stagingRoot.path], nil);
            }
            return nil;
        }

        NSUInteger completed = 0;
        for (NSString *relativePath in machOs) @autoreleasepool {
            if (progress) {
                progress(@"decrypting", completed, machOs.count);
            }
            NSString *sourcePath = [sourceAppURL.path stringByAppendingPathComponent:relativePath];
            NSString *resultPath = [resultAppURL.path stringByAppendingPathComponent:relativePath];
            [diagnostics addObject:[NSString stringWithFormat:@"Decrypting %@ from %@", relativePath, stagingRoot.path]];
            int result = fp_decrypt_file(sourcePath.fileSystemRepresentation,
                                         resultPath.fileSystemRepresentation,
                                         LCFairPlayCoreLog,
                                         (__bridge void *)diagnostics);
            if (result < 0) {
                if (error) {
                    *error = LCFairPlayMakeError(LCFairPlayErrorDecryption,
                                                 [NSString stringWithFormat:@"FairPlay decryption failed for %@.", relativePath],
                                                 diagnostics, @[stagingRoot.path], nil);
                }
                return nil;
            }
            completed += 1;
        }

        if (progress) {
            progress(@"verifying", completed, machOs.count);
        }
        if (!LCFairPlayVerifyDecryptedMachOs(resultAppURL, diagnostics, &fileError)) {
            if (error) {
                *error = fileError;
            }
            return nil;
        }

        if (progress) {
            progress(@"archiving", 0, 1);
        }
        memset(zipError, 0, sizeof(zipError));
        if (zip_create_from_dir(resultRoot.path.fileSystemRepresentation,
                                temporaryIPAURL.path.fileSystemRepresentation,
                                zipError, sizeof(zipError)) != 0) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorArchive,
                                             [NSString stringWithFormat:@"Could not create the decrypted IPA: %s", zipError],
                                             diagnostics, @[stagingRoot.path], nil);
            }
            return nil;
        }

        [fileManager removeItemAtURL:outputURL error:nil];
        if (![fileManager moveItemAtURL:temporaryIPAURL toURL:outputURL error:&fileError]) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorArchive,
                                             @"Could not publish the decrypted IPA.",
                                             diagnostics, @[stagingRoot.path], fileError);
            }
            return nil;
        }

        if (progress) {
            progress(@"finished", 1, 1);
        }
        return outputURL;
    } @finally {
        [fileManager removeItemAtURL:temporaryIPAURL error:nil];
        [fileManager removeItemAtURL:stagingDirectory error:nil];
        [fileManager removeItemAtURL:resultRoot error:nil];
    }
}

@implementation LCFairPlayPipeline

+ (NSURL *)decryptIPAAtURL:(NSURL *)ipaURL
              stagingRoots:(NSArray<NSURL *> *)stagingRoots
                 outputURL:(NSURL *)outputURL
                  mainSinf:(NSData *)mainSinf
             metadataPlist:(NSData *)metadataPlist
                  progress:(LCFairPlayProgressHandler)progress
                     error:(NSError **)error {
#if TARGET_OS_SIMULATOR
    if (error) {
        *error = LCFairPlayMakeError(LCFairPlayErrorUnsupportedPlatform,
                                     @"FairPlay decryption requires a physical arm64 iOS device.",
                                     @[], @[], nil);
    }
    return nil;
#else
    if (!ipaURL.isFileURL || !outputURL.isFileURL || !stagingRoots.count) {
        if (error) {
            *error = LCFairPlayMakeError(LCFairPlayErrorInvalidIPA,
                                         @"The FairPlay pipeline requires local IPA, output, and staging URLs.",
                                         @[], @[], nil);
        }
        return nil;
    }

    NSMutableArray<NSString *> *diagnostics = [NSMutableArray array];
    NSMutableArray<NSString *> *attemptedRoots = [NSMutableArray array];
    NSMutableSet<NSString *> *seenRoots = [NSMutableSet set];
    NSError *lastError = nil;

    for (NSURL *rootURL in stagingRoots) {
        if (!rootURL.isFileURL) {
            continue;
        }
        NSString *rootPath = rootURL.URLByStandardizingPath.path;
        if ([seenRoots containsObject:rootPath]) {
            continue;
        }
        [seenRoots addObject:rootPath];
        [attemptedRoots addObject:rootPath];
        [diagnostics addObject:[NSString stringWithFormat:@"Trying FairPlay staging root: %@", rootPath]];

        NSURL *result = LCFairPlayRunAttempt(ipaURL, rootURL, outputURL, mainSinf, metadataPlist,
                                              progress, diagnostics, &lastError);
        if (result) {
            return result;
        }
        if (lastError.localizedDescription.length) {
            [diagnostics addObject:[NSString stringWithFormat:@"Attempt failed: %@", lastError.localizedDescription]];
        }
    }

    if (error) {
        NSString *description = lastError.localizedDescription ?: @"FairPlay decryption failed at every staging location.";
        *error = LCFairPlayMakeError(lastError ? (LCFairPlayErrorCode)lastError.code : LCFairPlayErrorDecryption,
                                     description, diagnostics, attemptedRoots, lastError);
    }
    return nil;
#endif
}

+ (NSURL *)decryptIPAAtURL:(NSURL *)ipaURL
              stagingRoots:(NSArray<NSURL *> *)stagingRoots
                 outputURL:(NSURL *)outputURL
                  progress:(LCFairPlayProgressHandler)progress
                     error:(NSError **)error {
    return [self decryptIPAAtURL:ipaURL
                    stagingRoots:stagingRoots
                       outputURL:outputURL
                        mainSinf:nil
                   metadataPlist:nil
                        progress:progress
                           error:error];
}

+ (NSURL *)decryptInstalledAppAtURL:(NSURL *)appURL
                         outputURL:(NSURL *)outputURL
                          progress:(LCFairPlayProgressHandler)progress
                             error:(NSError **)error {
#if TARGET_OS_SIMULATOR
    if (error) {
        *error = LCFairPlayMakeError(LCFairPlayErrorUnsupportedPlatform,
                                     @"FairPlay decryption requires a physical arm64 iOS device.",
                                     @[], @[], nil);
    }
    return nil;
#else
    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (!appURL.isFileURL || !outputURL.isFileURL ||
        ![appURL.pathExtension.lowercaseString isEqualToString:@"app"] ||
        ![fileManager isReadableFileAtPath:[appURL URLByAppendingPathComponent:@"Info.plist"].path]) {
        if (error) {
            *error = LCFairPlayMakeError(LCFairPlayErrorInvalidIPA,
                                         @"The installed app bundle is missing or unreadable.",
                                         @[], @[appURL.path ?: @""], nil);
        }
        return nil;
    }

    NSMutableArray<NSString *> *diagnostics = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"Decrypting directly from installed bundle: %@", appURL.path]];
    NSString *operationID = NSUUID.UUID.UUIDString;
    NSURL *resultRoot = [[fileManager.temporaryDirectory
                          URLByAppendingPathComponent:@"LiveContainer-InstalledApp" isDirectory:YES]
                         URLByAppendingPathComponent:operationID isDirectory:YES];
    NSURL *resultPayloadURL = [resultRoot URLByAppendingPathComponent:@"Payload" isDirectory:YES];
    NSURL *resultAppURL = [resultPayloadURL URLByAppendingPathComponent:appURL.lastPathComponent isDirectory:YES];
    NSURL *temporaryIPAURL = [outputURL.URLByDeletingLastPathComponent
                              URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.tmp.ipa", operationID]];

    [fileManager removeItemAtURL:resultRoot error:nil];
    [fileManager removeItemAtURL:temporaryIPAURL error:nil];

    @try {
        NSError *fileError = nil;
        if (![fileManager createDirectoryAtURL:resultPayloadURL
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:&fileError] ||
            ![fileManager createDirectoryAtURL:outputURL.URLByDeletingLastPathComponent
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:&fileError]) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorStaging,
                                             @"Could not create the installed-app work directories.",
                                             diagnostics, @[appURL.path], fileError);
            }
            return nil;
        }

        if (progress) progress(@"extracting", 0, 1);
        if (!LCFairPlayCopyTreeWithoutSCInfo(appURL, resultAppURL, &fileError)) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorStaging,
                                             @"Could not copy the installed app bundle.",
                                             diagnostics, @[appURL.path], fileError);
            }
            return nil;
        }
        [fileManager removeItemAtURL:[resultAppURL URLByAppendingPathComponent:@"Watch" isDirectory:YES]
                               error:nil];

        NSArray<NSString *> *machOs = LCFairPlayMachORelativePaths(appURL);
        if (!machOs.count) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorInvalidIPA,
                                             @"No Mach-O binaries were found in the installed app bundle.",
                                             diagnostics, @[appURL.path], nil);
            }
            return nil;
        }

        NSUInteger completed = 0;
        for (NSString *relativePath in machOs) @autoreleasepool {
            if (progress) progress(@"decrypting", completed, machOs.count);
            NSString *sourcePath = [appURL.path stringByAppendingPathComponent:relativePath];
            NSString *resultPath = [resultAppURL.path stringByAppendingPathComponent:relativePath];
            [diagnostics addObject:[NSString stringWithFormat:@"Decrypting installed Mach-O: %@", relativePath]];
            int decryptResult = fp_decrypt_file(sourcePath.fileSystemRepresentation,
                                                resultPath.fileSystemRepresentation,
                                                LCFairPlayCoreLog,
                                                (__bridge void *)diagnostics);
            if (decryptResult < 0) {
                if (error) {
                    *error = LCFairPlayMakeError(LCFairPlayErrorDecryption,
                                                 [NSString stringWithFormat:@"FairPlay decryption failed for %@.", relativePath],
                                                 diagnostics, @[appURL.path], nil);
                }
                return nil;
            }
            completed += 1;
        }

        if (progress) progress(@"verifying", completed, machOs.count);
        if (!LCFairPlayVerifyDecryptedMachOs(resultAppURL, diagnostics, &fileError)) {
            if (error) *error = fileError;
            return nil;
        }

        if (progress) progress(@"archiving", 0, 1);
        char zipError[512] = {0};
        if (zip_create_from_dir(resultRoot.path.fileSystemRepresentation,
                                temporaryIPAURL.path.fileSystemRepresentation,
                                zipError, sizeof(zipError)) != 0) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorArchive,
                                             [NSString stringWithFormat:@"Could not archive the imported app: %s", zipError],
                                             diagnostics, @[appURL.path], nil);
            }
            return nil;
        }

        [fileManager removeItemAtURL:outputURL error:nil];
        if (![fileManager moveItemAtURL:temporaryIPAURL toURL:outputURL error:&fileError]) {
            if (error) {
                *error = LCFairPlayMakeError(LCFairPlayErrorArchive,
                                             @"Could not publish the imported IPA.",
                                             diagnostics, @[appURL.path], fileError);
            }
            return nil;
        }
        if (progress) progress(@"finished", 1, 1);
        return outputURL;
    } @finally {
        [fileManager removeItemAtURL:temporaryIPAURL error:nil];
        [fileManager removeItemAtURL:resultRoot error:nil];
    }
#endif
}

@end
