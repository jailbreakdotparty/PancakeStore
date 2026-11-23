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
    @Published var sent2FA = false
    @Published var isLoggedIn = false
    @Published var isAuthenticating = false
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
                    VStack(alignment: .leading, spacing: 0) {
                        Text("section.logs.footer")
                        Text("section.logs.workingEdition")
                    }
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
                                Text("status.downgradeSuccessful")
                            }
                        } else {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("status.downgrading")
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
                            guard !store.isAuthenticating else { return }
                            store.isAuthenticating = true
                            let tool = IPATool(appleId: appleId, password: password)
                            ipaTool = tool
                            Task { @MainActor in
                                defer { store.isAuthenticating = false }
                                _ = await tool.authenticate()
                                if let saved = EncryptedKeychainWrapper.getAuthInfo() {
                                    accountName = saved["accountName"] as? String ?? appleId
                                }
                            }
                        } label: {
                            if store.isAuthenticating {
                                ProgressView()
                            } else {
                                ButtonLabel(text: String(localized: "action.continue"), icon: "arrow.right")
                            }
                        }
                        .buttonStyle(FancyButtonStyle())
                        .disabled(appleId.isEmpty || password.isEmpty || store.isAuthenticating)
                    }

                    if !store.isLoggedIn && store.sent2FA {
                        Button {
                            guard !store.isAuthenticating else { return }
                            store.isAuthenticating = true
                            let tool = IPATool(appleId: appleId, password: password)
                            ipaTool = tool
                            Task { @MainActor in
                                defer { store.isAuthenticating = false }
                                _ = await tool.authenticate(authCode: authCode)
                                if let saved = EncryptedKeychainWrapper.getAuthInfo() {
                                    accountName = saved["accountName"] as? String ?? appleId
                                }
                            }
                        } label: {
                            if store.isAuthenticating {
                                ProgressView()
                            } else {
                                ButtonLabel(text: String(localized: "action.logIn"), icon: "arrow.right")
                            }
                        }
                        .buttonStyle(FancyButtonStyle())
                        .disabled(authCode.count != 6 || authCode.contains(where: { !$0.isNumber }) || store.isAuthenticating)
                    }

                    if store.isLoggedIn && !store.hasServedApp {
                        Button {
                            guard !isDowngrading else { return }
                            var appLinkParsed = storeURL
                            appLinkParsed = appLinkParsed.components(separatedBy: "id").last ?? ""
                            
                            for char in appLinkParsed {
                                if !char.isNumber {
                                    appLinkParsed = String(appLinkParsed.prefix(upTo: appLinkParsed.firstIndex(of: char)!))
                                    break
                                }
                            }
                            
                            print("App ID: \(appLinkParsed)")
                            // Let SwiftUI render the existing FancyButtonStyle disabled state
                            // before the synchronous version lookup begins.
                            isDowngrading = true
                            DispatchQueue.main.async {
                                isDowngrading = downgradeApp(appId: appLinkParsed, ipaTool: ipaTool!)
                            }
                        } label: {
                            if isDowngrading {
                                Text(String(localized: "action.downgrading"))
                                    .font(.body.weight(.medium))
                            } else {
                                ButtonLabel(text: String(localized: "action.downgradeApp"), icon: "arrow.down")
                            }
                        }
                        .buttonStyle(FancyButtonStyle())
                        .disabled(storeURL.isEmpty || isDowngrading)
                    }
                    
                    if isDowngrading {
                        VStack {
                            Button {
                                LSApplicationWorkspace.default().openApplication(withBundleID: store.appBID)
                            } label: {
                                ButtonLabel(text: String(localized: "action.openApp"), icon: "arrow.up.right.square")
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
                print("\n[*] PancakeStore LE v\(AppInfo.appVersion) (\(appBuild))")
                print("[*] Running on \(device.systemName) \(device.systemVersion), \(machineName()).")
                let savedAuth = EncryptedKeychainWrapper.getAuthInfo()
                let hasNativeAccount = (savedAuth?["nativeAuthVersion"] as? Int) == 1 && savedAuth?["nativeAccount"] != nil
                let hasPendingNative2FA = (savedAuth?["nativeAuthPending2FA"] as? Bool) == true
                store.isLoggedIn = savedAuth != nil && ((savedAuth?["nativeAuthVersion"] as? Int) != 1 || hasNativeAccount)
                store.sent2FA = hasPendingNative2FA
                print(store.isLoggedIn ? "Found auth info in keychain" : (savedAuth == nil ? "Found no auth info in keychain" : (hasPendingNative2FA ? "Restored pending native 2FA state" : "Found pending native authentication state")))

                if let authInfo = savedAuth {
                    appleId = authInfo["appleId"] as? String ?? ""
                    password = authInfo["password"] as? String ?? ""
                    accountName = authInfo["accountName"] as? String ?? ""
                    ipaTool = IPATool(appleId: appleId, password: password)

                    if store.isLoggedIn, let tool = ipaTool {
                        Task { @MainActor in
                            let result = await tool.authenticate()
                            print(result ? "Restored native Store session" : "Native Store session restore failed")
                        }
                    }
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
