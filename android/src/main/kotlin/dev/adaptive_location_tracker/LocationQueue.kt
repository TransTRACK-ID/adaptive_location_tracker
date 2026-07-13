package dev.adaptive_location_tracker

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

data class LocationEntry(
    val id: Long,
    val lat: Double,
    val lon: Double,
    val timestampSec: Double, // Unix seconds
    val accuracy: Double,
    val speed: Double, // m/s
    val heading: Double, // degrees, -1 if unavailable
    val altitude: Double,
    val battery: Int,
)

/** Offline queue for fixes that failed to send. One row per pending fix. */
class LocationQueue private constructor(context: Context) : SQLiteOpenHelper(
    context.applicationContext, DB_NAME, null, DB_VERSION,
) {
    companion object {
        private const val DB_NAME = "adaptive_location_tracker_queue.db"
        private const val DB_VERSION = 1

        @Volatile private var INSTANCE: LocationQueue? = null

        fun get(context: Context): LocationQueue =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: LocationQueue(context).also { INSTANCE = it }
            }
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS queue (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                lat       REAL    NOT NULL,
                lon       REAL    NOT NULL,
                timestamp REAL    NOT NULL,
                accuracy  REAL    DEFAULT 0,
                speed     REAL    DEFAULT 0,
                heading   REAL    DEFAULT -1,
                altitude  REAL    DEFAULT 0,
                battery   INTEGER DEFAULT 0
               )""",
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS idx_ts ON queue (timestamp)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {}

    fun enqueue(entry: LocationEntry) {
        ContentValues().apply {
            put("lat", entry.lat)
            put("lon", entry.lon)
            put("timestamp", entry.timestampSec)
            put("accuracy", entry.accuracy)
            put("speed", entry.speed)
            put("heading", entry.heading)
            put("altitude", entry.altitude)
            put("battery", entry.battery)
        }.also { writableDatabase.insert("queue", null, it) }
    }

    fun dequeueAll(): List<LocationEntry> {
        val list = mutableListOf<LocationEntry>()
        readableDatabase.rawQuery(
            "SELECT id,lat,lon,timestamp,accuracy,speed,heading,altitude,battery " +
                "FROM queue ORDER BY timestamp ASC",
            null,
        ).use { c ->
            while (c.moveToNext()) {
                list += LocationEntry(
                    id = c.getLong(0),
                    lat = c.getDouble(1),
                    lon = c.getDouble(2),
                    timestampSec = c.getDouble(3),
                    accuracy = c.getDouble(4),
                    speed = c.getDouble(5),
                    heading = c.getDouble(6),
                    altitude = c.getDouble(7),
                    battery = c.getInt(8),
                )
            }
        }
        return list
    }

    fun count(): Int {
        readableDatabase.rawQuery("SELECT COUNT(*) FROM queue", null).use { c ->
            return if (c.moveToFirst()) c.getInt(0) else 0
        }
    }

    fun delete(id: Long) {
        writableDatabase.delete("queue", "id = ?", arrayOf(id.toString()))
    }

    fun clear() {
        writableDatabase.delete("queue", null, null)
    }
}
