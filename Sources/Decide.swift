//
//  Decide.swift
//  Mixpanel
//
//  Created by Yarden Eitan on 8/5/16.
//  Copyright © 2016 Mixpanel. All rights reserved.
//

import Foundation
import UIKit

struct DecideResponse {
    var unshownInAppNotifications: [InAppNotification]
    var newCodelessBindings: Set<CodelessBinding>
    var newVariants: Set<Variant>
    var toFinishVariants: Set<Variant>
    var integrations: [String]

    init() {
        unshownInAppNotifications = []
        newCodelessBindings = Set()
        newVariants = Set()
        toFinishVariants = Set()
        integrations = []
    }
}

class Decide {

    let decideRequest: DecideRequest
    let lock: ReadWriteLock
    var decideFetched = false
    var notificationsInstance: InAppNotifications
    var codelessInstance = Codeless()
    var ABTestingInstance = ABTesting()
    var webSocketWrapper: WebSocketWrapper?
    var gestureRecognizer: UILongPressGestureRecognizer?
    var automaticEventsEnabled: Bool?

    var inAppDelegate: InAppNotificationsDelegate? {
        set {
            notificationsInstance.delegate = newValue
        }
        get {
            return notificationsInstance.delegate
        }
    }
    var enableVisualEditorForCodeless = true

    let switchboardURL = "wss://switchboard.mixpanel.com"

    let isDebugMode: Bool
    let token: String
    
    required init(basePathIdentifier: String, lock: ReadWriteLock, isDebugMode: Bool, token: String) {
        self.decideRequest = DecideRequest(basePathIdentifier: basePathIdentifier, isDebugMode: isDebugMode, token: token)
        self.lock = lock
        self.notificationsInstance = InAppNotifications(lock: self.lock)
        self.isDebugMode = isDebugMode
        self.token = token
    }

    func checkDecide(forceFetch: Bool = false,
                     distinctId: String,
                     token: String,
                     completion: @escaping ((_ response: DecideResponse?) -> Void)) {
        var decideResponse = DecideResponse()

        if !decideFetched || forceFetch {
            let semaphore = DispatchSemaphore(value: 0)
            decideRequest.sendRequest(distinctId: distinctId, token: token) { [weak self] decideResult in
                guard let self = self else {
                    return
                }
                guard let result = decideResult else {
                    semaphore.signal()
                    completion(nil)
                    return
                }

                var parsedNotifications = [InAppNotification]()
                if let rawNotifications = result["notifications"] as? [[String: Any]] {
                    for rawNotif in rawNotifications {
                        if let notificationType = rawNotif["type"] as? String {
                            if notificationType == InAppType.takeover.rawValue,
                                let notification = TakeoverNotification(JSONObject: rawNotif) {
                                parsedNotifications.append(notification)
                            } else if notificationType == InAppType.mini.rawValue,
                                let notification = MiniNotification(JSONObject: rawNotif) {
                                parsedNotifications.append(notification)
                            }
                        }
                    }
                } else {
                    Logger.error(message: "in-app notifications check response format error")
                }
                
                for parsedNotification in parsedNotifications {
                    if parsedNotification.hasDisplayTriggers() {
                        self.notificationsInstance.triggeredNotifications.append(parsedNotification)
                    } else {
                        self.notificationsInstance.inAppNotifications.append(parsedNotification)
                    }
                }
                
                var parsedCodelessBindings = Set<CodelessBinding>()
                if let rawCodelessBindings = result["event_bindings"] as? [[String: Any]] {
                    for rawBinding in rawCodelessBindings {
                        if let binding = Codeless.createBinding(object: rawBinding) {
                            parsedCodelessBindings.insert(binding)
                        }
                    }
                } else {
                    Logger.debug(message: "codeless event bindings check response format error")
                }

                let finishedCodelessBindings = self.codelessInstance.codelessBindings.subtracting(parsedCodelessBindings)
                for finishedBinding in finishedCodelessBindings {
                    finishedBinding.stop()
                }

                let newCodelessBindings = parsedCodelessBindings.subtracting(self.codelessInstance.codelessBindings)
                decideResponse.newCodelessBindings = newCodelessBindings

                self.codelessInstance.codelessBindings.formUnion(newCodelessBindings)
                self.codelessInstance.codelessBindings.subtract(finishedCodelessBindings)

                var parsedVariants = Set<Variant>()
                if let rawVariants = result["variants"] as? [[String: Any]] {
                    for rawVariant in rawVariants {
                        if let variant = Variant(JSONObject: rawVariant) {
                            parsedVariants.insert(variant)
                        }
                    }
                } else {
                    Logger.debug(message: "variants check response format error")
                }

                let runningVariants = Set(self.ABTestingInstance.variants.filter { return $0.running })
                decideResponse.toFinishVariants = runningVariants.subtracting(parsedVariants)
                decideResponse.newVariants = parsedVariants.subtracting(runningVariants)
                self.ABTestingInstance.variants = parsedVariants.subtracting(runningVariants).union(runningVariants)

                if let automaticEvents = result["automatic_events"] as? Bool {
                    self.automaticEventsEnabled = automaticEvents
                }

                if let integrations = result["integrations"] as? [String] {
                    decideResponse.integrations = integrations
                }

                self.decideFetched = true
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: DispatchTime.distantFuture)

        } else {
            Logger.info(message: "decide cache found, skipping network request")
        }

        decideResponse.unshownInAppNotifications = notificationsInstance.inAppNotifications.filter {
            !notificationsInstance.shownNotifications.contains($0.ID)
        }
        
        let allTriggeredNotifications = notificationsInstance.triggeredNotifications
        notificationsInstance.triggeredNotifications = notificationsInstance.triggeredNotifications.filter {
            !notificationsInstance.shownNotifications.contains($0.ID)
        }

        Logger.info(message: "decide check found \(decideResponse.unshownInAppNotifications.count) " +
            "available notifications out of " +
            "\(notificationsInstance.inAppNotifications.count) total")
        Logger.info(message: "decide check found \(notificationsInstance.triggeredNotifications.count) " +
            "available triggered notifications out of " +
            "\(allTriggeredNotifications.count) total")
        Logger.info(message: "decide check found \(decideResponse.newCodelessBindings.count) " +
            "new codeless bindings out of \(codelessInstance.codelessBindings)")
        Logger.info(message: "decide check found \(decideResponse.newVariants.count) " +
            "new variants out of \(ABTestingInstance.variants)")

        completion(decideResponse)
    }

    func connectToWebSocket(token: String, mixpanelInstance: MixpanelInstance, reconnect: Bool = false) {
        var oldInterval = 0.0
        let webSocketURL = "\(switchboardURL)/connect?key=\(token)&type=device"
        guard let url = URL(string: webSocketURL) else {
            Logger.error(message: "bad URL to connect to websocket \(webSocketURL)")
            return
        }
        let connectCallback = { [weak mixpanelInstance] in
            guard let mixpanelInstance = mixpanelInstance else {
                return
            }
            oldInterval = mixpanelInstance.flushInterval
            mixpanelInstance.flushInterval = 1

            for binding in self.codelessInstance.codelessBindings {
                binding.stop()
            }

            for variant in self.ABTestingInstance.variants {
                variant.stop()
            }

        }

        let disconnectCallback = { [weak mixpanelInstance] in
            guard let mixpanelInstance = mixpanelInstance else {
                return
            }
            mixpanelInstance.flushInterval = oldInterval

            for binding in self.codelessInstance.codelessBindings {
                binding.execute()
            }

            for variant in self.ABTestingInstance.variants {
                variant.execute()
            }
        }

        webSocketWrapper = WebSocketWrapper(url: url,
                                            keepTrying: reconnect,
                                            connectCallback: connectCallback,
                                            disconnectCallback: disconnectCallback)
    }

}
