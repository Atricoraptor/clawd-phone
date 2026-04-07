import '../models/tool_definition.dart';

/// All tools available to the agent.
/// Permission-gated tools are exposed to Claude and may return
/// PERMISSION_DENIED at runtime until the user grants access in Android Settings.
final List<ToolDefinition> toolRegistry = [
  // --- FILE TOOLS ---
  const ToolDefinition(
    name: 'FileSearch',
    description:
        'Search for files on the device by filename, extension, wildcard pattern, MIME type, size range, or date range.\n'
        'Works for files downloaded by Chrome, Samsung Internet, other browsers, or file manager apps as long as they are in readable public storage.\n'
        'Understands natural queries like "pdf", ".md", "markdown file", "tax pdf", as well as explicit wildcards like "*.pdf", "invoice*", "IMG_2024*".\n'
        'Searches public folders such as Download, Documents, Pictures, and DCIM, and also uses Android\'s file index when available.\n'
        'Returns matching files sorted by date (newest first) with name, path, size, MIME type, and dates.\n'
        'Default limit is 20 results. Use offset to page through larger result sets in batches instead of raising limit aggressively. For exploratory searches, prefer a small limit and refine if needed. Use this tool BEFORE FileRead to locate files — do not guess paths.\n'
        'Dates should be ISO format (e.g., "2025-07-01"). Leave fields empty to match all.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description': 'Filename pattern with * wildcards'
        },
        'mime_type': {
          'type': 'string',
          'description': 'MIME filter: image/*, video/*, application/pdf, etc.'
        },
        'min_size_bytes': {
          'type': 'integer',
          'description': 'Minimum file size'
        },
        'max_size_bytes': {
          'type': 'integer',
          'description': 'Maximum file size'
        },
        'date_after': {
          'type': 'string',
          'description': 'ISO date: files modified after this'
        },
        'date_before': {
          'type': 'string',
          'description': 'ISO date: files modified before this'
        },
        'directory': {
          'type': 'string',
          'description': 'Limit to directory (e.g., Download, DCIM)'
        },
        'sort_by': {
          'type': 'string',
          'enum': ['date_modified', 'date_added', 'name', 'size']
        },
        'limit': {'type': 'integer', 'description': 'Max results (default 20)'},
        'offset': {
          'type': 'integer',
          'minimum': 0,
          'description': 'Pagination offset for results (default 0)'
        },
      },
    },
    requiredPermission: 'storage',
    category: 'files',
  ),

  const ToolDefinition(
    name: 'FileRead',
    description: 'Read the contents of a file. Behavior depends on file type:\n'
        '- Text files (.txt, .md, .csv, .json, .xml, .log, .py, .js, .html, etc.): returns content with line numbers. Use offset/limit for large files. offset is a 1-based starting line number, so offset=1 starts at line 1. Reads are bounded by native line, character, and token budgets, so very large requested ranges may return an error asking you to narrow the read.\n'
        '- Images (.jpg, .png, .webp, .gif): returns base64 image for visual analysis. Auto-resized to fit token limits.\n'
        '- PDFs (.pdf): Small PDFs (< 3MB, ≤ 20 pages) may be sent as a document block so you can read them directly. Larger PDFs or specific page ranges are rendered as JPEG page images at 100 DPI for your vision to read. Use pages param ("1-5", "3") for larger PDFs. Max 20 pages per call. Works with both digital and scanned PDFs.\n'
        '- EPUBs (.epub): by default returns a structure list of readable chapter/section entries. Use FileContentSearch to find keywords inside the EPUB, then call FileRead again with the entry parameter plus offset/limit to read specific normalized lines from that entry. EPUB entry reads are bounded too; if a requested range is too large, reduce limit or move offset.\n'
        '- ZIP (.zip): lists archive contents (filenames, sizes, compressed sizes). Does not extract files.\n'
        '- Other types: returns basic file info. Use Metadata tool for detailed properties.\n'
        'Always use FileSearch first to get the file path. Do not guess or invent paths.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Absolute file path'},
        'offset': {
          'type': 'integer',
          'minimum': 1,
          'description': 'For text: 1-based starting line number (default 1)'
        },
        'limit': {
          'type': 'integer',
          'minimum': 1,
          'description': 'For text: max lines (default 1000)'
        },
        'pages': {
          'type': 'string',
          'description':
              'For PDFs: page range e.g. "1-5", "3". Max 20 pages per call.'
        },
        'entry': {
          'type': 'string',
          'description':
              'For EPUBs: internal chapter/section entry path returned by FileRead or FileContentSearch.'
        },
      },
      'required': ['path'],
    },
    requiredPermission: 'storage',
    maxResultSizeChars: double
        .infinity, // Native Kotlin enforces line, char, and token budgets for read paths.
    category: 'files',
  ),

  const ToolDefinition(
    name: 'FileWrite',
    description:
        'Create a new UTF-8 text file or fully rewrite an existing one inside the app workspace at Download/Clawd-Phone/.\n'
        'Only supports these extensions: .html, .md, .txt, .csv.\n'
        'Use this for exports, notes, reports, generated pages, or complete rewrites. Prefer FileEdit for targeted changes to an existing file.\n'
        'relative_path must be a path INSIDE Download/Clawd-Phone/ and must never be absolute. Subfolders are allowed, for example "reports/day1/plan.html".\n'
        'If the file already exists and overwrite is false, the tool returns FILE_ALREADY_EXISTS and changes nothing.\n'
        'If the file already exists and overwrite is true, you must first read the current file with FileRead or have just written it earlier in this conversation. Do not claim a file was changed unless this tool succeeds.\n'
        'For HTML documents, include a UTF-8 charset declaration. CSV files are written with UTF-8 BOM for better spreadsheet compatibility.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'relative_path': {
          'type': 'string',
          'description':
              'Path inside Download/Clawd-Phone/, e.g. "report.html" or "exports/april.csv"'
        },
        'content': {
          'type': 'string',
          'description': 'Full file contents to write'
        },
        'overwrite': {
          'type': 'boolean',
          'description':
              'Overwrite an existing file only when true (default false)'
        },
      },
      'required': ['relative_path', 'content'],
    },
    requiredPermission: 'storage_full',
    maxResultSizeChars: 100000,
    category: 'files',
  ),

  const ToolDefinition(
    name: 'FileEdit',
    description:
        'Edit an existing UTF-8 text file inside Download/Clawd-Phone/ by exact string replacement.\n'
        'Only supports these extensions: .html, .md, .txt, .csv.\n'
        'Use this for targeted updates when most of the file should stay the same. Use FileWrite for new files or full rewrites.\n'
        'relative_path must be inside Download/Clawd-Phone/ and must never be absolute.\n'
        'You must read the current file with FileRead first, or have just created or rewritten it earlier in this conversation.\n'
        'old_string and new_string must match actual file text exactly and must NOT include the line-number prefixes shown by FileRead.\n'
        'If old_string is not found, the tool errors. If it appears multiple times and replace_all is false, the tool errors so you can provide a more specific match.\n'
        'The tool preserves CSV UTF-8 BOM on disk for compatibility.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'relative_path': {
          'type': 'string',
          'description':
              'Path inside Download/Clawd-Phone/, e.g. "report.html" or "notes/today.md"'
        },
        'old_string': {
          'type': 'string',
          'description': 'Exact text to replace, without FileRead line numbers'
        },
        'new_string': {'type': 'string', 'description': 'Replacement text'},
        'replace_all': {
          'type': 'boolean',
          'description':
              'Replace every occurrence of old_string when true (default false)'
        },
      },
      'required': ['relative_path', 'old_string', 'new_string'],
    },
    requiredPermission: 'storage_full',
    maxResultSizeChars: 100000,
    category: 'files',
  ),

  const ToolDefinition(
    name: 'Metadata',
    description:
        'Get detailed metadata about any file. Returns different data depending on type:\n'
        '- Images: full EXIF data — camera make/model, GPS coordinates, aperture, ISO, exposure, date taken, dimensions, orientation.\n'
        '- Videos: duration, resolution, codec, bitrate, frame rate, creation date, location.\n'
        '- Audio: title, artist, album, genre, year, duration, bitrate, sample rate.\n'
        '- All files: name, path, size, MIME type, date modified, parent directory.\n'
        'Use this for "where was this taken?", "what camera?", "how long is this video?" — NOT for "what is in this image?" (use FileRead for that).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Absolute file path'},
      },
      'required': ['path'],
    },
    requiredPermission: 'storage',
    category: 'files',
  ),

  const ToolDefinition(
    name: 'StorageStats',
    description: 'Get device storage usage statistics.\n'
        '- breakdown="overview" (default): total, used, free space plus count/size by type (images, videos, audio, documents).\n'
        '- breakdown="type": same type breakdown without device totals.\n'
        '- top_n=N: also returns the N largest files on the device (default 20).\n'
        'Use this for "how much space do I have?", "what is using my storage?", "find biggest files".',
    inputSchema: {
      'type': 'object',
      'properties': {
        'breakdown': {
          'type': 'string',
          'enum': ['overview', 'type'],
          'description': 'What to break down by (default: overview)',
        },
        'top_n': {
          'type': 'integer',
          'description': 'Top N largest files (default 20)'
        },
      },
    },
    requiredPermission: 'storage',
    maxResultSizeChars: 100000,
    category: 'files',
  ),

  const ToolDefinition(
    name: 'DirectoryList',
    description:
        'List contents of a directory on the device. Shows files and subdirectories with name, type, size, and date.\n'
        'Default path is the shared storage root (/storage/emulated/0). Use recursive=true with max_depth to explore tree structure.\n'
        'Useful for browsing folder contents, understanding project structure, or finding files in a known location.\n'
        'For searching by name/type across the whole device, use FileSearch instead.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Directory path (default: shared storage root)'
        },
        'recursive': {
          'type': 'boolean',
          'description': 'Include subdirectories'
        },
        'max_depth': {
          'type': 'integer',
          'description': 'Recursion depth (default 1, max 5)'
        },
        'show_hidden': {'type': 'boolean', 'description': 'Include dot-files'},
        'sort_by': {
          'type': 'string',
          'enum': ['name', 'size', 'date_modified']
        },
        'limit': {
          'type': 'integer',
          'description': 'Max entries (default 100)'
        },
      },
    },
    requiredPermission: 'storage',
    maxResultSizeChars: 100000,
    category: 'files',
  ),

  // --- CORE DEVICE TOOLS (always loaded, no permission) ---
  const ToolDefinition(
    name: 'DeviceInfo',
    description:
        'Get comprehensive device hardware and software information. No permissions needed.\n'
        'Sections: hardware (model, CPU, RAM), software (Android version, security patch, uptime), display (resolution, DPI), features (NFC, fingerprint, GPS, etc.).\n'
        'Use sections param to request only what you need — e.g., ["hardware", "software"] skips display and features.\n'
        'Default returns all sections.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'sections': {
          'type': 'array',
          'items': {
            'type': 'string',
            'enum': ['hardware', 'software', 'display', 'features', 'all']
          },
          'description': 'Which sections to include (default: all)',
        },
      },
    },
    category: 'device',
  ),

  // --- WEB TOOLS (always loaded, no permission needed) ---
  const ToolDefinition(
    name: 'WebFetch',
    description: 'Fetch a web page by URL and return its text content.\n'
        'HTML is automatically converted to plain text (scripts/styles removed, tags stripped, entities decoded).\n'
        'Use this to read specific URLs: documentation pages, articles, blog posts, or any public web page.\n'
        'For deep research, use web_search to find relevant sources, then use WebFetch to read the most promising URLs in detail.\n'
        'Do NOT use this for web searching — use web_search instead.\n'
        'Results are cached for 15 minutes. Max output: 100K characters. Timeout: 30 seconds.\n'
        'URL must start with https://.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'url': {
          'type': 'string',
          'description': 'The URL to fetch (must start with https://)'
        },
        'max_length': {
          'type': 'integer',
          'minimum': 1000,
          'description': 'Max characters to return (default 100000)'
        },
      },
      'required': ['url'],
    },
    maxResultSizeChars: 100000,
    category: 'web',
  ),

  const ToolDefinition(
    name: 'web_search',
    description:
        'Search the web for current information using Anthropic\'s built-in web search.\n'
        'Returns search results with titles and URLs. Use this when you need up-to-date information beyond your training data.\n'
        'IMPORTANT: After answering a question using web search results, you MUST include a "Sources:" section at the end with markdown hyperlinks to the relevant URLs.\n'
        'Use allowed_domains to restrict results to specific sites. Use blocked_domains to exclude sites.\n'
        'Do not use both allowed_domains and blocked_domains in the same call.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'The search query'},
        'allowed_domains': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Only include results from these domains',
        },
        'blocked_domains': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Exclude results from these domains',
        },
      },
      'required': ['query'],
    },
    builtInType: 'web_search_20250305',
    category: 'web',
  ),

  const ToolDefinition(
    name: 'Battery',
    description: 'Get current battery status. No permissions needed.\n'
        'Returns: level (%), health (good/overheat/dead/cold), temperature (Celsius), voltage, charging status, charger type (AC/USB/wireless), technology.\n'
        'No input parameters required — just call it.',
    inputSchema: {
      'type': 'object',
      'properties': {},
    },
    category: 'device',
  ),

  // --- PERSONAL TOOLS (implemented in PersonalToolsChannel.kt) ---
  const ToolDefinition(
    name: 'Contacts',
    description:
        'Search and read contacts. Actions: search by name/number, list all, detail for one, '
        'stats overview.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['search', 'list', 'detail', 'stats']
        },
        'query': {
          'type': 'string',
          'description': 'Search by name, number, or email'
        },
        'contact_id': {'type': 'string', 'description': 'For detail action'},
        'sort_by': {
          'type': 'string',
          'enum': ['name', 'last_contacted', 'times_contacted']
        },
        'limit': {'type': 'integer', 'description': 'Max results (default 50)'},
      },
    },
    requiredPermission: 'contacts',
    category: 'personal',
  ),

  const ToolDefinition(
    name: 'Calendar',
    description:
        'Read calendar events. Actions: upcoming, date range, search by title, today, stats.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['upcoming', 'range', 'search', 'today', 'stats']
        },
        'query': {
          'type': 'string',
          'description': 'Search in title/description'
        },
        'date_from': {'type': 'string', 'description': 'ISO date start'},
        'date_to': {'type': 'string', 'description': 'ISO date end'},
        'limit': {'type': 'integer', 'description': 'Max events (default 20)'},
      },
    },
    requiredPermission: 'calendar',
    category: 'personal',
  ),

  // --- Intelligence tools ---
  const ToolDefinition(
    name: 'AppDetail',
    description: 'Inspect installed apps visible to Android package APIs.\n'
        'Actions:\n'
        '- list: count and list installed apps\n'
        '- search: find apps by name or package\n'
        '- detail: show metadata for one app\n'
        '- last_used: show when an app was last used\n'
        'Use package_name when you know the exact app. Otherwise use query.\n'
        'last_used requires Android Usage Access; if it is not enabled, the tool returns a permission error telling the user to enable it in Settings.\n'
        'This v1 does not implement storage ranking, exact app size, or unused-app analysis.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['list', 'search', 'detail', 'last_used']
        },
        'query': {'type': 'string', 'description': 'App name to search'},
        'package_name': {'type': 'string', 'description': 'For detail action'},
        'include_system_apps': {'type': 'boolean'},
        'sort_by': {
          'type': 'string',
          'enum': ['name', 'install_date', 'update_date']
        },
        'limit': {'type': 'integer'},
      },
    },
    category: 'apps',
  ),

  const ToolDefinition(
    name: 'UsageStats',
    description:
        'App usage and screen time. Actions: today, date range, top_apps, app_detail, hourly_breakdown, summary.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': [
            'today',
            'range',
            'top_apps',
            'app_detail',
            'hourly_breakdown',
            'summary'
          ]
        },
        'date_from': {'type': 'string'},
        'date_to': {'type': 'string'},
        'package_name': {'type': 'string', 'description': 'For app_detail'},
        'interval': {
          'type': 'string',
          'enum': ['daily', 'weekly', 'monthly']
        },
        'limit': {'type': 'integer'},
      },
    },
    requiredPermission: 'usage_stats',
    category: 'intelligence',
  ),

  // --- Additional file tools ---
  const ToolDefinition(
    name: 'FileContentSearch',
    description:
        'Search inside file contents for text/regex (like grep). Works on text-based files and inside EPUB chapter entries.\n'
        'Prefer a small limit for exploratory searches, then narrow and retry if needed. Use offset to page through additional matched files.\n'
        'Default limit is 20 matched file or EPUB-entry results.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'pattern': {'type': 'string', 'description': 'Text or regex pattern'},
        'path': {'type': 'string'},
        'file_pattern': {
          'type': 'string',
          'description': 'Glob filter: *.txt, *.json'
        },
        'case_sensitive': {'type': 'boolean'},
        'limit': {
          'type': 'integer',
          'description': 'Max matched file or EPUB-entry results (default 20)'
        },
        'offset': {
          'type': 'integer',
          'minimum': 0,
          'description':
              'Pagination offset for matched file or EPUB-entry results (default 0)'
        },
      },
      'required': ['pattern'],
    },
    requiredPermission: 'storage',
    maxResultSizeChars: 100000,
    category: 'files',
  ),

  const ToolDefinition(
    name: 'RecentActivity',
    description:
        'Show recently added or modified files on the device as a timeline.\n'
        'Use action="added" for newly downloaded/created files, "modified" for recently changed files, "all" for both.\n'
        'Use mime_filter to narrow by type (e.g., "image/*", "application/pdf").\n'
        'Default: last 24 hours, all types, limit 30. Useful for "what did I download today?" or "recent photos".',
    inputSchema: {
      'type': 'object',
      'properties': {
        'hours_back': {
          'type': 'integer',
          'minimum': 1,
          'description': 'Look back N hours (default 24)'
        },
        'action': {
          'type': 'string',
          'enum': ['added', 'modified', 'all'],
          'description': 'Filter by added, modified, or all'
        },
        'mime_filter': {
          'type': 'string',
          'description': 'MIME type filter e.g. image/*, application/pdf'
        },
        'limit': {
          'type': 'integer',
          'minimum': 1,
          'description': 'Max results (default 30)'
        },
      },
    },
    requiredPermission: 'storage',
    category: 'files',
  ),

  const ToolDefinition(
    name: 'LargeFiles',
    description:
        'Find the largest files on the device, sorted by size (biggest first).\n'
        'Default: files over 10MB, limit 25. Use for storage cleanup recommendations.\n'
        'Returns name, path, size, MIME type, and date for each file.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'min_size_bytes': {
          'type': 'integer',
          'minimum': 0,
          'description': 'Only files larger than this (default 10MB)'
        },
        'limit': {
          'type': 'integer',
          'minimum': 1,
          'description': 'Max results (default 25)'
        },
      },
    },
    requiredPermission: 'storage',
    category: 'files',
  ),

  const ToolDefinition(
    name: 'Notifications',
    description: 'Read current/recent notifications from all apps.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['current', 'history', 'summary', 'from_app']
        },
        'package_filter': {'type': 'string'},
        'limit': {'type': 'integer'},
      },
    },
    requiredPermission: 'notifications',
    category: 'intelligence',
  ),

  const ToolDefinition(
    name: 'CallLog',
    description:
        'Phone call history: recent, search, stats, frequent contacts.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['recent', 'search', 'stats', 'frequent']
        },
        'query': {'type': 'string'},
        'call_type': {
          'type': 'string',
          'enum': ['all', 'incoming', 'outgoing', 'missed']
        },
        'date_after': {'type': 'string'},
        'limit': {'type': 'integer'},
      },
    },
    requiredPermission: 'call_log',
    category: 'personal',
  ),

  const ToolDefinition(
    name: 'Location',
    description:
        'Current device location: coordinates, accuracy, reverse-geocoded address.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'include_address': {'type': 'boolean'},
      },
    },
    requiredPermission: 'location',
    category: 'advanced',
  ),
];
