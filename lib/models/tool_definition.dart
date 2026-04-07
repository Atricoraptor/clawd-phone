/// Defines a tool that Claude can call.
class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final String? requiredPermission;
  final String category;

  /// Maximum chars for this tool's result before truncation.
  /// Set to double.infinity to opt out (e.g. FileRead uses token gate instead).
  /// Clamped by the system-wide default (50K) unless explicitly set higher.
  final double maxResultSizeChars;

  /// If non-null, this is an Anthropic built-in server tool (e.g., web_search).
  /// Uses 'type' field instead of 'name'/'description'/'input_schema'.
  final String? builtInType;

  const ToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.requiredPermission,
    this.category = 'general',
    this.maxResultSizeChars = 50000,
    this.builtInType,
  });

  Map<String, dynamic> toApiSchema() {
    if (builtInType != null) {
      // Anthropic built-in server tool format
      return {
        'type': builtInType,
        'name': name,
      };
    }
    return {
      'name': name,
      'description': description,
      'input_schema': inputSchema,
    };
  }
}
