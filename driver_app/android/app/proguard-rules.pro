# Proguard rules for driver_app
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Firebase obfuscation rules
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }

# Google Maps Proguard
-keep class com.google.maps.** { *; }
-keep class com.google.android.gms.maps.** { *; }

# Kotlin
-keep class kotlin.** { *; }
-keep class kotlinx.** { *; }

# Play Core Splitcompat / Deferred Components
-dontwarn com.google.android.play.core.**

# Razorpay Rules
-keepattributes *Annotation*
-dontwarn com.razorpay.**
-keep class com.razorpay.** {*;}
-optimizations !method/inlining/*
-keepclasseswithmembers class * {
  public void onPayment*(...);
}

