# Video playback (better_player_plus / media3 / ExoPlayer).
# The plugin's own consumer-rules.pro already keeps its package and the
# ExoPlayer classes, and those *are* applied when R8 runs. They are repeated
# here because media3 loads classes reflectively and through service-loader in
# paths a consumer rule's `-keep class ...exoplayer.**` does not reach, and the
# failure mode is a ClassNotFoundException inside ExoPlayer at playback time —
# only in release and profile, since R8 does not run in debug.
-keep class uz.shs.better_player_plus.** { *; }
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# webview_flutter's Java<->JS bridge: the annotated methods are looked up by
# name at runtime, so R8 would strip them.
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# The Flutter plugin registrant is itself instantiated reflectively.
-keep class io.flutter.plugins.** { *; }

# work-runtime comes in with better_player_plus. Workers are instantiated by
# class name, and its Room database is built reflectively by
# Room.getGeneratedImplementation() — R8 full mode drops <init>() unless kept.
-keep class * extends androidx.work.ListenableWorker { <init>(...); }
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
