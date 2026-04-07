import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'auth/auth_screen.dart';
import 'auth/auth_provider.dart';
import 'permissions/onboarding_permissions_screen.dart';
import 'sessions/session_list_screen.dart';
import 'sessions/session_provider.dart';
import 'settings/settings_provider.dart';
import 'settings/settings_screen.dart';

class ClaudeAssistantApp extends ConsumerWidget {
  const ClaudeAssistantApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return MaterialApp(
      title: 'Clawd Phone',
      debugShowCheckedModeBanner: false,
      themeMode: settings.themeMode,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: const _AppRouter(),
      routes: {
        '/auth': (_) => const AuthScreen(),
        '/home': (_) => const SessionListScreen(),
        '/settings': (_) => const SettingsScreen(),
        '/onboarding-permissions': (_) => const OnboardingPermissionsScreen(),
      },
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFD97706), // Anthropic amber
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      textTheme: GoogleFonts.interTextTheme(
        ThemeData(brightness: brightness).textTheme,
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

/// Routes to the correct initial screen based on auth + onboarding + session state.
class _AppRouter extends ConsumerWidget {
  const _AppRouter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);
    final sessions = ref.watch(sessionListProvider);
    final onboarded = ref.watch(permissionsOnboardedProvider);

    return authState.when(
      loading: () => const _SplashScreen(),
      noKey: () => const AuthScreen(),
      valid: (_) => onboarded.when(
        data: (done) {
          if (!done) return const OnboardingPermissionsScreen();
          return sessions.when(
            data: (list) => const SessionListScreen(),
            loading: () => const _SplashScreen(),
            error: (_, __) => const SessionListScreen(),
          );
        },
        loading: () => const _SplashScreen(),
        error: (_, __) => sessions.when(
          data: (list) => const SessionListScreen(),
          loading: () => const _SplashScreen(),
          error: (_, __) => const SessionListScreen(),
        ),
      ),
      invalid: (error) => AuthScreen(initialError: error),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.assistant,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Clawd Phone',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
    );
  }
}
