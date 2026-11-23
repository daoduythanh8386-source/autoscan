package vn.smartscanner.smart_document_scanner

import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Kênh native "sds/storage": trả về dung lượng trống để cảnh báo bộ nhớ gần đầy.
 * Không truy cập mạng, không đọc dữ liệu ngoài phạm vi ứng dụng.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sds/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "freeBytes" -> try {
                        val path = call.argument<String>("path") ?: filesDir.absolutePath
                        result.success(StatFs(path).availableBytes)
                    } catch (e: Exception) {
                        result.error("ERR", e.message, null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
