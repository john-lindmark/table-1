# kotlinx.serialization keeps its generated serializers via the plugin; keep our DTOs' companions.
-keepclassmembers class site.table1.events.data.** { *** Companion; }
-keepclasseswithmembers class site.table1.events.data.** { kotlinx.serialization.KSerializer serializer(...); }

# Home screen widgets: R8 merged NextEventWidget, ValueWidget and MatchWidget into one class, so Glance (which finds a
# widget's ids by its provider's class name) redrew every widget as Collection value on each Library sync. Keep every
# GlanceAppWidget whole and under its own name; ReleaseChecks in build.gradle.kts fails a release build that doesn't.
-keep class * extends androidx.glance.appwidget.GlanceAppWidget
