import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

/// Tracks which permissions have been granted.
/// Keys match requiredPermission in ToolDefinition.
final permissionStateProvider =
    StateNotifierProvider<PermissionNotifier, Set<String>>(
  (ref) => PermissionNotifier(),
);

class PermissionNotifier extends StateNotifier<Set<String>> {
  PermissionNotifier() : super({}) {
    refresh();
  }

  Future<void> refresh() async {
    final granted = <String>{};

    // Storage is checked via platform channel in _checkSpecialPermissions()
    // because permission_handler is unreliable on Android 13+ where
    // Permission.storage maps to READ_EXTERNAL_STORAGE (maxSdkVersion="32").

    if (await Permission.contacts.isGranted) {
      granted.add('contacts');
    }

    if (await Permission.calendarFullAccess.isGranted) {
      granted.add('calendar');
    }

    if (await Permission.location.isGranted) {
      granted.add('location');
    }

    if (await Permission.phone.isGranted) {
      granted.add('call_log');
    }

    // Usage stats and notifications require checking via platform channel
    // as permission_handler doesn't cover these. We check manually.
    granted.addAll(await _checkSpecialPermissions());

    state = granted;
  }

  Future<void> requestPermission(String permission) async {
    switch (permission) {
      case 'storage':
        await _requestStoragePermission();
        break;
      case 'contacts':
        final status = await Permission.contacts.request();
        if (status.isPermanentlyDenied) await openAppSettings();
        break;
      case 'calendar':
        final status = await Permission.calendarFullAccess.request();
        if (status.isPermanentlyDenied || status.isDenied) {
          await openAppSettings();
        }
        break;
      case 'location':
        final status = await Permission.location.request();
        if (status.isPermanentlyDenied) await openAppSettings();
        break;
      case 'call_log':
        // On older Android, phone permission covers call log.
        // Try both phone and call log permissions.
        final phoneStatus = await Permission.phone.request();
        if (phoneStatus.isPermanentlyDenied || phoneStatus.isDenied) {
          await openAppSettings();
        }
        break;
      case 'usage_stats':
        // Usage stats requires opening a specific Android Settings page
        try {
          const channel = MethodChannel('com.clawdphone.app/tools');
          await channel.invokeMethod('openUsageAccessSettings');
        } catch (_) {
          await openAppSettings();
        }
        break;
      case 'notifications':
        // Notification listener requires opening a specific Android Settings page
        try {
          const channel = MethodChannel('com.clawdphone.app/tools');
          await channel.invokeMethod('openNotificationListenerSettings');
        } catch (_) {
          await openAppSettings();
        }
        break;
    }
    // Always refresh after any permission request to pick up actual OS state
    await refresh();
  }

  Future<Set<String>> _checkSpecialPermissions() async {
    final granted = <String>{};
    try {
      const channel = MethodChannel('com.clawdphone.app/tools');

      // Check storage via platform channel — authoritative on all Android versions.
      // permission_handler's Permission.storage maps to READ_EXTERNAL_STORAGE which
      // has maxSdkVersion="32" and always returns false on Android 13+.
      final storageResult =
          await channel.invokeMethod<Map>('checkStoragePermission');
      if (storageResult != null) {
        final fullAccess = storageResult['full_access'] == true;
        final mediaAccess = storageResult['media_access'] == true;
        if (fullAccess || mediaAccess) {
          granted.add('storage');
        }
        if (fullAccess) {
          granted.add('storage_full');
        }
      }

      // Check usage stats access
      final hasUsageStats =
          await channel.invokeMethod<bool>('checkUsageStatsPermission') ??
              false;
      if (hasUsageStats) granted.add('usage_stats');

      // Check notification listener access
      final hasNotifications = await channel
              .invokeMethod<bool>('checkNotificationListenerPermission') ??
          false;
      if (hasNotifications) granted.add('notifications');

      // Double-check calendar via platform channel (permission_handler
      // can misreport on some older Samsung devices)
      final hasCalendar =
          await channel.invokeMethod<bool>('checkCalendarPermission') ?? false;
      if (hasCalendar) granted.add('calendar');

      // Double-check call log via platform channel
      final hasCallLog =
          await channel.invokeMethod<bool>('checkCallLogPermission') ?? false;
      if (hasCallLog) granted.add('call_log');
    } catch (_) {
      // Platform channel not available — fall back to permission_handler
      // for storage (best-effort on non-Android platforms).
      if (await Permission.storage.isGranted ||
          await Permission.manageExternalStorage.isGranted) {
        granted.add('storage');
      }
    }
    return granted;
  }

  Future<void> _requestStoragePermission() async {
    const channel = MethodChannel('com.clawdphone.app/tools');

    // Check current state via platform channel (authoritative).
    try {
      final current = await channel.invokeMethod<Map>('checkStoragePermission');
      if (current != null && current['full_access'] == true) {
        return; // Already have full access including documents/PDFs.
      }
    } catch (_) {
      // Fall through to permission_handler-based flow.
    }

    // On Android 12 and below, the legacy storage permission works fine
    // and grants access to all files including PDFs.
    final storageStatus = await Permission.storage.request();
    if (storageStatus.isGranted) {
      return;
    }

    // On Android 13+, Permission.storage.request() is a no-op (maxSdkVersion="32").
    // We need MANAGE_EXTERNAL_STORAGE for PDF/document access.
    // Open the All Files Access settings page — the user toggles it there.
    // When they return, didChangeAppLifecycleState → refresh() picks it up.
    try {
      await channel.invokeMethod('openAllFilesAccessSettings');
      // Do NOT check isGranted here — user hasn't toggled yet.
      // Do NOT request granular media permissions here — it would show
      // a dialog on top of the settings page, confusing the user.
      return;
    } catch (_) {
      // Opening All Files Access settings failed — fall back to requesting
      // granular media permissions. These won't cover PDFs but at least
      // enable image/video/audio tools.
      final result = await [
        Permission.photos,
        Permission.videos,
        Permission.audio,
      ].request();
      if (result.values.every((status) => status.isPermanentlyDenied)) {
        await openAppSettings();
      }
    }
  }
}

/// Permission metadata for the UI.
class PermissionInfo {
  final String key;
  final String title;
  final String description;
  final int icon;

  const PermissionInfo({
    required this.key,
    required this.title,
    required this.description,
    required this.icon,
  });
}

// Not using an import for Icons here — this is just data
const permissionInfoList = [
  PermissionInfo(
    key: 'storage',
    title: 'Files & Media',
    description:
        'Browse photos, videos, downloads, documents, check storage usage, and create files in the Clawd-Phone workspace with Full Access.',
    icon: 0xe2c7, // Icons.folder mapped as codepoint
  ),
  PermissionInfo(
    key: 'contacts',
    title: 'Contacts',
    description: 'Search contacts, find phone numbers, check for duplicates.',
    icon: 0xe7fd,
  ),
  PermissionInfo(
    key: 'calendar',
    title: 'Calendar',
    description: 'Show upcoming events, check for conflicts, analyze schedule.',
    icon: 0xe614,
  ),
  PermissionInfo(
    key: 'usage_stats',
    title: 'Usage Access',
    description: 'Show screen time, most-used apps, usage patterns.',
    icon: 0xe1b1,
  ),
  PermissionInfo(
    key: 'notifications',
    title: 'Notification Access',
    description: 'Read and summarize notifications, show what you missed.',
    icon: 0xe7f5,
  ),
  PermissionInfo(
    key: 'location',
    title: 'Location',
    description: 'Tell you where you are, find nearby things.',
    icon: 0xe55f,
  ),
  PermissionInfo(
    key: 'call_log',
    title: 'Call History',
    description: 'Show call history and analyze calling patterns.',
    icon: 0xe0b0,
  ),
];
