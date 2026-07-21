package us.lipkin.halved_sms

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.app.Activity

/**
 * Opens the default messaging app, pre-addressed and pre-filled.
 *
 * Android has no equivalent of iOS's in-app compose sheet — `ACTION_SENDTO`
 * hands off to whichever messaging app the user has chosen, and they come back
 * via the back button. That difference is inherent to the platform, not
 * something this plugin papers over; the Dart contract only ever promised that
 * a composer was opened.
 */
class HalvedSmsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

    private lateinit var channel: MethodChannel
    private var context: Context? = null
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "us.lipkin.halved/sms")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canSendSms" -> result.success(hasTelephony())
            "sendSms" -> {
                val message = call.argument<String>("message")
                val recipients = call.argument<List<String>>("recipients")
                if (message == null || recipients == null) {
                    result.error("bad_args", "message and recipients are required", null)
                    return
                }
                result.success(openComposer(message, recipients))
            }
            else -> result.notImplemented()
        }
    }

    private fun hasTelephony(): Boolean {
        val pm = context?.packageManager ?: return false
        return pm.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)
    }

    private fun openComposer(message: String, recipients: List<String>): Boolean {
        // `smsto:` with comma-separated numbers is the form every Android
        // messaging app understands; the body rides as an extra so it needs no
        // encoding of its own.
        val to = recipients.joinToString(",")
        val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:$to")).apply {
            putExtra("sms_body", message)
        }
        val host = activity
        return try {
            if (host != null) {
                host.startActivity(intent)
            } else {
                // No activity attached (backgrounded); NEW_TASK is required or
                // Android refuses to start it from an application context.
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context?.startActivity(intent) ?: return false
            }
            true
        } catch (e: Exception) {
            // No messaging app installed, or the intent was refused. Same
            // meaning as iOS answering canSendText() == false.
            false
        }
    }
}
