//
//  Downgrader.swift
//  MuffinStoreJailed
//
//  Created by Mineek on 19/10/2024.
//

import Foundation
import UIKit
import Telegraph
import SwiftUI
import SafariServices
import PartyUI

struct SafariWebView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        return SFSafariViewController(url: url)
    }
    
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
    }
}

func downgradeAppToVersion(appId: String, versionId: String, ipaTool: IPATool) {
    // Downloading and FairPlay preparation can take several minutes. Keep it
    // asynchronous so the app remains responsive while the embedded ipatool
    // bridge downloads the selected App Store version.
    Task { @MainActor in
        do {
            let result = try await ipaTool.downloadIPAForVersion(appId: appId, appVerId: versionId)
            guard let bundleID = result.bundleIdentifier, !bundleID.isEmpty,
                  let ipaPath = result.destinationPath, !ipaPath.isEmpty else {
                throw NSError(
                    domain: "PancakeStoreInstall",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The downloaded App Store package is missing its bundle identifier or IPA path."]
                )
            }

            let ipaURL = URL(fileURLWithPath: ipaPath)
            guard fm.fileExists(atPath: ipaURL.path) else {
                throw NSError(
                    domain: "PancakeStoreInstall",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The downloaded IPA file could not be found at \(ipaURL.path)."]
                )
            }

            let appVersion = result.shortVersion ?? result.bundleVersion ?? "unknown"
            let appName = result.displayName ?? bundleID
            let data = StoreData.shared
            data.hasServedApp = false
            data.appBID = bundleID
            data.appVersion = appVersion

            // Keep the existing App Store OTA handoff: Palera serves the
            // manifest over HTTPS, while iOS fetches the prepared IPA from this
            // device's local server and performs the actual installation.
            var manifestComponents = URLComponents()
            manifestComponents.scheme = "https"
            manifestComponents.host = "api.palera.in"
            manifestComponents.path = "/genPlist"
            manifestComponents.queryItems = [
                URLQueryItem(name: "bundleid", value: bundleID),
                URLQueryItem(name: "name", value: appName),
                URLQueryItem(name: "version", value: appVersion),
                URLQueryItem(name: "fetchurl", value: "http://127.0.0.1:9090/signed.ipa")
            ]
            guard let manifestURL = manifestComponents.url else {
                throw NSError(
                    domain: "PancakeStoreInstall",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Could not construct the App Store installation manifest URL."]
                )
            }

            let allowed = CharacterSet.alphanumerics
            guard let encodedManifestURL = manifestURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw NSError(
                    domain: "PancakeStoreInstall",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Could not encode the installation manifest URL."]
                )
            }
            let installURL = "itms-services://?action=download-manifest&url=\(encodedManifestURL)"

            guard let rootViewController = UIApplication.shared.windows.first?.rootViewController else {
                throw NSError(
                    domain: "PancakeStoreInstall",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Could not open the iOS installation page."]
                )
            }

            // iOS may background PancakeStore after the itms-services handoff.
            // Request the available background execution window so the local
            // IPA server can finish serving the package to the system installer.
            let backgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "PancakeStore App Store installation",
                expirationHandler: nil
            )

            DispatchQueue.global(qos: .userInitiated).async {
                let server = Server()

                server.route(.GET, "signed.ipa", { _ in
                    print("[Install] iOS requested the prepared App Store IPA")
                    let ipaData = try Data(contentsOf: ipaURL, options: [.mappedIfSafe])
                    let response = HTTPResponse(body: ipaData)
                    response.headers["Content-Type"] = "application/octet-stream"
                    response.headers["Content-Length"] = String(ipaData.count)
                    response.headers["Cache-Control"] = "no-store"
                    return response
                })

                server.route(.GET, "install", { _ in
                    print("[Install] serving itms-services handoff page")
                    DispatchQueue.main.async {
                        data.hasServedApp = true
                    }
                    let installPage = """
                    <!doctype html>
                    <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
                    <body><p>Opening the iOS App Store installer…</p>
                    <script>window.location.href = "\(installURL)";</script></body></html>
                    """
                    return HTTPResponse(.ok, headers: ["Content-Type": "text/html; charset=utf-8"], content: installPage)
                })

                do {
                    // Match the IPv4 loopback URL embedded in the manifest.
                    try server.start(port: 9090, interface: "127.0.0.1")
                    print("[Install] local IPA server started on 127.0.0.1:9090")
                } catch {
                    DispatchQueue.main.async {
                        if backgroundTask != .invalid {
                            UIApplication.shared.endBackgroundTask(backgroundTask)
                        }
                        showAlert(title: String(localized: "alert.error.title"), message: "Could not start the local IPA server: \(error.localizedDescription)")
                    }
                    return
                }

                DispatchQueue.main.async {
                    print("[Install] opening iOS installation handoff")
                    let webView = SafariWebView(url: URL(string: "http://127.0.0.1:9090/install")!)
                    rootViewController.present(UIHostingController(rootView: webView), animated: true)
                }

                // Telegraph remains active while iOS downloads the manifest
                // and IPA. As in the original project, it exits when the
                // listener is stopped by the system or the app process ends.
                while server.isRunning {
                    sleep(1)
                }
                print("[Install] local IPA server stopped")
                if backgroundTask != .invalid {
                    DispatchQueue.main.async {
                        UIApplication.shared.endBackgroundTask(backgroundTask)
                    }
                }
            }
        } catch {
            print("[Install] download or preparation failed: \(error.localizedDescription)")
            showAlert(title: String(localized: "alert.error.title"), message: error.localizedDescription)
        }
    }
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
