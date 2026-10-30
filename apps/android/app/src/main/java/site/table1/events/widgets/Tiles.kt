package site.table1.events.widgets

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import site.table1.events.util.Telemetry

/* Quick Settings tiles (contract/widgets-2026-10-22.md § Controls): Android's Control Center controls. Life tracker opens
   a local life tracker straight away; Scan cards opens Add cards with the scanner up. Signed out, both open sign-in. */

abstract class OpenTile(private val url: String, private val control: String) : TileService() {
    override fun onStartListening() {
        qsTile?.apply { state = Tile.STATE_INACTIVE; updateTile() }
    }

    override fun onClick() {
        Telemetry.capture("control_used", mapOf("control" to control, "surface" to "tile"))
        val intent = Widgets.open(this, url)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, control.hashCode(), intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}

class TrackerTileService : OpenTile("table1://tracker?src=tile", "tracker")

class ScanTileService : OpenTile("table1://scan?src=tile", "scan")
