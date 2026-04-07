import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/session.dart';

const _uuid = Uuid();

/// Manages session persistence: create, save, resume, delete.
class SessionManager {
  late Directory _sessionsDir;
  List<SessionMeta> _sessions = [];
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    final appDir = await getApplicationDocumentsDirectory();
    _sessionsDir = Directory('${appDir.path}/sessions');
    if (!await _sessionsDir.exists()) {
      await _sessionsDir.create(recursive: true);
    }
    await _loadIndex();
    _initialized = true;
  }

  List<SessionMeta> get sessions => List.unmodifiable(_sessions);

  /// Create a new session.
  SessionMeta createSession({String title = 'New conversation', String model = 'claude-haiku-4-5-20251001'}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final meta = SessionMeta(
      id: _uuid.v4(),
      title: title,
      createdAt: now,
      lastActiveAt: now,
      model: model,
    );
    _sessions.insert(0, meta);
    _saveIndex();
    return meta;
  }

  /// Append an entry to a session's JSONL file.
  Future<void> appendEntry(String sessionId, SessionEntry entry) async {
    final file = File('${_sessionsDir.path}/$sessionId.jsonl');
    await file.writeAsString(
      '${entry.toJsonLine()}\n',
      mode: FileMode.append,
    );
  }

  /// Update session metadata.
  Future<void> updateMeta(SessionMeta updated) async {
    final index = _sessions.indexWhere((s) => s.id == updated.id);
    if (index != -1) {
      _sessions[index] = updated;
      await _saveIndex();
    }
  }

  /// Load all entries from a session file.
  Future<List<SessionEntry>> loadSession(String sessionId) async {
    final file = File('${_sessionsDir.path}/$sessionId.jsonl');
    if (!await file.exists()) return [];
    final lines = await file.readAsLines();
    return lines
        .where((line) => line.trim().isNotEmpty)
        .map((line) {
          try {
            return SessionEntry.fromJsonLine(line);
          } catch (_) {
            return null;
          }
        })
        .whereType<SessionEntry>()
        .toList();
  }

  /// Delete a session.
  Future<void> deleteSession(String sessionId) async {
    _sessions.removeWhere((s) => s.id == sessionId);
    final file = File('${_sessionsDir.path}/$sessionId.jsonl');
    if (await file.exists()) await file.delete();
    await _saveIndex();
  }

  /// Delete all sessions.
  Future<void> clearAll() async {
    _sessions.clear();
    final files = await _sessionsDir.list().toList();
    for (final file in files) {
      if (file is File) await file.delete();
    }
    await _saveIndex();
  }

  // --- Private ---

  Future<void> _loadIndex() async {
    final file = File('${_sessionsDir.path}/index.json');
    if (!await file.exists()) {
      _sessions = [];
      return;
    }
    try {
      final json = jsonDecode(await file.readAsString());
      final list = json['sessions'] as List?;
      _sessions = list
              ?.map((e) => SessionMeta.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      // Sort by most recent first
      _sessions.sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));
    } catch (_) {
      _sessions = [];
    }
  }

  Future<void> _saveIndex() async {
    final file = File('${_sessionsDir.path}/index.json');
    // Enforce max 100 sessions
    if (_sessions.length > 100) {
      final toRemove = _sessions.sublist(100);
      _sessions = _sessions.sublist(0, 100);
      for (final meta in toRemove) {
        final f = File('${_sessionsDir.path}/${meta.id}.jsonl');
        if (await f.exists()) await f.delete();
      }
    }
    await file.writeAsString(jsonEncode({
      'sessions': _sessions.map((s) => s.toJson()).toList(),
    }));
  }
}
