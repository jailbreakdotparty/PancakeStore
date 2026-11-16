//
//  Downgrader.swift
//  MuffinStoreJailed
//
//  Created by Mineek on 19/10/2024.
//

import Foundation
import UIKit
import Zip
import SwiftUI
import PartyUI

/// Downloads the selected version and saves it as an IPA in Documents
/// (visible in the Files app), then offers it through the share sheet.
/// Nothing is installed.
func downgradeAppToVersion(appId: String, versionId: String, ipaTool: IPATool) {
    let data = StoreData.shared

    DispatchQueue.global(qos: .userInitiated).async {
        func fail(_ message: String) {
            print(message)
            DispatchQueue.main.async {
                Alertinator.shared.alert(title: String(localized: "alert.error.title"), body: message)
            }
        }

        let path = ipaTool.downloadIPAForVersion(appId: appId, appVerId: versionId)
        guard !path.isEmpty else {
            fail(String(localized: "alert.download.failed", defaultValue: "Failed to download the IPA. Check the logs for details."))
            return
        }
        print("IPA downloaded to \(path)")

        do {
            let unpacked = URL(fileURLWithPath: path)
            let payload = unpacked.appendingPathComponent("Payload")
            guard let appName = try fm.contentsOfDirectory(atPath: payload.path).first(where: { $0.hasSuffix(".app") }),
                  let infoPlist = NSDictionary(contentsOf: payload.appendingPathComponent(appName).appendingPathComponent("Info.plist")),
                  let appBundleId = infoPlist["CFBundleIdentifier"] as? String else {
                fail("Downloaded IPA has no app bundle")
                return
            }
            let appVersion = infoPlist["CFBundleShortVersionString"] as? String ?? versionId
            print("appBundleId: \(appBundleId)")
            print("appVersion: \(appVersion)")

            let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let ipaURL = documents.appendingPathComponent("\(appBundleId)_\(appVersion).ipa")
            try? fm.removeItem(at: ipaURL)
            let contents = try fm.contentsOfDirectory(atPath: path).map { unpacked.appendingPathComponent($0) }
            try Zip.zipFiles(paths: contents, zipFilePath: ipaURL, password: nil, progress: nil)
            try? fm.removeItem(at: unpacked)
            try? fm.removeItem(at: fm.temporaryDirectory.appendingPathComponent("app.ipa"))
            print("IPA saved to \(ipaURL.path)")

            // FairPlay-decrypt on-device so the result is runnable outside the
            // App Store (e.g. inside LiveContainer). Device-only; if it fails
            // we keep the still-encrypted IPA and surface the reason.
            var deliveredIPA = ipaURL
            do {
                deliveredIPA = try FairPlayDecryptor.decrypt(ipaAt: ipaURL)
                print("FairPlay decryption succeeded: \(deliveredIPA.lastPathComponent)")
            } catch {
                print("FairPlay decryption failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }

            DispatchQueue.main.async {
                data.appBID = appBundleId
                data.appVersion = appVersion
                data.downloadedIPA = deliveredIPA
                data.hasServedApp = true
                presentShareSheet(for: deliveredIPA)
            }
        } catch {
            fail("Failed to package the IPA: \(error.localizedDescription)")
        }
    }
}

func presentShareSheet(for url: URL) {
    guard var top = UIApplication.shared.windows.first?.rootViewController else { return }
    while let presented = top.presentedViewController {
        top = presented
    }
    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    activity.popoverPresentationController?.sourceView = top.view
    activity.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY, width: 0, height: 0)
    top.present(activity, animated: true)
}

func promptForVersionId(appId: String, versionIds: [String], ipaTool: IPATool) {
    let isiPad = UIDevice.current.userInterfaceIdiom == .pad
    let alert = UIAlertController(
        title: String(localized: "alert.version.enter.title"),
        message: String(localized: "alert.version.enter.message"),
        preferredStyle: isiPad ? .alert : .actionSheet
    )
    for versionId in versionIds {
        alert.addAction(UIAlertAction(title: versionId, style: .default, handler: { _ in
            downgradeAppToVersion(appId: appId, versionId: versionId, ipaTool: ipaTool)
        }))
    }
    alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel, handler: nil))
    UIApplication.shared.windows.first?.rootViewController?.present(alert, animated: true, completion: nil)
}

func showAlert(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default, handler: nil))
    UIApplication.shared.windows.first?.rootViewController?.present(alert, animated: true, completion: nil)
}

func getAllAppVersionIdsFromServer(appId: String, ipaTool: IPATool) {
    let serverURL = "https://apis.bilin.eu.org/history/"
    let url = URL(string: "\(serverURL)\(appId)")!
    let request = URLRequest(url: url)
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            DispatchQueue.main.async {
                showAlert(title: String(localized: "alert.error.title"), message: error.localizedDescription)
            }
            return
        }
        let json = try! JSONSerialization.jsonObject(with: data!) as! [String: Any]
        let versionIds = json["data"] as! [Dictionary<String, Any>]
        if versionIds.count == 0 {
            DispatchQueue.main.async {
                showAlert(title: String(localized: "alert.error.title"), message: String(localized: "alert.version.none"))
            }
            return
        }
        DispatchQueue.main.async {
            let isiPad = UIDevice.current.userInterfaceIdiom == .pad
            let alert = UIAlertController(
                title: String(localized: "alert.version.select.title"),
                message: String(localized: "alert.version.select.message"),
                preferredStyle: isiPad ? .alert : .actionSheet
            )
            for versionId in versionIds {
                alert.addAction(UIAlertAction(title: "\(versionId["bundle_version"]!)", style: .default, handler: { _ in
                    downgradeAppToVersion(appId: appId, versionId: "\(versionId["external_identifier"]!)", ipaTool: ipaTool)
                }))
            }
            alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel, handler: nil))
            UIApplication.shared.windows.first?.rootViewController?.present(alert, animated: true, completion: nil)
        }
    }
    task.resume()
}

func downgradeApp(appId: String, ipaTool: IPATool) -> Bool {
    let versionIds = ipaTool.getVersionIDList(appId: appId)
    if versionIds.isEmpty {
        print("No version ids were found, aborting...")
        DispatchQueue.main.async {
            Alertinator.shared.alert(
                title: String(localized: "alert.downgrade.failed.title"),
                body: String(localized: "alert.downgrade.failed.message")
            )
        }
        return false
    }

    DispatchQueue.main.async {
    let isiPad = UIDevice.current.userInterfaceIdiom == .pad

    let alert = UIAlertController(
        title: String(localized: "alert.version.mode.title"),
        message: String(localized: "alert.version.mode.message"),
        preferredStyle: isiPad ? .alert : .actionSheet
    )
    alert.addAction(UIAlertAction(title: String(localized: "alert.version.mode.manual"), style: .default, handler: { _ in
        promptForVersionId(appId: appId, versionIds: versionIds, ipaTool: ipaTool)
    }))
    alert.addAction(UIAlertAction(title: String(localized: "alert.version.mode.server"), style: .default, handler: { _ in
        getAllAppVersionIdsFromServer(appId: appId, ipaTool: ipaTool)
    }))
    alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel, handler: nil))
    UIApplication.shared.windows.first?.rootViewController?.present(alert, animated: true, completion: nil)
    }
    return true
}

func cleanUp() {
    do {
        // first, delete the temporary ipa file.
        let tempDir = fm.temporaryDirectory
        let tempIPA = tempDir.appendingPathComponent("app.ipa")
        
        try fm.removeItem(at: tempIPA)
        // then, nuke the app directory.
        let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let appFolder = docsURL.appendingPathComponent("app")
        
        try fm.removeItem(at: appFolder)
    } catch {
        
    }
}
