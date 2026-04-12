package com.o2.scanner

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.o2.scanner.databinding.ActivityScanResultBinding

class ScanResultActivity : AppCompatActivity() {

    private lateinit var binding: ActivityScanResultBinding
    private var scanResult: String = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityScanResultBinding.inflate(layoutInflater)
        setContentView(binding.root)

        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        supportActionBar?.title = "Scan Result"

        scanResult = intent.getStringExtra("SCAN_RESULT") ?: ""
        val scanFormat = intent.getStringExtra("SCAN_FORMAT") ?: "Unknown"

        binding.tvResult.text = scanResult
        binding.tvFormat.text = "Format: $scanFormat"

        setupButtons()
    }

    private fun setupButtons() {
        // Copy to clipboard
        binding.btnCopy.setOnClickListener {
            copyToClipboard()
        }

        // Share
        binding.btnShare.setOnClickListener {
            shareResult()
        }

        // Open as URL (if it's a URL)
        if (scanResult.startsWith("http://") || scanResult.startsWith("https://")) {
            binding.btnOpenUrl.visibility = android.view.View.VISIBLE
            binding.btnOpenUrl.setOnClickListener {
                openUrl()
            }
        }

        // Scan again
        binding.btnScanAgain.setOnClickListener {
            finish()
        }
    }

    private fun copyToClipboard() {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = ClipData.newPlainText("QR Code", scanResult)
        clipboard.setPrimaryClip(clip)
        Toast.makeText(this, "Copied to clipboard", Toast.LENGTH_SHORT).show()
    }

    private fun shareResult() {
        val shareIntent = Intent().apply {
            action = Intent.ACTION_SEND
            putExtra(Intent.EXTRA_TEXT, scanResult)
            type = "text/plain"
        }
        startActivity(Intent.createChooser(shareIntent, "Share QR Code"))
    }

    private fun openUrl() {
        try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(scanResult))
            startActivity(intent)
        } catch (e: Exception) {
            Toast.makeText(this, "Failed to open URL", Toast.LENGTH_SHORT).show()
        }
    }

    override fun onSupportNavigateUp(): Boolean {
        finish()
        return true
    }
}
