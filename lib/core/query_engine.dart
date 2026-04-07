import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../models/message.dart';
import '../utils/cost_tracker.dart';
import 'claude_api.dart';
import 'system_prompt.dart';
import 'tool_router.dart';

/// The core conversation loop.
/// Sends messages to Claude, handles tool calls, loops until end_turn.
class QueryEngine {
  final ClaudeApi api;
  final ToolRouter toolRouter;
  final CostTracker costTracker;
  String model;

  QueryEngine({
    required this.api,
    required this.toolRouter,
    required this.model,
    CostTracker? costTracker,
  }) : costTracker = costTracker ?? CostTracker();

  /// Maximum number of agentic loop iterations before forcing a stop.
  static const int maxTurns = 25;

  /// Timeout for individual tool executions.
  static const Duration defaultToolTimeout = Duration(seconds: 30);

  /// Timeout for the API stream (no event received within this window).
  static const Duration apiStreamTimeout = Duration(seconds: 120);

  /// Default per-tool result size limit (chars). Individual tools may override.
  static const int defaultMaxResultSizeChars = 50000;

  /// Per-message aggregate limit (chars) across all tool results in one turn.
  static const int maxToolResultsPerMessageChars = 200000;

  /// Maximum concurrent tool executions.
  /// Kept in sync with the Android native file-tool executor so queued work
  /// does not burn most of the per-tool timeout budget before execution starts.
  static const int maxConcurrentTools = 2;

  /// Maximum media blocks (image/document) in a single tool results message.
  /// Conservative on mobile to limit memory — 20 images × ~400KB base64
  /// each = ~8MB peak. API allows up to 100.
  static const int maxMediaBlocksPerMessage = 20;

  /// Maximum recovery attempts when output hits token limit.
  static const int maxOutputTokensRecoveryLimit = 3;

  static Duration _toolTimeoutFor(String toolName) {
    switch (toolName) {
      case 'FileWrite':
      case 'FileEdit':
        return const Duration(minutes: 3);
      case 'FileContentSearch':
        return const Duration(seconds: 90);
      case 'FileSearch':
      case 'FileRead':
        return const Duration(seconds: 60);
      case 'DirectoryList':
        return const Duration(seconds: 45);
      default:
        return defaultToolTimeout;
    }
  }

  /// Run a full conversation turn.
  /// Yields [ChatUpdate] events for the UI to render incrementally.
  Stream<ChatUpdate> sendMessage({
    required List<Message> conversationHistory,
  }) async* {
    final tools = toolRouter.getToolSchemas();
    final systemPrompt = buildSystemPrompt(
      model: model,
    );

    // The messages we'll send — starts with history, grows as we add tool results
    final messages = conversationHistory.map((m) => m.toJson()).toList();

    int outputTokensRecoveryCount = 0;
    final historyMessages = <Map<String, dynamic>>[];
    // Track media result IDs that have been sent in at least one API call.
    // Only media that Claude has already seen can be stripped by microcompact.
    final sentMediaIds = <String>{};

    for (int turn = 0; turn < maxTurns; turn++) {
      // Microcompact: strip image/document blocks from old tool results before
      // each API call, but only strip media Claude has already seen.
      final compactedMessages =
          _microcompact(messages, alreadySentIds: sentMediaIds);

      // Ordered list of content blocks to faithfully reconstruct the
      // visible assistant message (text and local tool_use blocks may interleave).
      final contentBlocks = <Map<String, dynamic>>[];
      // Full assistant API content for this streamed segment, including
      // server-tool blocks and citations that are hidden from the UI.
      final assistantApiBlocks = <Map<String, dynamic>>[];
      final pendingToolCalls = <int, _PendingToolCall>{};
      int? currentTextBlockIndex;
      int? currentApiTextBlockIndex;
      String? stopReason;
      String? responseMessageId;
      String? responseModel;
      int inputTokens = 0;
      int outputTokens = 0;
      int cacheReadTokens = 0;
      int cacheCreationTokens = 0;
      int webSearchRequests = 0;
      List<dynamic>? appliedContextEdits;

      void mergeUsageSnapshot({
        int? nextInputTokens,
        int? nextOutputTokens,
        int? nextCacheReadTokens,
        int? nextCacheCreationTokens,
        int? nextWebSearchRequests,
      }) {
        if (nextInputTokens != null && nextInputTokens > 0) {
          inputTokens = nextInputTokens;
        }
        if (nextOutputTokens != null) {
          outputTokens = nextOutputTokens;
        }
        if (nextCacheReadTokens != null && nextCacheReadTokens > 0) {
          cacheReadTokens = nextCacheReadTokens;
        }
        if (nextCacheCreationTokens != null && nextCacheCreationTokens > 0) {
          cacheCreationTokens = nextCacheCreationTokens;
        }
        if (nextWebSearchRequests != null && nextWebSearchRequests > 0) {
          webSearchRequests = nextWebSearchRequests;
        }
      }

      yield RequestPrepared(
        turnIndex: turn + 1,
        request: _buildRequestSnapshot(
          turnIndex: turn + 1,
          model: model,
          maxTokens: defaultClaudeMaxTokens,
          messages: compactedMessages,
          tools: tools,
          system: systemPrompt,
        ),
      );

      try {
        final rawStream = api.createMessageStream(
          model: model,
          messages: compactedMessages,
          tools: tools,
          system: systemPrompt,
          maxTokens: defaultClaudeMaxTokens,
        );
        await for (final event in rawStream.timeout(apiStreamTimeout)) {
          switch (event) {
            case MessageStartEvent():
              responseMessageId = event.messageId;
              responseModel = event.model;
              mergeUsageSnapshot(
                nextInputTokens: event.inputTokens,
                nextCacheReadTokens: event.cacheReadTokens,
                nextCacheCreationTokens: event.cacheCreationTokens,
                nextWebSearchRequests: event.webSearchRequests,
              );

            case ContentBlockStartEvent():
              if (event.type == 'text') {
                // Start a new text block
                assistantApiBlocks.add(_newAssistantTextBlock(event.block));
                currentApiTextBlockIndex = assistantApiBlocks.length - 1;
                contentBlocks.add({'type': 'text', 'text': ''});
                currentTextBlockIndex = contentBlocks.length - 1;
              } else {
                currentTextBlockIndex = null;
                currentApiTextBlockIndex = null;
                assistantApiBlocks.add(
                  Map<String, dynamic>.from(
                    _cloneJsonValue(event.block) as Map<String, dynamic>,
                  ),
                );
              }

            case TextDeltaEvent():
              // Append to the current text block, creating one if needed
              if (currentApiTextBlockIndex != null) {
                assistantApiBlocks[currentApiTextBlockIndex]['text'] =
                    (assistantApiBlocks[currentApiTextBlockIndex]['text']
                                as String? ??
                            '') +
                        event.text;
              } else {
                assistantApiBlocks.add({'type': 'text', 'text': event.text});
                currentApiTextBlockIndex = assistantApiBlocks.length - 1;
              }
              if (currentTextBlockIndex != null) {
                contentBlocks[currentTextBlockIndex]['text'] =
                    (contentBlocks[currentTextBlockIndex]['text'] as String) +
                        event.text;
              } else {
                contentBlocks.add({'type': 'text', 'text': event.text});
                currentTextBlockIndex = contentBlocks.length - 1;
              }
              yield TextDelta(event.text);

            case ToolUseStartEvent():
              // A tool_use block starts — any preceding text block is complete
              currentTextBlockIndex = null;
              currentApiTextBlockIndex = null;
              pendingToolCalls[event.index] = _PendingToolCall(
                id: event.id,
                name: event.name,
              );
              assistantApiBlocks.add({
                'type': 'tool_use',
                'id': event.id,
                'name': event.name,
                'input': <String, dynamic>{},
              });
              // Add a placeholder that will be filled once input JSON is complete
              contentBlocks.add({
                'type': 'tool_use',
                'id': event.id,
                'name': event.name,
                'input': <String, dynamic>{},
                '_block_index': event.index, // track which pending call this is
              });
              yield ToolCallStarted(
                toolUseId: event.id,
                toolName: event.name,
              );

            case ServerToolUseStartEvent():
              currentTextBlockIndex = null;
              currentApiTextBlockIndex = null;
              pendingToolCalls[event.index] = _PendingToolCall(
                id: event.id,
                name: event.name,
                isServer: true,
              );
              assistantApiBlocks.add({
                'type': 'server_tool_use',
                'id': event.id,
                'name': event.name,
                'input': <String, dynamic>{},
              });

            case StructuredContentBlockStartEvent():
              currentTextBlockIndex = null;
              currentApiTextBlockIndex = null;
              assistantApiBlocks.add(
                Map<String, dynamic>.from(
                  _cloneJsonValue(event.block) as Map<String, dynamic>,
                ),
              );

            case InputJsonDeltaEvent():
              pendingToolCalls[event.index]?.inputJson += event.partialJson;

            case CitationsDeltaEvent():
              _appendCitationToAssistantTextBlock(
                assistantApiBlocks,
                currentApiTextBlockIndex,
                event.citation,
              );

            case ContentBlockStopEvent():
              // If last block was a tool_use, it's now complete
              break;

            case MessageDeltaEvent():
              stopReason = event.stopReason;
              mergeUsageSnapshot(
                nextInputTokens: event.inputTokens,
                nextOutputTokens: event.outputTokens,
                nextCacheReadTokens: event.cacheReadTokens,
                nextCacheCreationTokens: event.cacheCreationTokens,
                nextWebSearchRequests: event.webSearchRequests,
              );
              if (event.appliedContextEdits != null) {
                appliedContextEdits = event.appliedContextEdits;
              }

            case MessageStopEvent():
              break;

            case ErrorEvent():
              yield StreamError(event.message);
              return;
          }
        }
      } on TimeoutException {
        yield StreamError(
            'API stream timed out after ${apiStreamTimeout.inSeconds}s with no events.');
        return;
      } on ApiException catch (e) {
        yield StreamError(e.message);
        return;
      } on RateLimitException {
        yield StreamError('Rate limited. Please wait and try again.');
        return;
      } catch (e) {
        yield StreamError('Connection error: ${e.toString()}');
        return;
      }

      // Parse tool inputs once and reuse for both assistant message history and
      // local tool execution.
      final parsedInputs = <String, Map<String, dynamic>>{};
      final parseErrors = <String, String>{};
      for (final tc in pendingToolCalls.values) {
        try {
          if (tc.inputJson.isNotEmpty) {
            parsedInputs[tc.id] =
                jsonDecode(tc.inputJson) as Map<String, dynamic>;
          } else {
            parsedInputs[tc.id] = {};
          }
        } catch (e) {
          parseErrors[tc.id] = 'Failed to parse tool input: $e';
          parsedInputs[tc.id] = {};
          debugPrint(
              '[QueryEngine] Parse error for ${tc.name} (${tc.id}): $e\nRaw: ${tc.inputJson}');
        }
      }

      // Track costs
      costTracker.addUsage(
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cacheReadTokens: cacheReadTokens,
        cacheWriteTokens: cacheCreationTokens,
        webSearchRequests: webSearchRequests,
      );
      yield UsageUpdate(
        turnIndex: turn + 1,
        messageId: responseMessageId,
        model: responseModel ?? model,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cacheReadTokens: cacheReadTokens,
        cacheCreationTokens: cacheCreationTokens,
        webSearchRequests: webSearchRequests,
        stopReason: stopReason,
        appliedContextEdits: appliedContextEdits,
        cost: costTracker.estimateCost(responseModel ?? model),
      );

      // Register all media result IDs in the messages we just sent.
      // After this API call, Claude has "seen" these media — they can be
      // stripped by microcompact on subsequent iterations.
      sentMediaIds.addAll(_findMediaResultIds(compactedMessages));

      final assistantContent = _finalizeAssistantContentBlocks(
        assistantApiBlocks,
        parsedInputs,
      );

      // --- Max output tokens recovery ---
      // When response is cut mid-sentence, inject continuation message and retry.
      if (stopReason == 'max_tokens') {
        if (outputTokensRecoveryCount < maxOutputTokensRecoveryLimit) {
          outputTokensRecoveryCount++;
          if (assistantContent.isNotEmpty) {
            messages.add({'role': 'assistant', 'content': assistantContent});
            historyMessages.add({
              'role': 'assistant',
              'content': _cloneJsonValue(assistantContent),
            });
            messages.add({
              'role': 'user',
              'content': [
                {
                  'type': 'text',
                  'text': 'Output token limit hit. Resume directly — no apology, '
                      'no recap of what you were doing. Pick up mid-thought if '
                      'that is where the cut happened. Break remaining work into '
                      'smaller pieces.',
                }
              ],
            });
            continue; // retry
          }
        }
        yield StreamError(
          'Response was cut short because it reached the maximum token limit. '
          'Try asking for a shorter response or splitting your request into smaller parts.',
        );
        return;
      }
      if (stopReason == 'pause_turn') {
        if (assistantContent.isEmpty) {
          yield StreamError(
            'Claude paused the turn without returning assistant content to continue from.',
          );
          return;
        }
        final assistantMessage = <String, dynamic>{
          'role': 'assistant',
          'content': assistantContent,
        };
        messages.add(
          Map<String, dynamic>.from(
            _cloneJsonValue(assistantMessage) as Map<String, dynamic>,
          ),
        );
        historyMessages.add(
          Map<String, dynamic>.from(
            _cloneJsonValue(assistantMessage) as Map<String, dynamic>,
          ),
        );
        continue;
      }
      if (stopReason == 'model_context_window_exceeded') {
        yield StreamError(
          'The conversation is too long and exceeds the model\'s context window. '
          'Please start a new conversation to continue.',
        );
        return;
      }
      final localToolCalls = pendingToolCalls.values
          .where((tc) => !tc.isServer)
          .toList(growable: false);
      if (stopReason != 'tool_use' || localToolCalls.isEmpty) {
        if (assistantContent.isNotEmpty) {
          historyMessages.add({
            'role': 'assistant',
            'content': _cloneJsonValue(assistantContent),
          });
        }
        yield TurnComplete(historyMessages: historyMessages);
        return;
      }

      messages.add({'role': 'assistant', 'content': assistantContent});
      historyMessages.add({
        'role': 'assistant',
        'content': _cloneJsonValue(assistantContent),
      });

      // Execute tools with concurrency limit of maxConcurrentTools.
      final results = await _executeToolsThrottled(
          localToolCalls, parsedInputs, parseErrors);

      // --- Per-message budget: largest-first truncation ---
      // Sort by estimated content size descending to identify which results
      // to truncate first. Then apply budget in original order.
      final budgets = <String, int>{}; // toolUseId → allocated chars
      final sizes = <String, int>{};
      int totalEstimated = 0;
      for (final r in results) {
        final size = _estimateContentChars(r.apiContent);
        sizes[r.toolUseId] = size;
        totalEstimated += size;
      }

      if (totalEstimated > maxToolResultsPerMessageChars) {
        // Over budget — truncate largest results first
        final sorted = List<_ToolExecResult>.from(results)
          ..sort((a, b) =>
              (sizes[b.toolUseId] ?? 0).compareTo(sizes[a.toolUseId] ?? 0));
        int remaining = totalEstimated;
        final toTruncate = <String>{};
        for (final r in sorted) {
          if (remaining <= maxToolResultsPerMessageChars) break;
          toTruncate.add(r.toolUseId);
          remaining -= (sizes[r.toolUseId] ?? 0);
        }
        // Allocate budgets
        final perTruncated = toTruncate.isEmpty
            ? 0
            : (maxToolResultsPerMessageChars -
                    (totalEstimated -
                        toTruncate.fold<int>(
                            0, (s, id) => s + (sizes[id] ?? 0)))) ~/
                toTruncate.length;
        for (final r in results) {
          budgets[r.toolUseId] = toTruncate.contains(r.toolUseId)
              ? math.max(perTruncated, 1000)
              : sizes[r.toolUseId] ?? 0;
        }
      }

      // Cap media blocks per message
      int mediaBlockCount = 0;
      for (final r in results) {
        for (final b in r.apiContent) {
          if (b['type'] == 'image' || b['type'] == 'document') {
            mediaBlockCount++;
          }
        }
      }

      // Yield completions and build tool_result message
      final toolResults = <Map<String, dynamic>>[];
      int mediaYielded = 0;
      for (final r in results) {
        var apiContent = r.apiContent;

        // Apply per-result budget if over aggregate limit
        if (budgets.containsKey(r.toolUseId)) {
          final budget = budgets[r.toolUseId]!;
          if ((sizes[r.toolUseId] ?? 0) > budget) {
            apiContent = _truncateContentToBudget(apiContent, budget);
          }
        }

        // Cap media blocks
        if (mediaBlockCount > maxMediaBlocksPerMessage) {
          apiContent = apiContent.map((b) {
            if ((b['type'] == 'image' || b['type'] == 'document') &&
                mediaYielded >= maxMediaBlocksPerMessage) {
              return {
                'type': 'text',
                'text':
                    '[media omitted — max $maxMediaBlocksPerMessage media blocks per message]'
              };
            }
            if (b['type'] == 'image' || b['type'] == 'document') mediaYielded++;
            return b;
          }).toList();
        }

        yield ToolCallCompleted(
          toolUseId: r.toolUseId,
          toolName: r.toolName,
          input: parsedInputs[r.toolUseId] ?? const <String, dynamic>{},
          summary: r.summary,
          fullResult: r.fullResult,
          isError: r.isError,
          duration: r.duration,
          apiContent: apiContent,
          resultData: r.resultData,
        );
        toolResults.add({
          'type': 'tool_result',
          'tool_use_id': r.toolUseId,
          'content': apiContent,
          if (r.isError) 'is_error': true,
        });
      }

      // Add tool results to conversation
      messages.add({'role': 'user', 'content': toolResults});
      historyMessages.add({
        'role': 'user',
        'content': _cloneJsonValue(toolResults),
      });
    }

    // BUG 2 FIX: If we exit the for loop, we hit the max turns limit.
    yield StreamError(
      'Reached maximum turn limit ($maxTurns). '
      'Please start a new message to continue.',
    );
  }

  /// Execute tools with concurrency limit.
  Future<List<_ToolExecResult>> _executeToolsThrottled(
    List<_PendingToolCall> toolCalls,
    Map<String, Map<String, dynamic>> parsedInputs,
    Map<String, String> parseErrors,
  ) async {
    final results = List<_ToolExecResult?>.filled(toolCalls.length, null);
    int nextIndex = 0;

    Future<void> worker() async {
      while (nextIndex < toolCalls.length) {
        final i = nextIndex++;
        if (i >= toolCalls.length) break;
        results[i] =
            await _executeSingleTool(toolCalls[i], parsedInputs, parseErrors);
      }
    }

    final workerCount = math.min(maxConcurrentTools, toolCalls.length);
    await Future.wait(List.generate(workerCount, (_) => worker()));
    return results.cast<_ToolExecResult>();
  }

  Future<_ToolExecResult> _executeSingleTool(
    _PendingToolCall tc,
    Map<String, Map<String, dynamic>> parsedInputs,
    Map<String, String> parseErrors,
  ) async {
    final parsedInput = parsedInputs[tc.id] ?? {};
    final jsonParseError = parseErrors[tc.id];

    if (jsonParseError != null) {
      return _ToolExecResult(
        toolUseId: tc.id,
        toolName: tc.name,
        summary: 'Error: $jsonParseError',
        fullResult:
            'Input JSON parse error: $jsonParseError\nRaw: ${tc.inputJson}',
        isError: true,
        duration: Duration.zero,
        apiContent: [
          {'type': 'text', 'text': 'Error: $jsonParseError'}
        ],
        resultData: null,
      );
    }

    final stopwatch = Stopwatch()..start();
    final timeout = _toolTimeoutFor(tc.name);
    try {
      final result =
          await toolRouter.execute(tc.name, parsedInput).timeout(timeout);
      stopwatch.stop();

      final apiContent = _buildToolResultContent(result, toolName: tc.name);

      // Strip base64 from fullResult when apiContent already has it (avoid double copy)
      final fullResult = _hasMediaContent(apiContent)
          ? _stripBase64FromResult(result)
          : const JsonEncoder.withIndent('  ').convert(result);

      return _ToolExecResult(
        toolUseId: tc.id,
        toolName: tc.name,
        summary: _summarizeResult(result),
        fullResult: fullResult,
        isError: false,
        duration: stopwatch.elapsed,
        apiContent: apiContent,
        resultData: _extractPersistableResultData(tc.name, result),
      );
    } on TimeoutException {
      stopwatch.stop();
      final msg = 'Tool "${tc.name}" timed out after ${timeout.inSeconds}s';
      return _ToolExecResult(
        toolUseId: tc.id,
        toolName: tc.name,
        summary: 'Error: $msg',
        fullResult: msg,
        isError: true,
        duration: stopwatch.elapsed,
        apiContent: [
          {'type': 'text', 'text': 'Error: $msg'}
        ],
        resultData: null,
      );
    } catch (e) {
      stopwatch.stop();
      return _ToolExecResult(
        toolUseId: tc.id,
        toolName: tc.name,
        summary: 'Error: $e',
        fullResult: e.toString(),
        isError: true,
        duration: stopwatch.elapsed,
        apiContent: [
          {'type': 'text', 'text': 'Error: $e'}
        ],
        resultData: null,
      );
    }
  }

  static Map<String, dynamic>? _extractPersistableResultData(
    String toolName,
    dynamic result,
  ) {
    if (result is! Map) return null;
    if (toolName != 'FileWrite' && toolName != 'FileEdit') return null;

    final map = Map<String, dynamic>.from(result);
    const allowedKeys = <String>{
      'action',
      'file_name',
      'relative_path',
      'path',
      'bytes_written',
      'match_count',
      'replaced_count',
    };
    final filtered = <String, dynamic>{};
    for (final key in allowedKeys) {
      if (map.containsKey(key)) filtered[key] = map[key];
    }
    return filtered.isEmpty ? null : filtered;
  }

  /// Convert a tool result into the correct API content blocks.
  List<Map<String, dynamic>> _buildToolResultContent(dynamic result,
      {String? toolName}) {
    // Empty result handling
    if (result == null ||
        (result is String && result.trim().isEmpty) ||
        (result is Map && result.isEmpty)) {
      return [
        {
          'type': 'text',
          'text': '(${toolName ?? 'tool'} completed with no output)'
        }
      ];
    }

    if (result is! Map) {
      return [
        {'type': 'text', 'text': result.toString()}
      ];
    }

    final contentType = result['content_type'] as String?;

    // Single image from FileRead for image files
    if (contentType == 'image' && result['base64'] != null) {
      return [
        {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': result['media_type'] ?? 'image/jpeg',
            'data': result['base64'],
          },
        },
      ];
    }

    // PDF sent as document block (small PDF, < 3MB)
    if (contentType == 'pdf_document' && result['base64'] != null) {
      return [
        {
          'type': 'document',
          'source': {
            'type': 'base64',
            'media_type': 'application/pdf',
            'data': result['base64'],
          },
        },
      ];
    }

    // PDF pages rendered as JPEG images
    if (contentType == 'pdf_pages' && result['pages'] != null) {
      final blocks = <Map<String, dynamic>>[];
      final pages = result['pages'] as List;
      for (final page in pages) {
        if (page is Map && page['image_base64'] != null) {
          blocks.add({
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': page['media_type'] ?? 'image/jpeg',
              'data': page['image_base64'],
            },
          });
        }
      }
      if (blocks.isEmpty) {
        return [
          {'type': 'text', 'text': jsonEncode(result)}
        ];
      }
      return blocks;
    }

    // Default: JSON text — apply per-tool size limit with smart truncation
    final text = jsonEncode(result);
    final tool = toolName != null ? toolRouter.findTool(toolName) : null;
    final effectiveLimit = tool != null && tool.maxResultSizeChars.isFinite
        ? tool.maxResultSizeChars.toInt()
        : defaultMaxResultSizeChars;

    if (text.length > effectiveLimit) {
      return _smartTruncate(text, effectiveLimit);
    }
    return [
      {'type': 'text', 'text': text}
    ];
  }

  /// Smart truncation: 70% head + 20% tail + guidance message.
  /// Gives Claude both the beginning and end of results.
  static List<Map<String, dynamic>> _smartTruncate(String text, int limit) {
    final headSize = (limit * 0.7).toInt();
    final tailSize = (limit * 0.2).toInt();
    final head = text.substring(0, math.min(headSize, text.length));
    final tail = text.substring(math.max(text.length - tailSize, headSize));
    final omitted = text.length - headSize - tailSize;
    return [
      {
        'type': 'text',
        'text': '$head\n\n'
            '[... $omitted characters omitted — ${text.length} total, limit $limit ...]\n\n'
            '$tail\n\n'
            '[Result truncated. Use more specific query parameters or request a smaller range.]',
      }
    ];
  }

  /// Estimate content chars including media blocks against the budget.
  static int _estimateContentChars(List<Map<String, dynamic>> content) {
    int total = 0;
    for (final b in content) {
      switch (b['type']) {
        case 'text':
          total += ((b['text'] as String?) ?? '').length;
        case 'image':
          total += 8000; // ~2000 tokens ≈ ~8000 chars
        case 'document':
          final data = (b['source'] as Map?)?['data'] as String? ?? '';
          total += data.length ~/ 4; // rough token-to-char estimate
        case 'server_tool_use':
        case 'web_search_tool_result':
          total += jsonEncode(b).length;
        default:
          total += 100;
      }
    }
    return total;
  }

  /// Truncate content blocks to fit within a char budget.
  static List<Map<String, dynamic>> _truncateContentToBudget(
    List<Map<String, dynamic>> content,
    int budget,
  ) {
    int used = 0;
    final result = <Map<String, dynamic>>[];
    for (final b in content) {
      final size = _estimateContentChars([b]);
      if (used + size <= budget) {
        result.add(b);
        used += size;
      } else if (b['type'] == 'text') {
        final remaining = budget - used;
        if (remaining > 200) {
          final text = (b['text'] as String?) ?? '';
          result.add({
            'type': 'text',
            'text':
                '${text.substring(0, math.min(remaining, text.length))}\n\n[Truncated to fit message budget]',
          });
        }
        break;
      }
      // Skip remaining media blocks if over budget
    }
    if (result.isEmpty) {
      result.add({
        'type': 'text',
        'text': '[Result omitted — message size budget exceeded]'
      });
    }
    return result;
  }

  /// Check if content has any image or document blocks.
  static bool _hasMediaContent(List<Map<String, dynamic>> content) {
    return content.any((b) => b['type'] == 'image' || b['type'] == 'document');
  }

  /// Strip base64 fields from a result for fullResult (UI display only).
  /// apiContent already has the real binary data for the API.
  static String _stripBase64FromResult(dynamic result) {
    if (result is! Map) return result.toString();
    final cleaned = Map<String, dynamic>.from(result);
    cleaned.remove('base64');
    cleaned.remove('image_base64');
    if (cleaned['pages'] is List) {
      cleaned['pages'] = (cleaned['pages'] as List).map((p) {
        if (p is Map) {
          final cp = Map<String, dynamic>.from(p);
          cp.remove('image_base64');
          return cp;
        }
        return p;
      }).toList();
    }
    return const JsonEncoder.withIndent('  ').convert(cleaned);
  }

  /// Microcompact: strip image/document base64 from old tool results.
  ///
  /// - Only strip media that Claude has already seen (in `alreadySentIds`)
  /// - Keep the N most recent already-seen media results intact
  /// - Never strip media that hasn't been sent yet (new tool results from this iteration)
  /// - This prevents re-sending large base64 data on every API call
  static const int _keepRecentMediaResults = 2;

  List<Map<String, dynamic>> _microcompact(
    List<Map<String, dynamic>> messages, {
    Set<String> alreadySentIds = const {},
  }) {
    final mediaResultIds = <String>[];

    for (final msg in messages) {
      final content = msg['content'];
      if (content is! List) continue;
      for (final block in content) {
        if (block is! Map) continue;
        if (block['type'] != 'tool_result') continue;
        final inner = block['content'];
        if (inner is! List) continue;
        for (final item in inner) {
          if (item is Map &&
              (item['type'] == 'image' || item['type'] == 'document')) {
            final id = block['tool_use_id'] as String?;
            if (id != null && !mediaResultIds.contains(id)) {
              mediaResultIds.add(id);
            }
            break;
          }
        }
      }
    }

    // Only consider stripping media Claude has already seen in a prior API call.
    // Media just added (not in alreadySentIds) must be kept for Claude to see.
    final strippable =
        mediaResultIds.where((id) => alreadySentIds.contains(id)).toList();

    if (strippable.length <= _keepRecentMediaResults) return messages;

    final stripIds = strippable
        .sublist(0, strippable.length - _keepRecentMediaResults)
        .toSet();

    return messages.map((msg) {
      final content = msg['content'];
      if (content is! List) return msg;

      bool modified = false;
      final newContent = content.map((block) {
        if (block is! Map) return block;
        if (block['type'] != 'tool_result') return block;
        final id = block['tool_use_id'] as String?;
        if (id == null || !stripIds.contains(id)) return block;

        final inner = block['content'];
        if (inner is! List) return block;

        final newInner = inner.map((item) {
          if (item is Map && item['type'] == 'image') {
            modified = true;
            return {'type': 'text', 'text': '[image previously analyzed]'};
          }
          if (item is Map && item['type'] == 'document') {
            modified = true;
            return {'type': 'text', 'text': '[document previously read]'};
          }
          return item;
        }).toList();

        return {...block, 'content': newInner};
      }).toList();

      return modified ? {...msg, 'content': newContent} : msg;
    }).toList();
  }

  /// Extract all tool_use_ids that have media content from serialized messages.
  static Set<String> _findMediaResultIds(List<Map<String, dynamic>> messages) {
    final ids = <String>{};
    for (final msg in messages) {
      final content = msg['content'];
      if (content is! List) continue;
      for (final block in content) {
        if (block is! Map || block['type'] != 'tool_result') continue;
        final inner = block['content'];
        if (inner is! List) continue;
        for (final item in inner) {
          if (item is Map &&
              (item['type'] == 'image' || item['type'] == 'document')) {
            final id = block['tool_use_id'] as String?;
            if (id != null) ids.add(id);
            break;
          }
        }
      }
    }
    return ids;
  }

  static Map<String, dynamic> _newAssistantTextBlock(
    Map<String, dynamic> rawBlock,
  ) {
    final textBlock = <String, dynamic>{
      'type': 'text',
      'text': rawBlock['text'] as String? ?? '',
    };
    final citations = (rawBlock['citations'] as List?)
        ?.whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    if (citations != null && citations.isNotEmpty) {
      textBlock['citations'] = citations;
    }
    return textBlock;
  }

  static void _appendCitationToAssistantTextBlock(
    List<Map<String, dynamic>> blocks,
    int? currentTextBlockIndex,
    Map<String, dynamic> citation,
  ) {
    if (currentTextBlockIndex == null ||
        currentTextBlockIndex < 0 ||
        currentTextBlockIndex >= blocks.length) {
      return;
    }
    final block = blocks[currentTextBlockIndex];
    if (block['type'] != 'text') return;
    final citations = ((block['citations'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    citations.add(Map<String, dynamic>.from(citation));
    block['citations'] = citations;
  }

  static List<Map<String, dynamic>> _finalizeAssistantContentBlocks(
    List<Map<String, dynamic>> blocks,
    Map<String, Map<String, dynamic>> parsedInputs,
  ) {
    final finalized = <Map<String, dynamic>>[];
    for (final rawBlock in blocks) {
      final block = Map<String, dynamic>.from(
        _cloneJsonValue(rawBlock) as Map<String, dynamic>,
      );
      final type = block['type'] as String?;
      if (type == 'text') {
        final text = block['text'] as String? ?? '';
        if (text.isEmpty) continue;
        final citations = (block['citations'] as List?)
            ?.whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        if (citations == null || citations.isEmpty) {
          block.remove('citations');
        } else {
          block['citations'] = citations;
        }
        finalized.add(block);
        continue;
      }
      if (type == 'tool_use' || type == 'server_tool_use') {
        final id = block['id'] as String?;
        block['input'] = parsedInputs[id] ?? const <String, dynamic>{};
      }
      finalized.add(block);
    }
    return finalized;
  }

  String _summarizeResult(dynamic result) {
    if (result is Map) {
      int? readInt(List<String> keys) {
        for (final key in keys) {
          final value = result[key];
          if (value is int) return value;
          if (value is num) return value.toInt();
          if (value is String) {
            final parsed = int.tryParse(value);
            if (parsed != null) return parsed;
          }
        }
        return null;
      }

      String summarizeCollection(String listKey, String label) {
        final returned =
            readInt(['returned']) ?? (result[listKey] as List?)?.length ?? 0;
        final total =
            readInt(['total_matches', 'count', 'app_count']) ?? returned;
        if (total > returned && returned > 0) {
          return 'Found $total $label (showing $returned)';
        }
        return 'Found $total $label';
      }

      if (result.containsKey('files')) {
        return summarizeCollection('files', 'files');
      }
      if (result.containsKey('contacts')) {
        return summarizeCollection('contacts', 'contacts');
      }
      if (result.containsKey('events')) {
        return summarizeCollection('events', 'events');
      }
      if (result.containsKey('notifications')) {
        return summarizeCollection('notifications', 'notifications');
      }
      if (result.containsKey('calls')) {
        return summarizeCollection('calls', 'calls');
      }
      if (result.containsKey('apps')) {
        return summarizeCollection('apps', 'apps');
      }
      final action = result['action'] as String?;
      if (action != null) {
        final target = result['relative_path'] ??
            result['file_name'] ??
            result['path'] ??
            'file';
        switch (action) {
          case 'created':
            return 'Created $target';
          case 'overwritten':
            return 'Overwrote $target';
          case 'edited':
            return 'Edited $target';
        }
      }
      if (result.containsKey('url')) {
        final rawUrl = result['url'] as String?;
        final host = rawUrl == null ? null : Uri.tryParse(rawUrl)?.host;
        if (host != null && host.isNotEmpty) {
          return 'Fetched $host';
        }
        return 'Fetched web page';
      }
      if (result.containsKey('content_type')) {
        return 'Read ${result['file_name'] ?? 'file'}';
      }
    }
    final str = result.toString();
    return str.length > 80 ? '${str.substring(0, 80)}...' : str;
  }

  Map<String, dynamic> _buildRequestSnapshot({
    required int turnIndex,
    required String model,
    required int maxTokens,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required dynamic system,
  }) {
    return {
      'turn_index': turnIndex,
      'anthropic_version': ClaudeApi.debugAnthropicVersion(),
      'betas': ClaudeApi.debugBetas(),
      'request': {
        'model': model,
        'max_tokens': maxTokens,
        'stream': true,
        'cache_control': ClaudeApi.debugPromptCacheControl(),
        'context_management': ClaudeApi.debugContextManagement(),
        if (system != null) 'system': _cloneJsonValue(system),
        if (tools.isNotEmpty) 'tools': _cloneJsonValue(tools),
        'messages': _summarizeMessagesForLog(messages),
      },
      'counts': {
        'message_count': messages.length,
        'tool_count': tools.length,
        'system_block_count':
            system is List ? system.length : (system == null ? 0 : 1),
      },
    };
  }

  static List<Map<String, dynamic>> _summarizeMessagesForLog(
    List<Map<String, dynamic>> messages,
  ) {
    return messages
        .map((message) => {
              'role': message['role'],
              'content': _summarizeContentForLog(message['content']),
            })
        .toList();
  }

  static List<Map<String, dynamic>> _summarizeContentForLog(dynamic content) {
    if (content is! List) return const [];
    return content
        .whereType<Map>()
        .map((block) => _summarizeContentBlockForLog(
              Map<String, dynamic>.from(block),
            ))
        .toList();
  }

  static Map<String, dynamic> _summarizeContentBlockForLog(
    Map<String, dynamic> block,
  ) {
    final type = block['type'] as String?;
    switch (type) {
      case 'text':
        final text = block['text'] as String? ?? '';
        return {
          'type': 'text',
          'text_preview': _previewText(text),
          'text_chars': text.length,
          if (block['cache_control'] != null)
            'cache_control': _cloneJsonValue(block['cache_control']),
        };
      case 'image':
        final source = block['source'] as Map<String, dynamic>? ??
            const <String, dynamic>{};
        final data = source['data'] as String? ?? '';
        return {
          'type': 'image',
          'media_type': source['media_type'],
          'base64_chars': data.length,
        };
      case 'document':
        final source = block['source'] as Map<String, dynamic>? ??
            const <String, dynamic>{};
        final data = source['data'] as String? ?? '';
        return {
          'type': 'document',
          'media_type': source['media_type'],
          'base64_chars': data.length,
        };
      case 'tool_use':
        return {
          'type': 'tool_use',
          'id': block['id'],
          'name': block['name'],
          'input': _cloneJsonValue(block['input']),
        };
      case 'server_tool_use':
        return {
          'type': 'server_tool_use',
          'id': block['id'],
          'name': block['name'],
          'input': _cloneJsonValue(block['input']),
        };
      case 'web_search_tool_result':
        final content = block['content'] as List? ?? const [];
        final summarizedResults = content.whereType<Map>().map((item) {
          final result = Map<String, dynamic>.from(item);
          return {
            'type': result['type'],
            'title': result['title'],
            'url': result['url'],
            if (result['page_age'] != null) 'page_age': result['page_age'],
            if (result['encrypted_content'] != null)
              'encrypted_content_chars':
                  (result['encrypted_content'] as String).length,
          };
        }).toList();
        return {
          'type': 'web_search_tool_result',
          'tool_use_id': block['tool_use_id'],
          'content': summarizedResults,
        };
      case 'tool_result':
        return {
          'type': 'tool_result',
          'tool_use_id': block['tool_use_id'],
          if (block['is_error'] == true) 'is_error': true,
          'content': _summarizeContentForLog(block['content']),
        };
      default:
        final encoded = jsonEncode(block);
        return {
          'type': type ?? 'unknown',
          'json_preview': _previewText(encoded),
          'json_chars': encoded.length,
        };
    }
  }

  static String _previewText(String text, {int maxChars = 240}) {
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}...';
  }

  static dynamic _cloneJsonValue(dynamic value) {
    if (value == null) return null;
    return jsonDecode(jsonEncode(value));
  }
}

class _PendingToolCall {
  final String id;
  final String name;
  final bool isServer;
  String inputJson = '';
  _PendingToolCall({
    required this.id,
    required this.name,
    this.isServer = false,
  });
}

/// Result of a single tool execution, collected during parallel Future.wait.
class _ToolExecResult {
  final String toolUseId;
  final String toolName;
  final String summary;
  final String fullResult;
  final bool isError;
  final Duration duration;
  final List<Map<String, dynamic>> apiContent;
  final Map<String, dynamic>? resultData;

  _ToolExecResult({
    required this.toolUseId,
    required this.toolName,
    required this.summary,
    required this.fullResult,
    required this.isError,
    required this.duration,
    required this.apiContent,
    this.resultData,
  });
}

// --- UI Update Events ---

sealed class ChatUpdate {}

class RequestPrepared extends ChatUpdate {
  final int turnIndex;
  final Map<String, dynamic> request;
  RequestPrepared({
    required this.turnIndex,
    required this.request,
  });
}

class TextDelta extends ChatUpdate {
  final String text;
  TextDelta(this.text);
}

class ToolCallStarted extends ChatUpdate {
  final String toolUseId;
  final String toolName;
  ToolCallStarted({required this.toolUseId, required this.toolName});
}

class ToolCallCompleted extends ChatUpdate {
  final String toolUseId;
  final String toolName;
  final Map<String, dynamic> input;
  final String summary;
  final String fullResult;
  final bool isError;
  final Duration duration;
  final List<Map<String, dynamic>> apiContent;
  final Map<String, dynamic>? resultData;
  ToolCallCompleted({
    required this.toolUseId,
    required this.toolName,
    this.input = const {},
    required this.summary,
    required this.fullResult,
    this.isError = false,
    this.duration = Duration.zero,
    this.apiContent = const [],
    this.resultData,
  });
}

class UsageUpdate extends ChatUpdate {
  final int turnIndex;
  final String? messageId;
  final String model;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheCreationTokens;
  final int webSearchRequests;
  final String? stopReason;
  final List<dynamic>? appliedContextEdits;
  final double cost;
  UsageUpdate({
    required this.turnIndex,
    this.messageId,
    required this.model,
    required this.inputTokens,
    required this.outputTokens,
    this.cacheReadTokens = 0,
    this.cacheCreationTokens = 0,
    this.webSearchRequests = 0,
    this.stopReason,
    this.appliedContextEdits,
    required this.cost,
  });
}

class StreamError extends ChatUpdate {
  final String message;
  StreamError(this.message);
}

class TurnComplete extends ChatUpdate {
  final List<Map<String, dynamic>> historyMessages;
  TurnComplete({this.historyMessages = const <Map<String, dynamic>>[]});
}
