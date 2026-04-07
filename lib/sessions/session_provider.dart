import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/session.dart';
import 'session_manager.dart';

final sessionManagerProvider = Provider<SessionManager>((ref) {
  return SessionManager();
});

final sessionListProvider = FutureProvider<List<SessionMeta>>((ref) async {
  final manager = ref.read(sessionManagerProvider);
  await manager.init();
  return manager.sessions;
});
