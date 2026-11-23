//
//  ShareViewController.swift
//  PancakeStore
//
//  Created by lunginspector on 4/26/26.
//

import UIKit
import UniformTypeIdentifiers

// thank you for letting me skid this skadz108.
// you don;t need permission to skid things from your team member? - skadz 6.5.26
class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        handleSharedContent()
    }
    
    func handleSharedContent() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments else {
            print("failed to get attachment")
            return
        }

        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, error in
                    guard let self = self else { return }

                    if let url = item as? URL {
                        self.openMainApp(with: url)
                    } else {
                        self.closeSheet()
                    }
                }
            }
        }
    }
    
    private func openMainApp(with url: URL) {
        var components = URLComponents()
        
        components.scheme = "pancakestore"
        components.path = url.absoluteString
        
        guard let url = components.url else {
            closeSheet()
            return
        }
        print("received url: \(url)")
        
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                application.open(url)
                break
            }
            
            responder = responder?.next
        }
        
        closeSheet()
    }
    
    func closeSheet() {
        extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
    }

    func configurationItems() -> [Any]! {
        return []
    }
}

