import 'package:http/http.dart' as http;

/// Fetches a URL, strips HTML to plain text, returns content.
/// Runs entirely in Dart — no platform channel needed.
class WebFetchHandler {
  static const _maxContentLength = 10 * 1024 * 1024; // 10 MB raw
  static const _maxOutputChars = 100000; // 100K chars after processing
  static const _timeout = Duration(seconds: 30);
  static const _userAgent = 'ClawdPhone/1.0';

  // Simple LRU cache
  static final _cache = <String, _CacheEntry>{};
  static const _cacheTtl = Duration(minutes: 15);
  static const _maxCacheEntries = 50;

  static Future<Map<String, dynamic>> fetch(Map<String, dynamic> input) async {
    final url = input['url'] as String?;
    if (url == null || url.isEmpty) {
      return {'error': 'URL is required'};
    }

    // Validate URL
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !uri.isScheme('https')) {
      return {'error': 'Invalid URL. Must start with https://'};
    }

    final maxLength = input['max_length'] as int? ?? _maxOutputChars;

    // Check cache
    final cached = _cache[url];
    if (cached != null && DateTime.now().difference(cached.time) < _cacheTtl) {
      return cached.data;
    }

    final stopwatch = Stopwatch()..start();

    try {
      final client = http.Client();
      try {
        final response = await client
            .get(uri, headers: {
              'User-Agent': _userAgent,
              'Accept': 'text/html, text/plain, text/markdown, */*',
            })
            .timeout(_timeout);

        stopwatch.stop();

        if (response.statusCode != 200) {
          return {
            'url': url,
            'status_code': response.statusCode,
            'error': 'HTTP ${response.statusCode}: ${response.reasonPhrase}',
            'duration_ms': stopwatch.elapsedMilliseconds,
          };
        }

        // Check content size
        final bodyBytes = response.bodyBytes;
        if (bodyBytes.length > _maxContentLength) {
          return {
            'url': url,
            'error': 'Content too large (${bodyBytes.length} bytes, max $_maxContentLength)',
            'duration_ms': stopwatch.elapsedMilliseconds,
          };
        }

        final contentType = response.headers['content-type'] ?? '';
        String body = response.body;

        // Convert HTML to plain text
        if (contentType.contains('html')) {
          body = _htmlToText(body);
        }

        // Truncate to max length
        final truncated = body.length > maxLength;
        if (truncated) {
          body = '${body.substring(0, maxLength)}\n\n[Content truncated at $maxLength characters]';
        }

        final result = <String, dynamic>{
          'url': url,
          'status_code': response.statusCode,
          'content_type': contentType,
          'content': body,
          'content_length': body.length,
          'original_bytes': bodyBytes.length,
          'truncated': truncated,
          'duration_ms': stopwatch.elapsedMilliseconds,
        };

        // Cache result
        if (_cache.length >= _maxCacheEntries) {
          // Remove oldest entry
          final oldest = _cache.entries.reduce(
              (a, b) => a.value.time.isBefore(b.value.time) ? a : b);
          _cache.remove(oldest.key);
        }
        _cache[url] = _CacheEntry(data: result, time: DateTime.now());

        return result;
      } finally {
        client.close();
      }
    } on Exception catch (e) {
      stopwatch.stop();
      return {
        'url': url,
        'error': 'Fetch failed: ${e.toString()}',
        'duration_ms': stopwatch.elapsedMilliseconds,
      };
    }
  }

  /// Strip HTML tags and decode entities to get plain text.
  static String _htmlToText(String html) {
    // Remove script and style blocks
    var text = html
        .replaceAll(RegExp(r'<script[^>]*>.*?</script>', dotAll: true), '')
        .replaceAll(RegExp(r'<style[^>]*>.*?</style>', dotAll: true), '')
        .replaceAll(RegExp(r'<noscript[^>]*>.*?</noscript>', dotAll: true), '');

    // Convert common block elements to newlines
    text = text
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</(p|div|h[1-6]|li|tr|blockquote|pre|section|article)>'), '\n\n')
        .replaceAll(RegExp(r'<(p|div|h[1-6]|li|tr|blockquote|pre|section|article)[^>]*>'), '')
        .replaceAll(RegExp(r'<hr\s*/?>'), '\n---\n');

    // Convert links: <a href="url">text</a> → text (url)
    text = text.replaceAllMapped(
        RegExp(r'<a[^>]+href="([^"]*)"[^>]*>(.*?)</a>', dotAll: true),
        (m) => '${m[2]} (${m[1]})');

    // Strip all remaining HTML tags
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');

    // Decode common HTML entities
    text = text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&hellip;', '...')
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m[1] ?? '');
      return code != null ? String.fromCharCode(code) : m[0]!;
    });

    // Collapse whitespace
    text = text
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();

    return text;
  }
}

class _CacheEntry {
  final Map<String, dynamic> data;
  final DateTime time;
  _CacheEntry({required this.data, required this.time});
}
