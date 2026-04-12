package com.o2.scanner

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import android.view.View
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.o2.scanner.databinding.ActivityMainBinding
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var cameraExecutor: ExecutorService
    private var camera: Camera? = null
    private var imageAnalyzer: ImageAnalysis? = null
    private var isScanning = true
    private var scanStartTime: Long = 0

    companion object {
        private const val TAG = "O2Scanner"
        private const val CAMERA_PERMISSION_CODE = 100
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        cameraExecutor = Executors.newSingleThreadExecutor()

        setupUI()
        checkCameraPermission()

        // Track camera initialization
        (application as? ScannerApplication)?.trackCameraEvent("initialized")
    }

    private fun setupUI() {
        binding.btnToggleFlash.setOnClickListener {
            toggleFlashlight()
        }

        binding.btnHistory.setOnClickListener {
            Toast.makeText(this, "Scan history feature coming soon", Toast.LENGTH_SHORT).show()
        }
    }

    private fun checkCameraPermission() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            == PackageManager.PERMISSION_GRANTED
        ) {
            startCamera()
        } else {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.CAMERA),
                CAMERA_PERMISSION_CODE
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CAMERA_PERMISSION_CODE) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                startCamera()
                (application as? ScannerApplication)?.trackCameraEvent("permission_granted")
            } else {
                Toast.makeText(
                    this,
                    "Camera permission is required to scan QR codes",
                    Toast.LENGTH_LONG
                ).show()
                (application as? ScannerApplication)?.trackCameraEvent("permission_denied")
                finish()
            }
        }
    }

    private fun startCamera() {
        scanStartTime = System.currentTimeMillis()

        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)

        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()

            val preview = Preview.Builder()
                .build()
                .also {
                    it.setSurfaceProvider(binding.previewView.surfaceProvider)
                }

            imageAnalyzer = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also {
                    it.setAnalyzer(cameraExecutor, QRCodeAnalyzer { barcodes ->
                        if (isScanning && barcodes.isNotEmpty()) {
                            processScanResult(barcodes[0])
                        }
                    })
                }

            val cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA

            try {
                cameraProvider.unbindAll()
                camera = cameraProvider.bindToLifecycle(
                    this,
                    cameraSelector,
                    preview,
                    imageAnalyzer
                )
                (application as? ScannerApplication)?.trackCameraEvent("started", "Camera bound successfully")
            } catch (e: Exception) {
                Log.e(TAG, "Camera binding failed", e)
                Toast.makeText(this, "Failed to start camera: ${e.message}", Toast.LENGTH_SHORT)
                    .show()
                (application as? ScannerApplication)?.trackScanError("camera_binding_failed", e.message ?: "Unknown error")
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun processScanResult(barcode: Barcode) {
        isScanning = false

        // Calculate scan duration
        val scanDuration = System.currentTimeMillis() - scanStartTime

        // Vibrate on successful scan
        vibrate()

        runOnUiThread {
            binding.scanOverlay.showSuccess()
        }

        val rawValue = barcode.rawValue ?: ""
        val format = when (barcode.format) {
            Barcode.FORMAT_QR_CODE -> "QR Code"
            Barcode.FORMAT_CODE_128 -> "Code 128"
            Barcode.FORMAT_CODE_39 -> "Code 39"
            Barcode.FORMAT_CODE_93 -> "Code 93"
            Barcode.FORMAT_EAN_8 -> "EAN-8"
            Barcode.FORMAT_EAN_13 -> "EAN-13"
            Barcode.FORMAT_UPC_A -> "UPC-A"
            Barcode.FORMAT_UPC_E -> "UPC-E"
            else -> "Unknown"
        }

        Log.d(TAG, "Scanned: $rawValue (Format: $format, Duration: ${scanDuration}ms)")

        // Track scan event with OpenTelemetry
        (application as? ScannerApplication)?.trackScanEvent(
            scannedValue = rawValue,
            barcodeFormat = format,
            scanDurationMs = scanDuration,
            success = true
        )

        // Navigate to result activity
        val intent = Intent(this, ScanResultActivity::class.java).apply {
            putExtra("SCAN_RESULT", rawValue)
            putExtra("SCAN_FORMAT", format)
            putExtra("SCAN_DURATION", scanDuration)
        }
        startActivity(intent)

        // Reset scanning after a delay
        binding.root.postDelayed({
            isScanning = true
            scanStartTime = System.currentTimeMillis()
            binding.scanOverlay.reset()
        }, 2000)
    }

    private fun toggleFlashlight() {
        camera?.let {
            val currentState = it.cameraInfo.torchState.value == TorchState.ON
            it.cameraControl.enableTorch(!currentState)
            binding.btnToggleFlash.setImageResource(
                if (currentState) R.drawable.ic_flash_off else R.drawable.ic_flash_on
            )

            // Track flashlight usage
            (application as? ScannerApplication)?.trackCameraEvent(
                "flashlight_toggled",
                if (currentState) "off" else "on"
            )
        }
    }

    private fun vibrate() {
        val vibrator = getSystemService(VIBRATOR_SERVICE) as Vibrator
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createOneShot(200, VibrationEffect.DEFAULT_AMPLITUDE))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(200)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        cameraExecutor.shutdown()
        (application as? ScannerApplication)?.trackCameraEvent("stopped")
    }

    override fun onResume() {
        super.onResume()
        isScanning = true
        scanStartTime = System.currentTimeMillis()
        binding.scanOverlay.reset()
    }
}

// QR Code Analyzer using ML Kit
class QRCodeAnalyzer(
    private val onBarcodeDetected: (List<Barcode>) -> Unit
) : ImageAnalysis.Analyzer {

    private val scanner = BarcodeScanning.getClient(
        BarcodeScannerOptions.Builder()
            .setBarcodeFormats(
                Barcode.FORMAT_QR_CODE,
                Barcode.FORMAT_CODE_128,
                Barcode.FORMAT_CODE_39,
                Barcode.FORMAT_CODE_93,
                Barcode.FORMAT_EAN_8,
                Barcode.FORMAT_EAN_13,
                Barcode.FORMAT_UPC_A,
                Barcode.FORMAT_UPC_E
            )
            .build()
    )

    @androidx.camera.core.ExperimentalGetImage
    override fun analyze(imageProxy: ImageProxy) {
        val mediaImage = imageProxy.image
        if (mediaImage != null) {
            val image = InputImage.fromMediaImage(
                mediaImage,
                imageProxy.imageInfo.rotationDegrees
            )

            scanner.process(image)
                .addOnSuccessListener { barcodes ->
                    if (barcodes.isNotEmpty()) {
                        onBarcodeDetected(barcodes)
                    }
                }
                .addOnFailureListener {
                    Log.e("QRCodeAnalyzer", "Barcode scanning failed", it)
                }
                .addOnCompleteListener {
                    imageProxy.close()
                }
        } else {
            imageProxy.close()
        }
    }
}
