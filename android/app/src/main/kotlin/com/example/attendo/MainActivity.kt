package com.example.attendo

import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.util.Log
import java.io.File
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            removeObsoleteDebugSnapshots()
        }
        super.onCreate(savedInstanceState)
    }

    private fun removeObsoleteDebugSnapshots() {
        val flutterAssets = File(applicationInfo.dataDir, "app_flutter/flutter_assets")
        listOf("kernel_blob.bin", "isolate_snapshot_data", "vm_snapshot_data")
            .forEach { name ->
                val snapshot = File(flutterAssets, name)
                if (snapshot.exists() && !snapshot.delete()) {
                    Log.w("AttendoStorage", "Could not remove obsolete asset: $name")
                }
            }
    }
}
