package dev.localpdf.local_pdf_editor

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.provider.DocumentsContract
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var source: File? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.localpdf/documents").setMethodCallHandler { call, result ->
            if (call.method == "openDocument") {
                if (pending != null) { result.error("EXPORT_BUSY", "Another picker is active", null); return@setMethodCallHandler }
                try {
                    pending = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/pdf"
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivityForResult(intent, 4200)
                } catch (error: Exception) {
                    pending = null
                    result.error("DOCUMENT_PICKER_FAILED", error.message, null)
                }
                return@setMethodCallHandler
            }
            if (call.method == "shareDocument") {
                try {
                    val uri = Uri.parse(call.argument<String>("uri") ?: error("Missing URI"))
                    require(uri.scheme == "content") { "A document URI is required" }
                    val intent = Intent(Intent.ACTION_SEND).apply {
                        type = call.argument<String>("mime") ?: "application/octet-stream"
                        putExtra(Intent.EXTRA_STREAM, uri)
                        clipData = android.content.ClipData.newRawUri("Folinq", uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivity(Intent.createChooser(intent, "分享文档"))
                    result.success(null)
                } catch (error: Exception) { result.error("SHARE_FAILED", error.message, null) }
                return@setMethodCallHandler
            }
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

    private fun importPdf(uri: Uri): File {
        var name = "document.pdf"
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) name = it.getString(0) ?: name
        }
        name = name.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_").take(120)
        if (!name.endsWith(".pdf", true)) name += ".pdf"
        val directory = File(filesDir, "imports/${UUID.randomUUID()}")
        check(directory.mkdirs()) { "Cannot create import directory" }
        val temporary = File(directory, "import.partial")
        try {
            contentResolver.openInputStream(uri)?.use { input ->
                temporary.outputStream().use { output ->
                    val buffer = ByteArray(65536)
                    var total = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= 256L * 1024 * 1024) { "FILE_LIMIT: maximum 256 MiB" }
                        output.write(buffer, 0, count)
                    }
                    output.fd.sync()
                }
            } ?: error("Cannot read selected document")
            temporary.inputStream().use {
                val header = ByteArray(5)
                require(it.read(header) == 5 && String(header, Charsets.US_ASCII) == "%PDF-") { "INVALID_PDF_HEADER" }
            }
            val destination = File(directory, name)
            check(temporary.renameTo(destination)) { "Cannot publish imported PDF" }
            return destination
        } catch (error: Exception) {
            temporary.delete()
            directory.delete()
            throw error
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
        if (requestCode != 4200 && requestCode != 4201) return
        val result = pending ?: return
        val file = source
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { pending = null; source = null; result.success(null); return }
        if (requestCode == 4200) {
            Thread {
                try {
                    val imported = importPdf(uri)
                    runOnUiThread { pending = null; result.success(imported.absolutePath) }
                } catch (error: Exception) {
                    runOnUiThread { pending = null; result.error("IMPORT_PROVIDER_FAILED", error.message, null) }
                }
            }.start()
            return
        }
        if (file == null) { pending = null; result.error("EXPORT_FAILED", "Prepared export missing", null); return }
        Thread {
            try {
                val expected = digest(file.inputStream())
                contentResolver.openOutputStream(uri, "wt")?.use { output -> file.inputStream().use { it.copyTo(output, 65536) }; output.flush() }
                    ?: error("Document provider did not provide a writable stream")
                val actual = contentResolver.openInputStream(uri)?.let { digest(it) } ?: error("Provider cannot verify the written file")
                require(expected.contentEquals(actual)) { "Export verification failed" }
                runOnUiThread { pending = null; source = null; result.success(uri.toString()) }
            } catch (error: Exception) {
                try { DocumentsContract.deleteDocument(contentResolver, uri) } catch (_: Exception) { }
                runOnUiThread { pending = null; source = null; result.error("EXPORT_PROVIDER_FAILED", error.message, null) }
            }
        }.start()
    }
}
