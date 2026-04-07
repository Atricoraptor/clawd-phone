import 'package:flutter/material.dart';

class SuggestionChips extends StatelessWidget {
  final void Function(String text) onTap;
  const SuggestionChips({super.key, required this.onTap});

  static const _suggestions = [
    ('Describe some photos I took last week', Icons.photo),
    ("What's using my storage?", Icons.storage),
    ('Any tax related documents on this phone?', Icons.picture_as_pdf),
    ('My calendar today', Icons.calendar_today),
    ('Screen time report', Icons.phone_android),
    ('What are the latest world news?', Icons.language),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.assistant,
              size: 48,
              color: theme.colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            Text(
              'Ask me anything about your phone',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            ..._suggestions.map((s) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: Icon(s.$2, size: 18),
                    label: Text(
                      s.$1,
                      textAlign: TextAlign.left,
                    ),
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      side: BorderSide(
                        color: theme.colorScheme.outlineVariant,
                      ),
                    ),
                    onPressed: () => onTap(s.$1),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
