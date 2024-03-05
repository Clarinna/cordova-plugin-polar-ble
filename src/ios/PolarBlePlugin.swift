import PolarBleSdk
import RxSwift
import Foundation
import CoreBluetooth


@objc(PolarBlePlugin)
class PolarBlePlugin: CDVPlugin, ObservableObject {
    
    var api: PolarBleApi!
    var deviceId: String!
    var variablesMap = [String: String]()
    var callbackMap = [String: String]()
    private let disposeBag = DisposeBag()
    var hrDisposable: Disposable?
    var ecgDisposable: Disposable?

    @objc(connect:)
    func connect(command: CDVInvokedUrlCommand) {
        var pluginResult: CDVPluginResult
        
        guard let arg = command.arguments[0] as? String else {
            pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)
            commandDelegate.send(pluginResult, callbackId: command.callbackId)
            return
        }
        deviceId = arg
        
        api = PolarBleApiDefaultImpl.polarImplementation(DispatchQueue.main,
                                                         features: [PolarBleSdkFeature.feature_battery_info,
                                                                    PolarBleSdkFeature.feature_device_info,
                                                                    PolarBleSdkFeature.feature_polar_online_streaming])
        
        
        api.deviceInfoObserver = self
        api.deviceFeaturesObserver = self
        
        var echoedMessage: String = ""
        do {
            try api.connectToDevice(deviceId)
            NSLog("POLAR API CONNECTED")
            echoedMessage = "POLAR API CONNECTED"
        } catch {
            NSLog("ERROR CONNECTING API")
            echoedMessage = "ERROR CONNECTING API"
        }
        
        pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: echoedMessage)
        commandDelegate.send(pluginResult, callbackId: command.callbackId)
    }
    
    @objc(disconnect:)
    func disconnect(command: CDVInvokedUrlCommand) {
        var pluginResult: CDVPluginResult
        
        guard let deviceId = command.arguments[0] as? String else {
            pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)
            commandDelegate.send(pluginResult, callbackId: command.callbackId)
            return
        }
        
        do {
            try api.disconnectFromDevice(deviceId)
        } catch let err {
            NSLog("Failed to disconnect from \(deviceId). Reason \(err)")
        }
        
        let message = "disconnected"
        pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: message)
        commandDelegate.send(pluginResult, callbackId: command.callbackId)
    }
    
    @objc(setCallback:)
    func setCallback(command: CDVInvokedUrlCommand) {
        var pluginResult: CDVPluginResult
        
        guard let variableId = command.arguments[0] as? String,
              let callbackId = command.arguments[1] as? String else {
            pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)
            commandDelegate.send(pluginResult, callbackId: command.callbackId)
            return
        }
        let key = "\(variableId):\(callbackId)"
        callbackMap[key] = command.callbackId
        
        //pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: "kk")
        //commandDelegate.send(pluginResult, callbackId: command.callbackId)
    }
    
    @objc(echo:)
    func echo(command: CDVInvokedUrlCommand) {
        var pluginResult: CDVPluginResult
        
        guard let arg1 = command.arguments[0] as? String else {
            pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR)
            commandDelegate.send(pluginResult, callbackId: command.callbackId)
            return
        }
        
        let echoedMessage = "\(arg1)"
        pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: echoedMessage)
        commandDelegate.send(pluginResult, callbackId: command.callbackId)
    }
    
    @objc func changeNotification(variableId: String) {
        
        let valor = variablesMap[variableId] ?? ""
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: valor)
        pluginResult?.keepCallback = true
        
        let matchingCallbacks = callbackMap.keys.filter { $0.starts(with: "\(variableId):") }
        matchingCallbacks.forEach { key in
            if let callbackContext = callbackMap[key] {
                print("VALOR: \(valor) TO \(callbackContext)")
                commandDelegate.send(pluginResult, callbackId: callbackContext)
            }
        }
    }
    
    func streamHR() {
        hrDisposable = api.startHrStreaming(deviceId)
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: {
                hrData in
                for sample in hrData {
                    var hr = sample.hr
                    self.variablesMap["heartRate"] = "\(hr)"
                    self.changeNotification(variableId: "heartRate")
                    //NSLog("HEART RATE: \(hr)")
                }
                
            }, onError: { error in
                NSLog("HR stream failed. Reason \(error)")
            }, onCompleted: {
                NSLog("HR stream complete")
            })
    }
    
    func streamECG() {
        ecgDisposable = api.requestStreamSettings(deviceId, feature: PolarDeviceDataType.ecg)
            .asObservable()
            .flatMap { sensorSetting -> Observable<PolarEcgData> in
                return self.api.startEcgStreaming(self.deviceId, settings: sensorSetting.maxSettings())
            }
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { polarEcgData in
                self.transformPolarEcgData(polarEcgData)
                    .subscribe(
                        onSuccess: { ecg in
                            self.variablesMap["ecg"] = "\(ecg)"
                            self.changeNotification(variableId: "ecg")
                        },
                        onFailure: { error in
                            NSLog("Error \(error)")
                        }
                    )
                    .disposed(by: DisposeBag())
                
            }, onError: { error in
                NSLog("ECG stream failed. Reason \(error)")
            }, onCompleted: {
                NSLog("ECG stream complete")
            })
    }
    
    /*func transformPolarEcgData(_ polarEcgData: PolarEcgData) -> (time: [UInt64], data: [Float]) {
        let timeStamps = polarEcgData.samples.map { $0.timeStamp }
        let waves = polarEcgData.samples.map { Float($0.voltage) / 1000.0 }
        return (time: timeStamps, data: waves)
    }*/
    
    func transformPolarEcgData(_ polarEcgData: PolarEcgData) -> Single<String> {
        return Single.create { single in
            do {
                let timeStamps = polarEcgData.samples.map { $0.timeStamp }
                let voltages = polarEcgData.samples.map { Float($0.voltage) / 1000.0 }
                let jsonDict: [String: Any] = ["time": timeStamps, "data": voltages]
                let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options: [])
                if let jsonString = String(data: jsonData, encoding: .utf8) {
                    single(.success(jsonString))
                    
                } else {
                    single(.failure(NSError(domain: "Error al convertir datos a cadena", code: 0, userInfo: nil)))
                    
                }
                
            } catch {
                single(.failure(error))
                
            }
            return Disposables.create()
            
        }
        
    }

}

extension PolarBlePlugin : PolarBleApiDeviceInfoObserver {
    func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
        //print("battery level updated: \(batteryLevel)")
        variablesMap["batteryLevel"] = batteryLevel.description
        //variablesMap["heartRate"] = "80"
        Task { @MainActor in
            //self.batteryStatusFeature.batteryLevel = batteryLevel
            changeNotification(variableId: "batteryLevel")
            //changeNotification(variableId: "heartRate")
        }
    }

    func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {
        print("dis info: \(uuid.uuidString) value: \(value)")
        if(uuid == BleDisClient.SOFTWARE_REVISION_STRING) {
            Task { @MainActor in
                //self.deviceInfoFeature.firmwareVersion = value
            }
        }
    }
}


extension PolarBlePlugin : PolarBleApiDeviceFeaturesObserver {
    func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdk.PolarBleSdkFeature) {
        NSLog("Feature is ready: \(feature)")
        switch(feature) {
        case .feature_polar_online_streaming:
            Task { @MainActor in
                //self.onlineStreamingFeature.isSupported = true
            }
            api.getAvailableOnlineStreamDataTypes(identifier)
                .observe(on: MainScheduler.instance)
                .subscribe{ e in
                    switch e {
                    case .success(_):
                        self.streamHR()
                        self.streamECG()
                    case .failure(let err):
                        NSLog("Failed to get available online streaming data types: \(err)")
                        //self.somethingFailed(text: "Failed to get available online streaming data types: \(err)")
                    }
                }.disposed(by: disposeBag)
            break
        default:
            NSLog("Feature unused")
        }
    }

    // deprecated
    func hrFeatureReady(_ identifier: String) {
        NSLog("HR ready")
    }

    // deprecated
    func ftpFeatureReady(_ identifier: String) {
        NSLog("FTP ready")
    }

    // deprecated
    func streamingFeaturesReady(_ identifier: String, streamingFeatures: Set<PolarDeviceDataType>) {
        for feature in streamingFeatures {
            NSLog("Feature \(feature) is ready.")
        }
    }

}

