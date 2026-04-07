import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/claude_api.dart';

const _keyStorageKey = 'anthropic_api_key';
const _storage = FlutterSecureStorage();

/// Auth state: loading, noKey, valid, or invalid.
sealed class AuthState {
  const AuthState();
  const factory AuthState.loading() = AuthLoading;
  const factory AuthState.noKey() = AuthNoKey;
  const factory AuthState.valid(String apiKey) = AuthValid;
  const factory AuthState.invalid(String error) = AuthInvalid;

  T when<T>({
    required T Function() loading,
    required T Function() noKey,
    required T Function(String apiKey) valid,
    required T Function(String error) invalid,
  }) {
    return switch (this) {
      AuthLoading() => loading(),
      AuthNoKey() => noKey(),
      AuthValid(apiKey: final key) => valid(key),
      AuthInvalid(error: final err) => invalid(err),
    };
  }
}

class AuthLoading extends AuthState {
  const AuthLoading();
}

class AuthNoKey extends AuthState {
  const AuthNoKey();
}

class AuthValid extends AuthState {
  final String apiKey;
  const AuthValid(this.apiKey);
}

class AuthInvalid extends AuthState {
  final String error;
  const AuthInvalid(this.error);
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier() : super(const AuthState.loading()) {
    _loadKey();
  }

  Future<void> _loadKey() async {
    final key = await _storage.read(key: _keyStorageKey);
    if (key != null && key.isNotEmpty) {
      state = AuthState.valid(key);
    } else {
      state = const AuthState.noKey();
    }
  }

  /// Validate and save a new API key.
  Future<void> setApiKey(String key) async {
    state = const AuthState.loading();
    try {
      final api = ClaudeApi(apiKey: key);
      await api.createMessage(
        model: 'claude-haiku-4-5-20251001',
        messages: [
          {'role': 'user', 'content': 'hi'}
        ],
        maxTokens: 1,
      );
      await _storage.write(key: _keyStorageKey, value: key);
      state = AuthState.valid(key);
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        state = const AuthState.invalid(
            'Invalid API key. Double-check you copied the full key.');
      } else {
        state = AuthState.invalid('API error: ${e.message}');
      }
    } on RateLimitException {
      // Key is valid if we get rate limited
      await _storage.write(key: _keyStorageKey, value: key);
      state = AuthState.valid(key);
    } catch (e) {
      state = const AuthState.invalid(
          'Cannot reach Anthropic API. Check your internet connection.');
    }
  }

  Future<void> clearKey() async {
    await _storage.delete(key: _keyStorageKey);
    state = const AuthState.noKey();
  }

  String? get currentKey {
    return switch (state) {
      AuthValid(apiKey: final key) => key,
      _ => null,
    };
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(),
);
