//
//  Constants.swift
//  AnisetteKit
//
//  Created by Magesh K on 07/09/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

import Foundation

public enum AnisetteConstants {
    public static let defaultClientInfo     = "<MacBookPro18,3> <macOS;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    public static let defaultUserAgent      = "AuthKit/1 (Macintosh; OS X 26.6) (com.apple.akd/1.0)"
    public static let defaultRoutingInfo    = "17106176"    // 0x01050500 default US routing code 
    public static let defaultLocalUserID    = "0000000000000000000000000000000000000000000000000000000000000001"
    public static let defaultSerialNumber   = "0"
    public static let defaultLocale         = "en_US"
    public static let defaultTimeZone       = "UTC"
    public static let posixLocaleIdentifier = "en_US_POSIX"
    public static let iso8601DateFormat     = "yyyy-MM-dd'T'HH:mm:ss'Z'"

    public enum URLs {
        public static let grandSlamLookup = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!
    }

    public enum Headers {
        public static let contentTypePlist = "text/x-xml-plist"
        public static let acceptAll        = "*/*"
        public static let contentType      = "Content-Type"
        public static let accept           = "Accept"
        public static let userAgent        = "User-Agent"
        public static let clientInfo       = "X-Mme-Client-Info"
        public static let deviceID         = "X-Mme-Device-Id"
        public static let localUserID      = "X-Apple-I-MD-LU"
        public static let routingInfo      = "X-Apple-I-MD-RINFO"
        public static let oneTimePassword  = "X-Apple-I-MD"
        public static let machineID        = "X-Apple-I-MD-M"
        public static let serialNumber     = "X-Apple-I-SRL-NO"
        public static let clientTime       = "X-Apple-I-Client-Time"
        public static let locale           = "X-Apple-Locale"
        public static let timeZone         = "X-Apple-I-TimeZone"
    }

    public enum Files {
        public static let adiPb = "adi.pb"
        public static let rinfo = "rinfo"
    }

    public enum Libraries {
        public static let requiredNames = [
            "libstoreservicescore.so",
            "libCoreADI.so"
        ]
    }
}