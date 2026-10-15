package dev.localpdf.local_pdf_editor

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.content.Intent
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var source: File? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.localpdf/documents").setMethodCallHandler { call, result ->
            if (call.method != "saveDocument") { result.notImplemented(); return@setMethodCallHandler }
            if (pending != null) { result.error("EXPORT_BUSY", "Another document picker is active", null); return@setMethodCallHandler }
            try {
                val file = File(call.argument<String>("source") ?: error("Missing source")).canonicalFile
                require(file.isFile && (file.path.startsWith(filesDir.canonicalPath + File.separator) ||
                    file.path.startsWith(cacheDir.canonicalPath + File.separator))) { "Source must be an app-private prepared export" }
                source = file
                pending = result
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = call.argument<String>("mime") ?: "application/pdf"
                    putExtra(Intent.EXTRA_TITLE, call.argument<String>("filename") ?: "edited.pdf")
                }
                startActivityForResult(intent, 4201)
            } catch (error: Exception) {
                pending = null; source = null
                result.error("EXPORT_FAILED", error.message, null)
            }
        }
    }

    private fun digest(input: java.io.InputStream): ByteArray {
        val hash = MessageDigest.getInstance("SHA-256")
        input.use { stream ->
            val buffer = ByteArray(65536)
            while (true) { val count = stream.read(buffer); if (count < 0) break; hash.update(buffer, 0, count) }
        }
        return hash.digest()
    }

    @Deprecated("Activity result compatibility for Flutter embedding")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 4201) return
        val result = pending ?: return
        val file = source
        pending = null; source = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || file == null) { result.success(null); return }
        Thread {
            try {
                val expected = digest(file.inputStream())
                contentResolver.openOutputStream(uri, "w")?.use { output -> file.inputStream().use { it.copyTo(output, 65536) }; output.flush() }
                    ?: error("Document provider did not provide a writable stream")
                val actual = contentResolver.openInputStream(uri)?.let { digest(it) } ?: error("Provider cannot verify the written file")
                require(expected.contentEquals(actual)) { "Export verification failed" }
                runOnUiThread { result.success(uri.toString()) }
            } catch (error: Exception) { runOnUiThread { result.error("EXPORT_PROVIDER_FAILED", error.message, null) } }
        }.start()
    }
}
