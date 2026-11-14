//
//  ContentView.swift
//  MuffinStoreJailed
//
//  Created by Mineek on 26/12/2024.
//

import SwiftUI
import PartyUI

final class StoreData: ObservableObject {
    static let shared = StoreData()
    
    @Published var appBID = ""
    @Published var appVersion = ""
    @Published var hasServedApp = false
    @Published var downloadedIPA: URL?
    @Published var sent2FA = false
    @Published var isLoggedIn = false
}

struct ContentView: View {
    @StateObject private var store = StoreData.shared
    @State private var ipaTool: IPATool?
    
    @State private var appleId = ""
    @State private var password = ""
    @State private var authCode = ""
    @State private var accountName = ""
    
    @State private var storeURL = ""
    @State private var isDowngrading = false
    
    @State private var shownWelcome = false
    @State private var showSettings = false
    
    let device = UIDevice.current
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LogView()
                        .modifier(TerminalPlatter())
                } header: {
                    HeaderLabel(text: String(localized: "section.logs.title"), icon: "terminal")
                } footer: {
                    Text("section.logs.footer")
                }

                // login stuff
                if !store.isLoggedIn {
                    Section {
                        TextField("login.placeholder.appleId", text: $appleId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("login.placeholder.password", text: $password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } header: {
                        HeaderLabel(text: String(localized: "section.login.title"), icon: "cloud")
                    } footer: {
                        Text("section.login.footer")
                    }

                    if store.sent2FA {
                        Section {
                            TextField("login.placeholder.twoFactor", text: $authCode)
                                .keyboardType(.numberPad)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } header: {
                            HeaderLabel(text: String(localized: "section.verification.title"), icon: "faceid")
                        }
                    }
                }

                // on login
                if store.isLoggedIn && !isDowngrading {
                    Section {
                        TextField("downgrade.placeholder.link", text: $storeURL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } header: {
                        HeaderLabel(text: String(localized: "section.downgrade.title"), icon: "arrow.down.app")
                    } footer: {
                        Text("section.downgrade.footer")
                    }
                }

                // while downgrading
                if isDowngrading {
                    Section {
                        if store.hasServedApp {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(String(localized: "status.ipaSaved", defaultValue: "IPA saved to Files"))
                            }
                        } else {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text(String(localized: "status.downloading", defaultValue: "Downloading IPA..."))
                            }
                        }
                    }

                    Section {
                        LabeledContent("downgrade.placeholder.link") {
                            if storeURL.isEmpty {
                                ProgressView()
                            } else {
                                Text(storeURL)
                                    .contextMenu {
                                        Button {
                                            UIPasteboard.general.string = storeURL
                                        } label: {
                                            Label("action.copy", systemImage: "doc.on.doc")
                                        }
                                    }
                            }
                        }

                        LabeledContent("info.label.bundleId") {
                            if store.appBID.isEmpty {
                                ProgressView()
                            } else {
                                Text(store.appBID)
                                    .contextMenu {
                                        Button {
                                            UIPasteboard.general.string = store.appBID
                                        } label: {
                                            Label("action.copy", systemImage: "doc.on.doc")
                                        }
                                    }
                            }
                        }

                        LabeledContent("info.label.targetVersion") {
                            if store.appVersion.isEmpty {
                                ProgressView()
                            } else {
                                Text(store.appVersion)
                            }
                        }
                    } header: {
                        HeaderLabel(text: String(localized: "section.appInfo.title"), icon: "info.circle")
                    }
                }
            }
            .navigationTitle("app.name")
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                Group {
                    if !store.isLoggedIn && !store.sent2FA {
                        Button {
                            ipaTool = IPATool(appleId: appleId, password: password)
                            let _ = ipaTool?.authenticate(requestCode: true)
                        } label: {
                            ButtonLabel(text: String(localized: "action.continue"), icon: "arrow.right")
                        }
                        .buttonStyle(FancyButtonStyle())
                        .disabled(appleId.isEmpty || password.isEmpty)
                    }
                    
                    if !store.isLoggedIn && store.sent2FA {
                        Button {
                            let finalPassword = password + authCode
                            ipaTool = IPATool(appleId: appleId, password: finalPassword)
                            let _ = ipaTool?.authenticate()
                        } label: {
                            ButtonLabel(text: String(localized: "action.logIn"), icon: "arrow.right")
                        }
                        .buttonStyle(FancyButtonStyle())
                        .disabled(authCode.isEmpty)
                    }
                    
                    if store.isLoggedIn && !isDowngrading {
                        Button {
                            var appLinkParsed = storeURL
                            appLinkParsed = appLinkParsed.components(separatedBy: "id").last ?? ""
                            
                            for char in appLinkParsed {
                                if !char.isNumber {
                                    appLinkParsed = String(appLinkParsed.prefix(upTo: appLinkParsed.firstIndex(of: char)!))
                                    break
                                }
                            }
                            
                            print("App ID: \(appLinkParsed)")
                            isDowngrading = true
                            isDowngrading = downgradeApp(appId: appLinkParsed, ipaTool: ipaTool!)
                        } label: {
                            ButtonLabel(text: String(localized: "action.downgradeApp"), icon: "arrow.down")
                        }
                        .buttonStyle(FancyButtonStyle())
                        .disabled(storeURL.isEmpty)
                    }
                    
                    if isDowngrading {
                        VStack {
                            Button {
                                if let ipa = store.downloadedIPA {
                                    presentShareSheet(for: ipa)
                                }
                            } label: {
                                ButtonLabel(text: String(localized: "action.shareIPA", defaultValue: "Share IPA"), icon: "square.and.arrow.up")
                            }
                            .buttonStyle(FancyButtonStyle())
                            .disabled(!store.hasServedApp)
                        }
                    }
                }
                .modifier(OverlayBackground())
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if store.isLoggedIn {
                            Button(action: {}) {
                                Text(verbatim: String(format: String(localized: "menu.signedInAs"), accountName))
                                Text("\(appleId)")
                            }
                        } else {
                            Button(action: {}) {
                                Text("menu.notSignedIn")
                                Text("menu.signInPrompt")
                            }
                        }

                        Button(role: .destructive) {
                            Alertinator.shared.alert(
                                title: String(localized: "alert.signOut.title"),
                                body: String(localized: "alert.signOut.message"),
                                actionLabel: String(localized: "action.signOutConfirm"),
                                action: {
                                    EncryptedKeychainWrapper.nuke()
                                    EncryptedKeychainWrapper.generateAndStoreKey()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        exitinator()
                                    }
                                })
                        } label: {
                            Label("action.signOut", systemImage: "person.fill.xmark")
                        }
                        .disabled(!store.isLoggedIn)
                    } label: {
                        Image(systemName: "person")
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings.toggle()
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .onAppear {
                print("\n[*] PancakeStore v\(AppInfo.appVersion) (\(appBuild))")
                print("[*] Running on \(device.systemName) \(device.systemVersion), \(machineName()).")
                Task { await StoreAnisette.shared.prepare() }
                print("[Store] Login uses relabeled machine anisette (X-Apple-AMD), ipatool build 9")
                store.isLoggedIn = EncryptedKeychainWrapper.hasAuthInfo()
                print(store.isLoggedIn ? "Found auth info in keychain" : "Found no auth info in keychain")

                if store.isLoggedIn {
                    guard let authInfo = EncryptedKeychainWrapper.getAuthInfo() else {
                        print("Failed to get auth info from keychain, logging out")
                        store.isLoggedIn = false
                        EncryptedKeychainWrapper.nuke()
                        EncryptedKeychainWrapper.generateAndStoreKey()
                        return
                    }

                    appleId = authInfo["appleId"]! as! String
                    password = authInfo["password"]! as! String
                    accountName = authInfo["accountName"]! as! String

                    ipaTool = IPATool(appleId: appleId, password: password)
                    let result = ipaTool?.authenticate()
                    print(result ?? false ? "Re-authenticated successfully" : "Re-authenticated unsuccessfully")
                } else {
                    print("No auth info found in keychain, setting up by generating a key in SEP")
                    EncryptedKeychainWrapper.generateAndStoreKey()
                }
            }
            .onOpenURL { schemedURL in
                let rawURL = schemedURL.absoluteString.replacingOccurrences(of: "pancakestore:", with: "")
                if let appLink = rawURL.removingPercentEncoding {
                    storeURL = appLink
                    print("Successfully received app link! \(appLink)")
                }
            }
        }
    }
}

func machineName() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machineMirror = Mirror(reflecting: systemInfo.machine)
    return machineMirror.children.reduce("") { identifier, element in
        guard let value = element.value as? Int8, value != 0 else { return identifier }
        return identifier + String(UnicodeScalar(UInt8(value)))
    }
}

#Preview {
    ContentView()
}
