//
//  ContentKeySessionDelegate.swift
//
//
//  Created by Emily Dixon on 4/19/24.
//

import Foundation
import AVFoundation

class ContentKeySessionDelegate : NSObject, AVContentKeySessionDelegate {
    
    // MARK: AVContentKeySessionDelegate implementation
    
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        handleContentKeyRequest(session, request: keyRequest)
    }
    
    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        handleContentKeyRequest(session, request: keyRequest)
    }
    
    func contentKeySession(_ session: AVContentKeySession, contentKeyRequestDidSucceed keyRequest: AVContentKeyRequest) {
        // this func intentionally left blank
        print("CKC Request Success")
    }
    
    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest keyRequest: AVContentKeyRequest, didFailWithError err: any Error) {
        print("CKC Request Failed!!! \(err.localizedDescription)")
    }
    
    func contentKeySessionContentProtectionSessionIdentifierDidChange(_ session: AVContentKeySession) {
        print("Content Key session ID changed apparently")
    }
    
    func contentKeySessionDidGenerateExpiredSessionReport(_ session: AVContentKeySession) {
        print("Expired session report generated (whatever that means)")
    }
    
    func contentKeySession(_ session: AVContentKeySession, externalProtectionStatusDidChangeFor contentKey: AVContentKey) {
        print("External Protection status changed for a content key sesison")
    }
    
    func contentKeySession(_ session: AVContentKeySession, shouldRetry keyRequest: AVContentKeyRequest,
                           reason retryReason: AVContentKeyRequest.RetryReason) -> Bool {
        print("===shouldRetry called with reason \(retryReason)")
        
        var shouldRetry = false
        
        switch retryReason {
            /*
             Indicates that the content key request should be retried because the key response was not set soon enough either
             due the initial request/response was taking too long, or a lease was expiring in the meantime.
             */
        case AVContentKeyRequest.RetryReason.timedOut:
            shouldRetry = true
            
            /*
             Indicates that the content key request should be retried because a key response with expired lease was set on the
             previous content key request.
             */
        case AVContentKeyRequest.RetryReason.receivedResponseWithExpiredLease:
            shouldRetry = true
            
            /*
             Indicates that the content key request should be retried because an obsolete key response was set on the previous
             content key request.
             */
        case AVContentKeyRequest.RetryReason.receivedObsoleteContentKey:
            shouldRetry = true
            
        default:
            break
        }
        
        return shouldRetry
    }
    
    // MARK: Logic
    
    func parsePlaybackId(fromSkdLocation uri: URL) -> String? {
       // pull the playbackID out of the uri to the key
       let urlComponents = URLComponents(url: uri, resolvingAgainstBaseURL: false)
        guard let urlComponents = urlComponents else {
            // not likely
            print("!! Error: Cannot Parse URI")
            return nil
        }
        let playbackID = urlComponents.findQueryValue(key: "playbackId")
        guard let playbackID = playbackID else {
            print("!! Error: URI [\(uri)] did not have playbackId!")
            return nil
        }
        print("|| PlaybackID from \(uri) is \(playbackID)")
        return playbackID
    }
    
    func lookUpDRMOptions(bySKDKeyUri uri: URL) -> (String, PlaybackOptions.DRMPlaybackOptions)? {
        let playbackID = parsePlaybackId(fromSkdLocation: uri)
        guard let playbackID = playbackID else {
            print("Loggable warning: didn't get a playback ID in key uri, can't get license")
            return nil
        }
        
        let playbackOptions = PlayerSDK.shared.fairplaySessionManager
            .findRegisteredPlaybackOptions(for: playbackID)
        

        if let playbackOptions = playbackOptions,
           case .drm(let drmOptions) = playbackOptions.playbackPolicy
        {
            print("Found DRMPlaybackOptions for \(playbackID)")
            return (playbackID, drmOptions)
        } else {
            print("Found NO playback options for \(playbackID)")
            return nil
        }
    }
    
    private func handleContentKeyRequest(_ session: AVContentKeySession, request: AVContentKeyRequest) {
        print("<><>handleContentKeyRequest: Called")
        // for hls, "the identifier must be an NSURL that matches a key URI in the Media Playlist." from the docs
        guard let keyURLStr = request.identifier as? String,
              let keyURL = URL(string: keyURLStr),
              let assetIDData = keyURLStr.data(using: .utf8)
        else {
            print("request identifier was not a key url, this is exceptional for hls")
            return
        }
        
        guard let (playbackID, drmOptions) = lookUpDRMOptions(bySKDKeyUri: keyURL) else {
            print("DRM Tokens must be registered when the AVPlayerItem is created, using FairplaySessionManager")
            return
        }
        
        // get app cert
        var applicationCertificate: Data?
        //  the drmtoday example does this by joining a dispatch group, but is this best?
        let group = DispatchGroup()
        group.enter()
        PlayerSDK.shared.fairplaySessionManager.requestCertificate(
            playbackID: playbackID, // todo - get from sdk caller
            drmToken: drmOptions.drmToken, // todo - get from sdk caller
            completion: { result in
                if let cert = try? result.get() {
                    applicationCertificate = cert
                }
                group.leave()
            }
        )
        group.wait()
        print("CERTIFICATE :: Giving App Cert to CDM: \(applicationCertificate?.base64EncodedString())")
        guard let applicationCertificate = applicationCertificate else {
            print("failed to get application certificate")
            return
        }
        
        // step: exchange app cert for SPC using KeyRequest w/completion handler (request wants to know if failed)
        request.makeStreamingContentKeyRequestData(forApp: applicationCertificate,
                                                   contentIdentifier: assetIDData,
                                                   options: [AVContentKeyRequestProtocolVersionsKey: [1]]) { [weak self] spcData, error in
            guard let self = self else {
                // todo - log or something?
                return
            }
            
            guard let spcData = spcData else {
                print("No SPC Data in spc response")
                // `error` will be non-nil by contract
                request.processContentKeyResponseError(error!)
                return
            }
            // step: exchange SPC for CKC using KeyRequest w/completion handler (request wants to know if failed)
            // todo - drmToken from Asset
            handleSpcObtainedFromCDM(spcData: spcData, playbackID: playbackID, drmToken: drmOptions.drmToken, domain: "TODO - Not Hooked Up!", request: request)
        }
    }
    
    private func handleSpcObtainedFromCDM(spcData: Data, playbackID: String, drmToken: String, domain: String, request: AVContentKeyRequest)  {
        // Send SPC to Key Server and obtain CKC
        
        // todo - DRM Today example does this by joining a DispatchGroup. Is this really preferable??
        var ckcData: Data? = nil
        let group = DispatchGroup()
        group.enter()
        PlayerSDK.shared.fairplaySessionManager.requestLicense(spcData: spcData, playbackID: playbackID, drmToken: drmToken, playbackDomain: domain, offline: false) { result in
            if let data = try? result.get() {
                ckcData = data
            }
            group.leave()
        }
        group.wait()
        
        // TODO - On error, CKC request returns a body so we can't rely on this
        guard let ckcData = ckcData else {
            print("no CKC Data in CKC response")
            return
        }
        
        print("<><> Providing CKC to System!")
        // Send CKC to CDM/wherever else so we can finally play our content
        let keyResponse = AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckcData)
        request.processContentKeyResponse(keyResponse)
        // no further interaction is required from us to play.
    }
}

extension URLComponents {
    func findQueryValue(key: String) -> String? {
        if let items = self.queryItems {
            for item in items {
                if item.name.lowercased() == key.lowercased() {
                    return item.value
                }
            }
        }
        
        return nil
    }
}
