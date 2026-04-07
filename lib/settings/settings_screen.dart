import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../auth/auth_provider.dart';
import '../permissions/permission_provider.dart';
import 'settings_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Refresh permissions when settings screen opens
    ref.read(permissionStateProvider.notifier).refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-check permissions when returning from Android settings
      ref.read(permissionStateProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final authState = ref.watch(authProvider);
    final grantedPerms = ref.watch(permissionStateProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // API Key section
          const _SectionHeader('API Key'),
          ListTile(
            leading: const Icon(Icons.key),
            title: Text(authState is AuthValid
                ? '${authState.apiKey.substring(0, 12)}...${authState.apiKey.substring(authState.apiKey.length - 4)}'
                : 'Not set'),
            subtitle: Text(authState is AuthValid ? 'Valid' : 'Invalid'),
            trailing: TextButton(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Remove API Key?'),
                    content: const Text(
                        'This will sign you out. Your conversations are kept.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Remove')),
                    ],
                  ),
                );
                if (confirmed == true) {
                  ref.read(authProvider.notifier).clearKey();
                  if (context.mounted) {
                    Navigator.of(context).pushReplacementNamed('/auth');
                  }
                }
              },
              child: const Text('Remove'),
            ),
          ),
          const Divider(),

          // Model section
          const _SectionHeader('Model'),
          ...availableModels.map(
            (m) => ListTile(
              leading: Icon(
                m.$1 == settings.model
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(m.$2),
              subtitle: Text(m.$4.isEmpty ? m.$3 : '${m.$3} \u00B7 ${m.$4}'),
              onTap: () => ref.read(settingsProvider.notifier).setModel(m.$1),
            ),
          ),
          const Divider(),

          // Permissions section
          const _SectionHeader('Permissions'),
          ...permissionInfoList.map((p) {
            final granted = grantedPerms.contains(p.key);
            final isStorage = p.key == 'storage';
            final hasFullStorage = grantedPerms.contains('storage_full');

            // Storage has three states: full, partial (media only), none.
            Widget trailing;
            Color iconColor;
            if (isStorage && granted && hasFullStorage) {
              iconColor = Colors.green;
              trailing = const Chip(label: Text('Granted'));
            } else if (isStorage && granted && !hasFullStorage) {
              iconColor = Colors.orange;
              trailing = TextButton(
                onPressed: () async {
                  await ref
                      .read(permissionStateProvider.notifier)
                      .requestPermission(p.key);
                },
                child: const Text('Enable Full Access'),
              );
            } else if (granted) {
              iconColor = Colors.green;
              trailing = const Chip(label: Text('Granted'));
            } else {
              iconColor = theme.colorScheme.onSurfaceVariant;
              trailing = TextButton(
                onPressed: () async {
                  await ref
                      .read(permissionStateProvider.notifier)
                      .requestPermission(p.key);
                },
                child: const Text('Grant'),
              );
            }

            return ListTile(
              leading: Icon(
                IconData(p.icon, fontFamily: 'MaterialIcons'),
                color: iconColor,
              ),
              title: Text(p.title),
              subtitle: isStorage && granted && !hasFullStorage
                  ? const Text(
                      'Media only — PDFs and Clawd-Phone file creation need Full Access')
                  : null,
              trailing: trailing,
            );
          }),
          const Divider(),

          // Appearance
          const _SectionHeader('Appearance'),
          ListTile(
            leading: const Icon(Icons.palette),
            title: const Text('Theme'),
            trailing: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('Auto')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (s) =>
                  ref.read(settingsProvider.notifier).setTheme(s.first),
            ),
          ),
          const Divider(),

          // About
          const _SectionHeader('About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Version'),
            subtitle: Text('1.0.0'),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      );
}
