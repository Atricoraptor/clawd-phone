import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../../files/file_preview_screen.dart';
import '../../models/message.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  const MessageBubble({super.key, required this.message});

  MarkdownStyleSheet _markdownStyle(ThemeData theme, bool isUser) {
    final textColor = isUser
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;
    final linkColor = isUser
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.primary;
    final subtleBg = isUser
        ? theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.08)
        : theme.colorScheme.surface;
    final borderColor = isUser
        ? theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.20)
        : theme.colorScheme.outlineVariant;

    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyMedium?.copyWith(color: textColor),
      a: theme.textTheme.bodyMedium?.copyWith(
        color: linkColor,
        decoration: TextDecoration.underline,
        decorationColor: linkColor,
      ),
      code: theme.textTheme.bodySmall?.copyWith(
        color: textColor,
        fontFamily: 'monospace',
      ),
      h1: theme.textTheme.titleLarge?.copyWith(color: textColor),
      h2: theme.textTheme.titleMedium?.copyWith(color: textColor),
      h3: theme.textTheme.titleSmall?.copyWith(color: textColor),
      h4: theme.textTheme.titleSmall?.copyWith(color: textColor),
      h5: theme.textTheme.titleSmall?.copyWith(color: textColor),
      h6: theme.textTheme.titleSmall?.copyWith(color: textColor),
      strong: theme.textTheme.bodyMedium?.copyWith(
        color: textColor,
        fontWeight: FontWeight.w700,
      ),
      em: theme.textTheme.bodyMedium?.copyWith(
        color: textColor,
        fontStyle: FontStyle.italic,
      ),
      del: theme.textTheme.bodyMedium?.copyWith(color: textColor),
      listBullet: theme.textTheme.bodyMedium?.copyWith(color: textColor),
      blockquote: theme.textTheme.bodyMedium?.copyWith(color: textColor),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      blockquoteDecoration: BoxDecoration(
        color: subtleBg,
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: borderColor, width: 3),
        ),
      ),
      codeblockPadding: const EdgeInsets.all(10),
      codeblockDecoration: BoxDecoration(
        color: subtleBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == 'user';
    final copyText = _buildCopyText();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primary,
              child: const Icon(Icons.assistant, size: 18, color: Colors.white),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isUser
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16).copyWith(
                      topLeft: isUser ? null : const Radius.circular(4),
                      topRight: isUser ? const Radius.circular(4) : null,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Pasted images
                      if (message.images.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(
                              message.images.first.bytes,
                              height: 200,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),

                      // Ordered content blocks — renders text and tool calls
                      // Ordered content blocks — text and tool calls interleaved.
                      for (final block in message.contentBlocks)
                        if (block is TextSegment && block.text.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            // Use plain Text while streaming to avoid expensive
                            // markdown re-parsing on every chunk. Switch to
                            // MarkdownBody once streaming is complete.
                            child: message.isStreaming
                                ? SelectableText(
                                    block.text,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: isUser
                                          ? theme.colorScheme.onPrimaryContainer
                                          : theme.colorScheme.onSurface,
                                    ),
                                  )
                                : MarkdownBody(
                                    data: block.text,
                                    styleSheet: _markdownStyle(theme, isUser),
                                  ),
                          )
                        else if (block is ToolUseSegment && !block.isHidden)
                          if (block.result != null)
                            _ToolResultCard(
                              result: block.result!,
                              input: block.input,
                            )
                          else
                            _ToolCallRunning(
                                toolCall: ToolCall(
                              id: block.toolUseId,
                              name: block.toolName,
                              input: {},
                            )),

                      // Streaming indicator
                      if (message.isStreaming && message.contentBlocks.isEmpty)
                        const _TypingIndicator(),
                    ],
                  ),
                ),
                // Copy icon sits outside the bubble so it never affects bubble size.
                if (!message.isStreaming && copyText.isNotEmpty)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(text: copyText));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            isUser ? 'Message copied' : 'Response copied',
                          ),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                      child: Icon(
                        Icons.content_copy,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.4),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  String _buildCopyText() {
    final parts = <String>[];

    if (message.images.isNotEmpty) {
      final fileName = message.images.first.fileName;
      parts.add(fileName == null
          ? '[Attached image]'
          : '[Attached image: $fileName]');
    }

    for (final block in message.contentBlocks) {
      if (block is TextSegment && block.text.trim().isNotEmpty) {
        parts.add(block.text.trim());
      } else if (block is ToolUseSegment &&
          !block.isHidden &&
          block.result != null) {
        parts.add(block.result!.summary.trim());
      }
    }

    return parts.join('\n\n').trim();
  }
}

class _ToolCallRunning extends StatelessWidget {
  final ToolCall toolCall;
  const _ToolCallRunning({required this.toolCall});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            '${toolCall.name}...',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ToolResultCard extends StatefulWidget {
  final ToolResult result;
  final Map<String, dynamic> input;
  const _ToolResultCard({required this.result, required this.input});

  @override
  State<_ToolResultCard> createState() => _ToolResultCardState();
}

class _ToolResultCardState extends State<_ToolResultCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = widget.result;
    final previewTarget = previewTargetFromToolResult(r.data);
    final inputText = widget.input.isEmpty
        ? '(no input)'
        : const JsonEncoder.withIndent('  ').convert(widget.input);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: r.isError
              ? theme.colorScheme.error.withValues(alpha: 0.5)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    r.isError ? Icons.error_outline : Icons.build_circle,
                    size: 18,
                    color: r.isError
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      r.summary,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          if (previewTarget != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FilePreviewScreen(target: previewTarget),
                    ),
                  );
                },
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open'),
              ),
            ),
          if (_expanded)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Text(
                    'Tool: ${r.toolName}',
                    style: theme.textTheme.labelSmall,
                  ),
                  Text(
                    'Duration: ${r.duration.inMilliseconds}ms',
                    style: theme.textTheme.labelSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Input',
                    style: theme.textTheme.labelSmall,
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SelectableText(
                      inputText.length > 1200
                          ? '${inputText.substring(0, 1200)}\n... (truncated)'
                          : inputText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Result',
                    style: theme.textTheme.labelSmall,
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SelectableText(
                      r.fullResult.length > 2000
                          ? '${r.fullResult.substring(0, 2000)}\n... (truncated)'
                          : r.fullResult,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final delay = i * 0.2;
          final t = ((_controller.value - delay) % 1.0).clamp(0.0, 1.0);
          final y = -4.0 * (1 - (2 * t - 1) * (2 * t - 1));
          return Transform.translate(
            offset: Offset(0, y),
            child: Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant
                    .withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
            ),
          );
        }),
      ),
    );
  }
}
