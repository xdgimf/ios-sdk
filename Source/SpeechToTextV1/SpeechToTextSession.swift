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

/**
 The IBM Watson Speech to Text service enables you to add speech transcription capabilities to
 your application. It uses machine intelligence to combine information about grammar and language
 structure to generate an accurate transcription. Transcriptions are supported for various audio
 formats and languages.
 */
public class SpeechToTextSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    private var results = [TranscriptionResult]()
    private let settings: TranscriptionSettings
    private var state: SpeechToTextSessionState
    private var buffer: NSMutableData
    private let token: RestToken
    private let socket: WebSocket
    private var captureSession: AVCaptureSession?
    private let userAgent = buildUserAgent("watson-apis-ios-sdk/0.5.0 SpeechToTextV1")
    private let domain = "com.ibm.watson.developer-cloud.SpeechToTextV1"
    
    private var retries = 0
    private let maxRetries = 2
    
    public var onResults: ([TranscriptionResult] -> Void)?
    public var onFailure: (NSError -> Void)?
    
    public init(
        username: String,
        password: String,
        settings: TranscriptionSettings,
        serviceURL: String = "https://stream.watsonplatform.net/speech-to-text/api",
        tokenURL: String = "https://stream.watsonplatform.net/authorization/api/v1/token",
        websocketsURL: String = "wss://stream.watsonplatform.net/speech-to-text/api/v1/recognize")
    {
        self.settings = settings
        
        state = .Disconnected
        
        buffer = NSMutableData()
        
        let tokenURL = tokenURL + "?url=" + serviceURL
        token = RestToken(tokenURL: tokenURL, username: username, password: password)
        
        socket = WebSocket(url: NSURL(string: websocketsURL)!)
        
        super.init()
        
        socket.onConnect = websocketDidConnect
        socket.onText = websocketDidReceiveMessage
        socket.onDisconnect = websocketDidDisconnect
    }
    
    public func startTranscribing() {
        if !socket.isConnected {
            connectWithToken()
        }
        startStreaming()
    }
    
    public func stopTranscribing() {
        stopStreaming()
        stopRecognitionRequest()
        // doesn't send disconnect -- server will time out
    }
    
    private func connectWithToken() {
        guard retries < maxRetries else {
            let failureReason = "Invalid HTTP upgrade. Please verify your credentials."
            let userInfo = [NSLocalizedFailureReasonErrorKey: failureReason]
            let error = NSError(domain: domain, code: 0, userInfo: userInfo)
            onFailure?(error)
            return
        }
        
        retries += 1
        
        if let token = token.token where retries == 1 {
            socket.headers["X-Watson-Authorization-Token"] = token
            socket.headers["User-Agent"] = userAgent
            socket.connect()
        } else {
            let failure = { (error: NSError) in
                let failureReason = "Failed to obtain an authentication token. Check credentials."
                let userInfo = [NSLocalizedFailureReasonErrorKey: failureReason]
                let error = NSError(domain: self.domain, code: 0, userInfo: userInfo)
                self.onFailure?(error)
            }
            token.refreshToken(failure) {
                self.socket.headers["X-Watson-Authorization-Token"] = self.token.token
                self.socket.headers["User-Agent"] = self.userAgent
                self.socket.connect()
            }
        }
    }
    
    private func startStreaming() {
        captureSession = AVCaptureSession()
        guard let captureSession = captureSession else {
            let failureReason = "Unable to create an AVCaptureSession."
            let userInfo = [NSLocalizedFailureReasonErrorKey: failureReason]
            let error = NSError(domain: domain, code: 0, userInfo: userInfo)
            onFailure?(error)
            return
        }
        
        let microphoneDevice = AVCaptureDevice.defaultDeviceWithMediaType(AVMediaTypeAudio)
        guard let microphoneInput = try? AVCaptureDeviceInput(device: microphoneDevice) else {
            let failureReason = "Unable to access the microphone."
            let userInfo = [NSLocalizedFailureReasonErrorKey: failureReason]
            let error = NSError(domain: domain, code: 0, userInfo: userInfo)
            onFailure?(error)
            return
        }
        
        guard captureSession.canAddInput(microphoneInput) else {
            let failureReason = "Unable to add the microphone as a capture session input. " +
                                "(Note that the microphone is only accessible on a physical " +
                                "device--no microphone is accessible from within the simulator.)"
            let userInfo = [NSLocalizedFailureReasonErrorKey: failureReason]
            let error = NSError(domain: domain, code: 0, userInfo: userInfo)
            onFailure?(error)
            return
        }
        
        let transcriptionOutput = AVCaptureAudioDataOutput()
        let queue = dispatch_queue_create("stt_streaming", DISPATCH_QUEUE_SERIAL)
        transcriptionOutput.setSampleBufferDelegate(self, queue: queue)
        
        guard captureSession.canAddOutput(transcriptionOutput) else {
            let failureReason = "Unable to add transcription as a capture session output."
            let userInfo = [NSLocalizedFailureReasonErrorKey: failureReason]
            let error = NSError(domain: domain, code: 0, userInfo: userInfo)
            onFailure?(error)
            return
        }
        
        startRecognitionRequest()
        captureSession.addInput(microphoneInput)
        captureSession.addOutput(transcriptionOutput)
        captureSession.startRunning()
    }
    
    private func stopStreaming() {
        captureSession?.stopRunning()
        captureSession = nil
    }
    
    private func startRecognitionRequest() {
        do {
            let start = try settings.toJSON().serializeString()
            socket.connect()
            socket.writeString(start)
        } catch {
            let failureReason = "Failed to convert `TranscriptionStart` to a JSON string."
            let userInfo = [NSLocalizedFailureReasonErrorKey: failureReason]
            let error = NSError(domain: domain, code: 0, userInfo: userInfo)
            onFailure?(error)
        }
    }
    
    private func stopRecognitionRequest() {
        do {
            let stop = try TranscriptionStop().toJSON().serializeString()
            socket.writeString(stop)
            // socket.disconnect()
        } catch {
            let failureReason = "Failed to convert `TranscriptionStop` to a JSON string."
            let userInfo = [NSLocalizedFailureReasonErrorKey: failureReason]
            let error = NSError(domain: domain, code: 0, userInfo: userInfo)
            onFailure?(error)
        }
    }
    
    @objc public func captureOutput(
        captureOutput: AVCaptureOutput!,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer!,
        fromConnection connection: AVCaptureConnection!)
    {
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            let failureReason = "Microphone audio buffer ignored because it was not ready."
            let userInfo = [NSLocalizedFailureReasonErrorKey: failureReason]
            let error = NSError(domain: domain, code: 0, userInfo: userInfo)
            onFailure?(error)
            return
        }
        
        let emptyBuffer = AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        var audioBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: emptyBuffer)
        var blockBuffer: CMBlockBuffer?
        
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            nil,
            &audioBufferList,
            sizeof(audioBufferList.dynamicType),
            nil,
            nil,
            UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            &blockBuffer
        )
        
        let audioData = NSMutableData()
        let audioBuffers = UnsafeBufferPointer<AudioBuffer>(start: &audioBufferList.mBuffers,
                                                            count: Int(audioBufferList.mNumberBuffers))
        for audioBuffer in audioBuffers {
            audioData.appendBytes(audioBuffer.mData, length: Int(audioBuffer.mDataByteSize))
        }
        
        switch state {
        case .Connected: buffer.appendData(audioData)
        case .Listening:
            state = .Transcribing
            socket.writeData(audioData)
        case .Transcribing: socket.writeData(audioData)
        case .Disconnected: return
        }
    }
    
    private func websocketDidConnect() {
        print("connected")
        state = .Listening
        retries = 0
    }
    
    private func websocketDidReceiveMessage(text: String) {
        print("did receive message: \(text)")
        do {
            let json = try JSON(jsonString: text)
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
        } catch {
            let failureReason = "Could not serialize a generic text response to an object."
            let userInfo = [NSLocalizedFailureReasonErrorKey: failureReason]
            let error = NSError(domain: domain, code: 0, userInfo: userInfo)
            onFailure?(error)
            return
        }
    }
    
    private func websocketDidDisconnect(error: NSError?) {
        print("did disconnect")
        state = .Disconnected
        buffer = NSMutableData()
        if isAuthenticationFailure(error) {
            connectWithToken()
        } else if isDisconnectedByServer(error) {
            return
        } else if let error = error {
            onFailure?(error)
        }
    }
    
    private func onStateDelegate(state: TranscriptionState) {
        if self.state == .Transcribing && state.state == "listening" {
            self.state = .Listening
            buffer = NSMutableData()
        }
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

public enum SpeechToTextSessionState {
    case Connected
    case Listening
    case Transcribing
    case Disconnected
}

//    public func connect() {
//        socket.connect()
//    }
//
//    public func startTranscribing() {
//
//    }
//
//    public func startMicrophone() {
//
//    }
//
//    public func stopMicrophone() {
//
//    }
//
//    public func stopTranscribing() {
//
//    }
//
//    public func disconnect() {
//
//    }