package polarbleplugin

import android.util.Log
import android.widget.Toast
import com.polar.sdk.api.PolarBleApi
import com.polar.sdk.api.PolarBleApiDefaultImpl
import com.polar.sdk.api.PolarBleApiCallback
import com.polar.sdk.api.model.PolarDeviceInfo
import com.polar.sdk.api.model.PolarEcgData
import com.polar.sdk.api.model.PolarHrData
import com.polar.sdk.api.model.PolarSensorSetting
import io.reactivex.rxjava3.android.schedulers.AndroidSchedulers
import io.reactivex.rxjava3.disposables.Disposable
import org.apache.cordova.CallbackContext
import org.apache.cordova.CordovaInterface
import org.apache.cordova.CordovaPlugin
import org.apache.cordova.CordovaWebView
import org.apache.cordova.PluginResult
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID


class PolarBlePlugin : CordovaPlugin() {

    private val variablesMap = mutableMapOf<String, String>()
    private val callbackMap = mutableMapOf<String, CallbackContext>()

    private lateinit var api: PolarBleApi
    private lateinit var deviceId: String
    private var ecgDisposable: Disposable? = null
    private var hrDisposable: Disposable? = null

    override fun initialize(cordova: CordovaInterface, webView: CordovaWebView) {
        super.initialize(cordova, webView)
    }

    override fun execute(action: String, args: JSONArray, callbackContext: CallbackContext): Boolean {
        try {
            when (action) {
                "connect" -> {
                    Log.d(TAG, "connect to device")
                    deviceId = args.getString(0)
                    api = PolarBleApiDefaultImpl.defaultImplementation(
                        cordova.context.applicationContext ,
                        setOf(
                            PolarBleApi.PolarBleSdkFeature.FEATURE_POLAR_ONLINE_STREAMING,
                            PolarBleApi.PolarBleSdkFeature.FEATURE_BATTERY_INFO,
                            PolarBleApi.PolarBleSdkFeature.FEATURE_DEVICE_INFO
                        )
                    )

                    api.setApiCallback(object : PolarBleApiCallback() {
                        override fun blePowerStateChanged(powered: Boolean) {
                            Log.d(TAG, "BLE power: $powered")
                        }

                        override fun deviceConnected(polarDeviceInfo: PolarDeviceInfo) {
                            Log.d(TAG, "CONNECTED: ${polarDeviceInfo.deviceId}")
                        }

                        override fun deviceConnecting(polarDeviceInfo: PolarDeviceInfo) {
                            Log.d(TAG, "CONNECTING: ${polarDeviceInfo.deviceId}")
                        }

                        override fun deviceDisconnected(polarDeviceInfo: PolarDeviceInfo) {
                            Log.d(TAG, "DISCONNECTED: ${polarDeviceInfo.deviceId}")
                        }

                        override fun bleSdkFeatureReady(
                            identifier: String,
                            feature: PolarBleApi.PolarBleSdkFeature
                        ) {
                            Log.d(TAG, "Polar BLE SDK feature $feature is ready")
                            when (feature) {
                                PolarBleApi.PolarBleSdkFeature.FEATURE_POLAR_ONLINE_STREAMING -> {
                                    streamECG(callbackContext)
                                    streamHR(callbackContext)
                                }
                                else -> {}
                            }
                        }

                        override fun disInformationReceived(identifier: String, uuid: UUID, value: String) {
                            Log.d(TAG, "DIS INFO uuid: $uuid value: $value")
                        }

                        override fun batteryLevelReceived(identifier: String, level: Int) {
                            Log.d(TAG, "BATTERY LEVEL: $level")
                            variablesMap["batteryLevel"] = level.toString()
                            changeNotification("batteryLevel")
                        }
                    })
                    api.connectToDevice(args.getString(0))
                    callbackContext.success("connected")
                }
                "disconnect" -> {
                    api.disconnectFromDevice(args.getString(0))
                    callbackContext.success("disconnected");
                }
                "setCallback" -> {
                    val variableId = args.optString(0, "")
                    val callbackId = args.optString(1, "")
                    callbackMap["$variableId:$callbackId"] = callbackContext
                    return true
                }
                "echo" -> {
                    val input = args.getString(0)
                    val output = "Kotlin says \"$input\""
                    Toast.makeText(webView.context, output, Toast.LENGTH_LONG).show()
                    callbackContext.success(output)
                }
                else -> handleError("Invalid action", callbackContext)
            }
            return true
        } catch (e: Exception) {
            handleException(e, callbackContext)
            return false
        }
    }

    private fun sendValue(variableId: String, callbackContext: CallbackContext) {
        val valor = variablesMap[variableId] ?: ""
        val result = PluginResult(PluginResult.Status.OK, valor)
        result.keepCallback = true
        callbackContext.sendPluginResult(result)
    }

    private fun changeNotification(variableId: String) {
        val valor = variablesMap[variableId] ?: ""
        val res = PluginResult(PluginResult.Status.OK, valor)
        res.keepCallback = true

        callbackMap.keys.filter { it.startsWith("$variableId:") }.forEach {
            callbackMap[it]?.sendPluginResult(res)
        }
    }

    private fun streamHR(callbackContext: CallbackContext) {
        val isDisposed = hrDisposable?.isDisposed ?: true
        if (isDisposed) {
            hrDisposable = api.startHrStreaming(deviceId)
                .observeOn(AndroidSchedulers.mainThread())
                .subscribe(
                    { hrData: PolarHrData ->
                        for (sample in hrData.samples) {
                            //Log.d(TAG, "HR " + sample.hr)
                            //if (sample.rrsMs.isNotEmpty()) {
                                //val rrText = "(${sample.rrsMs.joinToString(separator = "ms, ")}ms)"
                                //textViewRR.text = rrText
                            //}
                            variablesMap["heartRate"] = sample.hr.toString()
                            changeNotification("heartRate")
                        }
                    },
                    { error: Throwable ->
                        Log.e(TAG, "HR stream failed. Reason $error")
                        hrDisposable = null
                    },
                    { Log.d(TAG, "HR stream complete") }
                )
        } else {
            // NOTE stops streaming if it is "running"
            hrDisposable?.dispose()
            hrDisposable = null
        }
    }

    private fun streamECG(callbackContext: CallbackContext) {
        val isDisposed = ecgDisposable?.isDisposed ?: true
        if (isDisposed) {
            ecgDisposable = api.requestStreamSettings(deviceId, PolarBleApi.PolarDeviceDataType.ECG)
                .toFlowable()
                .flatMap { sensorSetting: PolarSensorSetting -> api.startEcgStreaming(deviceId, sensorSetting.maxSettings()) }
                .observeOn(AndroidSchedulers.mainThread())
                .subscribe(
                    { polarEcgData: PolarEcgData ->
                        handleECGData(polarEcgData, callbackContext)
                    },
                    { error: Throwable ->
                        Log.e(TAG, "Ecg stream failed $error")
                        ecgDisposable = null
                    },
                    {
                        Log.d(TAG, "Ecg stream complete")
                    }
                )
        } else {
            // NOTE stops streaming if it is "running"
            ecgDisposable?.dispose()
            ecgDisposable = null
        }
    }

    private fun handleECGData(polarEcgData: PolarEcgData, callbackContext: CallbackContext) {
        val timeData: List<Long> = polarEcgData.samples.map { it.timeStamp }
        val waveData: List<Float> = polarEcgData.samples.map { it.voltage.toFloat() / 1000.0.toFloat() }

        val ecg = JSONObject()
        ecg.put("time", JSONArray(timeData))
        ecg.put("data", JSONArray(waveData))
		
		//var delta = (timeData.last() - timeData.first()) / timeData.size // nanoseconds
        //var frequency = (1.0 / delta) * 1000 * 1000 * 1000
        //Log.d(TAG, "Frequency: " +  frequency.toString())

        variablesMap["ecg"] = ecg.toString()
        changeNotification("ecg")
    }

    private fun handleError(errorMsg: String, callbackContext: CallbackContext) {
        Log.e(TAG, errorMsg)
        callbackContext.error(errorMsg)
    }

    private fun handleException(exception: Exception, callbackContext: CallbackContext) {
        handleError(exception.toString(), callbackContext)
    }

    companion object {
        private const val TAG = "PolarBlePlugin"
    }

}