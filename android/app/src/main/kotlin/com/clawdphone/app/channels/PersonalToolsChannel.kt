package com.clawdphone.app.channels

import android.Manifest
import android.app.Activity
import android.content.ContentResolver
import android.content.pm.PackageManager
import android.database.Cursor
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.content.Context
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.*

/**
 * Handles Contacts, Calendar, and Location tools.
 * Delegated from FileToolsChannel via onMethodCall.
 */
class PersonalToolsChannel(private val activity: Activity) {

    private val contentResolver: ContentResolver get() = activity.contentResolver

    fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "Contacts" -> handleContacts(call, result)
            "Calendar" -> handleCalendar(call, result)
            "Location" -> handleLocation(call, result)
            "CallLog" -> handleCallLog(call, result)
            "Notifications" -> handleNotifications(call, result)
            else -> result.notImplemented()
        }
    }

    // ─── CONTACTS ──────────────────────────────────────────────────────

    private fun handleContacts(call: MethodCall, result: MethodChannel.Result) {
        if (!hasPermission(Manifest.permission.READ_CONTACTS)) {
            return result.error("PERMISSION_DENIED", "Contacts permission not granted.", null)
        }
        try {
            val action = call.argument<String>("action") ?: "search"
            val response = when (action) {
                "search" -> searchContacts(call)
                "list" -> listContacts(call)
                "detail" -> contactDetail(call)
                "stats" -> contactStats()
                else -> searchContacts(call)
            }
            result.success(response.toString())
        } catch (e: Exception) {
            result.error("CONTACTS_ERROR", e.message, null)
        }
    }

    private fun searchContacts(call: MethodCall): JSONObject {
        val query = call.argument<String>("query") ?: ""
        val limit = call.argument<Int>("limit") ?: 50
        val contacts = JSONArray()

        val selection = "${ContactsContract.Contacts.DISPLAY_NAME_PRIMARY} LIKE ?"
        val selectionArgs = arrayOf("%$query%")
        val sortOrder = "${ContactsContract.Contacts.DISPLAY_NAME_PRIMARY} ASC LIMIT $limit"

        contentResolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            arrayOf(
                ContactsContract.Contacts._ID,
                ContactsContract.Contacts.DISPLAY_NAME_PRIMARY,
                ContactsContract.Contacts.HAS_PHONE_NUMBER,
                ContactsContract.Contacts.STARRED,
                ContactsContract.Contacts.TIMES_CONTACTED,
                ContactsContract.Contacts.LAST_TIME_CONTACTED,
            ),
            selection, selectionArgs, sortOrder
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getString(0)
                val name = cursor.getString(1) ?: "Unknown"
                val hasPhone = cursor.getInt(2) > 0
                val starred = cursor.getInt(3) > 0

                val contact = JSONObject().apply {
                    put("id", id)
                    put("name", name)
                    put("starred", starred)
                }

                // Get phone numbers
                if (hasPhone) {
                    val phones = getPhoneNumbers(id)
                    if (phones.length() > 0) contact.put("phones", phones)
                }

                // Get emails
                val emails = getEmails(id)
                if (emails.length() > 0) contact.put("emails", emails)

                contacts.put(contact)
            }
        }

        // Also search by phone number if query looks like a number
        if (query.any { it.isDigit() }) {
            val phoneUri = android.net.Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                android.net.Uri.encode(query)
            )
            try {
                contentResolver.query(
                    phoneUri,
                    arrayOf(
                        ContactsContract.PhoneLookup._ID,
                        ContactsContract.PhoneLookup.DISPLAY_NAME,
                        ContactsContract.PhoneLookup.NUMBER,
                    ),
                    null, null, null
                )?.use { cursor ->
                    while (cursor.moveToNext()) {
                        val id = cursor.getString(0)
                        // Check if already in results
                        var exists = false
                        for (i in 0 until contacts.length()) {
                            if (contacts.getJSONObject(i).getString("id") == id) {
                                exists = true
                                break
                            }
                        }
                        if (!exists) {
                            contacts.put(JSONObject().apply {
                                put("id", id)
                                put("name", cursor.getString(1) ?: "Unknown")
                                put("phones", JSONArray().put(cursor.getString(2)))
                            })
                        }
                    }
                }
            } catch (_: Exception) { /* phone lookup may fail on some devices */ }
        }

        return JSONObject().apply {
            put("contacts", contacts)
            put("count", contacts.length())
            put("query", query)
        }
    }

    private fun listContacts(call: MethodCall): JSONObject {
        val limit = call.argument<Int>("limit") ?: 50
        val sortBy = call.argument<String>("sort_by") ?: "name"
        val contacts = JSONArray()

        val sortOrder = when (sortBy) {
            "last_contacted" -> "${ContactsContract.Contacts.LAST_TIME_CONTACTED} DESC LIMIT $limit"
            "times_contacted" -> "${ContactsContract.Contacts.TIMES_CONTACTED} DESC LIMIT $limit"
            else -> "${ContactsContract.Contacts.DISPLAY_NAME_PRIMARY} ASC LIMIT $limit"
        }

        contentResolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            arrayOf(
                ContactsContract.Contacts._ID,
                ContactsContract.Contacts.DISPLAY_NAME_PRIMARY,
                ContactsContract.Contacts.HAS_PHONE_NUMBER,
                ContactsContract.Contacts.STARRED,
            ),
            null, null, sortOrder
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getString(0)
                val name = cursor.getString(1) ?: "Unknown"
                val hasPhone = cursor.getInt(2) > 0

                val contact = JSONObject().apply {
                    put("id", id)
                    put("name", name)
                    put("starred", cursor.getInt(3) > 0)
                }

                if (hasPhone) {
                    val phones = getPhoneNumbers(id)
                    if (phones.length() > 0) contact.put("phones", phones)
                }

                contacts.put(contact)
            }
        }

        return JSONObject().apply {
            put("contacts", contacts)
            put("count", contacts.length())
        }
    }

    private fun contactDetail(call: MethodCall): JSONObject {
        val contactId = call.argument<String>("contact_id")
            ?: return JSONObject().put("error", "contact_id required")

        val contact = JSONObject()

        // Basic info
        contentResolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            null,
            "${ContactsContract.Contacts._ID} = ?",
            arrayOf(contactId),
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                contact.put("id", contactId)
                contact.put("name", cursor.getString(cursor.getColumnIndexOrThrow(ContactsContract.Contacts.DISPLAY_NAME_PRIMARY)) ?: "Unknown")
                contact.put("starred", cursor.getInt(cursor.getColumnIndexOrThrow(ContactsContract.Contacts.STARRED)) > 0)
            }
        }

        // Phones, emails, addresses, organizations
        contact.put("phones", getPhoneNumbers(contactId))
        contact.put("emails", getEmails(contactId))
        contact.put("addresses", getAddresses(contactId))
        contact.put("organization", getOrganization(contactId))
        contact.put("notes", getNotes(contactId))

        return contact
    }

    private fun contactStats(): JSONObject {
        var total = 0
        var withPhone = 0
        var withEmail = 0
        var starred = 0

        contentResolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            arrayOf(
                ContactsContract.Contacts._ID,
                ContactsContract.Contacts.HAS_PHONE_NUMBER,
                ContactsContract.Contacts.STARRED,
            ),
            null, null, null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                total++
                if (cursor.getInt(1) > 0) withPhone++
                if (cursor.getInt(2) > 0) starred++
            }
        }

        // Count contacts with emails
        contentResolver.query(
            ContactsContract.CommonDataKinds.Email.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Email.CONTACT_ID),
            null, null, null
        )?.use { cursor ->
            val seen = mutableSetOf<String>()
            while (cursor.moveToNext()) {
                cursor.getString(0)?.let { seen.add(it) }
            }
            withEmail = seen.size
        }

        return JSONObject().apply {
            put("total_contacts", total)
            put("with_phone", withPhone)
            put("with_email", withEmail)
            put("starred", starred)
        }
    }

    private fun getPhoneNumbers(contactId: String): JSONArray {
        val phones = JSONArray()
        contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER, ContactsContract.CommonDataKinds.Phone.TYPE),
            "${ContactsContract.CommonDataKinds.Phone.CONTACT_ID} = ?",
            arrayOf(contactId), null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                phones.put(cursor.getString(0))
            }
        }
        return phones
    }

    private fun getEmails(contactId: String): JSONArray {
        val emails = JSONArray()
        contentResolver.query(
            ContactsContract.CommonDataKinds.Email.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Email.ADDRESS),
            "${ContactsContract.CommonDataKinds.Email.CONTACT_ID} = ?",
            arrayOf(contactId), null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                emails.put(cursor.getString(0))
            }
        }
        return emails
    }

    private fun getAddresses(contactId: String): JSONArray {
        val addresses = JSONArray()
        contentResolver.query(
            ContactsContract.CommonDataKinds.StructuredPostal.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.StructuredPostal.FORMATTED_ADDRESS),
            "${ContactsContract.CommonDataKinds.StructuredPostal.CONTACT_ID} = ?",
            arrayOf(contactId), null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                addresses.put(cursor.getString(0))
            }
        }
        return addresses
    }

    private fun getOrganization(contactId: String): JSONObject? {
        contentResolver.query(
            ContactsContract.Data.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Organization.COMPANY,
                ContactsContract.CommonDataKinds.Organization.TITLE,
            ),
            "${ContactsContract.Data.CONTACT_ID} = ? AND ${ContactsContract.Data.MIMETYPE} = ?",
            arrayOf(contactId, ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE),
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val company = cursor.getString(0)
                val title = cursor.getString(1)
                if (company != null || title != null) {
                    return JSONObject().apply {
                        if (company != null) put("company", company)
                        if (title != null) put("title", title)
                    }
                }
            }
        }
        return null
    }

    private fun getNotes(contactId: String): String? {
        contentResolver.query(
            ContactsContract.Data.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Note.NOTE),
            "${ContactsContract.Data.CONTACT_ID} = ? AND ${ContactsContract.Data.MIMETYPE} = ?",
            arrayOf(contactId, ContactsContract.CommonDataKinds.Note.CONTENT_ITEM_TYPE),
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
        return null
    }

    // ─── CALENDAR ──────────────────────────────────────────────────────

    private fun handleCalendar(call: MethodCall, result: MethodChannel.Result) {
        if (!hasPermission(Manifest.permission.READ_CALENDAR)) {
            return result.error("PERMISSION_DENIED", "Calendar permission not granted.", null)
        }
        try {
            val action = call.argument<String>("action") ?: "upcoming"
            val response = when (action) {
                "upcoming" -> upcomingEvents(call)
                "today" -> todayEvents(call)
                "range" -> rangeEvents(call)
                "search" -> searchEvents(call)
                "stats" -> calendarStats()
                else -> upcomingEvents(call)
            }
            result.success(response.toString())
        } catch (e: Exception) {
            result.error("CALENDAR_ERROR", e.message, null)
        }
    }

    private fun upcomingEvents(call: MethodCall): JSONObject {
        val limit = call.argument<Int>("limit") ?: 20
        val now = System.currentTimeMillis()
        val oneWeek = now + 7L * 24 * 60 * 60 * 1000

        return queryEvents(now, oneWeek, null, limit)
    }

    private fun todayEvents(call: MethodCall): JSONObject {
        val cal = Calendar.getInstance()
        cal.set(Calendar.HOUR_OF_DAY, 0)
        cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0)
        val dayStart = cal.timeInMillis
        cal.add(Calendar.DAY_OF_MONTH, 1)
        val dayEnd = cal.timeInMillis
        val limit = call.argument<Int>("limit") ?: 20

        return queryEvents(dayStart, dayEnd, null, limit)
    }

    private fun rangeEvents(call: MethodCall): JSONObject {
        val dateFrom = call.argument<String>("date_from")
        val dateTo = call.argument<String>("date_to")
        val limit = call.argument<Int>("limit") ?: 20

        val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        val from = if (dateFrom != null) sdf.parse(dateFrom)?.time ?: System.currentTimeMillis()
        else System.currentTimeMillis()
        val to = if (dateTo != null) sdf.parse(dateTo)?.time ?: (from + 7L * 24 * 60 * 60 * 1000)
        else from + 7L * 24 * 60 * 60 * 1000

        return queryEvents(from, to, null, limit)
    }

    private fun searchEvents(call: MethodCall): JSONObject {
        val query = call.argument<String>("query") ?: ""
        val limit = call.argument<Int>("limit") ?: 20
        val now = System.currentTimeMillis()
        val sixMonths = now + 180L * 24 * 60 * 60 * 1000

        return queryEvents(now - 30L * 24 * 60 * 60 * 1000, sixMonths, query, limit)
    }

    private fun queryEvents(dtStart: Long, dtEnd: Long, titleQuery: String?, limit: Int): JSONObject {
        val events = JSONArray()
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.US)

        val projection = arrayOf(
            CalendarContract.Events._ID,
            CalendarContract.Events.TITLE,
            CalendarContract.Events.DESCRIPTION,
            CalendarContract.Events.DTSTART,
            CalendarContract.Events.DTEND,
            CalendarContract.Events.EVENT_LOCATION,
            CalendarContract.Events.ALL_DAY,
            CalendarContract.Events.CALENDAR_DISPLAY_NAME,
            CalendarContract.Events.STATUS,
        )

        var selection = "${CalendarContract.Events.DTSTART} >= ? AND ${CalendarContract.Events.DTSTART} <= ?"
        val selArgs = mutableListOf(dtStart.toString(), dtEnd.toString())

        if (!titleQuery.isNullOrBlank()) {
            selection += " AND ${CalendarContract.Events.TITLE} LIKE ?"
            selArgs.add("%$titleQuery%")
        }

        val sortOrder = "${CalendarContract.Events.DTSTART} ASC LIMIT $limit"

        contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            projection, selection, selArgs.toTypedArray(), sortOrder
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val start = cursor.getLong(3)
                val end = cursor.getLong(4)
                val allDay = cursor.getInt(6) > 0

                events.put(JSONObject().apply {
                    put("id", cursor.getString(0))
                    put("title", cursor.getString(1) ?: "(No title)")
                    val desc = cursor.getString(2)
                    if (!desc.isNullOrBlank()) put("description", desc)
                    put("start", sdf.format(Date(start)))
                    if (end > 0) put("end", sdf.format(Date(end)))
                    val loc = cursor.getString(5)
                    if (!loc.isNullOrBlank()) put("location", loc)
                    put("all_day", allDay)
                    put("calendar", cursor.getString(7) ?: "")
                    val durationMin = if (end > start) (end - start) / 60000 else 0
                    if (!allDay && durationMin > 0) put("duration_minutes", durationMin)
                })
            }
        }

        return JSONObject().apply {
            put("events", events)
            put("count", events.length())
        }
    }

    private fun calendarStats(): JSONObject {
        val now = System.currentTimeMillis()
        val oneMonth = now + 30L * 24 * 60 * 60 * 1000

        // Count upcoming events
        var upcoming = 0
        contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            arrayOf(CalendarContract.Events._ID),
            "${CalendarContract.Events.DTSTART} >= ? AND ${CalendarContract.Events.DTSTART} <= ?",
            arrayOf(now.toString(), oneMonth.toString()),
            null
        )?.use { cursor -> upcoming = cursor.count }

        // Count calendars
        val calendars = JSONArray()
        contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            arrayOf(
                CalendarContract.Calendars._ID,
                CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
                CalendarContract.Calendars.ACCOUNT_NAME,
            ),
            null, null, null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                calendars.put(JSONObject().apply {
                    put("name", cursor.getString(1) ?: "Unknown")
                    put("account", cursor.getString(2) ?: "")
                })
            }
        }

        return JSONObject().apply {
            put("upcoming_30_days", upcoming)
            put("calendars", calendars)
            put("calendar_count", calendars.length())
        }
    }

    // ─── LOCATION ──────────────────────────────────────────────────────

    private fun handleLocation(call: MethodCall, result: MethodChannel.Result) {
        if (!hasPermission(Manifest.permission.ACCESS_FINE_LOCATION) &&
            !hasPermission(Manifest.permission.ACCESS_COARSE_LOCATION)) {
            return result.error("PERMISSION_DENIED", "Location permission not granted.", null)
        }
        try {
            val includeAddress = call.argument<Boolean>("include_address") ?: true
            val locationManager = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager

            // Try cached location first (fast)
            var location: Location? = null
            for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)) {
                try {
                    if (locationManager.isProviderEnabled(provider)) {
                        @Suppress("DEPRECATION")
                        location = locationManager.getLastKnownLocation(provider)
                        if (location != null) break
                    }
                } catch (_: SecurityException) { }
            }

            if (location != null) {
                // Have cached location — return immediately
                result.success(buildLocationResponse(location, includeAddress).toString())
                return
            }

            // No cached location — request fresh one asynchronously.
            // Platform channel calls run on main thread, so we must NOT block.
            // Instead, use requestSingleUpdate with a callback that returns the result.
            val provider = when {
                locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
                locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
                else -> null
            }
            if (provider == null) {
                result.success(JSONObject().apply {
                    put("error", "No location provider available. Enable GPS or network location in Settings.")
                }.toString())
                return
            }

            // Timeout handler — if no location received within 15s, return error
            val handler = android.os.Handler(android.os.Looper.getMainLooper())
            var responded = false
            val timeoutRunnable = Runnable {
                if (!responded) {
                    responded = true
                    result.success(JSONObject().apply {
                        put("error", "Location request timed out. Try again outdoors or check that GPS is enabled.")
                    }.toString())
                }
            }
            handler.postDelayed(timeoutRunnable, 15000)

            try {
                @Suppress("DEPRECATION")
                locationManager.requestSingleUpdate(provider, object : android.location.LocationListener {
                    override fun onLocationChanged(loc: Location) {
                        if (!responded) {
                            responded = true
                            handler.removeCallbacks(timeoutRunnable)
                            result.success(buildLocationResponse(loc, includeAddress).toString())
                        }
                    }
                    @Suppress("DEPRECATION")
                    override fun onStatusChanged(p: String?, s: Int, b: android.os.Bundle?) {}
                    override fun onProviderEnabled(p: String) {}
                    override fun onProviderDisabled(p: String) {
                        if (!responded) {
                            responded = true
                            handler.removeCallbacks(timeoutRunnable)
                            result.success(JSONObject().apply {
                                put("error", "Location provider was disabled. Enable GPS in Settings.")
                            }.toString())
                        }
                    }
                }, android.os.Looper.getMainLooper())
            } catch (e: SecurityException) {
                responded = true
                handler.removeCallbacks(timeoutRunnable)
                result.error("LOCATION_ERROR", "Location permission denied: ${e.message}", null)
            }
        } catch (e: Exception) {
            result.error("LOCATION_ERROR", e.message, null)
        }
    }

    private fun buildLocationResponse(location: Location, includeAddress: Boolean): JSONObject {
        val response = JSONObject().apply {
            put("latitude", location.latitude)
            put("longitude", location.longitude)
            put("accuracy_meters", location.accuracy)
            put("altitude_meters", if (location.hasAltitude()) location.altitude else JSONObject.NULL)
            put("speed_mps", if (location.hasSpeed()) location.speed else JSONObject.NULL)
            put("provider", location.provider)
            put("timestamp", SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.US).format(Date(location.time)))
        }

        if (includeAddress) {
            try {
                val geocoder = Geocoder(activity, Locale.getDefault())
                @Suppress("DEPRECATION")
                val addresses = geocoder.getFromLocation(location.latitude, location.longitude, 1)
                if (!addresses.isNullOrEmpty()) {
                    val addr = addresses[0]
                    response.put("address", JSONObject().apply {
                        if (addr.getAddressLine(0) != null) put("full", addr.getAddressLine(0))
                        if (addr.locality != null) put("city", addr.locality)
                        if (addr.adminArea != null) put("state", addr.adminArea)
                        if (addr.countryName != null) put("country", addr.countryName)
                        if (addr.postalCode != null) put("postal_code", addr.postalCode)
                    })
                }
            } catch (_: Exception) {
                response.put("address_error", "Geocoding not available")
            }
        }

        return response
    }

    // ─── NOTIFICATIONS ──────────────────────────────────────────────────

    private fun handleNotifications(call: MethodCall, result: MethodChannel.Result) {
        // Check if notification listener is enabled
        val flat = android.provider.Settings.Secure.getString(
            activity.contentResolver,
            "enabled_notification_listeners"
        )
        if (flat == null || !flat.contains(activity.packageName)) {
            return result.error("PERMISSION_DENIED",
                "Notification access not granted. Go to Settings > Notification Access and enable this app.", null)
        }

        try {
            val action = call.argument<String>("action") ?: "current"
            val packageFilter = call.argument<String>("package_filter")
            val limit = call.argument<Int>("limit") ?: 30

            // Get the active NotificationListenerService instance
            val serviceInstance = com.clawdphone.app.services.NotificationService.instance
            if (serviceInstance == null) {
                return result.success(JSONObject().apply {
                    put("error", "Notification listener service not active. Try toggling notification access off and on in Settings.")
                }.toString())
            }

            val activeNotifications = serviceInstance.activeNotifications ?: emptyArray()
            val notifications = JSONArray()
            val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.US)

            for (sbn in activeNotifications) {
                if (notifications.length() >= limit) break
                if (packageFilter != null && sbn.packageName != packageFilter) continue

                val extras = sbn.notification.extras
                notifications.put(JSONObject().apply {
                    put("app", sbn.packageName)
                    put("title", extras?.getCharSequence("android.title")?.toString() ?: "")
                    put("text", extras?.getCharSequence("android.text")?.toString() ?: "")
                    put("time", sdf.format(Date(sbn.postTime)))
                    put("ongoing", sbn.isOngoing)
                })
            }

            result.success(JSONObject().apply {
                put("notifications", notifications)
                put("count", notifications.length())
                put("total_active", activeNotifications.size)
            }.toString())
        } catch (e: Exception) {
            result.error("NOTIFICATIONS_ERROR", e.message, null)
        }
    }

    // ─── CALL LOG ───────────────────────────────────────────────────────

    private fun handleCallLog(call: MethodCall, result: MethodChannel.Result) {
        if (!hasPermission(Manifest.permission.READ_CALL_LOG) &&
            !hasPermission(Manifest.permission.READ_PHONE_STATE)) {
            return result.error("PERMISSION_DENIED", "Call log permission not granted.", null)
        }
        try {
            val action = call.argument<String>("action") ?: "recent"
            val response = when (action) {
                "recent" -> recentCalls(call)
                "search" -> searchCalls(call)
                "stats" -> callStats(call)
                "frequent" -> frequentContacts(call)
                else -> recentCalls(call)
            }
            result.success(response.toString())
        } catch (e: Exception) {
            result.error("CALLLOG_ERROR", e.message, null)
        }
    }

    private fun recentCalls(call: MethodCall): JSONObject {
        val limit = call.argument<Int>("limit") ?: 30
        val callType = call.argument<String>("call_type") ?: "all"
        val dateAfter = call.argument<String>("date_after")
        val calls = JSONArray()
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.US)

        val selection = StringBuilder()
        val selectionArgs = mutableListOf<String>()

        if (callType != "all") {
            val typeVal = when (callType) {
                "incoming" -> android.provider.CallLog.Calls.INCOMING_TYPE.toString()
                "outgoing" -> android.provider.CallLog.Calls.OUTGOING_TYPE.toString()
                "missed" -> android.provider.CallLog.Calls.MISSED_TYPE.toString()
                else -> null
            }
            if (typeVal != null) {
                selection.append("${android.provider.CallLog.Calls.TYPE} = ?")
                selectionArgs.add(typeVal)
            }
        }

        if (!dateAfter.isNullOrEmpty()) {
            try {
                val sdfDate = SimpleDateFormat("yyyy-MM-dd", Locale.US)
                val millis = sdfDate.parse(dateAfter)?.time
                if (millis != null) {
                    if (selection.isNotEmpty()) selection.append(" AND ")
                    selection.append("${android.provider.CallLog.Calls.DATE} >= ?")
                    selectionArgs.add(millis.toString())
                }
            } catch (_: Exception) { }
        }

        contentResolver.query(
            android.provider.CallLog.Calls.CONTENT_URI,
            arrayOf(
                android.provider.CallLog.Calls.NUMBER,
                android.provider.CallLog.Calls.CACHED_NAME,
                android.provider.CallLog.Calls.TYPE,
                android.provider.CallLog.Calls.DATE,
                android.provider.CallLog.Calls.DURATION,
            ),
            selection.toString().ifEmpty { null },
            if (selectionArgs.isEmpty()) null else selectionArgs.toTypedArray(),
            "${android.provider.CallLog.Calls.DATE} DESC"
        )?.use { cursor ->
            while (cursor.moveToNext() && calls.length() < limit) {
                val typeInt = cursor.getInt(2)
                val typeName = when (typeInt) {
                    android.provider.CallLog.Calls.INCOMING_TYPE -> "incoming"
                    android.provider.CallLog.Calls.OUTGOING_TYPE -> "outgoing"
                    android.provider.CallLog.Calls.MISSED_TYPE -> "missed"
                    android.provider.CallLog.Calls.REJECTED_TYPE -> "rejected"
                    else -> "other"
                }
                val dateMillis = cursor.getLong(3)
                val durationSecs = cursor.getLong(4)

                calls.put(JSONObject().apply {
                    put("number", cursor.getString(0) ?: "Unknown")
                    put("name", cursor.getString(1) ?: "Unknown")
                    put("type", typeName)
                    put("date", sdf.format(Date(dateMillis)))
                    put("duration_seconds", durationSecs)
                    if (durationSecs >= 60) {
                        put("duration_human", "${durationSecs / 60}m ${durationSecs % 60}s")
                    } else {
                        put("duration_human", "${durationSecs}s")
                    }
                })
            }
        }

        return JSONObject().apply {
            put("calls", calls)
            put("count", calls.length())
        }
    }

    private fun searchCalls(call: MethodCall): JSONObject {
        val query = call.argument<String>("query") ?: ""
        val limit = call.argument<Int>("limit") ?: 30
        val calls = JSONArray()
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.US)

        val selection = "(${android.provider.CallLog.Calls.NUMBER} LIKE ? OR ${android.provider.CallLog.Calls.CACHED_NAME} LIKE ?)"
        val selectionArgs = arrayOf("%$query%", "%$query%")

        contentResolver.query(
            android.provider.CallLog.Calls.CONTENT_URI,
            arrayOf(
                android.provider.CallLog.Calls.NUMBER,
                android.provider.CallLog.Calls.CACHED_NAME,
                android.provider.CallLog.Calls.TYPE,
                android.provider.CallLog.Calls.DATE,
                android.provider.CallLog.Calls.DURATION,
            ),
            selection, selectionArgs,
            "${android.provider.CallLog.Calls.DATE} DESC"
        )?.use { cursor ->
            while (cursor.moveToNext() && calls.length() < limit) {
                val typeInt = cursor.getInt(2)
                val typeName = when (typeInt) {
                    android.provider.CallLog.Calls.INCOMING_TYPE -> "incoming"
                    android.provider.CallLog.Calls.OUTGOING_TYPE -> "outgoing"
                    android.provider.CallLog.Calls.MISSED_TYPE -> "missed"
                    else -> "other"
                }
                calls.put(JSONObject().apply {
                    put("number", cursor.getString(0) ?: "Unknown")
                    put("name", cursor.getString(1) ?: "Unknown")
                    put("type", typeName)
                    put("date", sdf.format(Date(cursor.getLong(3))))
                    put("duration_seconds", cursor.getLong(4))
                })
            }
        }

        return JSONObject().apply {
            put("calls", calls)
            put("count", calls.length())
            put("query", query)
        }
    }

    private fun callStats(call: MethodCall): JSONObject {
        var incoming = 0; var outgoing = 0; var missed = 0
        var totalDuration = 0L

        contentResolver.query(
            android.provider.CallLog.Calls.CONTENT_URI,
            arrayOf(
                android.provider.CallLog.Calls.TYPE,
                android.provider.CallLog.Calls.DURATION,
            ),
            null, null, null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                when (cursor.getInt(0)) {
                    android.provider.CallLog.Calls.INCOMING_TYPE -> incoming++
                    android.provider.CallLog.Calls.OUTGOING_TYPE -> outgoing++
                    android.provider.CallLog.Calls.MISSED_TYPE -> missed++
                }
                totalDuration += cursor.getLong(1)
            }
        }

        return JSONObject().apply {
            put("total_calls", incoming + outgoing + missed)
            put("incoming", incoming)
            put("outgoing", outgoing)
            put("missed", missed)
            put("total_duration_seconds", totalDuration)
            put("total_duration_human", "${totalDuration / 3600}h ${(totalDuration % 3600) / 60}m")
        }
    }

    private fun frequentContacts(call: MethodCall): JSONObject {
        val limit = call.argument<Int>("limit") ?: 10
        val freq = mutableMapOf<String, Pair<String, Int>>() // number → (name, count)

        contentResolver.query(
            android.provider.CallLog.Calls.CONTENT_URI,
            arrayOf(
                android.provider.CallLog.Calls.NUMBER,
                android.provider.CallLog.Calls.CACHED_NAME,
            ),
            null, null, null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val number = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: "Unknown"
                val entry = freq[number]
                freq[number] = Pair(name, (entry?.second ?: 0) + 1)
            }
        }

        val sorted = freq.entries.sortedByDescending { it.value.second }.take(limit)
        val contacts = JSONArray()
        for (entry in sorted) {
            contacts.put(JSONObject().apply {
                put("number", entry.key)
                put("name", entry.value.first)
                put("call_count", entry.value.second)
            })
        }

        return JSONObject().apply {
            put("frequent_contacts", contacts)
            put("count", contacts.length())
        }
    }

    // ─── HELPERS ───────────────────────────────────────────────────────

    private fun hasPermission(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(activity, permission) == PackageManager.PERMISSION_GRANTED
    }
}
