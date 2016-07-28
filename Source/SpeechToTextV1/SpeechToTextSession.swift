/**
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import Foundation
import AVFoundation
import Starscream
import Freddy
import RestKit

enum SpeechToTextSessionErrors: ErrorType {
    case InvalidHTTPUpgrade // check credentials
}

public class SpeechToTextSession: NSObject {
    
    public var results = [TranscriptionResult]()
    public var state = SessionState.Disconnected
    public var onResults: ([TranscriptionResult] -> Void)?
    public var onFailure: (NSError -> Void)?
    
    private let restToken: RestToken
    private var tokenRefreshes = 0
    private let maxTokenRefreshes = 1
    private let socket: WebSocket
    private let queue = NSOperationQueue()
    private let userAgent = buildUserAgent("watson-apis-ios-sdk/0.5.0 SpeechToTextV1")
    private let domain = "com.ibm.watson.developer-cloud.SpeechToTextV1"
    
    public init(
        username: String,
        password: String,
        model: String? = nil,
        learningOptOut: Bool? = nil,
        serviceURL: String = "https://stream.watsonplatform.net/speech-to-text/api",
        tokenURL: String = "https://stream.watsonplatform.net/authorization/api/v1/token",
        websocketsURL: String = "wss://stream.watsonplatform.net/speech-to-text/api/v1/recognize")
    {
        let tokenURL = tokenURL + "?url=" + serviceURL
        restToken = RestToken(tokenURL: tokenURL, username: username, password: password)
        
        let url = SpeechToTextSession.buildURL(websocketsURL, model: model, learningOptOut: learningOptOut)
        socket = WebSocket(url: url!)
        
        queue.maxConcurrentOperationCount = 1
        queue.suspended = true
        
        super.init()
        socket.delegate = self
    }
    
    public func connect() {
        print("connecting")
        try! connectWithToken()
    }
    
    public func startSession(settings: TranscriptionSettings) {
        print("queueing start message")
        let start = try! settings.toJSON().serializeString()
        self.writeString(start)
    }
    
    public func startRecording() {
        print("queueing recording start")
        queue.addOperationWithBlock {
            print("starting recording")
        }
    }
    
    public func stopRecording() {
        print("queueing recording stop")
        queue.addOperationWithBlock {
            print("stopping recording")
        }
    }
    
    public func stopSession() throws {
        print("queueing stop message")
        let stop = try! TranscriptionStop().toJSON().serializeString()
        self.writeString(stop)
    }
    
    public func disconnect(forceTimeout: NSTimeInterval? = nil) {
        print("queueing disconnect")
        queue.addOperationWithBlock {
            print("disconnecting")
            self.queue.suspended = true
            self.socket.disconnect(forceTimeout: forceTimeout)
        }
        queue.addOperationWithBlock {
            print("this should never print")
        }
    }
}

// MARK: - Socket Management
extension SpeechToTextSession {
    
    private static func buildURL(url: String, model: String? = nil, learningOptOut: Bool? = nil) -> NSURL? {
        
        var queryParameters = [NSURLQueryItem]()
        
        if let model = model {
            queryParameters.append(NSURLQueryItem(name: "model", value: model))
        }
        
        if let learningOptOut = learningOptOut {
            let value = "\(learningOptOut)"
            queryParameters.append(NSURLQueryItem(name: "x-watson-learning-opt-out", value: value))
        }
        
        let urlComponents = NSURLComponents(string: url)
        urlComponents?.queryItems = queryParameters
        return urlComponents?.URL
    }
    
    private func connectWithToken() throws {
        
        print("connecting with token")
        
        // restrict the number of retries
        guard tokenRefreshes <= maxTokenRefreshes else {
            throw SpeechToTextSessionErrors.InvalidHTTPUpgrade
        }
        
        // refresh token, if necessary
        guard let token = restToken.token else {
            print("refreshing token")
            restToken.refreshToken() {
                self.tokenRefreshes += 1
                try! self.connectWithToken()
            }
            return
        }
        
        // set token and connect to socket
        socket.headers["X-Watson-Authorization-Token"] = token
        socket.headers["User-Agent"] = userAgent
        socket.connect()
    }
    
    private func writeString(str: String) {
        print("queueing write string")
        queue.addOperationWithBlock {
            print("writing string")
            self.socket.writeString(str)
        }
    }
    
    private func writeData(data: NSData) {
        print("queueing write data")
        queue.addOperationWithBlock {
            print("writing data")
            self.socket.writeData(data)
        }
    }
}

// MARK: - WebSocketDelegate
extension SpeechToTextSession: WebSocketDelegate {
    
    public func websocketDidConnect(socket: WebSocket) {
        print("did connect")
        state = .Listening
        queue.suspended = false
    }
    
    public func websocketDidReceiveData(socket: WebSocket, data: NSData) {
        return
    }
    
    public func websocketDidReceiveMessage(socket: WebSocket, text: String) {
        print("did receive message: \(text)")
        let json = try! JSON(jsonString: text)
        let state = try? json.decode(type: TranscriptionState.self)
        let results = try? json.decode(type: TranscriptionResultWrapper.self)
        let error = try? json.string("error")
        
        if let state = state {
            onStateDelegate(state)
        } else if let results = results {
            onResultsDelegate(results)
        } else if let error = error {
            onErrorDelegate(error)
        }
    }
    
    public func websocketDidDisconnect(socket: WebSocket, error: NSError?) {
        print("did disconnect: \(error)")
        state = .Disconnected
        if isAuthenticationFailure(error) {
            try! connectWithToken()
        } else if isDisconnectedByServer(error) {
            return
        } else if let error = error {
            onFailure?(error)
        }
    }
    
}

extension SpeechToTextSession {

    private func onStateDelegate(state: TranscriptionState) {
        if self.state == .Transcribing && state.state == "listening" {
            self.state = .Listening
            queue.suspended = false
        }
        return
    }
    
    private func onResultsDelegate(wrapper: TranscriptionResultWrapper) {
        var localIndex = wrapper.resultIndex
        var wrapperIndex = 0
        while localIndex < results.count {
            results[localIndex] = wrapper.results[wrapperIndex]
            localIndex = localIndex + 1
            wrapperIndex = wrapperIndex + 1
        }
        while wrapperIndex < wrapper.results.count {
            results.append(wrapper.results[wrapperIndex])
            wrapperIndex = wrapperIndex + 1
        }
        
        onResults?(results)
    }
    
    private func onErrorDelegate(error: String) {
        state = .Listening
        let failureReason = error
        let userInfo = [NSLocalizedFailureReasonErrorKey: failureReason]
        let error = NSError(domain: domain, code: 0, userInfo: userInfo)
        onFailure?(error)
    }
    
    private func isAuthenticationFailure(error: NSError?) -> Bool {
        guard let error = error else {
            return false
        }
        guard let description = error.userInfo[NSLocalizedDescriptionKey] as? String else {
            return false
        }
        
        let authDomain = (error.domain == "WebSocket")
        let authCode = (error.code == 400)
        let authDescription = (description == "Invalid HTTP upgrade")
        if authDomain && authCode && authDescription {
            return true
        }
        
        return false
    }
    
    private func isDisconnectedByServer(error: NSError?) -> Bool {
        guard let error = error else {
            return false
        }
        guard let description = error.userInfo[NSLocalizedDescriptionKey] as? String else {
            return false
        }
        
        let authDomain = (error.domain == "WebSocket")
        let authCode = (error.code == 1000)
        let authDescription = (description == "connection closed by server")
        if authDomain && authCode && authDescription {
            return true
        }
        
        return false
    }
    
}
