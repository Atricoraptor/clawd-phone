import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/tool_definition.dart';
import '../tools/tool_registry.dart';
import '../tools/web_fetch_handler.dart';

/// Routes tool calls from Claude to the correct platform channel or Dart handler.
class ToolRouter {
  static const _channel = MethodChannel('com.clawdphone.app/tools');

  // Note: WebSearch is an Anthropic built-in server tool — handled by the API itself,
  // never routed through ToolRouter.execute().

  /// Get all tool schemas exposed to the model.
  /// Permission-gated tools remain visible and may return PERMISSION_DENIED at runtime.
  List<Map<String, dynamic>> getToolSchemas() {
    final schemas = toolRegistry.map((tool) => tool.toApiSchema()).toList();
    // Add cache_control to last non-builtin tool for prompt caching
    final lastNonBuiltin =
        schemas.lastIndexWhere((s) => !s.containsKey('type'));
    if (lastNonBuiltin >= 0) {
      schemas[lastNonBuiltin]['cache_control'] = {'type': 'ephemeral'};
    }
    return schemas;
  }

  /// Get a tool definition by name.
  ToolDefinition? findTool(String name) {
    try {
      return toolRegistry.firstWhere((t) => t.name == name);
    } catch (_) {
      return null;
    }
  }

  /// Execute a tool call — either in Dart or via platform channel.
  Future<dynamic> execute(String toolName, Map<String, dynamic> input) async {
    // Dart-handled tools (no platform channel needed)
    if (toolName == 'WebFetch') return WebFetchHandler.fetch(input);

    // Everything else goes to the Android platform channel
    try {
      final result = await _channel.invokeMethod(toolName, input);
      if (result is String) {
        // Platform returns JSON string
        return _tryParseJson(result);
      }
      return result;
    } on PlatformException catch (e) {
      throw ToolExecutionException(toolName, e.message ?? 'Unknown error');
    } on MissingPluginException {
      throw ToolExecutionException(
        toolName,
        'Tool not implemented on this platform.',
      );
    }
  }

  dynamic _tryParseJson(String str) {
    try {
      return Map<String, dynamic>.from(const JsonCodec().decode(str) as Map);
    } catch (_) {
      return str;
    }
  }
}

class ToolExecutionException implements Exception {
  final String toolName;
  final String message;
  ToolExecutionException(this.toolName, this.message);
  @override
  String toString() => 'ToolExecutionException($toolName): $message';
}
