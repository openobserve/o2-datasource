# OpenTelemetry Integration Examples for Different App Types

Real-world examples showing how to integrate OpenTelemetry into different types of Android applications.

---

## Table of Contents

1. [QR Code Scanner App](#1-qr-code-scanner-app-o2-scanner-reference)
2. [E-Commerce Shopping App](#2-e-commerce-shopping-app)
3. [Social Media App](#3-social-media-app)
4. [Fitness Tracking App](#4-fitness-tracking-app)
5. [Food Delivery App](#5-food-delivery-app)
6. [Banking App](#6-banking-app)
7. [News Reader App](#7-news-reader-app)

---

## 1. QR Code Scanner App (O2 Scanner Reference)

### App Type
Warehouse/retail scanning application using camera to scan barcodes and QR codes.

### What to Track

**Auto-Instrumented (Automatic):**
- Activity lifecycle
- App crashes
- Camera permission requests

**Custom Events:**
- Scan events (format, duration, success rate)
- Camera operations (flashlight, focus)
- Inventory lookups

### Implementation

**File:** `ScannerApplication.kt`

```kotlin
package com.o2.scanner

import android.app.Application
import android.provider.Settings
import android.util.Log
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.agent.OpenTelemetryRumInitializer
import io.opentelemetry.api.common.AttributeKey.longKey
import io.opentelemetry.api.common.AttributeKey.stringKey

class ScannerApplication : Application() {

    var otelRum: OpenTelemetryRum? = null

    private val deviceId: String by lazy {
        Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
    }

    override fun onCreate() {
        super.onCreate()
        otelRum = initializeOpenTelemetry()
    }

    private fun initializeOpenTelemetry(): OpenTelemetryRum? {
        return try {
            OpenTelemetryRumInitializer.initialize(
                context = this,
                configuration = {
                    httpExport {
                        baseUrl = "https://introspection.dev.zinclabs.dev/api/default"
                        baseHeaders = mapOf(
                            "Authorization" to "Basic YOUR_TOKEN",
                            "stream-name" to "o2scanner"
                        )
                    }
                }
            )
        } catch (e: Exception) {
            Log.e("Scanner", "Failed to init telemetry", e)
            null
        }
    }

    // Track QR/Barcode scans
    fun trackScanEvent(
        scannedValue: String,
        barcodeFormat: String,
        scanDurationMs: Long,
        success: Boolean = true
    ) {
        val tracer = otelRum?.openTelemetry?.tracerProvider?.get("scanner")

        tracer?.spanBuilder("qr.scan")
            ?.setAttribute(stringKey("scan.format"), barcodeFormat)
            ?.setAttribute(stringKey("scan.value.length"), scannedValue.length.toString())
            ?.setAttribute(longKey("scan.duration_ms"), scanDurationMs)
            ?.setAttribute(stringKey("scan.status"), if (success) "success" else "failed")
            ?.setAttribute(stringKey("device.id"), deviceId)
            ?.startSpan()
            ?.end()
    }

    // Track camera operations
    fun trackCameraEvent(eventType: String, details: String = "") {
        val logger = otelRum?.openTelemetry?.logsBridge?.get("camera")

        logger?.logRecordBuilder()
            ?.setEventName("camera.$eventType")
            ?.setAttribute(stringKey("event.details"), details)
            ?.setAttribute(stringKey("device.id"), deviceId)
            ?.emit()
    }

    // Track scan errors
    fun trackScanError(errorType: String, errorMessage: String) {
        val logger = otelRum?.openTelemetry?.logsBridge?.get("scanner-errors")

        logger?.logRecordBuilder()
            ?.setEventName("scan.error")
            ?.setAttribute(stringKey("error.type"), errorType)
            ?.setAttribute(stringKey("error.message"), errorMessage)
            ?.setAttribute(stringKey("device.id"), deviceId)
            ?.emit()
    }
}
```

**Usage in MainActivity:**

```kotlin
class MainActivity : AppCompatActivity() {
    private var scanStartTime: Long = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        scanStartTime = System.currentTimeMillis()

        // Track camera initialization
        (application as? ScannerApplication)?.trackCameraEvent("initialized")
    }

    private fun onBarcodeDetected(barcode: Barcode) {
        val scanDuration = System.currentTimeMillis() - scanStartTime

        // Track successful scan
        (application as? ScannerApplication)?.trackScanEvent(
            scannedValue = barcode.rawValue ?: "",
            barcodeFormat = "QR Code",
            scanDurationMs = scanDuration,
            success = true
        )
    }
}
```

### Key Metrics Dashboard

- Total scans per device per day
- Average scan duration
- Scan success rate by format (QR, Code128, etc.)
- Camera permission denial rate
- Devices with scan errors

---

## 2. E-Commerce Shopping App

### App Type
Online shopping app with product catalog, cart, and checkout.

### What to Track

**Auto-Instrumented:**
- Activity lifecycle
- App crashes
- Network connectivity

**Custom Events:**
- Product views
- Add to cart
- Checkout steps
- Payment completion
- Search queries

### Implementation

```kotlin
package com.shop.app

import android.app.Application
import android.util.Log
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.agent.OpenTelemetryRumInitializer
import io.opentelemetry.api.common.AttributeKey.*

class ShoppingApplication : Application() {

    var otelRum: OpenTelemetryRum? = null

    override fun onCreate() {
        super.onCreate()
        otelRum = OpenTelemetryRumInitializer.initialize(context = this)
    }

    // Track product views
    fun trackProductView(
        productId: String,
        productName: String,
        category: String,
        price: Double,
        inStock: Boolean
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("ecommerce")
            ?.spanBuilder("product.viewed")
            ?.setAttribute(stringKey("product.id"), productId)
            ?.setAttribute(stringKey("product.name"), productName)
            ?.setAttribute(stringKey("product.category"), category)
            ?.setAttribute(doubleKey("product.price"), price)
            ?.setAttribute(booleanKey("product.in_stock"), inStock)
            ?.startSpan()
            ?.end()
    }

    // Track cart actions
    fun trackCartAction(action: String, itemCount: Int, totalValue: Double) {
        otelRum?.openTelemetry?.tracerProvider?.get("ecommerce")
            ?.spanBuilder("cart.$action")  // cart.add, cart.remove, cart.clear
            ?.setAttribute(longKey("cart.item_count"), itemCount.toLong())
            ?.setAttribute(doubleKey("cart.total_value"), totalValue)
            ?.startSpan()
            ?.end()
    }

    // Track search
    fun trackSearch(queryLength: Int, resultsCount: Int, categoryFilter: String?) {
        otelRum?.openTelemetry?.tracerProvider?.get("ecommerce")
            ?.spanBuilder("search.performed")
            ?.setAttribute(longKey("search.query_length"), queryLength.toLong())
            ?.setAttribute(longKey("search.results_count"), resultsCount.toLong())
            ?.setAttribute(stringKey("search.category"), categoryFilter ?: "all")
            ?.startSpan()
            ?.end()
    }

    // Track checkout flow
    fun trackCheckoutStep(step: String, success: Boolean, paymentMethod: String? = null) {
        val builder = otelRum?.openTelemetry?.tracerProvider?.get("ecommerce")
            ?.spanBuilder("checkout.$step")
            ?.setAttribute(booleanKey("success"), success)

        paymentMethod?.let {
            builder?.setAttribute(stringKey("payment.method"), it)
        }

        builder?.startSpan()?.end()
    }

    // Track purchase
    fun trackPurchase(
        orderId: String,
        totalAmount: Double,
        itemCount: Int,
        paymentMethod: String
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("ecommerce")
            ?.spanBuilder("purchase.completed")
            ?.setAttribute(stringKey("order.id"), orderId)
            ?.setAttribute(doubleKey("order.total"), totalAmount)
            ?.setAttribute(longKey("order.item_count"), itemCount.toLong())
            ?.setAttribute(stringKey("payment.method"), paymentMethod)
            ?.startSpan()
            ?.end()
    }
}
```

**Usage:**

```kotlin
// In ProductDetailActivity
override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)

    (application as ShoppingApplication).trackProductView(
        productId = product.id,
        productName = product.name,
        category = product.category,
        price = product.price,
        inStock = product.inStock
    )
}

// In CartActivity
private fun addToCart(product: Product) {
    cart.add(product)

    (application as ShoppingApplication).trackCartAction(
        action = "add",
        itemCount = cart.size,
        totalValue = cart.totalValue
    )
}

// In CheckoutActivity
private fun completePayment() {
    (application as ShoppingApplication).trackPurchase(
        orderId = order.id,
        totalAmount = order.total,
        itemCount = order.items.size,
        paymentMethod = "credit_card"
    )
}
```

---

## 3. Social Media App

### App Type
Social networking app with posts, comments, likes, and messaging.

### Implementation

```kotlin
package com.social.app

import android.app.Application
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.agent.OpenTelemetryRumInitializer
import io.opentelemetry.api.common.AttributeKey.*

class SocialApplication : Application() {

    var otelRum: OpenTelemetryRum? = null

    override fun onCreate() {
        super.onCreate()
        otelRum = OpenTelemetryRumInitializer.initialize(context = this)
    }

    // Track post creation
    fun trackPostCreated(
        postType: String,  // text, photo, video
        hasMedia: Boolean,
        characterCount: Int,
        hashtagCount: Int
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("social")
            ?.spanBuilder("post.created")
            ?.setAttribute(stringKey("post.type"), postType)
            ?.setAttribute(booleanKey("post.has_media"), hasMedia)
            ?.setAttribute(longKey("post.character_count"), characterCount.toLong())
            ?.setAttribute(longKey("post.hashtag_count"), hashtagCount.toLong())
            ?.startSpan()
            ?.end()
    }

    // Track social interactions
    fun trackInteraction(
        type: String,  // like, comment, share, repost
        targetType: String  // post, story, comment
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("social")
            ?.spanBuilder("social.$type")
            ?.setAttribute(stringKey("target.type"), targetType)
            ?.startSpan()
            ?.end()
    }

    // Track feed engagement
    fun trackFeedScroll(
        postsViewed: Int,
        scrollDepth: Int,  // Percentage
        timeSpentSeconds: Int
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("social")
            ?.spanBuilder("feed.scrolled")
            ?.setAttribute(longKey("feed.posts_viewed"), postsViewed.toLong())
            ?.setAttribute(longKey("feed.scroll_depth_percent"), scrollDepth.toLong())
            ?.setAttribute(longKey("feed.time_spent_seconds"), timeSpentSeconds.toLong())
            ?.startSpan()
            ?.end()
    }

    // Track messaging
    fun trackMessage(
        messageType: String,  // text, image, voice
        recipientCount: Int,
        isGroup: Boolean
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("social")
            ?.spanBuilder("message.sent")
            ?.setAttribute(stringKey("message.type"), messageType)
            ?.setAttribute(longKey("message.recipient_count"), recipientCount.toLong())
            ?.setAttribute(booleanKey("message.is_group"), isGroup)
            ?.startSpan()
            ?.end()
    }
}
```

---

## 4. Fitness Tracking App

### Implementation

```kotlin
package com.fitness.app

import android.app.Application
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.agent.OpenTelemetryRumInitializer
import io.opentelemetry.api.common.AttributeKey.*

class FitnessApplication : Application() {

    var otelRum: OpenTelemetryRum? = null

    override fun onCreate() {
        super.onCreate()
        otelRum = OpenTelemetryRumInitializer.initialize(context = this)
    }

    // Track workout start
    fun trackWorkoutStarted(
        workoutType: String,  // running, cycling, weights
        plannedDurationMinutes: Int,
        location: String  // outdoor, gym, home
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("fitness")
            ?.spanBuilder("workout.started")
            ?.setAttribute(stringKey("workout.type"), workoutType)
            ?.setAttribute(longKey("workout.planned_duration"), plannedDurationMinutes.toLong())
            ?.setAttribute(stringKey("workout.location"), location)
            ?.startSpan()
            ?.end()
    }

    // Track workout completion
    fun trackWorkoutCompleted(
        workoutType: String,
        actualDurationMinutes: Int,
        caloriesBurned: Int,
        averageHeartRate: Int?,
        distanceMeters: Int?,
        completed: Boolean  // true if finished, false if stopped early
    ) {
        val builder = otelRum?.openTelemetry?.tracerProvider?.get("fitness")
            ?.spanBuilder("workout.completed")
            ?.setAttribute(stringKey("workout.type"), workoutType)
            ?.setAttribute(longKey("workout.duration"), actualDurationMinutes.toLong())
            ?.setAttribute(longKey("workout.calories"), caloriesBurned.toLong())
            ?.setAttribute(booleanKey("workout.completed"), completed)

        averageHeartRate?.let {
            builder?.setAttribute(longKey("workout.avg_heart_rate"), it.toLong())
        }

        distanceMeters?.let {
            builder?.setAttribute(longKey("workout.distance_meters"), it.toLong())
        }

        builder?.startSpan()?.end()
    }

    // Track nutrition logging
    fun trackMealLogged(
        mealType: String,  // breakfast, lunch, dinner, snack
        calories: Int,
        protein: Int,
        carbs: Int,
        fats: Int
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("fitness")
            ?.spanBuilder("meal.logged")
            ?.setAttribute(stringKey("meal.type"), mealType)
            ?.setAttribute(longKey("meal.calories"), calories.toLong())
            ?.setAttribute(longKey("meal.protein_g"), protein.toLong())
            ?.setAttribute(longKey("meal.carbs_g"), carbs.toLong())
            ?.setAttribute(longKey("meal.fats_g"), fats.toLong())
            ?.startSpan()
            ?.end()
    }

    // Track goal achievement
    fun trackGoalAchieved(
        goalType: String,  // daily_steps, weekly_workouts, weight_loss
        targetValue: Int,
        actualValue: Int,
        achieved: Boolean
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("fitness")
            ?.spanBuilder("goal.checked")
            ?.setAttribute(stringKey("goal.type"), goalType)
            ?.setAttribute(longKey("goal.target"), targetValue.toLong())
            ?.setAttribute(longKey("goal.actual"), actualValue.toLong())
            ?.setAttribute(booleanKey("goal.achieved"), achieved)
            ?.startSpan()
            ?.end()
    }
}
```

---

## 5. Food Delivery App

### Implementation

```kotlin
package com.delivery.app

import android.app.Application
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.agent.OpenTelemetryRumInitializer
import io.opentelemetry.api.common.AttributeKey.*

class DeliveryApplication : Application() {

    var otelRum: OpenTelemetryRum? = null

    override fun onCreate() {
        super.onCreate()
        otelRum = OpenTelemetryRumInitializer.initialize(context = this)
    }

    // Track restaurant browsing
    fun trackRestaurantViewed(
        restaurantId: String,
        cuisineType: String,
        distance: Double,  // km
        rating: Double,
        deliveryTime: Int  // minutes
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("delivery")
            ?.spanBuilder("restaurant.viewed")
            ?.setAttribute(stringKey("restaurant.id"), restaurantId)
            ?.setAttribute(stringKey("restaurant.cuisine"), cuisineType)
            ?.setAttribute(doubleKey("restaurant.distance_km"), distance)
            ?.setAttribute(doubleKey("restaurant.rating"), rating)
            ?.setAttribute(longKey("restaurant.delivery_time_min"), deliveryTime.toLong())
            ?.startSpan()
            ?.end()
    }

    // Track order placement
    fun trackOrderPlaced(
        orderId: String,
        restaurantId: String,
        itemCount: Int,
        totalAmount: Double,
        deliveryFee: Double,
        estimatedDeliveryMinutes: Int
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("delivery")
            ?.spanBuilder("order.placed")
            ?.setAttribute(stringKey("order.id"), orderId)
            ?.setAttribute(stringKey("restaurant.id"), restaurantId)
            ?.setAttribute(longKey("order.item_count"), itemCount.toLong())
            ?.setAttribute(doubleKey("order.total"), totalAmount)
            ?.setAttribute(doubleKey("order.delivery_fee"), deliveryFee)
            ?.setAttribute(longKey("order.estimated_delivery_min"), estimatedDeliveryMinutes.toLong())
            ?.startSpan()
            ?.end()
    }

    // Track order status updates
    fun trackOrderStatus(
        orderId: String,
        status: String,  // confirmed, preparing, picked_up, delivered
        elapsedMinutes: Int
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("delivery")
            ?.spanBuilder("order.status_changed")
            ?.setAttribute(stringKey("order.id"), orderId)
            ?.setAttribute(stringKey("order.status"), status)
            ?.setAttribute(longKey("order.elapsed_minutes"), elapsedMinutes.toLong())
            ?.startSpan()
            ?.end()
    }

    // Track delivery tracking
    fun trackDeliveryTracking(
        orderId: String,
        driverDistance: Double,  // km from customer
        estimatedArrivalMinutes: Int
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("delivery")
            ?.spanBuilder("delivery.tracked")
            ?.setAttribute(stringKey("order.id"), orderId)
            ?.setAttribute(doubleKey("driver.distance_km"), driverDistance)
            ?.setAttribute(longKey("delivery.eta_minutes"), estimatedArrivalMinutes.toLong())
            ?.startSpan()
            ?.end()
    }
}
```

---

## 6. Banking App

### Implementation

```kotlin
package com.bank.app

import android.app.Application
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.agent.OpenTelemetryRumInitializer
import io.opentelemetry.api.common.AttributeKey.*

class BankingApplication : Application() {

    var otelRum: OpenTelemetryRum? = null

    override fun onCreate() {
        super.onCreate()
        otelRum = OpenTelemetryRumInitializer.initialize(context = this)
    }

    // Track login attempts
    fun trackLoginAttempt(
        method: String,  // password, fingerprint, face_id
        success: Boolean,
        failureReason: String? = null
    ) {
        val builder = otelRum?.openTelemetry?.tracerProvider?.get("banking")
            ?.spanBuilder("auth.login_attempt")
            ?.setAttribute(stringKey("auth.method"), method)
            ?.setAttribute(booleanKey("auth.success"), success)

        failureReason?.let {
            builder?.setAttribute(stringKey("auth.failure_reason"), it)
        }

        builder?.startSpan()?.end()
    }

    // Track account views (NO account numbers or balances!)
    fun trackAccountViewed(
        accountType: String,  // checking, savings, credit_card
        hasTransactions: Boolean
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("banking")
            ?.spanBuilder("account.viewed")
            ?.setAttribute(stringKey("account.type"), accountType)
            ?.setAttribute(booleanKey("account.has_transactions"), hasTransactions)
            ?.startSpan()
            ?.end()
    }

    // Track transfer initiation (NO amounts or account details!)
    fun trackTransferInitiated(
        transferType: String,  // internal, external, bill_pay
        success: Boolean
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("banking")
            ?.spanBuilder("transfer.initiated")
            ?.setAttribute(stringKey("transfer.type"), transferType)
            ?.setAttribute(booleanKey("transfer.success"), success)
            ?.startSpan()
            ?.end()
    }

    // Track feature usage
    fun trackFeatureUsed(featureName: String) {
        // deposit_check, pay_bill, view_statements, etc.
        otelRum?.openTelemetry?.tracerProvider?.get("banking")
            ?.spanBuilder("feature.used")
            ?.setAttribute(stringKey("feature.name"), featureName)
            ?.startSpan()
            ?.end()
    }
}
```

**⚠️ IMPORTANT for Banking/Finance Apps:**
- **NEVER** track account numbers, balances, transaction amounts
- **NEVER** track personal information (SSN, DOB, etc.)
- **ONLY** track feature usage and non-sensitive metadata
- Ensure compliance with PCI-DSS, GDPR, and local regulations

---

## 7. News Reader App

### Implementation

```kotlin
package com.news.app

import android.app.Application
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.agent.OpenTelemetryRumInitializer
import io.opentelemetry.api.common.AttributeKey.*

class NewsApplication : Application() {

    var otelRum: OpenTelemetryRum? = null

    override fun onCreate() {
        super.onCreate()
        otelRum = OpenTelemetryRumInitializer.initialize(context = this)
    }

    // Track article views
    fun trackArticleViewed(
        articleId: String,
        category: String,
        author: String,
        publishedDate: String,
        wordCount: Int,
        isPremium: Boolean
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("news")
            ?.spanBuilder("article.viewed")
            ?.setAttribute(stringKey("article.id"), articleId)
            ?.setAttribute(stringKey("article.category"), category)
            ?.setAttribute(stringKey("article.author"), author)
            ?.setAttribute(stringKey("article.published_date"), publishedDate)
            ?.setAttribute(longKey("article.word_count"), wordCount.toLong())
            ?.setAttribute(booleanKey("article.is_premium"), isPremium)
            ?.startSpan()
            ?.end()
    }

    // Track reading engagement
    fun trackReadingTime(
        articleId: String,
        timeSpentSeconds: Int,
        scrollDepthPercent: Int,
        completed: Boolean  // scrolled to end
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("news")
            ?.spanBuilder("article.read")
            ?.setAttribute(stringKey("article.id"), articleId)
            ?.setAttribute(longKey("reading.time_seconds"), timeSpentSeconds.toLong())
            ?.setAttribute(longKey("reading.scroll_depth"), scrollDepthPercent.toLong())
            ?.setAttribute(booleanKey("reading.completed"), completed)
            ?.startSpan()
            ?.end()
    }

    // Track article interactions
    fun trackArticleInteraction(
        articleId: String,
        action: String  // share, bookmark, like, comment
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("news")
            ?.spanBuilder("article.$action")
            ?.setAttribute(stringKey("article.id"), articleId)
            ?.startSpan()
            ?.end()
    }

    // Track feed refresh
    fun trackFeedRefresh(
        feedType: String,  // top_stories, personalized, category
        newArticlesCount: Int
    ) {
        otelRum?.openTelemetry?.tracerProvider?.get("news")
            ?.spanBuilder("feed.refreshed")
            ?.setAttribute(stringKey("feed.type"), feedType)
            ?.setAttribute(longKey("feed.new_articles"), newArticlesCount.toLong())
            ?.startSpan()
            ?.end()
    }
}
```

---

## Comparison Summary

| App Type | Auto Events | Custom Events | Complexity |
|----------|-------------|---------------|------------|
| **QR Scanner** | Activities, Crashes | Scan events, Camera ops | Low |
| **E-Commerce** | Activities, Crashes | Product views, Purchases | Medium |
| **Social Media** | Activities, Crashes | Posts, Likes, Messages | Medium |
| **Fitness** | Activities, Crashes | Workouts, Nutrition | Medium |
| **Food Delivery** | Activities, Crashes | Orders, Tracking | Medium-High |
| **Banking** | Activities, Crashes | Login, Feature usage | High (PII concerns) |
| **News** | Activities, Crashes | Article views, Reading time | Low-Medium |

---

## Common Patterns Across All Apps

### 1. Device Identification

```kotlin
private val deviceId: String by lazy {
    Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
}
```

Always include `device.id` for fleet tracking.

### 2. Error Tracking

```kotlin
fun trackError(errorType: String, context: String, errorMessage: String) {
    otelRum?.openTelemetry?.logsBridge?.get("errors")
        ?.logRecordBuilder()
        ?.setEventName("app.error")
        ?.setAttribute(stringKey("error.type"), errorType)
        ?.setAttribute(stringKey("error.context"), context)
        ?.setAttribute(stringKey("error.message"), errorMessage)
        ?.emit()
}
```

### 3. Feature Usage

```kotlin
fun trackFeature(featureName: String, details: Map<String, String> = emptyMap()) {
    val builder = otelRum?.openTelemetry?.tracerProvider?.get("app")
        ?.spanBuilder("feature.used")
        ?.setAttribute(stringKey("feature.name"), featureName)

    details.forEach { (key, value) ->
        builder?.setAttribute(stringKey(key), value)
    }

    builder?.startSpan()?.end()
}
```

---

## Next Steps

1. **Choose the example** closest to your app type
2. **Copy the Application class** structure
3. **Customize tracking methods** for your specific features
4. **Add tracking calls** in your Activities/Fragments
5. **Test and verify** data appears in your backend
6. **Create dashboards** for your key metrics

---

**Reference Implementation:** O2 Scanner (`ScannerApplication.kt`)
**Full Guide:** `OPENTELEMETRY_ANDROID_INTEGRATION_GUIDE.md`
**Quick Start:** `QUICK_START_GUIDE.md`
