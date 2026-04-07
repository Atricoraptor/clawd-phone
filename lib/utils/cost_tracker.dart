/// Tracks API token usage and cost for a session and overall.
class CostTracker {
  static const String pricingEffectiveDateLabel = 'Pricing as of Apr 7, 2026';

  int _inputTokens = 0;
  int _outputTokens = 0;
  int _cacheReadTokens = 0;
  int _cacheWriteTokens = 0;
  int _webSearchRequests = 0;

  int get inputTokens => _inputTokens;
  int get outputTokens => _outputTokens;
  int get cacheReadTokens => _cacheReadTokens;
  int get cacheWriteTokens => _cacheWriteTokens;
  int get webSearchRequests => _webSearchRequests;

  void addUsage({
    int inputTokens = 0,
    int outputTokens = 0,
    int cacheReadTokens = 0,
    int cacheWriteTokens = 0,
    int webSearchRequests = 0,
  }) {
    _inputTokens += inputTokens;
    _outputTokens += outputTokens;
    _cacheReadTokens += cacheReadTokens;
    _cacheWriteTokens += cacheWriteTokens;
    _webSearchRequests += webSearchRequests;
  }

  /// Calculate cost in USD based on model pricing.
  double estimateCost(String model) {
    final pricing = _pricingForModel(model);
    final inputCost = _inputTokens * pricing.inputPerToken;
    final outputCost = _outputTokens * pricing.outputPerToken;
    final cacheReadCost = _cacheReadTokens * pricing.cacheReadPerToken;
    final cacheWriteCost = _cacheWriteTokens * pricing.cacheWritePerToken;
    final webSearchCost = _webSearchRequests * pricing.webSearchPerRequest;
    return inputCost +
        outputCost +
        cacheReadCost +
        cacheWriteCost +
        webSearchCost;
  }

  void reset() {
    _inputTokens = 0;
    _outputTokens = 0;
    _cacheReadTokens = 0;
    _cacheWriteTokens = 0;
    _webSearchRequests = 0;
  }

  static const _defaultPricingKey = 'claude-sonnet-4-6';

  static const _modelPricing = {
    'claude-haiku-4-5': _Pricing(
      inputPerToken: 1.0 / 1e6,
      outputPerToken: 5.0 / 1e6,
      cacheWritePerToken: 1.25 / 1e6,
      cacheReadPerToken: 0.1 / 1e6,
      webSearchPerRequest: 10.0 / 1000.0,
    ),
    'claude-sonnet-4-6': _Pricing(
      inputPerToken: 3.0 / 1e6,
      outputPerToken: 15.0 / 1e6,
      cacheWritePerToken: 3.75 / 1e6,
      cacheReadPerToken: 0.3 / 1e6,
      webSearchPerRequest: 10.0 / 1000.0,
    ),
    'claude-opus-4-6': _Pricing(
      inputPerToken: 5.0 / 1e6,
      outputPerToken: 25.0 / 1e6,
      cacheWritePerToken: 6.25 / 1e6,
      cacheReadPerToken: 0.5 / 1e6,
      webSearchPerRequest: 10.0 / 1000.0,
    ),
  };

  static _Pricing _pricingForModel(String model) {
    final normalized = model.toLowerCase();
    if (normalized.startsWith('claude-haiku-4-5')) {
      return _modelPricing['claude-haiku-4-5']!;
    }
    if (normalized.startsWith('claude-sonnet-4-6')) {
      return _modelPricing['claude-sonnet-4-6']!;
    }
    if (normalized.startsWith('claude-opus-4-6')) {
      return _modelPricing['claude-opus-4-6']!;
    }
    if (normalized.contains('haiku')) {
      return _modelPricing['claude-haiku-4-5']!;
    }
    if (normalized.contains('opus')) {
      return _modelPricing['claude-opus-4-6']!;
    }
    if (normalized.contains('sonnet')) {
      return _modelPricing['claude-sonnet-4-6']!;
    }
    return _modelPricing[_defaultPricingKey]!;
  }
}

class _Pricing {
  final double inputPerToken;
  final double outputPerToken;
  final double cacheWritePerToken;
  final double cacheReadPerToken;
  final double webSearchPerRequest;
  const _Pricing({
    required this.inputPerToken,
    required this.outputPerToken,
    required this.cacheWritePerToken,
    required this.cacheReadPerToken,
    required this.webSearchPerRequest,
  });
}

String formatCost(double cost) {
  if (cost < 0.01) return '<\$0.01';
  return '\$${cost.toStringAsFixed(2)}';
}
