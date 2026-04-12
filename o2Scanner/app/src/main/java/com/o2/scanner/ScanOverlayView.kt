package com.o2.scanner

import android.content.Context
import android.graphics.*
import android.util.AttributeSet
import android.view.View
import androidx.core.content.ContextCompat

class ScanOverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private val backgroundPaint = Paint().apply {
        color = Color.parseColor("#99000000") // Semi-transparent black
        style = Paint.Style.FILL
    }

    private val framePaint = Paint().apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeWidth = 8f
    }

    private val successPaint = Paint().apply {
        color = Color.GREEN
        style = Paint.Style.STROKE
        strokeWidth = 8f
    }

    private val cornerPaint = Paint().apply {
        color = Color.WHITE
        style = Paint.Style.STROKE
        strokeWidth = 16f
        strokeCap = Paint.Cap.ROUND
    }

    private val textPaint = Paint().apply {
        color = Color.WHITE
        textSize = 48f
        textAlign = Paint.Align.CENTER
        isAntiAlias = true
    }

    private var isSuccess = false
    private val scanFrameRect = RectF()
    private val cornerLength = 80f

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val width = width.toFloat()
        val height = height.toFloat()

        // Calculate frame dimensions (square in center)
        val frameSize = (width * 0.7f).coerceAtMost(height * 0.5f)
        val left = (width - frameSize) / 2
        val top = (height - frameSize) / 2
        val right = left + frameSize
        val bottom = top + frameSize

        scanFrameRect.set(left, top, right, bottom)

        // Draw semi-transparent background
        val path = Path().apply {
            addRect(0f, 0f, width, height, Path.Direction.CW)
            addRect(scanFrameRect, Path.Direction.CCW)
        }
        canvas.drawPath(path, backgroundPaint)

        // Draw frame
        val currentPaint = if (isSuccess) successPaint else framePaint
        canvas.drawRect(scanFrameRect, currentPaint)

        // Draw corners
        drawCorners(canvas, currentPaint)

        // Draw instruction text
        val text = if (isSuccess) "✓ Scanned Successfully!" else "Align QR code within frame"
        canvas.drawText(text, width / 2, bottom + 100f, textPaint)
    }

    private fun drawCorners(canvas: Canvas, paint: Paint) {
        // Top-left corner
        canvas.drawLine(
            scanFrameRect.left,
            scanFrameRect.top,
            scanFrameRect.left + cornerLength,
            scanFrameRect.top,
            paint
        )
        canvas.drawLine(
            scanFrameRect.left,
            scanFrameRect.top,
            scanFrameRect.left,
            scanFrameRect.top + cornerLength,
            paint
        )

        // Top-right corner
        canvas.drawLine(
            scanFrameRect.right - cornerLength,
            scanFrameRect.top,
            scanFrameRect.right,
            scanFrameRect.top,
            paint
        )
        canvas.drawLine(
            scanFrameRect.right,
            scanFrameRect.top,
            scanFrameRect.right,
            scanFrameRect.top + cornerLength,
            paint
        )

        // Bottom-left corner
        canvas.drawLine(
            scanFrameRect.left,
            scanFrameRect.bottom - cornerLength,
            scanFrameRect.left,
            scanFrameRect.bottom,
            paint
        )
        canvas.drawLine(
            scanFrameRect.left,
            scanFrameRect.bottom,
            scanFrameRect.left + cornerLength,
            scanFrameRect.bottom,
            paint
        )

        // Bottom-right corner
        canvas.drawLine(
            scanFrameRect.right,
            scanFrameRect.bottom - cornerLength,
            scanFrameRect.right,
            scanFrameRect.bottom,
            paint
        )
        canvas.drawLine(
            scanFrameRect.right - cornerLength,
            scanFrameRect.bottom,
            scanFrameRect.right,
            scanFrameRect.bottom,
            paint
        )
    }

    fun showSuccess() {
        isSuccess = true
        invalidate()
    }

    fun reset() {
        isSuccess = false
        invalidate()
    }
}
