import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../auth/auth_provider.dart';
import '../core/claude_api.dart';
import '../core/query_engine.dart';
import '../core/tool_router.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../sessions/session_provider.dart';
import '../settings/settings_provider.dart';
import '../utils/cost_tracker.dart';

const _uuid = Uuid();

class ChatState {
  final String? sessionId;
  final List<ChatMessage> messages;
  final bool isStreaming;
  final double sessionCost;
  final String? error;
  final String model;

  const ChatState({
    this.sessionId,
    this.messages = const [],
    this.isStreaming = false,
    this.sessionCost = 0.0,
    this.error,
    this.model = 'claude-haiku-4-5-20251001',
  });

  ChatState copyWith({
    String? sessionId,
    List<ChatMessage>? messages,
    bool? isStreaming,
    double? sessionCost,
    String? error,
    String? model,
  }) =>
      ChatState(
        sessionId: sessionId ?? this.sessionId,
        messages: messages ?? this.messages,
        isStreaming: isStreaming ?? this.isStreaming,
        sessionCost: sessionCost ?? this.sessionCost,
        error: error,
        model: model ?? this.model,
      );
}

class ChatNotifier extends StateNotifier<ChatState> {
  static const int _maxPersistedToolTextChars = 12000;

  final Ref _ref;
  final CostTracker _costTracker = CostTracker();
  QueryEngine? _engine;
  ClaudeApi? _activeApi;
  bool _cancelled = false;

  // Conversation history in API format
  final List<Message> _apiMessages = [];

  // Batch UI updates to reduce widget rebuilds during streaming.
  // Text deltas are buffered and flushed every 50ms instead of on every chunk.
  Timer? _uiFlushTimer;
  bool _uiDirty = false;

  ChatNotifier(this._ref) : super(const ChatState());

  /// Initialize or resume a session.
  Future<void> init({String? sessionId}) async {
    final settings = _ref.read(settingsProvider);

    // FIX 3: Clear any existing state so session switching is clean.
    _apiMessages.clear();
    state = ChatState(model: settings.model);

    if (sessionId != null) {
      state = state.copyWith(sessionId: sessionId);
      await _loadSession(sessionId);

      // Restore cost from session metadata
      final manager = _ref.read(sessionManagerProvider);
      await manager.init();
      final meta = manager.sessions.where((s) => s.id == sessionId).firstOrNull;
      if (meta != null && meta.estimatedCost > 0) {
        state = state.copyWith(sessionCost: meta.estimatedCost);
      }
    }
  }

  /// Send a user message (text only or text+image).
  Future<void> sendMessage(String text, {List<AttachedImage>? images}) async {
    if (text.trim().isEmpty && (images == null || images.isEmpty)) return;
    if (state.isStreaming) return;

    // Create session if needed
    var sessionId = state.sessionId;
    if (sessionId == null) {
      final manager = _ref.read(sessionManagerProvider);
      await manager.init();
      final title = text.trim().isNotEmpty
          ? (text.length > 50 ? '${text.substring(0, 50)}...' : text)
          : (images != null && images.isNotEmpty
              ? 'Image conversation'
              : 'New conversation');
      final meta = manager.createSession(
        title: title,
        model: state.model,
      );
      sessionId = meta.id;
      state = state.copyWith(sessionId: sessionId);
      _ref.invalidate(sessionListProvider);
    }

    // Build user message
    final userMsg = ChatMessage(
      id: _uuid.v4(),
      role: 'user',
      contentBlocks: [TextSegment(text)],
      images: images ?? [],
    );
    state = state.copyWith(
      messages: [...state.messages, userMsg],
      isStreaming: true,
      error: null,
    );

    // Build API message
    Message apiMsg;
    if (images != null && images.isNotEmpty) {
      apiMsg = Message.userWithImage(
        text: text,
        imageBytes: images.first.bytes,
        mediaType: images.first.mediaType,
      );
    } else {
      apiMsg = Message.user(text);
    }
    _apiMessages.add(apiMsg);

    // Save to JSONL
    final manager = _ref.read(sessionManagerProvider);
    await manager.appendEntry(
      sessionId,
      SessionEntry(
        type: 'user',
        uuid: userMsg.id,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        data: {
          'content': text,
          if (images != null && images.isNotEmpty)
            'image': _serializeAttachedImage(images.first),
        },
      ),
    );

    // Run query engine
    await _runEngine(sessionId);
  }

  /// Update the model for the current session. Takes effect on the next message.
  void updateModel(String model) {
    state = state.copyWith(model: model);
  }

  /// BUG 2 FIX: Retry the last message without duplicating the user message
  /// in _apiMessages. The Retry button previously called sendMessage(), which
  /// pushed another user message and caused two consecutive 'user' roles → 400.
  Future<void> retryLastMessage() async {
    if (state.isStreaming) return;
    final sessionId = state.sessionId;
    if (sessionId == null) return;

    // Remove the failed/empty assistant message from the UI
    final msgs = [...state.messages];
    while (msgs.isNotEmpty && msgs.last.role == 'assistant') {
      msgs.removeLast();
    }
    state = state.copyWith(messages: msgs, isStreaming: true, error: null);

    // Don't touch _apiMessages — the user message is already there
    try {
      await _runEngine(sessionId);
    } catch (e) {
      state = state.copyWith(
        error: 'Retry failed: ${e.toString()}',
        isStreaming: false,
      );
    }
  }

  Future<void> _runEngine(String sessionId) async {
    final authState = _ref.read(authProvider);
    final apiKey = authState is AuthValid ? authState.apiKey : null;
    if (apiKey == null) {
      state = state.copyWith(error: 'Not authenticated', isStreaming: false);
      return;
    }

    // FIX 4: Reset cancellation flag at the start of each engine run.
    _cancelled = false;

    final api = ClaudeApi(apiKey: apiKey);
    _activeApi = api;
    final toolRouter = ToolRouter();
    _engine = QueryEngine(
      api: api,
      toolRouter: toolRouter,
      model: state.model,
      costTracker: _costTracker,
    );

    _replaceApiHistoryWithPairedVersion();

    // Start assistant message with ordered content blocks.
    final assistantId = _uuid.v4();
    final blocks = <ChatContentBlock>[];
    var assistantMsg = ChatMessage(
      id: assistantId,
      role: 'assistant',
      contentBlocks: blocks,
      isStreaming: true,
    );
    state = state.copyWith(
      messages: [...state.messages, assistantMsg],
    );

    final baseCost = state.sessionCost;
    _costTracker.reset();
    int currentApiTurnIndex = 0;
    int runTotalInputTokens = 0;
    int runTotalOutputTokens = 0;
    int runTotalCacheReadInputTokens = 0;
    int runTotalCacheCreationInputTokens = 0;
    int runTotalWebSearchRequests = 0;
    String? lastAssistantModel;
    final assistantTurnUsages = <Map<String, dynamic>>[];
    List<Map<String, dynamic>> assistantHistoryMessages =
        const <Map<String, dynamic>>[];

    try {
      await for (final update in _engine!.sendMessage(
        conversationHistory: _apiMessages,
      )) {
        // FIX 4: Break out of the stream if cancelled.
        if (_cancelled) break;

        switch (update) {
          case RequestPrepared(:final turnIndex, :final request):
            currentApiTurnIndex = turnIndex;
            final sessionManager = _ref.read(sessionManagerProvider);
            await sessionManager.appendEntry(
              sessionId,
              SessionEntry(
                type: 'api_request',
                uuid: _uuid.v4(),
                timestamp: DateTime.now().millisecondsSinceEpoch,
                parentUuid: assistantId,
                data: {
                  'assistant_message_id': assistantId,
                  ...request,
                },
              ),
            );

          case TextDelta(:final text):
            // Append to existing TextSegment or create new one.
            // A new TextSegment starts after a ToolUseSegment, preserving
            // interleaved order.
            if (blocks.isNotEmpty && blocks.last is TextSegment) {
              (blocks.last as TextSegment).text += text;
            } else {
              blocks.add(TextSegment(text));
            }
            assistantMsg = assistantMsg.copyWith(contentBlocks: [...blocks]);
            // Flush the first chunk immediately so streaming text appears
            // right away (especially on first message when widget tree
            // transitions from SuggestionChips to ListView). Subsequent
            // chunks are batched every 50ms to reduce rebuilds.
            if (_uiFlushTimer == null) {
              _flushUi(assistantMsg);
            }
            _scheduleUiFlush(assistantMsg);

          case ToolCallStarted(:final toolUseId, :final toolName):
            _flushUi(assistantMsg); // Flush pending text before tool card
            blocks.add(ToolUseSegment(
              toolUseId: toolUseId,
              toolName: toolName,
            ));
            assistantMsg = assistantMsg.copyWith(contentBlocks: [...blocks]);
            _updateLastMessage(assistantMsg);

          case ToolCallCompleted(
              :final toolUseId,
              :final toolName,
              :final input,
              :final summary,
              :final fullResult,
              :final isError,
              :final duration,
              :final apiContent,
              :final resultData,
            ):
            // Find the matching ToolUseSegment and update it with the result.
            for (final block in blocks) {
              if (block is ToolUseSegment && block.toolUseId == toolUseId) {
                block.input = Map<String, dynamic>.from(input);
                block.status = ToolCallStatus.completed;
                block.result = ToolResult(
                  toolUseId: toolUseId,
                  toolName: toolName,
                  summary: summary,
                  fullResult: fullResult,
                  isError: isError,
                  duration: duration,
                  apiContent: apiContent,
                  data: resultData,
                );
                break;
              }
            }
            assistantMsg = assistantMsg.copyWith(contentBlocks: [...blocks]);
            _updateLastMessage(assistantMsg);

            // FIX 2: Save tool result to JSONL.
            final manager = _ref.read(sessionManagerProvider);
            await manager.appendEntry(
              sessionId,
              SessionEntry(
                type: 'tool_result',
                uuid: _uuid.v4(),
                timestamp: DateTime.now().millisecondsSinceEpoch,
                data: {
                  'tool_use_id': toolUseId,
                  'tool_name': toolName,
                  'summary': summary,
                  'full_result': _compactToolResultForPersistence(
                    summary: summary,
                    fullResult: fullResult,
                    apiContent: apiContent,
                  ),
                  if (resultData != null) 'result_data': resultData,
                  if (apiContent.isNotEmpty)
                    'api_content':
                        _sanitizeApiContentForPersistence(apiContent),
                  'is_error': isError,
                },
              ),
            );

          case UsageUpdate(
              :final turnIndex,
              :final messageId,
              :final model,
              :final inputTokens,
              :final outputTokens,
              :final cacheReadTokens,
              :final cacheCreationTokens,
              :final webSearchRequests,
              :final stopReason,
              :final appliedContextEdits,
              :final cost,
            ):
            currentApiTurnIndex = turnIndex;
            final totalInputTokens =
                inputTokens + cacheReadTokens + cacheCreationTokens;
            runTotalInputTokens += inputTokens;
            runTotalOutputTokens += outputTokens;
            runTotalCacheReadInputTokens += cacheReadTokens;
            runTotalCacheCreationInputTokens += cacheCreationTokens;
            runTotalWebSearchRequests += webSearchRequests;
            lastAssistantModel = model;
            assistantTurnUsages.add({
              'turn_index': turnIndex,
              if (messageId != null) 'message_id': messageId,
              'model': model,
              'input_tokens': inputTokens,
              'cache_read_input_tokens': cacheReadTokens,
              'cache_creation_input_tokens': cacheCreationTokens,
              'output_tokens': outputTokens,
              if (webSearchRequests > 0)
                'web_search_requests': webSearchRequests,
              'total_input_tokens': totalInputTokens,
              'total_tokens': totalInputTokens + outputTokens,
              if (stopReason != null) 'stop_reason': stopReason,
              'applied_context_edits': appliedContextEdits ?? const [],
            });
            state = state.copyWith(sessionCost: baseCost + cost);
            final sessionManager = _ref.read(sessionManagerProvider);
            await sessionManager.appendEntry(
              sessionId,
              SessionEntry(
                type: 'api_response',
                uuid: _uuid.v4(),
                timestamp: DateTime.now().millisecondsSinceEpoch,
                parentUuid: assistantId,
                data: {
                  'assistant_message_id': assistantId,
                  'turn_index': turnIndex,
                  if (messageId != null) 'message_id': messageId,
                  'model': model,
                  'usage': {
                    'input_tokens': inputTokens,
                    'cache_read_input_tokens': cacheReadTokens,
                    'cache_creation_input_tokens': cacheCreationTokens,
                    'output_tokens': outputTokens,
                    if (webSearchRequests > 0)
                      'web_search_requests': webSearchRequests,
                    'total_input_tokens': totalInputTokens,
                    'total_tokens': totalInputTokens + outputTokens,
                  },
                  if (stopReason != null) 'stop_reason': stopReason,
                  'context_management': {
                    'applied_edits': appliedContextEdits ?? const [],
                  },
                },
              ),
            );

          case StreamError(:final message):
            final sessionManager = _ref.read(sessionManagerProvider);
            await sessionManager.appendEntry(
              sessionId,
              SessionEntry(
                type: 'api_error',
                uuid: _uuid.v4(),
                timestamp: DateTime.now().millisecondsSinceEpoch,
                parentUuid: assistantId,
                data: {
                  'assistant_message_id': assistantId,
                  if (currentApiTurnIndex > 0)
                    'turn_index': currentApiTurnIndex,
                  'message': message,
                },
              ),
            );
            _cancelUiTimer();
            // BUG 4 FIX: Remove empty assistant message on failure.
            final msgs = [...state.messages];
            if (msgs.isNotEmpty &&
                msgs.last.id == assistantId &&
                msgs.last.contentBlocks.isEmpty) {
              msgs.removeLast();
            } else {
              // Has partial text — keep it but mark as not streaming.
              assistantMsg = assistantMsg.copyWith(isStreaming: false);
              final idx = msgs.indexWhere((m) => m.id == assistantId);
              if (idx != -1) msgs[idx] = assistantMsg;
            }
            state = state.copyWith(
                messages: msgs, error: message, isStreaming: false);
            return;

          case TurnComplete(:final historyMessages):
            assistantHistoryMessages = historyMessages;
            _flushUi(assistantMsg); // Flush any remaining buffered text
            assistantMsg = assistantMsg.copyWith(isStreaming: false);
            _updateLastMessage(assistantMsg);
        }
      }
    } catch (e) {
      final sessionManager = _ref.read(sessionManagerProvider);
      await sessionManager.appendEntry(
        sessionId,
        SessionEntry(
          type: 'api_error',
          uuid: _uuid.v4(),
          timestamp: DateTime.now().millisecondsSinceEpoch,
          parentUuid: assistantId,
          data: {
            'assistant_message_id': assistantId,
            if (currentApiTurnIndex > 0) 'turn_index': currentApiTurnIndex,
            'message': e.toString(),
          },
        ),
      );
      _cancelUiTimer();
      // BUG 4 FIX: Remove empty assistant message on unexpected failure.
      final msgs = [...state.messages];
      if (msgs.isNotEmpty &&
          msgs.last.id == assistantId &&
          msgs.last.contentBlocks.isEmpty) {
        msgs.removeLast();
      }
      state = state.copyWith(
          messages: msgs, error: e.toString(), isStreaming: false);
      return;
    }

    // BUG 3 FIX: When the user stops streaming, mark the partial assistant
    // message as no longer streaming so it renders cleanly. If no text was
    // generated yet, remove the empty bubble. We deliberately do NOT set an
    // error — the user chose to stop, so this is expected behaviour.
    if (_cancelled) {
      final msgs = [...state.messages];
      if (msgs.isNotEmpty && msgs.last.id == assistantId) {
        if (msgs.last.contentBlocks.isEmpty) {
          msgs.removeLast();
        } else {
          assistantMsg = assistantMsg.copyWith(isStreaming: false);
          final idx = msgs.indexWhere((m) => m.id == assistantId);
          if (idx != -1) msgs[idx] = assistantMsg;
        }
      }
      state = state.copyWith(messages: msgs, isStreaming: false);
      return;
    }

    // Save assistant message to JSONL after streaming completes.
    // Include tool_use blocks so the full exchange can be reconstructed on resume.
    if (!_cancelled &&
        (assistantMsg.text.isNotEmpty ||
            assistantMsg.toolResults.isNotEmpty ||
            assistantHistoryMessages.isNotEmpty)) {
      final manager = _ref.read(sessionManagerProvider);
      final orderedBlocks =
          _serializeAssistantBlocksForPersistence(assistantMsg.contentBlocks);
      final aggregatedUsage = _buildPersistedAssistantUsage(
        model: lastAssistantModel ?? state.model,
        inputTokens: runTotalInputTokens,
        outputTokens: runTotalOutputTokens,
        cacheReadTokens: runTotalCacheReadInputTokens,
        cacheCreationTokens: runTotalCacheCreationInputTokens,
        webSearchRequests: runTotalWebSearchRequests,
      );
      await manager.appendEntry(
        sessionId,
        SessionEntry(
          type: 'assistant',
          uuid: assistantId,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          parentUuid: null,
          data: {
            // Keep 'content' for backward compatibility with older sessions
            'content': assistantMsg.text,
            'ordered_blocks': orderedBlocks,
            'message': {
              'role': 'assistant',
              if (lastAssistantModel != null) 'model': lastAssistantModel,
              'content': orderedBlocks,
            },
            if (assistantHistoryMessages.isNotEmpty)
              'api_messages':
                  _serializeApiMessagesForPersistence(assistantHistoryMessages),
            'usage': aggregatedUsage,
            if (assistantTurnUsages.isNotEmpty)
              'turn_usages': assistantTurnUsages,
          },
        ),
      );
    }

    // Append assistant response to _apiMessages so multi-turn conversations
    // retain full context including tool exchanges.
    if (!_cancelled &&
        (assistantMsg.text.isNotEmpty ||
            assistantMsg.toolResults.isNotEmpty ||
            assistantHistoryMessages.isNotEmpty)) {
      if (assistantHistoryMessages.isNotEmpty) {
        _apiMessages
            .addAll(_messagesFromSavedApiMessages(assistantHistoryMessages));
      } else {
        _appendAssistantToApiHistory(
          contentBlocks: assistantMsg.contentBlocks,
        );
      }
    }

    // Compact _apiMessages: strip old image/document blocks to free memory.
    // Keeps 2 most recent media messages intact (same as microcompact).
    _compactApiMessages();

    _cancelUiTimer();
    state = state.copyWith(isStreaming: false);

    // Update session metadata
    final manager = _ref.read(sessionManagerProvider);
    final sessions = manager.sessions;
    final idx = sessions.indexWhere((s) => s.id == sessionId);
    if (idx != -1) {
      await manager.updateMeta(sessions[idx].copyWith(
        lastActiveAt: DateTime.now().millisecondsSinceEpoch,
        messageCount: state.messages.length,
        model: state.model,
        totalInputTokens: sessions[idx].totalInputTokens + runTotalInputTokens,
        totalOutputTokens:
            sessions[idx].totalOutputTokens + runTotalOutputTokens,
        totalCacheReadInputTokens: sessions[idx].totalCacheReadInputTokens +
            runTotalCacheReadInputTokens,
        totalCacheCreationInputTokens:
            sessions[idx].totalCacheCreationInputTokens +
                runTotalCacheCreationInputTokens,
        estimatedCost: state.sessionCost,
        toolsUsed: {
          ...sessions[idx].toolsUsed,
          ...assistantMsg.toolResults.map((r) => r.toolName),
          if (runTotalWebSearchRequests > 0) 'web_search',
        },
      ));
      // FIX 5: Invalidate sessionListProvider so the UI reflects updated metadata.
      _ref.invalidate(sessionListProvider);
    }
  }

  static List<Map<String, dynamic>> _serializeAssistantBlocksForPersistence(
    List<ChatContentBlock> blocks,
  ) {
    final orderedBlocks = <Map<String, dynamic>>[];
    for (final block in blocks) {
      if (block is TextSegment && block.text.isNotEmpty) {
        orderedBlocks.add({
          'type': 'text',
          'text': block.text,
        });
      } else if (block is ToolUseSegment) {
        orderedBlocks.add({
          'type': 'tool_use',
          'id': block.toolUseId,
          'name': block.toolName,
          'input': Map<String, dynamic>.from(block.input),
        });
      }
    }
    return orderedBlocks;
  }

  static Map<String, dynamic> _buildPersistedAssistantUsage({
    required String model,
    required int inputTokens,
    required int outputTokens,
    required int cacheReadTokens,
    required int cacheCreationTokens,
    required int webSearchRequests,
  }) {
    final totalInputTokens =
        inputTokens + cacheReadTokens + cacheCreationTokens;
    return {
      'model': model,
      'input_tokens': inputTokens,
      'cache_read_input_tokens': cacheReadTokens,
      'cache_creation_input_tokens': cacheCreationTokens,
      'output_tokens': outputTokens,
      if (webSearchRequests > 0) 'web_search_requests': webSearchRequests,
      'total_input_tokens': totalInputTokens,
      'total_tokens': totalInputTokens + outputTokens,
    };
  }

  /// Convert API content blocks (Maps from _buildToolResultContent) to proper
  /// ContentBlock objects. Falls back to TextBlock(fullResult) if no apiContent.
  /// Strips base64 from the fullResult fallback to avoid sending it as text.
  static List<ContentBlock> _contentBlocksFromApiContent(
    List<Map<String, dynamic>>? apiContent,
    String fullResult,
  ) {
    if (apiContent == null || apiContent.isEmpty) {
      // No API content blocks saved — use text fallback but strip any base64
      return [TextBlock(_stripBase64FromJson(fullResult))];
    }
    return apiContent.map((block) {
      final type = block['type'] as String?;
      if (type == 'image') {
        final source = block['source'] as Map<String, dynamic>?;
        if (source != null) {
          return ImageBlock(
            base64Data: source['data'] as String? ?? '',
            mediaType: source['media_type'] as String? ?? 'image/jpeg',
          ) as ContentBlock;
        }
      }
      if (type == 'text') {
        return TextBlock(block['text'] as String? ?? '') as ContentBlock;
      }
      if (type == 'document') {
        return TextBlock('[document previously read]') as ContentBlock;
      }
      return TextBlock(jsonEncode(block)) as ContentBlock;
    }).toList();
  }

  static List<Map<String, dynamic>> _sanitizeApiContentForPersistence(
    List<Map<String, dynamic>> apiContent,
  ) {
    return apiContent.map((block) {
      final type = block['type'] as String?;
      if (type == 'image') {
        return <String, dynamic>{
          'type': 'text',
          'text': '[image previously analyzed]',
        };
      }
      if (type == 'document') {
        return <String, dynamic>{
          'type': 'text',
          'text': '[document previously read]',
        };
      }
      if (type == 'text') {
        return <String, dynamic>{
          'type': 'text',
          'text': block['text'] as String? ?? '',
        };
      }
      return <String, dynamic>{
        'type': 'text',
        'text': jsonEncode(block),
      };
    }).toList();
  }

  static List<Map<String, dynamic>> _serializeApiMessagesForPersistence(
    List<Map<String, dynamic>> messages,
  ) {
    return messages
        .map((message) => {
              'role': message['role'],
              'content': _sanitizePersistedContentList(message['content']),
            })
        .toList();
  }

  static List<Map<String, dynamic>> _sanitizePersistedContentList(
    dynamic content,
  ) {
    if (content is! List) return const <Map<String, dynamic>>[];
    return content
        .whereType<Map>()
        .map(
          (block) => _sanitizePersistedContentBlock(
            Map<String, dynamic>.from(block),
          ),
        )
        .toList();
  }

  static Map<String, dynamic> _sanitizePersistedContentBlock(
    Map<String, dynamic> block,
  ) {
    final type = block['type'] as String?;
    switch (type) {
      case 'image':
        return const {
          'type': 'text',
          'text': '[image previously analyzed]',
        };
      case 'document':
        return const {
          'type': 'text',
          'text': '[document previously read]',
        };
      case 'tool_result':
        return {
          'type': 'tool_result',
          'tool_use_id': block['tool_use_id'],
          if (block['is_error'] == true) 'is_error': true,
          'content': _sanitizePersistedContentList(block['content']),
        };
      default:
        return Map<String, dynamic>.from(
          jsonDecode(jsonEncode(block)) as Map<String, dynamic>,
        );
    }
  }

  static List<Message> _messagesFromSavedApiMessages(
    List<Map<String, dynamic>> messages,
  ) {
    return messages.map((message) {
      final role = message['role'] as String? ?? 'assistant';
      final content = (message['content'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => ContentBlock.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      return Message(role: role, content: content);
    }).toList();
  }

  static String _compactToolResultForPersistence({
    required String summary,
    required String fullResult,
    required List<Map<String, dynamic>> apiContent,
  }) {
    final sanitizedBlocks = _sanitizeApiContentForPersistence(apiContent);
    if (sanitizedBlocks.isNotEmpty) {
      final text = sanitizedBlocks
          .map((block) => block['text'] as String? ?? '')
          .where((text) => text.trim().isNotEmpty)
          .join('\n\n')
          .trim();
      if (text.isNotEmpty) {
        return _truncatePersistedText(text);
      }
    }

    final stripped = _stripBase64FromJson(fullResult).trim();
    if (stripped.isNotEmpty) {
      return _truncatePersistedText(stripped);
    }
    return summary;
  }

  static String _truncatePersistedText(String text) {
    if (text.length <= _maxPersistedToolTextChars) return text;
    final head = text.substring(0, _maxPersistedToolTextChars);
    return '$head\n\n[tool result truncated for session storage]';
  }

  /// Remove base64 fields from a JSON string to prevent accidental text-token billing.
  static String _stripBase64FromJson(String json) {
    // Quick check — if no base64 key, return as-is
    if (!json.contains('"base64"') && !json.contains('"image_base64"')) {
      return json;
    }
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) {
        _removeBase64Keys(decoded);
        return const JsonEncoder.withIndent('  ').convert(decoded);
      }
    } catch (_) {}
    return json;
  }

  static void _removeBase64Keys(Map<String, dynamic> map) {
    for (final key in map.keys.toList()) {
      if (key == 'base64' || key == 'image_base64') {
        map[key] = '[image data stripped]';
      } else if (map[key] is Map<String, dynamic>) {
        _removeBase64Keys(map[key] as Map<String, dynamic>);
      } else if (map[key] is List) {
        for (final item in map[key] as List) {
          if (item is Map<String, dynamic>) _removeBase64Keys(item);
        }
      }
    }
  }

  /// Strip old image/document blocks from _apiMessages in-place.
  /// Keeps only the 2 most recent messages containing media intact.
  /// This prevents the Dart heap from growing unboundedly as images accumulate.
  ///
  /// Must recurse into ToolResultBlock.content because tool-returned images
  /// are nested: Message.content = [ToolResultBlock(content: [ImageBlock(...)])]
  void _compactApiMessages() {
    const keepRecent = 2;
    final mediaIndices = <int>[];

    for (int i = 0; i < _apiMessages.length; i++) {
      if (_messageContainsMedia(_apiMessages[i])) {
        mediaIndices.add(i);
      }
    }

    if (mediaIndices.length <= keepRecent) return;

    final toStrip = mediaIndices.sublist(0, mediaIndices.length - keepRecent);
    for (final idx in toStrip) {
      final msg = _apiMessages[idx];
      final newContent = msg.content.map((block) {
        if (block is ImageBlock) {
          return TextBlock('[image previously analyzed]') as ContentBlock;
        }
        if (block is ToolResultBlock) {
          final hasMedia = block.content.any((c) => c is ImageBlock);
          if (hasMedia) {
            final newInner = block.content.map((c) {
              if (c is ImageBlock) {
                return TextBlock('[image previously analyzed]') as ContentBlock;
              }
              return c;
            }).toList();
            return ToolResultBlock(
              toolUseId: block.toolUseId,
              content: newInner,
              isError: block.isError,
            ) as ContentBlock;
          }
        }
        return block;
      }).toList();
      _apiMessages[idx] = Message(role: msg.role, content: newContent);
    }
  }

  /// Check if a message contains image blocks at any nesting level.
  static bool _messageContainsMedia(Message msg) {
    for (final b in msg.content) {
      if (b is ImageBlock) return true;
      if (b is ToolResultBlock) {
        if (b.content.any((c) => c is ImageBlock)) return true;
      }
    }
    return false;
  }

  static Map<String, dynamic> _serializeAttachedImage(AttachedImage image) {
    return {
      'media_type': image.mediaType,
      'base64': base64Encode(image.bytes),
      if (image.fileName != null) 'file_name': image.fileName,
    };
  }

  static AttachedImage? _restoreAttachedImage(dynamic value) {
    if (value is! Map) return null;
    final image = Map<String, dynamic>.from(value);
    final mediaType = image['media_type'] as String?;
    final base64Data = image['base64'] as String?;
    if (mediaType == null ||
        mediaType.isEmpty ||
        base64Data == null ||
        base64Data.isEmpty) {
      return null;
    }
    try {
      return AttachedImage(
        bytes: base64Decode(base64Data),
        mediaType: mediaType,
        fileName: image['file_name'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  void _appendAssistantToApiHistory({
    required List<ChatContentBlock> contentBlocks,
  }) {
    final assistantBlocks = <ContentBlock>[];
    final resultBlocks = <ContentBlock>[];

    void flushCurrentTurn() {
      if (assistantBlocks.isNotEmpty) {
        _apiMessages.add(
          Message(
            role: 'assistant',
            content: List<ContentBlock>.from(assistantBlocks),
          ),
        );
      }
      if (resultBlocks.isNotEmpty) {
        _apiMessages.add(
          Message(
            role: 'user',
            content: List<ContentBlock>.from(resultBlocks),
          ),
        );
      }
      assistantBlocks.clear();
      resultBlocks.clear();
    }

    for (final block in contentBlocks) {
      if (block is TextSegment && block.text.isNotEmpty) {
        if (resultBlocks.isNotEmpty) {
          flushCurrentTurn();
        }
        assistantBlocks.add(TextBlock(block.text));
      } else if (block is ToolUseSegment) {
        final tr = block.result;
        final hasResult = tr != null &&
            (tr.fullResult.trim().isNotEmpty ||
                (tr.apiContent?.isNotEmpty ?? false));
        if (!hasResult) {
          continue;
        }
        assistantBlocks.add(ToolUseBlock(
          id: block.toolUseId,
          name: block.toolName,
          input: Map<String, dynamic>.from(block.input),
        ));
        resultBlocks.add(ToolResultBlock(
          toolUseId: tr.toolUseId,
          content: _contentBlocksFromApiContent(tr.apiContent, tr.fullResult),
          isError: tr.isError,
        ));
      }
    }
    flushCurrentTurn();
  }

  void _replaceApiHistoryWithPairedVersion() {
    final repaired = _ensureToolResultPairing(_apiMessages);
    if (repaired.length != _apiMessages.length ||
        !_sameMessageSequence(_apiMessages, repaired)) {
      developer.log(
        'Repaired tool_use/tool_result pairing before API call.',
        name: 'ChatNotifier._replaceApiHistoryWithPairedVersion',
      );
      _apiMessages
        ..clear()
        ..addAll(repaired);
    }
  }

  static List<Message> _ensureToolResultPairing(List<Message> messages) {
    final repaired = <Message>[];
    int index = 0;

    while (index < messages.length) {
      final msg = messages[index];
      if (msg.role != 'assistant') {
        final sanitizedUser = _stripOrphanedToolResults(msg);
        if (sanitizedUser != null) repaired.add(sanitizedUser);
        index++;
        continue;
      }

      final assistantToolUses = msg.content.whereType<ToolUseBlock>().toList();
      if (assistantToolUses.isEmpty) {
        repaired.add(msg);
        index++;
        continue;
      }

      final next = index + 1 < messages.length ? messages[index + 1] : null;
      final nextUserResults = next?.role == 'user'
          ? next!.content.whereType<ToolResultBlock>().toList()
          : const <ToolResultBlock>[];
      final nextUserResultIds =
          nextUserResults.map((block) => block.toolUseId).toSet();
      final matchedToolUses = assistantToolUses
          .where((toolUse) => nextUserResultIds.contains(toolUse.id))
          .toList();

      final sanitizedAssistant = _sanitizeAssistantMessage(
        msg,
        keepToolUseIds: matchedToolUses.map((toolUse) => toolUse.id).toSet(),
      );
      if (sanitizedAssistant != null) {
        repaired.add(sanitizedAssistant);
      }

      if (next?.role == 'user') {
        final keepToolUseIds =
            matchedToolUses.map((toolUse) => toolUse.id).toSet();
        final sanitizedUser = _sanitizeUserToolResultMessage(
          next!,
          keepToolUseIds: keepToolUseIds,
        );
        if (sanitizedUser != null) {
          repaired.add(sanitizedUser);
        }
        index += 2;
      } else {
        index++;
      }
    }

    return repaired;
  }

  static Message? _sanitizeAssistantMessage(
    Message msg, {
    required Set<String> keepToolUseIds,
  }) {
    final content = <ContentBlock>[];
    for (final block in msg.content) {
      if (block is ToolUseBlock) {
        if (keepToolUseIds.contains(block.id)) {
          content.add(block);
        }
      } else {
        content.add(block);
      }
    }
    return content.isEmpty ? null : Message(role: msg.role, content: content);
  }

  static Message? _sanitizeUserToolResultMessage(
    Message msg, {
    required Set<String> keepToolUseIds,
  }) {
    final content = <ContentBlock>[];
    for (final block in msg.content) {
      if (block is ToolResultBlock) {
        if (keepToolUseIds.contains(block.toolUseId)) {
          content.add(block);
        }
      } else {
        content.add(block);
      }
    }
    return content.isEmpty ? null : Message(role: msg.role, content: content);
  }

  static Message? _stripOrphanedToolResults(Message msg) {
    if (msg.role != 'user') return msg;
    final content =
        msg.content.where((block) => block is! ToolResultBlock).toList();
    return content.isEmpty ? null : Message(role: msg.role, content: content);
  }

  static bool _sameMessageSequence(List<Message> a, List<Message> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (jsonEncode(a[i].toJson()) != jsonEncode(b[i].toJson())) return false;
    }
    return true;
  }

  /// Schedule a batched UI update. Marks state dirty and starts a 50ms timer.
  /// When the timer fires, the latest message is flushed to state.
  void _scheduleUiFlush(ChatMessage msg) {
    _pendingMsg = msg;
    _uiDirty = true;
    _uiFlushTimer ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_uiDirty && _pendingMsg != null) {
        _flushUi(_pendingMsg!);
      }
    });
  }

  ChatMessage? _pendingMsg;

  /// Immediately flush pending UI state (cancel timer debounce).
  void _flushUi(ChatMessage msg) {
    _uiDirty = false;
    _updateLastMessage(msg);
  }

  void _cancelUiTimer() {
    _uiFlushTimer?.cancel();
    _uiFlushTimer = null;
    _uiDirty = false;
    _pendingMsg = null;
  }

  void _updateLastMessage(ChatMessage msg) {
    final msgs = [...state.messages];
    if (msgs.isNotEmpty && msgs.last.id == msg.id) {
      msgs[msgs.length - 1] = msg;
    }
    state = state.copyWith(messages: msgs);
  }

  void stopStreaming() {
    _cancelled = true;
    _cancelUiTimer();
    // Cancel the in-flight HTTP request so the server stops generating
    // tokens (and billing) immediately.
    _activeApi?.cancelStream();
    _activeApi = null;
    _engine = null;
    state = state.copyWith(isStreaming: false);
  }

  Future<void> _loadSession(String sessionId) async {
    final manager = _ref.read(sessionManagerProvider);
    await manager.init();
    final entries = await manager.loadSession(sessionId);

    final List<ChatMessage> chatMessages = [];
    _apiMessages.clear();

    // Collect tool_result entries keyed by tool_use_id for pairing with assistant messages
    final toolResultsByUseId = <String, SessionEntry>{};
    for (final entry in entries) {
      if (entry.type == 'tool_result') {
        final useId = entry.data['tool_use_id'] as String?;
        if (useId != null) toolResultsByUseId[useId] = entry;
      }
    }

    for (final entry in entries) {
      switch (entry.type) {
        case 'user':
          final content = entry.data['content'] as String? ?? '';
          final restoredImage = _restoreAttachedImage(entry.data['image']);
          final contentBlocks = <ChatContentBlock>[];
          final images = <AttachedImage>[];

          if (restoredImage != null) {
            images.add(restoredImage);
          }

          if (content.isNotEmpty) {
            contentBlocks.add(TextSegment(content));
          }

          if (images.isNotEmpty || contentBlocks.isNotEmpty) {
            chatMessages.add(ChatMessage(
              id: entry.uuid,
              role: 'user',
              contentBlocks: contentBlocks,
              images: images,
            ));
          }

          if (restoredImage != null) {
            _apiMessages.add(Message(
              role: 'user',
              content: [
                ImageBlock(
                  base64Data: base64Encode(restoredImage.bytes),
                  mediaType: restoredImage.mediaType,
                ),
                if (content.trim().isNotEmpty) TextBlock(content),
              ],
            ));
          } else if (content.isNotEmpty) {
            _apiMessages.add(Message.user(content));
          }

        case 'assistant':
          final content = entry.data['content'] as String? ?? '';
          final orderedBlocks = entry.data['ordered_blocks'] as List?;
          // Fallback for older sessions that don't have ordered_blocks
          final toolUses = entry.data['tool_uses'] as List?;
          final usage = entry.data['usage'] as Map?;

          // Build ordered content blocks for UI.
          final resumeBlocks = <ChatContentBlock>[];

          if (orderedBlocks != null) {
            // New format: blocks are saved in order
            for (final block in orderedBlocks) {
              final type = block['type'] as String?;
              if (type == 'text') {
                final text = block['text'] as String? ?? '';
                if (text.isNotEmpty) resumeBlocks.add(TextSegment(text));
              } else if (type == 'tool_use') {
                final useId = block['id'] as String? ?? '';
                final name = block['name'] as String? ?? '';
                final input = Map<String, dynamic>.from(
                  (block['input'] as Map?) ?? const <String, dynamic>{},
                );
                final saved = toolResultsByUseId[useId];
                final toolResult = ToolResult(
                  toolUseId: useId,
                  toolName: name,
                  summary: saved?.data['summary'] as String? ?? 'Completed',
                  fullResult: saved?.data['full_result'] as String? ??
                      saved?.data['summary'] as String? ??
                      '',
                  isError: saved?.data['is_error'] as bool? ?? false,
                  apiContent: _savedApiContent(saved),
                  data: _savedResultData(saved),
                );
                resumeBlocks.add(ToolUseSegment(
                  toolUseId: useId,
                  toolName: name,
                  input: input,
                  status: ToolCallStatus.completed,
                  result: toolResult,
                ));
              }
            }
          } else {
            // Old format: tools first, then text
            if (toolUses != null) {
              for (final tu in toolUses) {
                final useId = tu['id'] as String? ?? '';
                final name = tu['name'] as String? ?? '';
                final input = Map<String, dynamic>.from(
                  (tu['input'] as Map?) ?? const <String, dynamic>{},
                );
                final saved = toolResultsByUseId[useId];
                final toolResult = ToolResult(
                  toolUseId: useId,
                  toolName: name,
                  summary: saved?.data['summary'] as String? ?? 'Completed',
                  fullResult: saved?.data['full_result'] as String? ??
                      saved?.data['summary'] as String? ??
                      '',
                  isError: saved?.data['is_error'] as bool? ?? false,
                  apiContent: _savedApiContent(saved),
                  data: _savedResultData(saved),
                );
                resumeBlocks.add(ToolUseSegment(
                  toolUseId: useId,
                  toolName: name,
                  input: input,
                  status: ToolCallStatus.completed,
                  result: toolResult,
                ));
              }
            }
            if (content.isNotEmpty) {
              resumeBlocks.add(TextSegment(content));
            }
          }

          chatMessages.add(ChatMessage(
            id: entry.uuid,
            role: 'assistant',
            contentBlocks: resumeBlocks,
            inputTokens: usage?['total_input_tokens'] as int? ?? 0,
            outputTokens: usage?['output_tokens'] as int? ?? 0,
          ));

          final savedApiMessages = _savedApiMessages(entry);
          if (savedApiMessages != null && savedApiMessages.isNotEmpty) {
            _apiMessages
                .addAll(_messagesFromSavedApiMessages(savedApiMessages));
          } else {
            _appendAssistantToApiHistory(
              contentBlocks: resumeBlocks,
            );
          }

        case 'tool_result':
          // Handled above via toolResultsByUseId — paired with assistant entries
          break;

        case 'api_request':
        case 'api_response':
        case 'api_error':
          break;

        default:
          developer.log(
            'Unknown session entry type: "${entry.type}"',
            name: 'ChatNotifier._loadSession',
            level: 900,
          );
      }
    }

    state = state.copyWith(messages: chatMessages);
    _replaceApiHistoryWithPairedVersion();
  }

  static List<Map<String, dynamic>>? _savedApiContent(SessionEntry? saved) {
    return (saved?.data['api_content'] as List?)
        ?.whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  static List<Map<String, dynamic>>? _savedApiMessages(SessionEntry entry) {
    return (entry.data['api_messages'] as List?)
        ?.whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  static Map<String, dynamic>? _savedResultData(SessionEntry? saved) {
    final raw = saved?.data['result_data'];
    if (raw is! Map) return null;
    return Map<String, dynamic>.from(raw);
  }

  @override
  void dispose() {
    _cancelUiTimer();
    stopStreaming();
    super.dispose();
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>(
  (ref) => ChatNotifier(ref),
);
