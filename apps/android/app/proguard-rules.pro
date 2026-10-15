# kotlinx.serialization keeps its generated serializers via the plugin; keep our DTOs' companions.
-keepclassmembers class site.table1.events.data.** { *** Companion; }
-keepclasseswithmembers class site.table1.events.data.** { kotlinx.serialization.KSerializer serializer(...); }
