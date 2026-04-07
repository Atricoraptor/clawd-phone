import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../models/message.dart';
import '../utils/cost_tracker.dart';
import '../permissions/permission_provider.dart';
import '../settings/settings_provider.dart';
import 'chat_provider.dart';
import 'widgets/message_bubble.dart';
import 'widgets/suggestion_chips.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String? sessionId;
  const ChatScreen({super.key, this.sessionId});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  AttachedImage? _pendingImage;
  final List<String> _pendingFiles = [];
  Uint8List? _clipboardImage;
  Timer? _scrollDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(chatProvider.notifier).init(sessionId: widget.sessionId);
    });
  }

  @override
  void dispose() {
    _scrollDebounce?.cancel();
    // Stop streaming when leaving the screen to avoid wasted memory/bandwidth.
    ref.read(chatProvider.notifier).stopStreaming();
    WidgetsBinding.instance.removeObserver(this);
    _inputController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboardForImage();
      // BUG 5 FIX: Refresh permissions when the app resumes so that grants
      // made in system Settings are picked up immediately.
      ref.read(permissionStateProvider.notifier).refresh();
    }
  }

  Future<void> _checkClipboardForImage() async {
    try {
      const channel = MethodChannel('com.clawdphone.app/clipboard');
      final hasImage =
          await channel.invokeMethod<bool>('clipboardHasImage') ?? false;
      if (hasImage) {
        final bytes =
            await channel.invokeMethod<Uint8List>('getClipboardImage');
        if (bytes != null && mounted) {
          setState(() => _clipboardImage = bytes);
        }
      } else {
        if (mounted) setState(() => _clipboardImage = null);
      }
    } catch (_) {
      // Platform channel not available
    }
  }

  IconData _fileIcon(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'pdf' => Icons.picture_as_pdf,
      'doc' || 'docx' => Icons.description,
      'xls' || 'xlsx' || 'csv' => Icons.table_chart,
      'txt' || 'md' || 'log' => Icons.text_snippet,
      'zip' || 'rar' || '7z' => Icons.folder_zip,
      'mp3' || 'wav' || 'aac' || 'flac' => Icons.audio_file,
      'mp4' || 'mkv' || 'avi' || 'mov' => Icons.video_file,
      _ => Icons.insert_drive_file,
    };
  }

  void _attachClipboardImage() {
    if (_clipboardImage == null) return;
    setState(() {
      _pendingImage = AttachedImage(
        bytes: _clipboardImage!,
        mediaType: 'image/png',
        fileName: 'clipboard_image.png',
      );
      _clipboardImage = null;
    });
  }

  Future<void> _pickFile() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('Pick a file'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );

    if (result == null) return;

    if (result == 'file') {
      final picked = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
      );
      if (picked != null && picked.files.isNotEmpty) {
        for (final file in picked.files) {
          final ext = (file.extension ?? '').toLowerCase();
          final isImage = ['jpg', 'jpeg', 'png', 'webp', 'gif'].contains(ext);
          final path = file.path;

          if (path == null) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Could not attach ${file.name}')),
              );
            }
            continue;
          }

          if (isImage && _pendingImage == null) {
            // Read bytes only for the image we'll send via vision
            try {
              final bytes = await File(path).readAsBytes();
              final mediaType = switch (ext) {
                'png' => 'image/png',
                'gif' => 'image/gif',
                'webp' => 'image/webp',
                _ => 'image/jpeg',
              };
              setState(() {
                _pendingImage = AttachedImage(
                  bytes: bytes,
                  mediaType: mediaType,
                  fileName: file.name,
                );
              });
            } catch (_) {
              // Fall back to file chip if reading fails
              setState(() => _pendingFiles.add(path));
            }
          } else {
            // Non-image or additional files: add as file chip
            setState(() => _pendingFiles.add(path));
          }
        }
      }
    } else if (result == 'camera' || result == 'gallery') {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: result == 'camera' ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 1536,
        maxHeight: 1536,
        imageQuality: 85,
      );
      if (picked != null) {
        final bytes = await picked.readAsBytes();
        setState(() {
          _pendingImage = AttachedImage(
            bytes: bytes,
            mediaType: 'image/jpeg',
            fileName: picked.name,
          );
        });
      }
    }
  }

  void _send() {
    var text = _inputController.text.trim();
    if (text.isEmpty && _pendingImage == null && _pendingFiles.isEmpty) return;

    // Append file paths so Claude knows to use FileRead.
    // Full paths are needed for Claude, but the user sees the message
    // bubble which renders via markdown — keep it readable.
    if (_pendingFiles.isNotEmpty) {
      final paths = _pendingFiles.map((p) {
        final name = p.split('/').last;
        return '[Attached file "$name": $p]';
      }).join('\n');
      text = text.isEmpty ? paths : '$text\n$paths';
    }

    final images = _pendingImage != null ? [_pendingImage!] : <AttachedImage>[];
    ref.read(chatProvider.notifier).sendMessage(text, images: images);

    _inputController.clear();
    setState(() {
      _pendingImage = null;
      _pendingFiles.clear();
    });

    // Scroll to bottom after the widget tree has rebuilt.
    // Use post-frame callback + a small delay to handle the
    // SuggestionChips → ListView transition on first message.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(
            _scrollController.position.maxScrollExtent,
          );
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatProvider);
    final theme = Theme.of(context);

    // Auto-scroll: during streaming (debounced) and once when streaming ends.
    ref.listen(chatProvider, (prev, next) {
      if (!_scrollController.hasClients) return;

      // When streaming ends, do a final scroll to bottom after the frame renders.
      if (prev != null && prev.isStreaming && !next.isStreaming) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
        return;
      }

      // During streaming, debounce scroll to bottom.
      if (next.isStreaming) {
        _scrollDebounce?.cancel();
        _scrollDebounce = Timer(const Duration(milliseconds: 100), () {
          if (!_scrollController.hasClients) return;
          final pos = _scrollController.position;
          final nearBottom = pos.maxScrollExtent - pos.pixels < 150;
          if (nearBottom) {
            _scrollController.jumpTo(pos.maxScrollExtent);
          }
        });
      }
    });

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: 'Sessions',
          onPressed: () {
            if (Navigator.canPop(context)) {
              Navigator.pop(context);
            } else {
              Navigator.pushReplacementNamed(context, '/home');
            }
          },
        ),
        title: Text(
          chatState.messages.isEmpty
              ? 'New conversation'
              : chatState.messages.first.text.length > 30
                  ? '${chatState.messages.first.text.substring(0, 30)}...'
                  : chatState.messages.first.text,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          if (chatState.sessionCost > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'Est. ${formatCost(chatState.sessionCost)}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      CostTracker.pricingEffectiveDateLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'settings') {
                Navigator.pushNamed(context, '/settings');
              } else if (value == 'new_chat') {
                ref.read(chatProvider.notifier).init();
              } else if (value.startsWith('model:')) {
                final newModel = value.substring(6);
                ref.read(settingsProvider.notifier).setModel(newModel);
                ref.read(chatProvider.notifier).updateModel(newModel);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'new_chat',
                child: Row(
                  children: [
                    Icon(Icons.add, size: 18),
                    SizedBox(width: 8),
                    Text('New Chat'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              // Model submenu
              ...availableModels.map((m) => PopupMenuItem(
                    value: 'model:${m.$1}',
                    child: Row(
                      children: [
                        Icon(
                          chatState.model == m.$1
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text('${m.$2} (${m.$3})'),
                      ],
                    ),
                  )),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Messages
          Expanded(
            child: chatState.messages.isEmpty
                ? SuggestionChips(onTap: (text) {
                    _inputController.text = text;
                    _send();
                  })
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
                    itemCount: chatState.messages.length,
                    itemBuilder: (_, i) => MessageBubble(
                      key: ValueKey(chatState.messages[i].id),
                      message: chatState.messages[i],
                    ),
                  ),
          ),

          // Error banner
          if (chatState.error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: theme.colorScheme.errorContainer,
              child: Row(
                children: [
                  Icon(Icons.warning_amber,
                      size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      chatState.error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                  TextButton(
                    // BUG 2 FIX: Use retryLastMessage() instead of
                    // sendMessage() to avoid duplicating the user message
                    // in _apiMessages (which caused 400 API errors).
                    onPressed: () {
                      ref.read(chatProvider.notifier).retryLastMessage();
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),

          // Clipboard image banner
          if (_clipboardImage != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: theme.colorScheme.secondaryContainer,
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(_clipboardImage!,
                        height: 40, width: 40, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('Image in clipboard')),
                  TextButton(
                    onPressed: _attachClipboardImage,
                    child: const Text('Attach'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _clipboardImage = null),
                  ),
                ],
              ),
            ),

          // Pending image preview
          if (_pendingImage != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(_pendingImage!.bytes,
                        height: 50, width: 50, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _pendingImage!.fileName ?? 'Image',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _pendingImage = null),
                  ),
                ],
              ),
            ),

          // Pending file chips
          if (_pendingFiles.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: _pendingFiles.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final path = entry.value;
                  final name = path.split('/').last;
                  return Chip(
                    avatar: Icon(
                      _fileIcon(name),
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    label: Text(
                      name,
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    onDeleted: () =>
                        setState(() => _pendingFiles.removeAt(idx)),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  );
                }).toList(),
              ),
            ),

          // Input bar
          SafeArea(
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Attach
                  IconButton(
                    icon: const Icon(Icons.attach_file),
                    onPressed: _pickFile,
                  ),
                  // Text field
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      focusNode: _focusNode,
                      maxLines: 5,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      decoration: InputDecoration(
                        hintText: 'Ask about your phone...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // Send / Stop button
                  chatState.isStreaming
                      ? IconButton.filled(
                          icon: const Icon(Icons.stop),
                          onPressed: () =>
                              ref.read(chatProvider.notifier).stopStreaming(),
                        )
                      : IconButton.filled(
                          icon: const Icon(Icons.send),
                          onPressed: _send,
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
