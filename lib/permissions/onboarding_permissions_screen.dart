import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'permission_provider.dart';

/// One-time permission onboarding shown after first API key entry.
/// Requests key permissions via system dialogs, then navigates to home.
class OnboardingPermissionsScreen extends ConsumerStatefulWidget {
  const OnboardingPermissionsScreen({super.key});

  @override
  ConsumerState<OnboardingPermissionsScreen> createState() =>
      _OnboardingPermissionsScreenState();
}

class _OnboardingPermissionsScreenState
    extends ConsumerState<OnboardingPermissionsScreen>
    with WidgetsBindingObserver {
  static const _settingsPermissions = ['usage_stats', 'notifications'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check permissions when user returns from system settings pages
    if (state == AppLifecycleState.resumed) {
      ref.read(permissionStateProvider.notifier).refresh();
    }
  }

  Future<void> _finish() async {
    // Mark onboarding as complete
    const storage = FlutterSecureStorage();
    await storage.write(key: 'permissions_onboarded', value: 'true');
    if (mounted) {
      Navigator.of(context).pushReplacementNamed('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    final granted = ref.watch(permissionStateProvider);
    final theme = Theme.of(context);
    final grantedCount =
        permissionInfoList.where((p) => granted.contains(p.key)).length;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 48),
              Icon(
                Icons.security,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Set Up Permissions',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Grant permissions so Claude can search your files, read contacts, check your calendar, and more. '
                'Everything is read-only except the app workspace, where it can create or edit text files in Download/Clawd-Phone. It still cannot delete anything.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // Permission list
              Expanded(
                child: ListView.builder(
                  itemCount: permissionInfoList.length,
                  itemBuilder: (context, index) {
                    final info = permissionInfoList[index];
                    final isGranted = granted.contains(info.key);
                    final isSettings = _settingsPermissions.contains(info.key);

                    return ListTile(
                      leading: Icon(
                        IconData(info.icon, fontFamily: 'MaterialIcons'),
                        color: isGranted
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: Text(
                        info.title,
                        style: TextStyle(
                          fontWeight:
                              isGranted ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        info.description,
                        style: theme.textTheme.bodySmall,
                      ),
                      trailing: isGranted
                          ? Icon(Icons.check_circle,
                              color: theme.colorScheme.primary)
                          : isSettings
                              ? TextButton(
                                  onPressed: () => ref
                                      .read(permissionStateProvider.notifier)
                                      .requestPermission(info.key),
                                  child: const Text('Open'),
                                )
                              : TextButton(
                                  onPressed: () => ref
                                      .read(permissionStateProvider.notifier)
                                      .requestPermission(info.key),
                                  child: const Text('Grant'),
                                ),
                    );
                  },
                ),
              ),

              // Action buttons
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: _finish,
                child: Text(
                  grantedCount == 0
                      ? 'Skip for Now'
                      : 'Continue ($grantedCount/${permissionInfoList.length} granted)',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'You can change these anytime in Settings.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// Provider to check if permission onboarding has been completed.
final permissionsOnboardedProvider = FutureProvider<bool>((ref) async {
  const storage = FlutterSecureStorage();
  final value = await storage.read(key: 'permissions_onboarded');
  return value == 'true';
});
