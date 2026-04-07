import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

const _anthropicVersion = '2023-06-01';
const _anthropicBetas = <String>[
  'web-search-2025-03-05',
  'context-management-2025-06-27',
];
const defaultClaudeMaxTokens = 16000;

Map<String, dynamic> _buildPromptCacheControl() {
  return {
    'type': 'ephemeral',
  };
}

Map<String, dynamic> _buildContextManagement() {
  return {
    'edits': [
      {
        'type': 'clear_tool_uses_20250919',
        'trigger': {'type': 'input_tokens', 'value': 40000},
        'keep': {'type': 'tool_uses', 'value': 4},
        'clear_at_least': {'type': 'input_tokens', 'value': 8000},
      },
    ],
  };
}

/// Raw HTTP+SSE client for the Anthropic Messages API.
/// No SDK dependency — just HTTP and JSON.
class ClaudeApi {
  final String apiKey;
  final String baseUrl;
  final http.Client _client;

  /// A separate client used for the current streaming request.
  /// Closing this client aborts the in-flight HTTP connection immediately.
  http.Client? _streamClient;

  /// Set when the user explicitly cancels the stream so we don't retry.
  bool _userCancelled = false;

  ClaudeApi({
    required this.apiKey,
    this.baseUrl = 'https://api.anthropic.com',
    http.Client? client,
  }) : _client = client ?? http.Client();

  static String debugAnthropicVersion() => _anthropicVersion;

  static List<String> debugBetas() =>
      List<String>.unmodifiable(_anthropicBetas);

  static Map<String, dynamic> debugPromptCacheControl() =>
      Map<String, dynamic>.from(_buildPromptCacheControl());

  static Map<String, dynamic> debugContextManagement() =>
      Map<String, dynamic>.from(_buildContextManagement());

  void dispose() {
    cancelStream();
    _client.close();
  }

  /// Cancel the in-flight streaming request, if any.
  /// Closing the per-stream client tears down the underlying socket so
  /// no further data (or token billing) occurs.
  void cancelStream() {
    _userCancelled = true;
    _streamClient?.close();
    _streamClient = null;
  }

  /// Stream a message response from the Claude API.
  /// Retries on 429 (rate limited), 529 (overloaded), and network errors
  /// with exponential backoff.
  Stream<StreamEvent> createMessageStream({
    required String model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    dynamic system,
    int maxTokens = defaultClaudeMaxTokens,
  }) async* {
    _userCancelled = false;
    const maxRetries = 3;
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        yield* _doCreateMessageStream(
          model: model,
          messages: messages,
          tools: tools,
          system: system,
          maxTokens: maxTokens,
        );
        return; // Success
      } on ApiException catch (e) {
        if (_userCancelled ||
            attempt == maxRetries ||
            (e.statusCode != 429 && e.statusCode != 529)) {
          rethrow;
        }
        // Exponential backoff: 1s, 2s, 4s
        await Future.delayed(Duration(seconds: 1 << attempt));
      } on RateLimitException {
        if (_userCancelled || attempt == maxRetries) rethrow;
        await Future.delayed(Duration(seconds: 2 << attempt));
      } on SocketException {
        // Network error — but don't retry if the user cancelled
        if (_userCancelled || attempt == maxRetries) rethrow;
        await Future.delayed(Duration(seconds: 1 << attempt));
      } on HttpException {
        // Network error — but don't retry if the user cancelled
        if (_userCancelled || attempt == maxRetries) rethrow;
        await Future.delayed(Duration(seconds: 1 << attempt));
      }
    }
  }

  /// Internal implementation of createMessageStream (called by retry wrapper).
  Stream<StreamEvent> _doCreateMessageStream({
    required String model,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    dynamic system,
    int maxTokens = defaultClaudeMaxTokens,
  }) async* {
    // Create a dedicated client for this stream so cancelStream() can
    // close it independently without affecting the main _client.
    final streamClient = http.Client();
    _streamClient = streamClient;

    final request = http.Request(
      'POST',
      Uri.parse('$baseUrl/v1/messages'),
    );

    request.headers.addAll({
      'x-api-key': apiKey,
      'anthropic-version': _anthropicVersion,
      'anthropic-beta': _anthropicBetas.join(','),
      'content-type': 'application/json',
      'accept': 'text/event-stream',
    });

    final body = <String, dynamic>{
      'model': model,
      'max_tokens': maxTokens,
      'stream': true,
      'cache_control': _buildPromptCacheControl(),
    };
    if (system != null) body['system'] = system;
    if (tools != null && tools.isNotEmpty) body['tools'] = tools;
    body['messages'] = messages;
    body['context_management'] = _buildContextManagement();

    request.body = jsonEncode(body);

    final response = await streamClient.send(request);

    if (response.statusCode == 401) {
      throw ApiException(401, 'Invalid API key');
    }
    if (response.statusCode == 400) {
      final body = await response.stream.bytesToString();
      String message = 'Bad request';
      try {
        final json = jsonDecode(body) as Map<String, dynamic>;
        message = (json['error'] as Map?)?['message'] as String? ?? body;
      } catch (_) {}
      if (message.contains('prompt is too long')) {
        throw ApiException(
            400, 'Conversation too long. Please start a new conversation.');
      }
      throw ApiException(400, message);
    }
    if (response.statusCode == 413) {
      throw ApiException(413,
          'Request too large. Try a shorter message or fewer attachments.');
    }
    if (response.statusCode == 429) {
      throw RateLimitException();
    }
    if (response.statusCode == 529) {
      throw ApiException(529, 'API overloaded. Try again in a moment.');
    }
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      String message = body;
      try {
        final json = jsonDecode(body) as Map<String, dynamic>;
        final error = json['error'] as Map<String, dynamic>?;
        message = error?['message'] as String? ?? body;
      } catch (_) {}
      throw ApiException(response.statusCode, message);
    }

    // Parse SSE stream
    String buffer = '';
    await for (final chunk in response.stream.transform(utf8.decoder)) {
      buffer += chunk;
      while (buffer.contains('\n')) {
        final lineEnd = buffer.indexOf('\n');
        final line = buffer.substring(0, lineEnd).trim();
        buffer = buffer.substring(lineEnd + 1);

        if (line.startsWith('data: ') && line != 'data: [DONE]') {
          try {
            final data = jsonDecode(line.substring(6)) as Map<String, dynamic>;
            final event = StreamEvent.parse(data);
            if (event != null) yield event;
          } catch (_) {
            // Skip malformed events
          }
        }
      }
    }

    // Stream completed normally — clean up the dedicated client.
    if (_streamClient == streamClient) {
      _streamClient = null;
    }
  }

  /// Non-streaming call — used for API key validation.
  Future<Map<String, dynamic>> createMessage({
    required String model,
    required List<Map<String, dynamic>> messages,
    int maxTokens = 1,
  }) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/v1/messages'),
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': _anthropicVersion,
        'anthropic-beta': _anthropicBetas.join(','),
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': model,
        'max_tokens': maxTokens,
        'cache_control': _buildPromptCacheControl(),
        'messages': messages,
        'context_management': _buildContextManagement(),
      }),
    );

    if (response.statusCode == 401) throw ApiException(401, 'Invalid API key');
    if (response.statusCode == 429) throw RateLimitException();
    if (response.statusCode != 200) {
      String message = response.body;
      try {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final error = json['error'] as Map<String, dynamic>?;
        message = error?['message'] as String? ?? response.body;
      } catch (_) {}
      throw ApiException(response.statusCode, message);
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

// --- Stream Events ---

sealed class StreamEvent {
  static StreamEvent? parse(Map<String, dynamic> data) {
    switch (data['type']) {
      case 'message_start':
        final usage = data['message']?['usage'] as Map<String, dynamic>?;
        return MessageStartEvent(
          messageId: data['message']?['id'] as String? ?? '',
          model: data['message']?['model'] as String? ?? '',
          inputTokens: usage?['input_tokens'] as int? ?? 0,
          cacheReadTokens: usage?['cache_read_input_tokens'] as int? ?? 0,
          cacheCreationTokens:
              usage?['cache_creation_input_tokens'] as int? ?? 0,
          webSearchRequests: (usage?['server_tool_use']
                  as Map?)?['web_search_requests'] as int? ??
              0,
        );
      case 'content_block_start':
        final block = data['content_block'] as Map<String, dynamic>?;
        if (block == null) return null;
        if (block['type'] == 'tool_use') {
          return ToolUseStartEvent(
            index: data['index'] as int? ?? 0,
            id: block['id'] as String? ?? '',
            name: block['name'] as String? ?? '',
          );
        }
        if (block['type'] == 'server_tool_use') {
          return ServerToolUseStartEvent(
            index: data['index'] as int? ?? 0,
            id: block['id'] as String? ?? '',
            name: block['name'] as String? ?? '',
          );
        }
        if (block['type'] == 'web_search_tool_result') {
          return StructuredContentBlockStartEvent(
            index: data['index'] as int? ?? 0,
            block: Map<String, dynamic>.from(block),
          );
        }
        return ContentBlockStartEvent(
          index: data['index'] as int? ?? 0,
          type: block['type'] as String? ?? 'text',
          block: Map<String, dynamic>.from(block),
        );
      case 'content_block_delta':
        final delta = data['delta'] as Map<String, dynamic>?;
        if (delta == null) return null;
        if (delta['type'] == 'text_delta') {
          return TextDeltaEvent(
            index: data['index'] as int? ?? 0,
            text: delta['text'] as String? ?? '',
          );
        }
        if (delta['type'] == 'input_json_delta') {
          return InputJsonDeltaEvent(
            index: data['index'] as int? ?? 0,
            partialJson: delta['partial_json'] as String? ?? '',
          );
        }
        if (delta['type'] == 'citations_delta') {
          final rawCitation =
              delta['citation'] ?? delta['citation_delta'] ?? delta['value'];
          if (rawCitation is Map) {
            return CitationsDeltaEvent(
              index: data['index'] as int? ?? 0,
              citation: Map<String, dynamic>.from(rawCitation),
            );
          }
        }
        return null;
      case 'content_block_stop':
        return ContentBlockStopEvent(
          index: data['index'] as int? ?? 0,
        );
      case 'message_delta':
        final usage = data['usage'] as Map<String, dynamic>?;
        final contextManagement =
            data['context_management'] as Map<String, dynamic>?;
        return MessageDeltaEvent(
          stopReason: data['delta']?['stop_reason'] as String?,
          inputTokens: usage?['input_tokens'] as int? ?? 0,
          outputTokens: usage?['output_tokens'] as int? ?? 0,
          cacheReadTokens: usage?['cache_read_input_tokens'] as int? ?? 0,
          cacheCreationTokens:
              usage?['cache_creation_input_tokens'] as int? ?? 0,
          webSearchRequests: (usage?['server_tool_use']
                  as Map?)?['web_search_requests'] as int? ??
              0,
          appliedContextEdits:
              (contextManagement?['applied_edits'] as List?)?.cast<dynamic>(),
        );
      case 'message_stop':
        return MessageStopEvent();
      case 'error':
        return ErrorEvent(
          message: data['error']?['message'] as String? ?? 'Unknown error',
        );
      default:
        return null;
    }
  }
}

class MessageStartEvent extends StreamEvent {
  final String messageId;
  final String model;
  final int inputTokens;
  final int cacheReadTokens;
  final int cacheCreationTokens;
  final int webSearchRequests;
  MessageStartEvent({
    required this.messageId,
    required this.model,
    required this.inputTokens,
    this.cacheReadTokens = 0,
    this.cacheCreationTokens = 0,
    this.webSearchRequests = 0,
  });
}

class ContentBlockStartEvent extends StreamEvent {
  final int index;
  final String type;
  final Map<String, dynamic> block;
  ContentBlockStartEvent({
    required this.index,
    required this.type,
    required this.block,
  });
}

class ToolUseStartEvent extends StreamEvent {
  final int index;
  final String id;
  final String name;
  ToolUseStartEvent({
    required this.index,
    required this.id,
    required this.name,
  });
}

class ServerToolUseStartEvent extends StreamEvent {
  final int index;
  final String id;
  final String name;
  ServerToolUseStartEvent({
    required this.index,
    required this.id,
    required this.name,
  });
}

class StructuredContentBlockStartEvent extends StreamEvent {
  final int index;
  final Map<String, dynamic> block;
  StructuredContentBlockStartEvent({
    required this.index,
    required this.block,
  });
}

class TextDeltaEvent extends StreamEvent {
  final int index;
  final String text;
  TextDeltaEvent({required this.index, required this.text});
}

class InputJsonDeltaEvent extends StreamEvent {
  final int index;
  final String partialJson;
  InputJsonDeltaEvent({required this.index, required this.partialJson});
}

class CitationsDeltaEvent extends StreamEvent {
  final int index;
  final Map<String, dynamic> citation;
  CitationsDeltaEvent({required this.index, required this.citation});
}

class ContentBlockStopEvent extends StreamEvent {
  final int index;
  ContentBlockStopEvent({required this.index});
}

class MessageDeltaEvent extends StreamEvent {
  final String? stopReason;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheCreationTokens;
  final int webSearchRequests;
  final List<dynamic>? appliedContextEdits;
  MessageDeltaEvent({
    this.stopReason,
    this.inputTokens = 0,
    required this.outputTokens,
    this.cacheReadTokens = 0,
    this.cacheCreationTokens = 0,
    this.webSearchRequests = 0,
    this.appliedContextEdits,
  });
}

class MessageStopEvent extends StreamEvent {}

class ErrorEvent extends StreamEvent {
  final String message;
  ErrorEvent({required this.message});
}

// --- Exceptions ---

class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);
  @override
  String toString() => 'ApiException($statusCode): $message';
}

class RateLimitException implements Exception {
  @override
  String toString() => 'Rate limited. Please wait and try again.';
}
