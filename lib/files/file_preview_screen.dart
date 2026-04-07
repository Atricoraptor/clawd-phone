import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _workspaceParentFolder = 'Download';
const _workspaceFolder = 'Clawd-Phone';
const _previewableExtensions = <String>{'html', 'md', 'txt', 'csv'};

class FilePreviewTarget {
  final String path;
  final String relativePath;
  final String extension;

  const FilePreviewTarget({
    required this.path,
    required this.relativePath,
    required this.extension,
  });

  String get fileName => relativePath.split('/').last;
}

FilePreviewTarget? previewTargetFromToolResult(Map<String, dynamic>? data) {
  if (data == null) return null;
  final path = data['path'] as String?;
  final relativePath = data['relative_path'] as String?;
  if (path == null || relativePath == null) return null;
  final normalizedRelativePath = _normalizeWorkspaceRelativePath(relativePath);
  if (normalizedRelativePath == null) return null;
  if (!_isWorkspacePath(path, normalizedRelativePath)) return null;
  final ext = normalizedRelativePath.split('.').last.toLowerCase();
  if (!_previewableExtensions.contains(ext)) return null;
  return FilePreviewTarget(
    path: path,
    relativePath: normalizedRelativePath,
    extension: ext,
  );
}

String? _normalizeWorkspaceRelativePath(String relativePath) {
  final normalizedSlashes = relativePath.trim().replaceAll('\\', '/');
  if (normalizedSlashes.isEmpty ||
      normalizedSlashes.startsWith('/') ||
      normalizedSlashes.startsWith('~')) {
    return null;
  }

  final segments = normalizedSlashes.split('/').where((s) => s.isNotEmpty);
  if (segments.isEmpty || segments.any((s) => s == '.' || s == '..')) {
    return null;
  }

  return segments.join('/');
}

bool _isWorkspacePath(String path, String relativePath) {
  final normalizedPath = path.replaceAll('\\', '/');
  final expectedSuffix =
      '/$_workspaceParentFolder/$_workspaceFolder/$relativePath';
  return normalizedPath.endsWith(expectedSuffix);
}

class FilePreviewScreen extends StatelessWidget {
  final FilePreviewTarget target;

  const FilePreviewScreen({
    super.key,
    required this.target,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          target.relativePath,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: FutureBuilder<_PreviewData>(
        future: _loadPreview(target),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _PreviewError(
              title: 'Unable to open file',
              message: snapshot.error.toString(),
            );
          }
          final data = snapshot.data;
          if (data == null) {
            return const _PreviewError(
              title: 'Unable to open file',
              message: 'Unknown preview error.',
            );
          }
          return switch (data.kind) {
            _PreviewKind.text => _PlainTextPreview(content: data.content),
            _PreviewKind.markdown => _MarkdownPreview(content: data.content),
            _PreviewKind.csv => _CsvPreview(
                content: data.content,
                rows: data.csvRows,
                parseFailed: data.csvParseFailed,
              ),
            _PreviewKind.html => _HtmlPreview(html: data.content),
          };
        },
      ),
    );
  }

  static Future<_PreviewData> _loadPreview(FilePreviewTarget target) async {
    final file = File(target.path);
    if (!await file.exists()) {
      throw StateError('File not found at ${target.relativePath}.');
    }
    final bytes = await file.readAsBytes();
    final content = _stripBom(utf8.decode(bytes, allowMalformed: true));

    switch (target.extension) {
      case 'txt':
        return _PreviewData.text(content);
      case 'md':
        return _PreviewData.markdown(content);
      case 'html':
        return _PreviewData.html(content);
      case 'csv':
        try {
          final parsed = const CsvToListConverter(
            shouldParseNumbers: false,
          ).convert(content);
          final rows = parsed
              .map(
                (row) => row.map((cell) => cell?.toString() ?? '').toList(),
              )
              .toList();
          return _PreviewData.csv(content, rows, parseFailed: false);
        } catch (_) {
          return _PreviewData.csv(content, const [], parseFailed: true);
        }
      default:
        throw StateError('Unsupported preview type: ${target.extension}.');
    }
  }

  static String _stripBom(String text) {
    return text.startsWith('\uFEFF') ? text.substring(1) : text;
  }
}

enum _PreviewKind {
  text,
  markdown,
  csv,
  html,
}

class _PreviewData {
  final _PreviewKind kind;
  final String content;
  final List<List<String>> csvRows;
  final bool csvParseFailed;

  const _PreviewData._(
    this.kind,
    this.content, {
    this.csvRows = const [],
    this.csvParseFailed = false,
  });

  factory _PreviewData.text(String content) =>
      _PreviewData._(_PreviewKind.text, content);

  factory _PreviewData.markdown(String content) =>
      _PreviewData._(_PreviewKind.markdown, content);

  factory _PreviewData.html(String content) =>
      _PreviewData._(_PreviewKind.html, content);

  factory _PreviewData.csv(
    String content,
    List<List<String>> rows, {
    required bool parseFailed,
  }) =>
      _PreviewData._(
        _PreviewKind.csv,
        content,
        csvRows: rows,
        csvParseFailed: parseFailed,
      );
}

class _PreviewError extends StatelessWidget {
  final String title;
  final String message;

  const _PreviewError({
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 40,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _PlainTextPreview extends StatelessWidget {
  final String content;

  const _PlainTextPreview({required this.content});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        content,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
            ),
      ),
    );
  }
}

class _MarkdownPreview extends StatelessWidget {
  final String content;

  const _MarkdownPreview({required this.content});

  MarkdownStyleSheet _styleSheet(ThemeData theme) {
    final textColor = theme.colorScheme.onSurface;
    final linkColor = theme.colorScheme.primary;
    final subtleBg = theme.colorScheme.surfaceContainerHighest;
    final borderColor = theme.colorScheme.outlineVariant;

    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyMedium?.copyWith(color: textColor),
      a: theme.textTheme.bodyMedium?.copyWith(
        color: linkColor,
        decoration: TextDecoration.underline,
        decorationColor: linkColor,
      ),
      code: theme.textTheme.bodySmall?.copyWith(
        color: textColor,
        fontFamily: 'monospace',
        backgroundColor: subtleBg,
      ),
      h1: theme.textTheme.titleLarge?.copyWith(color: textColor),
      h2: theme.textTheme.titleMedium?.copyWith(color: textColor),
      h3: theme.textTheme.titleSmall?.copyWith(color: textColor),
      h4: theme.textTheme.titleSmall?.copyWith(color: textColor),
      h5: theme.textTheme.titleSmall?.copyWith(color: textColor),
      h6: theme.textTheme.titleSmall?.copyWith(color: textColor),
      strong: theme.textTheme.bodyMedium?.copyWith(
        color: textColor,
        fontWeight: FontWeight.w700,
      ),
      em: theme.textTheme.bodyMedium?.copyWith(
        color: textColor,
        fontStyle: FontStyle.italic,
      ),
      del: theme.textTheme.bodyMedium?.copyWith(color: textColor),
      listBullet: theme.textTheme.bodyMedium?.copyWith(color: textColor),
      blockquote: theme.textTheme.bodyMedium?.copyWith(color: textColor),
      tableBody: theme.textTheme.bodyMedium?.copyWith(color: textColor),
      tableHead: theme.textTheme.bodyMedium?.copyWith(
        color: textColor,
        fontWeight: FontWeight.w700,
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      blockquoteDecoration: BoxDecoration(
        color: subtleBg,
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: borderColor, width: 3),
        ),
      ),
      codeblockPadding: const EdgeInsets.all(10),
      codeblockDecoration: BoxDecoration(
        color: subtleBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: MarkdownBody(
        data: content,
        styleSheet: _styleSheet(theme),
      ),
    );
  }
}

class _CsvPreview extends StatelessWidget {
  final String content;
  final List<List<String>> rows;
  final bool parseFailed;

  const _CsvPreview({
    required this.content,
    required this.rows,
    required this.parseFailed,
  });

  @override
  Widget build(BuildContext context) {
    if (parseFailed || rows.isEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('CSV table preview unavailable. Showing raw text.'),
            const SizedBox(height: 12),
            SelectableText(
              content,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
            ),
          ],
        ),
      );
    }

    final headerRow = rows.length > 1 ? rows.first : null;
    final dataRows = rows.length > 1 ? rows.sublist(1) : rows;
    final columnCount = rows.fold<int>(
      0,
      (maxCols, row) => row.length > maxCols ? row.length : maxCols,
    );
    if (columnCount == 0) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          content,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
              ),
        ),
      );
    }

    final headers = headerRow != null && headerRow.isNotEmpty
        ? List<String>.generate(columnCount, (index) {
            final value = index < headerRow.length ? headerRow[index] : '';
            return value.isEmpty ? 'Column ${index + 1}' : value;
          })
        : List<String>.generate(columnCount, (index) => 'Column ${index + 1}');

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: headers
              .map(
                (header) => DataColumn(
                  label: Text(
                    header,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          rows: dataRows
              .map(
                (row) => DataRow(
                  cells: List<DataCell>.generate(
                    columnCount,
                    (index) => DataCell(
                      SizedBox(
                        width: 160,
                        child: Text(index < row.length ? row[index] : ''),
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _HtmlPreview extends StatefulWidget {
  final String html;

  const _HtmlPreview({required this.html});

  @override
  State<_HtmlPreview> createState() => _HtmlPreviewState();
}

class _HtmlPreviewState extends State<_HtmlPreview> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.prevent;
            if (uri.scheme == 'about' ||
                uri.scheme == 'data' ||
                uri.scheme == 'file') {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadHtmlString(widget.html);
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
