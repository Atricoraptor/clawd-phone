import 'dart:convert';
import 'dart:typed_data';

/// Represents a content block in a Claude API message.
sealed class ContentBlock {
  Map<String, dynamic> toJson();

  static ContentBlock fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'text':
        return TextBlock(
          json['text'] as String? ?? '',
          citations: (json['citations'] as List?)
              ?.whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList(),
        );
      case 'image':
        final source =
            Map<String, dynamic>.from((json['source'] as Map?) ?? const {});
        return ImageBlock(
          base64Data: source['data'] as String? ?? '',
          mediaType: source['media_type'] as String? ?? 'image/jpeg',
        );
      case 'tool_use':
        return ToolUseBlock.fromJson(json);
      case 'tool_result':
        return ToolResultBlock.fromJson(json);
      default:
        return RawContentBlock(Map<String, dynamic>.from(json));
    }
  }
}

class TextBlock extends ContentBlock {
  final String text;
  final List<Map<String, dynamic>>? citations;

  TextBlock(this.text, {this.citations});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'text',
        'text': text,
        if (citations != null && citations!.isNotEmpty) 'citations': citations,
      };
}

class ImageBlock extends ContentBlock {
  final String base64Data;
  final String mediaType;

  ImageBlock({required this.base64Data, required this.mediaType});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': mediaType,
          'data': base64Data,
        },
      };
}

class ToolUseBlock extends ContentBlock {
  final String id;
  final String name;
  final Map<String, dynamic> input;

  ToolUseBlock({required this.id, required this.name, required this.input});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool_use',
        'id': id,
        'name': name,
        'input': input,
      };

  factory ToolUseBlock.fromJson(Map<String, dynamic> json) => ToolUseBlock(
        id: json['id'] as String,
        name: json['name'] as String,
        input: Map<String, dynamic>.from(json['input'] as Map),
      );
}

class ToolResultBlock extends ContentBlock {
  final String toolUseId;
  final List<ContentBlock> content;
  final bool isError;

  ToolResultBlock({
    required this.toolUseId,
    required this.content,
    this.isError = false,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool_result',
        'tool_use_id': toolUseId,
        'content': content.map((c) => c.toJson()).toList(),
        if (isError) 'is_error': true,
      };

  factory ToolResultBlock.fromJson(Map<String, dynamic> json) =>
      ToolResultBlock(
        toolUseId: json['tool_use_id'] as String? ?? '',
        content: (json['content'] as List? ?? const [])
            .whereType<Map>()
            .map((item) =>
                ContentBlock.fromJson(Map<String, dynamic>.from(item)))
            .toList(),
        isError: json['is_error'] == true,
      );
}

class RawContentBlock extends ContentBlock {
  final Map<String, dynamic> json;

  RawContentBlock(this.json);

  @override
  Map<String, dynamic> toJson() => json;
}

/// A message in the conversation (user, assistant, or tool result).
class Message {
  final String role; // 'user' or 'assistant'
  final List<ContentBlock> content;

  Message({required this.role, required this.content});

  /// Convenience for simple text messages.
  factory Message.user(String text) =>
      Message(role: 'user', content: [TextBlock(text)]);

  factory Message.userWithImage({
    required String text,
    required Uint8List imageBytes,
    required String mediaType,
  }) =>
      Message(role: 'user', content: [
        ImageBlock(
          base64Data: base64Encode(imageBytes),
          mediaType: mediaType,
        ),
        // Only include text block if non-empty — API rejects empty text blocks
        if (text.trim().isNotEmpty) TextBlock(text),
      ]);

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content.map((c) => c.toJson()).toList(),
      };
}

/// An ordered content block in an assistant message for the UI.
/// Ordered content blocks for a chat message.
sealed class ChatContentBlock {}

/// A text segment in the assistant's response.
class TextSegment extends ChatContentBlock {
  String text;
  TextSegment(this.text);
}

/// A tool use + result pair, rendered inline at its position.
class ToolUseSegment extends ChatContentBlock {
  final String toolUseId;
  final String toolName;
  Map<String, dynamic> input;
  ToolCallStatus status;
  ToolResult? result;

  /// Whether this tool should be hidden in the UI.
  /// Whether this tool should be hidden in the UI.
  bool get isHidden => _hiddenTools.contains(toolName);

  static const _hiddenTools = <String>{};

  ToolUseSegment({
    required this.toolUseId,
    required this.toolName,
    this.input = const {},
    this.status = ToolCallStatus.running,
    this.result,
  });
}

/// A displayable chat message for the UI layer.
class ChatMessage {
  final String id;
  final String role;
  final List<ChatContentBlock> contentBlocks;
  final List<AttachedImage> images;
  final DateTime timestamp;
  final bool isStreaming;
  final int inputTokens;
  final int outputTokens;

  ChatMessage({
    required this.id,
    required this.role,
    this.contentBlocks = const [],
    this.images = const [],
    DateTime? timestamp,
    this.isStreaming = false,
    this.inputTokens = 0,
    this.outputTokens = 0,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Convenience: get all text concatenated (for session title, etc.)
  String get text =>
      contentBlocks.whereType<TextSegment>().map((s) => s.text).join('');

  /// Convenience: get all tool results.
  List<ToolResult> get toolResults => contentBlocks
      .whereType<ToolUseSegment>()
      .where((s) => s.result != null)
      .map((s) => s.result!)
      .toList();

  /// Convenience: get all tool calls (running or completed).
  List<ToolCall> get toolCalls => contentBlocks
      .whereType<ToolUseSegment>()
      .map((s) => ToolCall(
            id: s.toolUseId,
            name: s.toolName,
            input: Map<String, dynamic>.from(s.input),
            status: s.status,
          ))
      .toList();

  ChatMessage copyWith({
    List<ChatContentBlock>? contentBlocks,
    List<AttachedImage>? images,
    bool? isStreaming,
    int? inputTokens,
    int? outputTokens,
  }) =>
      ChatMessage(
        id: id,
        role: role,
        contentBlocks: contentBlocks ?? this.contentBlocks,
        images: images ?? this.images,
        timestamp: timestamp,
        isStreaming: isStreaming ?? this.isStreaming,
        inputTokens: inputTokens ?? this.inputTokens,
        outputTokens: outputTokens ?? this.outputTokens,
      );
}

class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> input;
  final ToolCallStatus status;

  ToolCall({
    required this.id,
    required this.name,
    required this.input,
    this.status = ToolCallStatus.running,
  });
}

enum ToolCallStatus { running, completed, error }

class ToolResult {
  final String toolUseId;
  final String toolName;
  final String summary;
  final String fullResult;
  final bool isError;
  final Duration duration;

  /// The actual API content blocks (image, document, text) returned by the tool.
  /// Used to build proper tool_result messages for subsequent API calls so that
  /// images are sent as image blocks (fixed ~1600 token cost) instead of as
  /// JSON text (which would cost ~114K tokens for a single image).
  final List<Map<String, dynamic>>? apiContent;
  final Map<String, dynamic>? data;

  ToolResult({
    required this.toolUseId,
    required this.toolName,
    required this.summary,
    required this.fullResult,
    this.isError = false,
    this.duration = Duration.zero,
    this.apiContent,
    this.data,
  });
}

class AttachedImage {
  final Uint8List bytes;
  final String mediaType;
  final String? fileName;

  AttachedImage({
    required this.bytes,
    required this.mediaType,
    this.fileName,
  });
}
