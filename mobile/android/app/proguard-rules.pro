# Flutter embedding and the native location bridge are reached by reflection.
-keep class io.flutter.** { *; }
-keep class com.example.goofyrider_mobile.** { *; }
-keep class com.google.android.gms.location.** { *; }
-dontwarn io.flutter.embedding.**
