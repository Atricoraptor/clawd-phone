import 'dart:convert';

/// Metadata for a session, stored in index.json.
class SessionMeta {
  final String id;
  final String title;
  final int createdAt;
  final int lastActiveAt;
  final int messageCount;
  final String firstPrompt;
  final String lastPrompt;
  final String model;
  final int totalInputTokens;
  final int totalOutputTokens;
  final int totalCacheReadInputTokens;
  final int totalCacheCreationInputTokens;
  final double estimatedCost;
  final Set<String> toolsUsed;

  SessionMeta({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.lastActiveAt,
    this.messageCount = 0,
    this.firstPrompt = '',
    this.lastPrompt = '',
    this.model = 'claude-haiku-4-5-20251001',
    this.totalInputTokens = 0,
    this.totalOutputTokens = 0,
    this.totalCacheReadInputTokens = 0,
    this.totalCacheCreationInputTokens = 0,
    this.estimatedCost = 0.0,
    this.toolsUsed = const {},
  });

  SessionMeta copyWith({
    String? title,
    int? lastActiveAt,
    int? messageCount,
    String? lastPrompt,
    String? model,
    int? totalInputTokens,
    int? totalOutputTokens,
    int? totalCacheReadInputTokens,
    int? totalCacheCreationInputTokens,
    double? estimatedCost,
    Set<String>? toolsUsed,
  }) =>
      SessionMeta(
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        lastActiveAt: lastActiveAt ?? this.lastActiveAt,
        messageCount: messageCount ?? this.messageCount,
        firstPrompt: firstPrompt,
        lastPrompt: lastPrompt ?? this.lastPrompt,
        model: model ?? this.model,
        totalInputTokens: totalInputTokens ?? this.totalInputTokens,
        totalOutputTokens: totalOutputTokens ?? this.totalOutputTokens,
        totalCacheReadInputTokens:
            totalCacheReadInputTokens ?? this.totalCacheReadInputTokens,
        totalCacheCreationInputTokens:
            totalCacheCreationInputTokens ?? this.totalCacheCreationInputTokens,
        estimatedCost: estimatedCost ?? this.estimatedCost,
        toolsUsed: toolsUsed ?? this.toolsUsed,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt,
        'lastActiveAt': lastActiveAt,
        'messageCount': messageCount,
        'firstPrompt': firstPrompt,
        'lastPrompt': lastPrompt,
        'model': model,
        'totalInputTokens': totalInputTokens,
        'totalOutputTokens': totalOutputTokens,
        'totalCacheReadInputTokens': totalCacheReadInputTokens,
        'totalCacheCreationInputTokens': totalCacheCreationInputTokens,
        'estimatedCost': estimatedCost,
        'toolsUsed': toolsUsed.toList(),
      };

  factory SessionMeta.fromJson(Map<String, dynamic> json) => SessionMeta(
        id: json['id'] as String,
        title: json['title'] as String,
        createdAt: json['createdAt'] as int,
        lastActiveAt: json['lastActiveAt'] as int,
        messageCount: json['messageCount'] as int? ?? 0,
        firstPrompt: json['firstPrompt'] as String? ?? '',
        lastPrompt: json['lastPrompt'] as String? ?? '',
        model: json['model'] as String? ?? 'claude-haiku-4-5-20251001',
        totalInputTokens: json['totalInputTokens'] as int? ?? 0,
        totalOutputTokens: json['totalOutputTokens'] as int? ?? 0,
        totalCacheReadInputTokens:
            json['totalCacheReadInputTokens'] as int? ?? 0,
        totalCacheCreationInputTokens:
            json['totalCacheCreationInputTokens'] as int? ?? 0,
        estimatedCost: (json['estimatedCost'] as num?)?.toDouble() ?? 0.0,
        toolsUsed: Set<String>.from(json['toolsUsed'] as List? ?? []),
      );
}

/// A single entry in the session JSONL file.
class SessionEntry {
  final String
      type; // 'user', 'assistant', 'tool_result', 'api_request', 'api_response', 'api_error'
  final String uuid;
  final int timestamp;
  final String? parentUuid;
  final Map<String, dynamic> data;

  SessionEntry({
    required this.type,
    required this.uuid,
    required this.timestamp,
    this.parentUuid,
    required this.data,
  });

  String toJsonLine() => jsonEncode({
        'type': type,
        'uuid': uuid,
        'timestamp': timestamp,
        if (parentUuid != null) 'parentUuid': parentUuid,
        ...data,
      });

  factory SessionEntry.fromJsonLine(String line) {
    final json = jsonDecode(line) as Map<String, dynamic>;
    final data = Map<String, dynamic>.from(json)
      ..remove('type')
      ..remove('uuid')
      ..remove('timestamp')
      ..remove('parentUuid');
    return SessionEntry(
      type: json['type'] as String,
      uuid: json['uuid'] as String,
      timestamp: json['timestamp'] as int,
      parentUuid: json['parentUuid'] as String?,
      data: data,
    );
  }
}
