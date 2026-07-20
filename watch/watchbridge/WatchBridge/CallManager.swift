import Foundation
import CallKit
import AVFoundation

/// Manages phone call handling and forwarding to watch
class CallManager: NSObject {
    static let shared = CallManager()
    
    private let callController = CXCallController()
    
    // Current call UUID tracking
    private var currentCallUUID: UUID?
    
    // MARK: - Public Methods
    
    func reportIncomingCall(phoneNumber: String, callerName: String?, completion: @escaping (Bool) -> Void) {
        let handle = CXHandle(type: .phoneNumber, value: phoneNumber)
        let callUUID = UUID()
        currentCallUUID = callUUID
        
        let callUpdate = CXCallUpdate()
        callUpdate.remoteHandle = handle
        callUpdate.localizedCallerName = callerName ?? "Unknown"
        callUpdate.hasVideo = false
        
        // Forward call event to watch
        let callEvent = CallEventData(
            action: .incoming,
            callerName: callerName,
            callerNumber: phoneNumber,
            timestamp: Date().timeIntervalSince1970
        )
        
        BLEManager.shared.sendCallEvent(callEvent)
        
        completion(true)
    }
    
    func reportOutgoingCall(phoneNumber: String, completion: @escaping (Bool) -> Void) {
        let handle = CXHandle(type: .phoneNumber, value: phoneNumber)
        let callUUID = UUID()
        currentCallUUID = callUUID
        
        let startCallAction = CXStartCallAction(call: callUUID, handle: handle)
        let transaction = CXTransaction(action: startCallAction)
        
        callController.request(transaction) { error in
            if let error = error {
                print("Error starting call: \(error.localizedDescription)")
                completion(false)
            } else {
                // Forward to watch
                let callEvent = CallEventData(
                    action: .outgoing,
                    callerName: nil,
                    callerNumber: phoneNumber,
                    timestamp: Date().timeIntervalSince1970
                )
                
                BLEManager.shared.sendCallEvent(callEvent)
                completion(true)
            }
        }
    }
    
    func handleWatchCallAction(_ action: String) {
        guard let callUUID = self.currentCallUUID else { return }
        
        switch action {
        case "ANSWER":
            answerCall(callUUID)
        case "REJECT":
            endCall(callUUID)
        default:
            break
        }
    }
    
    private func answerCall(_ callUUID: UUID) {
        let answerAction = CXAnswerCallAction(call: callUUID)
        let transaction = CXTransaction(action: answerAction)
        
        callController.request(transaction) { error in
            if let error = error {
                print("Error answering call: \(error.localizedDescription)")
            } else {
                // Update watch
                let callEvent = CallEventData(
                    action: .answered,
                    callerName: nil,
                    callerNumber: nil,
                    timestamp: Date().timeIntervalSince1970
                )
                
                BLEManager.shared.sendCallEvent(callEvent)
            }
        }
    }
    
    private func endCall(_ callUUID: UUID) {
        let endAction = CXEndCallAction(call: callUUID)
        let transaction = CXTransaction(action: endAction)
        
        callController.request(transaction) { error in
            if let error = error {
                print("Error ending call: \(error.localizedDescription)")
            } else {
                // Update watch
                let callEvent = CallEventData(
                    action: .ended,
                    callerName: nil,
                    callerNumber: nil,
                    timestamp: Date().timeIntervalSince1970
                )
                
                BLEManager.shared.sendCallEvent(callEvent)
                self.currentCallUUID = nil
            }
        }
    }
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        print("Call provider did reset")
    }
    
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Handle answer action
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        // Handle end call action
        self.currentCallUUID = nil
        action.fulfill()
    }
}

