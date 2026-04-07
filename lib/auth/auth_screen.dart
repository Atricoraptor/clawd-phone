import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'auth_provider.dart';

class AuthScreen extends ConsumerStatefulWidget {
  final String? initialError;
  const AuthScreen({super.key, this.initialError});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _controller = TextEditingController();
  String? _error;
  bool _isVerifying = false;

  @override
  void initState() {
    super.initState();
    _error = widget.initialError;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isValidFormat =>
      _controller.text.startsWith('sk-ant-') && _controller.text.length > 20;

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null) {
      _controller.text = data!.text!.trim();
      setState(() {});
    }
  }

  Future<void> _verify() async {
    if (!_isValidFormat) return;
    setState(() {
      _isVerifying = true;
      _error = null;
    });
    await ref.read(authProvider.notifier).setApiKey(_controller.text.trim());
    final state = ref.read(authProvider);
    if (state is AuthValid && mounted) {
      Navigator.of(context).pushReplacementNamed('/home');
    } else if (state is AuthInvalid && mounted) {
      setState(() {
        _error = state.error;
        _isVerifying = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 60),
              Icon(Icons.assistant, size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                'Clawd Phone',
                style: theme.textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'Your AI Phone Assistant',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              Text(
                'Enter your Anthropic API Key',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _controller,
                autofocus: true,
                obscureText: true,
                decoration: InputDecoration(
                  hintText: 'sk-ant-api03-...',
                  errorText: _error,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.content_paste),
                    onPressed: _pasteFromClipboard,
                    tooltip: 'Paste',
                  ),
                ),
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) => _verify(),
              ),
              if (_controller.text.isNotEmpty && !_isValidFormat)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Key should start with sk-ant-',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _isValidFormat && !_isVerifying ? _verify : null,
                child: _isVerifying
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Continue'),
              ),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 16),
              Text('How to get a key', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              const _Step(n: 1, text: 'Open console.anthropic.com'),
              const _Step(n: 2, text: 'Sign up or log in'),
              const _Step(n: 3, text: 'Add a payment method'),
              const _Step(n: 4, text: 'Go to API Keys \u2192 Create Key'),
              const _Step(n: 5, text: 'Copy the key and paste it above'),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('https://console.anthropic.com/settings/keys'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open Anthropic Console'),
              ),
              const SizedBox(height: 24),
              Text(
                'Your API key stays on this device.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int n;
  final String text;
  const _Step({required this.n, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 12,
            child: Text('$n', style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
