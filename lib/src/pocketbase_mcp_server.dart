import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart' as app_logging;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:pocketbase/pocketbase.dart';

enum AccessMode { readonly, readwrite }

enum McpAuthMode { token, oauth }

class McpAuthConfig {
  const McpAuthConfig({
    required this.enabled,
    required this.mode,
    this.bearerTokens = const <String>{},
  });

  const McpAuthConfig.disabled()
      : enabled = false,
        mode = McpAuthMode.token,
        bearerTokens = const <String>{};

  final bool enabled;
  final McpAuthMode mode;
  final Set<String> bearerTokens;
}

class PocketBaseMcpServer {
  PocketBaseMcpServer({
    required String pocketbaseUrl,
    String? adminEmail,
    String? adminPassword,
    AccessMode accessMode = AccessMode.readonly,
    McpAuthConfig authConfig = const McpAuthConfig.disabled(),
    Set<String> allowedTools = const {},
    Set<String> deniedTools = const {},
  })  : _adminEmail = adminEmail,
        _adminPassword = adminPassword,
        _pocketbaseUrl = pocketbaseUrl,
        _accessMode = accessMode,
        _authConfig = authConfig,
        _allowedTools = allowedTools.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet(),
        _deniedTools = deniedTools.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet(),
        _server = McpServer(
          const Implementation(name: 'pocketbase-server', version: '0.2.0'),
          options: const McpServerOptions(
            capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
          ),
        ),
        _pb = PocketBase(pocketbaseUrl);

  final McpServer _server;
  final PocketBase _pb;
  final String? _adminEmail;
  final String? _adminPassword;
  final String _pocketbaseUrl;
  final AccessMode _accessMode;
  final McpAuthConfig _authConfig;
  final Set<String> _allowedTools;
  final Set<String> _deniedTools;
  final Map<String, _ToolPolicy> _toolPolicies = <String, _ToolPolicy>{};
  final app_logging.Logger _log = app_logging.Logger('PocketBaseMcpServer');
  final Map<String, StreamableHTTPServerTransport> _streamableTransports = {};
  final Map<String, McpServer> _streamableServers = {};
  HttpServer? _streamableHttpServer;

  void registerTools() {
    _registerTool(
      'get_server_permissions',
      description: 'Return current server permission configuration.',
      inputSchema: JsonSchema.object(properties: const {}),
      callback: (args) async => _resultAny({
        'accessMode': _accessMode.name,
        'allowedTools': _allowedTools.toList()..sort(),
        'deniedTools': _deniedTools.toList()..sort(),
        'adminConfigured': (_adminEmail ?? '').isNotEmpty && (_adminPassword ?? '').isNotEmpty,
      }),
      write: false,
      admin: false,
    );

    _registerTool(
      'raw_api_call',
      description:
          'Generic PocketBase API bridge for full SDK/API coverage. Use path like /api/collections/posts/records.',
      inputSchema: JsonSchema.object(
        properties: {
          'path': JsonSchema.string(description: 'API path, e.g. /api/collections/users/records'),
          'method': JsonSchema.string(
            description: 'HTTP method',
            enumValues: const ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
          ),
          'body': JsonSchema.object(description: 'Optional request body'),
          'query': JsonSchema.object(description: 'Optional query params'),
          'headers': JsonSchema.object(description: 'Optional headers'),
          'requireAdmin': JsonSchema.boolean(
            description: 'If true, force superuser authentication first.',
          ),
        },
        required: const ['path'],
      ),
      callback: _rawApiCall,
      write: false,
      admin: false,
    );

    _registerTool(
      'get_record',
      description: 'Fetch one record by collection and id.',
      inputSchema: JsonSchema.object(
        properties: {
          'collection': JsonSchema.string(),
          'id': JsonSchema.string(),
          'expand': JsonSchema.string(),
          'fields': JsonSchema.string(),
        },
        required: const ['collection', 'id'],
      ),
      callback: _getRecord,
      write: false,
      admin: false,
    );

    _registerTool(
      'list_records',
      description: 'List records from a collection with paging/filter/sort.',
      inputSchema: JsonSchema.object(
        properties: {
          'collection': JsonSchema.string(),
          'filter': JsonSchema.string(),
          'sort': JsonSchema.string(),
          'page': JsonSchema.number(),
          'perPage': JsonSchema.number(),
          'expand': JsonSchema.string(),
          'fields': JsonSchema.string(),
        },
        required: const ['collection'],
      ),
      callback: _listRecords,
      write: false,
      admin: false,
    );

    _registerTool(
      'list_all_records',
      description: 'Fetch all records from a collection using batch pagination.',
      inputSchema: JsonSchema.object(
        properties: {
          'collection': JsonSchema.string(),
          'batch': JsonSchema.number(),
          'filter': JsonSchema.string(),
          'sort': JsonSchema.string(),
          'expand': JsonSchema.string(),
          'fields': JsonSchema.string(),
        },
        required: const ['collection'],
      ),
      callback: _listAllRecords,
      write: false,
      admin: false,
    );

    _registerTool(
      'create_record',
      description: 'Create a record in a collection.',
      inputSchema: JsonSchema.object(
        properties: {
          'collection': JsonSchema.string(),
          'data': JsonSchema.object(),
        },
        required: const ['collection', 'data'],
      ),
      callback: _createRecord,
      write: true,
      admin: false,
    );

    _registerTool(
      'update_record',
      description: 'Update a record in a collection.',
      inputSchema: JsonSchema.object(
        properties: {
          'collection': JsonSchema.string(),
          'id': JsonSchema.string(),
          'data': JsonSchema.object(),
        },
        required: const ['collection', 'id', 'data'],
      ),
      callback: _updateRecord,
      write: true,
      admin: false,
    );

    _registerTool(
      'delete_record',
      description: 'Delete a record from a collection.',
      inputSchema: JsonSchema.object(
        properties: {
          'collection': JsonSchema.string(),
          'id': JsonSchema.string(),
        },
        required: const ['collection', 'id'],
      ),
      callback: _deleteRecord,
      write: true,
      admin: false,
    );

    _registerTool(
      'import_data',
      description: 'Bulk import records in create/update/upsert mode.',
      inputSchema: JsonSchema.object(
        properties: {
          'collection': JsonSchema.string(),
          'data': JsonSchema.array(items: JsonSchema.object()),
          'mode': JsonSchema.string(enumValues: const ['create', 'update', 'upsert']),
        },
        required: const ['collection', 'data'],
      ),
      callback: _importData,
      write: true,
      admin: false,
    );

    _registerTool(
      'list_auth_methods',
      description: 'List available auth methods for auth collection (default users).',
      inputSchema: JsonSchema.object(
        properties: {
          'collection': JsonSchema.string(),
          'fields': JsonSchema.string(),
        },
      ),
      callback: _listAuthMethods,
      write: false,
      admin: false,
    );

    _registerTool(
      'authenticate_user',
      description: 'Authenticate with username/email + password (or superuser).',
      inputSchema: JsonSchema.object(
        properties: {
          'email': JsonSchema.string(),
          'password': JsonSchema.string(),
          'collection': JsonSchema.string(),
          'isAdmin': JsonSchema.boolean(),
          'expand': JsonSchema.string(),
          'fields': JsonSchema.string(),
        },
      ),
      callback: _authenticateUser,
      write: true,
      admin: false,
    );

    _registerTool(
      'auth_refresh',
      description: 'Refresh current auth token for collection (default users).',
      inputSchema: JsonSchema.object(
        properties: {
          'collection': JsonSchema.string(),
          'expand': JsonSchema.string(),
          'fields': JsonSchema.string(),
        },
      ),
      callback: _authRefresh,
      write: true,
      admin: false,
    );

    _registerTool(
      'authenticate_with_oauth2',
      description: 'Authenticate auth record via OAuth2 code exchange.',
      inputSchema: JsonSchema.object(
        properties: {
          'provider': JsonSchema.string(),
          'code': JsonSchema.string(),
          'codeVerifier': JsonSchema.string(),
          'redirectUrl': JsonSchema.string(),
          'collection': JsonSchema.string(),
          'createData': JsonSchema.object(),
          'expand': JsonSchema.string(),
          'fields': JsonSchema.string(),
        },
        required: const ['provider', 'code', 'codeVerifier', 'redirectUrl'],
      ),
      callback: _authenticateWithOAuth2,
      write: true,
      admin: false,
    );

    _registerTool(
      'request_otp',
      description: 'Request one-time password for email.',
      inputSchema: JsonSchema.object(
        properties: {
          'email': JsonSchema.string(),
          'collection': JsonSchema.string(),
        },
        required: const ['email'],
      ),
      callback: _requestOtp,
      write: true,
      admin: false,
    );

    _registerTool(
      'authenticate_with_otp',
      description: 'Authenticate using otpId and OTP code/password.',
      inputSchema: JsonSchema.object(
        properties: {
          'otpId': JsonSchema.string(),
          'password': JsonSchema.string(),
          'collection': JsonSchema.string(),
          'expand': JsonSchema.string(),
          'fields': JsonSchema.string(),
        },
        required: const ['otpId', 'password'],
      ),
      callback: _authenticateWithOtp,
      write: true,
      admin: false,
    );

    _registerTool(
      'request_verification',
      description: 'Request email verification token.',
      inputSchema: JsonSchema.object(
        properties: {
          'email': JsonSchema.string(),
          'collection': JsonSchema.string(),
        },
        required: const ['email'],
      ),
      callback: _requestVerification,
      write: true,
      admin: false,
    );

    _registerTool(
      'confirm_verification',
      description: 'Confirm email verification with token.',
      inputSchema: JsonSchema.object(
        properties: {
          'token': JsonSchema.string(),
          'collection': JsonSchema.string(),
          'expand': JsonSchema.string(),
          'fields': JsonSchema.string(),
        },
        required: const ['token'],
      ),
      callback: _confirmVerification,
      write: true,
      admin: false,
    );

    _registerTool(
      'request_password_reset',
      description: 'Request password reset token by email.',
      inputSchema: JsonSchema.object(
        properties: {
          'email': JsonSchema.string(),
          'collection': JsonSchema.string(),
        },
        required: const ['email'],
      ),
      callback: _requestPasswordReset,
      write: true,
      admin: false,
    );

    _registerTool(
      'confirm_password_reset',
      description: 'Confirm password reset using token and new password.',
      inputSchema: JsonSchema.object(
        properties: {
          'token': JsonSchema.string(),
          'password': JsonSchema.string(),
          'passwordConfirm': JsonSchema.string(),
          'collection': JsonSchema.string(),
        },
        required: const ['token', 'password', 'passwordConfirm'],
      ),
      callback: _confirmPasswordReset,
      write: true,
      admin: false,
    );

    _registerTool(
      'request_email_change',
      description: 'Request email change for currently authenticated user.',
      inputSchema: JsonSchema.object(
        properties: {
          'newEmail': JsonSchema.string(),
          'collection': JsonSchema.string(),
        },
        required: const ['newEmail'],
      ),
      callback: _requestEmailChange,
      write: true,
      admin: false,
    );

    _registerTool(
      'confirm_email_change',
      description: 'Confirm email change with token + current password.',
      inputSchema: JsonSchema.object(
        properties: {
          'token': JsonSchema.string(),
          'password': JsonSchema.string(),
          'collection': JsonSchema.string(),
        },
        required: const ['token', 'password'],
      ),
      callback: _confirmEmailChange,
      write: true,
      admin: false,
    );

    _registerTool(
      'impersonate_user',
      description: 'Impersonate user by id (requires superuser auth).',
      inputSchema: JsonSchema.object(
        properties: {
          'id': JsonSchema.string(),
          'collection': JsonSchema.string(),
          'duration': JsonSchema.number(),
        },
        required: const ['id'],
      ),
      callback: _impersonateUser,
      write: true,
      admin: true,
    );

    _registerTool(
      'create_user',
      description: 'Create auth record in collection (default users).',
      inputSchema: JsonSchema.object(
        properties: {
          'email': JsonSchema.string(),
          'password': JsonSchema.string(),
          'passwordConfirm': JsonSchema.string(),
          'name': JsonSchema.string(),
          'collection': JsonSchema.string(),
        },
        required: const ['email', 'password', 'passwordConfirm'],
      ),
      callback: _createUser,
      write: true,
      admin: false,
    );

    _registerTool(
      'create_collection',
      description: 'Create collection (admin).',
      inputSchema: JsonSchema.object(
        properties: {
          'name': JsonSchema.string(),
          'type': JsonSchema.string(enumValues: const ['base', 'view', 'auth']),
          'fields': JsonSchema.array(items: JsonSchema.object()),
          'listRule': JsonSchema.string(),
          'viewRule': JsonSchema.string(),
          'createRule': JsonSchema.string(),
          'updateRule': JsonSchema.string(),
          'deleteRule': JsonSchema.string(),
          'authRule': JsonSchema.string(),
          'manageRule': JsonSchema.string(),
          'viewQuery': JsonSchema.string(),
          'passwordAuth': JsonSchema.object(),
        },
        required: const ['name', 'fields'],
      ),
      callback: _createCollection,
      write: true,
      admin: true,
    );

    _registerTool(
      'update_collection',
      description: 'Update collection (admin).',
      inputSchema: JsonSchema.object(
        properties: {
          'collectionIdOrName': JsonSchema.string(),
          'name': JsonSchema.string(),
          'type': JsonSchema.string(enumValues: const ['base', 'view', 'auth']),
          'fields': JsonSchema.array(items: JsonSchema.object()),
          'listRule': JsonSchema.string(),
          'viewRule': JsonSchema.string(),
          'createRule': JsonSchema.string(),
          'updateRule': JsonSchema.string(),
          'deleteRule': JsonSchema.string(),
          'authRule': JsonSchema.string(),
          'manageRule': JsonSchema.string(),
          'viewQuery': JsonSchema.string(),
          'passwordAuth': JsonSchema.object(),
        },
        required: const ['collectionIdOrName'],
      ),
      callback: _updateCollection,
      write: true,
      admin: true,
    );

    _registerTool(
      'delete_collection',
      description: 'Delete collection (admin).',
      inputSchema: JsonSchema.object(
        properties: {'collectionIdOrName': JsonSchema.string()},
        required: const ['collectionIdOrName'],
      ),
      callback: _deleteCollection,
      write: true,
      admin: true,
    );

    _registerTool(
      'truncate_collection',
      description: 'Delete all records in a collection (admin).',
      inputSchema: JsonSchema.object(
        properties: {'collectionIdOrName': JsonSchema.string()},
        required: const ['collectionIdOrName'],
      ),
      callback: _truncateCollection,
      write: true,
      admin: true,
    );

    _registerTool(
      'list_collections',
      description: 'List collections (admin).',
      inputSchema: JsonSchema.object(
        properties: {
          'filter': JsonSchema.string(),
          'sort': JsonSchema.string(),
          'page': JsonSchema.number(),
          'perPage': JsonSchema.number(),
        },
      ),
      callback: _listCollections,
      write: false,
      admin: true,
    );

    _registerTool(
      'get_collection',
      description: 'Get collection details (admin).',
      inputSchema: JsonSchema.object(
        properties: {
          'collectionIdOrName': JsonSchema.string(),
          'fields': JsonSchema.string(),
        },
        required: const ['collectionIdOrName'],
      ),
      callback: _getCollection,
      write: false,
      admin: true,
    );

    _registerTool(
      'get_collection_scaffolds',
      description: 'Get default scaffold models for collection types (admin).',
      inputSchema: JsonSchema.object(properties: const {}),
      callback: _getCollectionScaffolds,
      write: false,
      admin: true,
    );

    _registerTool(
      'backup_database',
      description: 'Create a backup (admin).',
      inputSchema: JsonSchema.object(
        properties: {'name': JsonSchema.string()},
      ),
      callback: _backupDatabase,
      write: true,
      admin: true,
    );

    _registerTool(
      'list_backups',
      description: 'List backups (admin).',
      inputSchema: JsonSchema.object(properties: const {}),
      callback: _listBackups,
      write: false,
      admin: true,
    );

    _registerTool(
      'delete_backup',
      description: 'Delete backup by key (admin).',
      inputSchema: JsonSchema.object(
        properties: {'key': JsonSchema.string()},
        required: const ['key'],
      ),
      callback: _deleteBackup,
      write: true,
      admin: true,
    );

    _registerTool(
      'restore_backup',
      description: 'Restore backup by key (admin).',
      inputSchema: JsonSchema.object(
        properties: {'key': JsonSchema.string()},
        required: const ['key'],
      ),
      callback: _restoreBackup,
      write: true,
      admin: true,
    );

    _registerTool(
      'list_logs',
      description: 'List API logs (admin).',
      inputSchema: JsonSchema.object(
        properties: {
          'page': JsonSchema.number(),
          'perPage': JsonSchema.number(),
          'filter': JsonSchema.string(),
          'sort': JsonSchema.string(),
        },
      ),
      callback: _listLogs,
      write: false,
      admin: true,
    );

    _registerTool(
      'get_log',
      description: 'Get one API log by id (admin).',
      inputSchema: JsonSchema.object(
        properties: {'id': JsonSchema.string()},
        required: const ['id'],
      ),
      callback: _getLog,
      write: false,
      admin: true,
    );

    _registerTool(
      'get_logs_stats',
      description: 'Get log statistics (admin).',
      inputSchema: JsonSchema.object(
        properties: {'filter': JsonSchema.string()},
      ),
      callback: _getLogsStats,
      write: false,
      admin: true,
    );

    _registerTool(
      'list_cron_jobs',
      description: 'List cron jobs (admin).',
      inputSchema: JsonSchema.object(
        properties: {'fields': JsonSchema.string()},
      ),
      callback: _listCronJobs,
      write: false,
      admin: true,
    );

    _registerTool(
      'run_cron_job',
      description: 'Run cron job by id (admin).',
      inputSchema: JsonSchema.object(
        properties: {'jobId': JsonSchema.string()},
        required: const ['jobId'],
      ),
      callback: _runCronJob,
      write: true,
      admin: true,
    );

    _registerTool(
      'health_check',
      description: 'Check PocketBase health.',
      inputSchema: JsonSchema.object(properties: const {}),
      callback: _healthCheck,
      write: false,
      admin: false,
    );

    _registerTool(
      'get_settings',
      description: 'Get app settings (admin).',
      inputSchema: JsonSchema.object(properties: const {}),
      callback: _getSettings,
      write: false,
      admin: true,
    );

    _registerTool(
      'update_settings',
      description: 'Bulk update app settings (admin).',
      inputSchema: JsonSchema.object(
        properties: {'data': JsonSchema.object()},
        required: const ['data'],
      ),
      callback: _updateSettings,
      write: true,
      admin: true,
    );

    _registerTool(
      'test_s3_settings',
      description: 'Test S3 settings payload (admin).',
      inputSchema: JsonSchema.object(
        properties: {'data': JsonSchema.object()},
      ),
      callback: _testS3Settings,
      write: true,
      admin: true,
    );

    _registerTool(
      'send_test_email',
      description: 'Send a test template email via PocketBase settings API (admin).',
      inputSchema: JsonSchema.object(
        properties: {
          'toEmail': JsonSchema.string(),
          'template': JsonSchema.string(),
          'collection': JsonSchema.string(),
          'data': JsonSchema.object(),
        },
        required: const ['toEmail', 'template'],
      ),
      callback: _sendTestEmail,
      write: true,
      admin: true,
    );
  }

  Future<void> start() async {
    registerTools();
    _log.info('Tools registered: ${_toolPolicies.length}');

    final transport = StdioServerTransport();
    transport.onerror = (error) => _log.severe('MCP transport error', error);

    await _server.connect(transport);
    _log.info('PocketBase MCP server running on stdio (mode=${_accessMode.name})');
  }

  Future<void> startStreamableHttp({
    String host = '127.0.0.1',
    int port = 3000,
    String path = '/mcp',
    bool healthEnabled = false,
    bool enableDnsRebindingProtection = true,
    Set<String>? allowedHosts,
    Set<String>? allowedOrigins,
  }) async {
    if (_streamableHttpServer != null) {
      throw StateError('Streamable HTTP server already started');
    }

    final normalizedPath = _normalizeHttpPath(path);
    const healthPath = '/healthz';

    _streamableHttpServer = await HttpServer.bind(host, port);
    _streamableHttpServer!.listen(
      (request) => _handleStreamableHttpRequest(
        request,
        path: normalizedPath,
        healthEnabled: healthEnabled,
        healthPath: healthPath,
        enableDnsRebindingProtection: enableDnsRebindingProtection,
        allowedHosts: allowedHosts,
        allowedOrigins: allowedOrigins,
      ),
    );

    _log.info(
      'PocketBase MCP server running on streamablehttp '
      '(http://$host:$port$normalizedPath, mode=${_accessMode.name}, authEnabled=${_authConfig.enabled}, authMode=${_authConfig.mode.name}, '
      'healthz=${healthEnabled ? 'enabled' : 'disabled'}$healthPath, '
      'dnsRebindingProtection=$enableDnsRebindingProtection, allowedHosts=${allowedHosts?.length ?? 0}, allowedOrigins=${allowedOrigins?.length ?? 0})',
    );
  }

  Future<void> _handleStreamableHttpRequest(
    HttpRequest request, {
    required String path,
    required bool healthEnabled,
    required String healthPath,
    required bool enableDnsRebindingProtection,
    required Set<String>? allowedHosts,
    required Set<String>? allowedOrigins,
  }) async {
    _setCorsHeaders(request.response);

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    if (healthEnabled && request.uri.path == healthPath) {
      final remoteAddress = request.connectionInfo?.remoteAddress.address ?? 'unknown';
      final remotePort = request.connectionInfo?.remotePort;
      final remoteAddr = remotePort == null ? remoteAddress : '$remoteAddress:$remotePort';
      _log.info('Health check request: remoteAddr=$remoteAddr, method=${request.method}');
      await _writeHealthResponse(request.response);
      return;
    }

    if (request.uri.path != path) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not Found');
      await request.response.close();
      return;
    }

    if (request.method != 'OPTIONS' && _authConfig.enabled) {
      final allowed = await _authenticateHttpRequest(request);
      if (!allowed) {
        request.response
          ..statusCode = HttpStatus.forbidden
          ..write('Forbidden');
        await request.response.close();
        return;
      }
    }

    try {
      if (request.method == 'POST') {
        await _handleStreamablePostRequest(
          request,
          enableDnsRebindingProtection: enableDnsRebindingProtection,
          allowedHosts: allowedHosts,
          allowedOrigins: allowedOrigins,
        );
      } else if (request.method == 'GET') {
        await _handleStreamableGetRequest(request);
      } else if (request.method == 'DELETE') {
        await _handleStreamableDeleteRequest(request);
      } else {
        request.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..headers.set(HttpHeaders.allowHeader, 'GET, POST, DELETE, OPTIONS')
          ..write('Method Not Allowed');
        await request.response.close();
      }
    } catch (error, stackTrace) {
      _log.severe('Error handling streamablehttp request', error, stackTrace);
      if (!request.response.headers.contentType
          .toString()
          .startsWith('text/event-stream')) {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('Internal Server Error');
        await request.response.close();
      }
    }
  }

  Future<void> _handleStreamablePostRequest(
    HttpRequest request, {
    required bool enableDnsRebindingProtection,
    required Set<String>? allowedHosts,
    required Set<String>? allowedOrigins,
  }) async {
    final bodyBytes = await _collectBytes(request);
    final bodyString = utf8.decode(bodyBytes);

    dynamic body;
    try {
      body = jsonDecode(bodyString);
    } catch (_) {
      await _respondWithJsonRpcError(
        request.response,
        httpStatus: HttpStatus.badRequest,
        errorCode: ErrorCode.parseError,
        message: 'Parse error',
      );
      return;
    }

    if (body is! Map && body is! List) {
      await _respondWithJsonRpcError(
        request.response,
        httpStatus: HttpStatus.badRequest,
        errorCode: ErrorCode.invalidRequest,
        message: 'Invalid Request: POST body must contain a JSON-RPC message object',
      );
      return;
    }

    final sessionId = request.headers.value('mcp-session-id');
    StreamableHTTPServerTransport? transport;

    if (sessionId != null && _streamableTransports.containsKey(sessionId)) {
      transport = _streamableTransports[sessionId]!;
    } else if (sessionId == null && _isInitializeRequest(body)) {
      transport = _createStreamableTransport(
        enableDnsRebindingProtection: enableDnsRebindingProtection,
        allowedHosts: allowedHosts,
        allowedOrigins: allowedOrigins,
      );
      await transport.handleRequest(request, body);
      return;
    } else {
      await _respondWithJsonRpcError(
        request.response,
        httpStatus: HttpStatus.badRequest,
        errorCode: ErrorCode.connectionClosed,
        message: 'Bad Request: No valid session ID provided or not an initialize request',
      );
      return;
    }

    await transport.handleRequest(request, body);
  }

  Future<void> _handleStreamableGetRequest(HttpRequest request) async {
    final sessionId = request.headers.value('mcp-session-id');
    if (sessionId == null || !_streamableTransports.containsKey(sessionId)) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Invalid or missing session ID');
      await request.response.close();
      return;
    }

    await _streamableTransports[sessionId]!.handleRequest(request);
  }

  Future<void> _handleStreamableDeleteRequest(HttpRequest request) async {
    final sessionId = request.headers.value('mcp-session-id');
    if (sessionId == null || !_streamableTransports.containsKey(sessionId)) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Invalid or missing session ID');
      await request.response.close();
      return;
    }

    await _streamableTransports[sessionId]!.handleRequest(request);
  }

  StreamableHTTPServerTransport _createStreamableTransport({
    required bool enableDnsRebindingProtection,
    required Set<String>? allowedHosts,
    required Set<String>? allowedOrigins,
  }) {
    late StreamableHTTPServerTransport transport;

    transport = StreamableHTTPServerTransport(
      options: StreamableHTTPServerTransportOptions(
        sessionIdGenerator: () => generateUUID(),
        enableDnsRebindingProtection: enableDnsRebindingProtection,
        allowedHosts: allowedHosts,
        allowedOrigins: allowedOrigins,
        onsessioninitialized: (sid) {
          _streamableTransports[sid] = transport;

          final sessionServer = PocketBaseMcpServer(
            pocketbaseUrl: _pocketbaseUrl,
            adminEmail: _adminEmail,
            adminPassword: _adminPassword,
            accessMode: _accessMode,
            authConfig: _authConfig,
            allowedTools: _allowedTools,
            deniedTools: _deniedTools,
          );
          sessionServer.registerTools();

          final server = sessionServer._server;
          _streamableServers[sid] = server;
          server.connect(transport).catchError((error, stackTrace) {
            _log.severe('Error connecting session server', error, stackTrace);
            _streamableTransports.remove(sid);
            _streamableServers.remove(sid);
          });
        },
      ),
    );

    transport.onclose = () {
      final sid = transport.sessionId;
      if (sid != null) {
        _streamableTransports.remove(sid);
        _streamableServers.remove(sid);
      }
    };

    return transport;
  }

  Future<void> _respondWithJsonRpcError(
    HttpResponse response, {
    required int httpStatus,
    required ErrorCode errorCode,
    required String message,
  }) async {
    response
      ..statusCode = httpStatus
      ..write(
        jsonEncode(
          JsonRpcError(
            id: null,
            error: JsonRpcErrorData(
              code: errorCode.value,
              message: message,
            ),
          ).toJson(),
        ),
      );
    await response.close();
  }

  bool _isInitializeRequest(dynamic body) {
    if (body is Map<String, dynamic> && body['method'] == 'initialize') {
      return true;
    }
    if (body is List) {
      for (final item in body) {
        if (item is Map<String, dynamic> && item['method'] == 'initialize') {
          return true;
        }
      }
    }
    return false;
  }

  Future<Uint8List> _collectBytes(HttpRequest request) async {
    final completer = Completer<Uint8List>();
    final sink = BytesBuilder();
    request.listen(
      sink.add,
      onDone: () => completer.complete(sink.takeBytes()),
      onError: completer.completeError,
      cancelOnError: true,
    );
    return completer.future;
  }

  Future<void> _writeHealthResponse(HttpResponse response) async {
    response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.text
      ..write('ok');
    await response.close();
  }

  String _normalizeHttpPath(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty || trimmed == '/') {
      return '/mcp';
    }
    return trimmed.startsWith('/') ? trimmed : '/$trimmed';
  }

  void _setCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
    response.headers.set(
      'Access-Control-Allow-Headers',
      'Origin, X-Requested-With, Content-Type, Accept, mcp-session-id, Last-Event-ID, Authorization, MCP-Protocol-Version',
    );
    response.headers.set('Access-Control-Allow-Credentials', 'true');
    response.headers.set('Access-Control-Max-Age', '86400');
    response.headers.set('Access-Control-Expose-Headers', 'mcp-session-id');
  }

  Future<bool> _authenticateHttpRequest(HttpRequest request) async {
    if (!_authConfig.enabled) {
      return true;
    }

    switch (_authConfig.mode) {
      case McpAuthMode.token:
        return _authenticateBearerToken(request);
      case McpAuthMode.oauth:
        // TODO: Implement OAuth flow integration for Streamable HTTP transport.
        _log.warning('OAuth auth mode is enabled but not implemented yet.');
        return false;
    }
  }

  bool _authenticateBearerToken(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (!header.startsWith('Bearer ')) {
      _log.warning('Missing or invalid Authorization header for streamablehttp request');
      return false;
    }

    final token = header.substring('Bearer '.length).trim();
    if (token.isEmpty) {
      _log.warning('Bearer token is empty');
      return false;
    }

    if (_authConfig.bearerTokens.isEmpty) {
      _log.warning('Token auth is enabled but no auth bearer tokens are configured');
      return false;
    }

    final allowed = _authConfig.bearerTokens.contains(token);
    if (!allowed) {
      _log.warning('Bearer token rejected');
    }
    return allowed;
  }

  void _registerTool(
    String name, {
    required String description,
    required JsonObject inputSchema,
    required Future<CallToolResult> Function(Map<String, dynamic>) callback,
    required bool write,
    required bool admin,
  }) {
    _toolPolicies[name] = _ToolPolicy(write: write, admin: admin);

    _server.registerTool(
      name,
      description: description,
      inputSchema: inputSchema,
      callback: (args, extra) => _safeCall(
        name,
        args,
        callback,
      ),
    );
  }

  Future<CallToolResult> _safeCall(
    String toolName,
    Map<String, dynamic> args,
    Future<CallToolResult> Function(Map<String, dynamic>) fn,
  ) async {
    _log.info('Executing tool: $toolName');
    try {
      _authorizeTool(toolName);
      final result = await fn(args);
      _log.info('Tool completed: $toolName');
      return result;
    } catch (error, stackTrace) {
      _log.severe('Tool failed: $toolName', error, stackTrace);
      return CallToolResult(
        content: [TextContent(text: '$toolName failed: ${pocketbaseErrorMessage(error)}')],
        isError: true,
      );
    }
  }

  void _authorizeTool(String toolName) {
    if (_allowedTools.isNotEmpty && !_allowedTools.contains(toolName)) {
      _log.warning('Authorization denied by allow-list: $toolName');
      throw StateError('Tool is not allowed by policy: $toolName');
    }
    if (_deniedTools.contains(toolName)) {
      _log.warning('Authorization denied by deny-list: $toolName');
      throw StateError('Tool is denied by policy: $toolName');
    }

    final policy = _toolPolicies[toolName];
    if (policy == null) {
      _log.warning('Missing tool policy for tool: $toolName');
      throw StateError('Unknown tool policy: $toolName');
    }

    if (_accessMode == AccessMode.readonly && policy.write) {
      _log.warning('Readonly policy blocked write tool: $toolName');
      throw StateError('Readonly mode forbids write tool: $toolName');
    }

    if (policy.admin && ((_adminEmail ?? '').isEmpty || (_adminPassword ?? '').isEmpty)) {
      _log.warning('Admin credentials missing for admin tool: $toolName');
      throw StateError(
        'Tool $toolName requires POCKETBASE_ADMIN_EMAIL and POCKETBASE_ADMIN_PASSWORD.',
      );
    }
  }

  Future<void> _ensureAdminAuth() async {
    if ((_adminEmail ?? '').isEmpty || (_adminPassword ?? '').isEmpty) {
      _log.warning('Admin auth attempted without credentials');
      throw StateError(
        'POCKETBASE_ADMIN_EMAIL and POCKETBASE_ADMIN_PASSWORD are required for admin tools.',
      );
    }

    _log.info('Authenticating as superuser');
    await _pb.collection('_superusers').authWithPassword(_adminEmail!, _adminPassword!);
  }

  Future<CallToolResult> _rawApiCall(Map<String, dynamic> args) async {
    final path = _requiredString(args, 'path');
    final method = (_optionalString(args, 'method') ?? 'GET').toUpperCase();
    final requireAdmin = args['requireAdmin'] == true;

    if (_accessMode == AccessMode.readonly && method != 'GET') {
      _log.warning('Readonly blocked raw_api_call method: $method');
      throw StateError('Readonly mode allows only GET in raw_api_call');
    }

    if (requireAdmin) {
      await _ensureAdminAuth();
    }

    final result = await _pb.send<dynamic>(
      path,
      method: method,
      body: _optionalMap(args, 'body') ?? const <String, dynamic>{},
      query: _optionalMap(args, 'query') ?? const <String, dynamic>{},
      headers: _optionalStringMap(args, 'headers') ?? const <String, String>{},
    );

    return _resultAny(result);
  }

  Future<CallToolResult> _getRecord(Map<String, dynamic> args) async {
    final result = await _pb.collection(_requiredString(args, 'collection')).getOne(
          _requiredString(args, 'id'),
          expand: _optionalString(args, 'expand'),
          fields: _optionalString(args, 'fields'),
        );
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _listRecords(Map<String, dynamic> args) async {
    final result = await _pb.collection(_requiredString(args, 'collection')).getList(
          page: _optionalInt(args, 'page') ?? 1,
          perPage: _optionalInt(args, 'perPage') ?? 50,
          filter: _optionalString(args, 'filter'),
          sort: _optionalString(args, 'sort'),
          expand: _optionalString(args, 'expand'),
          fields: _optionalString(args, 'fields'),
        );
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _listAllRecords(Map<String, dynamic> args) async {
    final result = await _pb.collection(_requiredString(args, 'collection')).getFullList(
          batch: _optionalInt(args, 'batch') ?? 1000,
          filter: _optionalString(args, 'filter'),
          sort: _optionalString(args, 'sort'),
          expand: _optionalString(args, 'expand'),
          fields: _optionalString(args, 'fields'),
        );
    return _resultAny(result.map((e) => e.toJson()).toList(growable: false));
  }

  Future<CallToolResult> _createRecord(Map<String, dynamic> args) async {
    final result = await _pb
        .collection(_requiredString(args, 'collection'))
        .create(body: _requiredMap(args, 'data'));
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _updateRecord(Map<String, dynamic> args) async {
    final result = await _pb.collection(_requiredString(args, 'collection')).update(
          _requiredString(args, 'id'),
          body: _requiredMap(args, 'data'),
        );
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _deleteRecord(Map<String, dynamic> args) async {
    await _pb.collection(_requiredString(args, 'collection')).delete(_requiredString(args, 'id'));
    return _textResult('Successfully deleted record ${_requiredString(args, 'id')}');
  }

  Future<CallToolResult> _importData(Map<String, dynamic> args) async {
    final collection = _requiredString(args, 'collection');
    final data = _listOfMap(args['data']);
    final mode = (_optionalString(args, 'mode') ?? 'create').toLowerCase();

    if (mode != 'create' && mode != 'update' && mode != 'upsert') {
      throw ArgumentError('mode must be one of create, update, upsert');
    }

    final service = _pb.collection(collection);
    final results = <Map<String, dynamic>>[];

    for (final item in data) {
      switch (mode) {
        case 'create':
          results.add((await service.create(body: item)).toJson());
          break;
        case 'update':
          final id = item['id'];
          if (id is! String || id.isEmpty) {
            throw ArgumentError('update mode requires each record item to include id');
          }
          results.add((await service.update(id, body: {...item}..remove('id'))).toJson());
          break;
        case 'upsert':
          final id = item['id'];
          if (id is String && id.isNotEmpty) {
            results.add((await service.update(id, body: {...item}..remove('id'))).toJson());
          } else {
            results.add((await service.create(body: item)).toJson());
          }
          break;
      }
    }

    return _resultAny({'mode': mode, 'count': results.length, 'items': results});
  }

  Future<CallToolResult> _listAuthMethods(Map<String, dynamic> args) async {
    final result = await _pb.collection(_optionalString(args, 'collection') ?? 'users').listAuthMethods(
          fields: _optionalString(args, 'fields'),
        );
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _authenticateUser(Map<String, dynamic> args) async {
    final isAdmin = args['isAdmin'] == true;
    final collection = isAdmin ? '_superusers' : (_optionalString(args, 'collection') ?? 'users');

    final email = isAdmin
        ? (_optionalString(args, 'email') ?? _adminEmail)
        : _optionalString(args, 'email');
    final password = isAdmin
        ? (_optionalString(args, 'password') ?? _adminPassword)
        : _optionalString(args, 'password');

    if (email == null || email.isEmpty || password == null || password.isEmpty) {
      throw ArgumentError('email and password are required');
    }

    final result = await _pb.collection(collection).authWithPassword(
          email,
          password,
          expand: _optionalString(args, 'expand'),
          fields: _optionalString(args, 'fields'),
        );
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _authRefresh(Map<String, dynamic> args) async {
    final result = await _pb.collection(_optionalString(args, 'collection') ?? 'users').authRefresh(
          expand: _optionalString(args, 'expand'),
          fields: _optionalString(args, 'fields'),
        );
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _authenticateWithOAuth2(Map<String, dynamic> args) async {
    final result = await _pb.collection(_optionalString(args, 'collection') ?? 'users').authWithOAuth2Code(
          _requiredString(args, 'provider'),
          _requiredString(args, 'code'),
          _requiredString(args, 'codeVerifier'),
          _requiredString(args, 'redirectUrl'),
          createData: _optionalMap(args, 'createData') ?? const <String, dynamic>{},
          expand: _optionalString(args, 'expand'),
          fields: _optionalString(args, 'fields'),
        );
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _requestOtp(Map<String, dynamic> args) async {
    final result = await _pb
        .collection(_optionalString(args, 'collection') ?? 'users')
        .requestOTP(_requiredString(args, 'email'));
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _authenticateWithOtp(Map<String, dynamic> args) async {
    final result = await _pb.collection(_optionalString(args, 'collection') ?? 'users').authWithOTP(
          _requiredString(args, 'otpId'),
          _requiredString(args, 'password'),
          expand: _optionalString(args, 'expand'),
          fields: _optionalString(args, 'fields'),
        );
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _requestVerification(Map<String, dynamic> args) async {
    await _pb
        .collection(_optionalString(args, 'collection') ?? 'users')
        .requestVerification(_requiredString(args, 'email'));
    return _textResult('Verification email requested successfully.');
  }

  Future<CallToolResult> _confirmVerification(Map<String, dynamic> args) async {
    await _pb.collection(_optionalString(args, 'collection') ?? 'users').confirmVerification(
          _requiredString(args, 'token'),
        );
    return _textResult('Verification confirmed successfully.');
  }

  Future<CallToolResult> _requestPasswordReset(Map<String, dynamic> args) async {
    await _pb
        .collection(_optionalString(args, 'collection') ?? 'users')
        .requestPasswordReset(_requiredString(args, 'email'));
    return _textResult('Password reset requested successfully.');
  }

  Future<CallToolResult> _confirmPasswordReset(Map<String, dynamic> args) async {
    await _pb.collection(_optionalString(args, 'collection') ?? 'users').confirmPasswordReset(
          _requiredString(args, 'token'),
          _requiredString(args, 'password'),
          _requiredString(args, 'passwordConfirm'),
        );
    return _textResult('Password reset confirmed successfully.');
  }

  Future<CallToolResult> _requestEmailChange(Map<String, dynamic> args) async {
    await _pb.collection(_optionalString(args, 'collection') ?? 'users').requestEmailChange(
          _requiredString(args, 'newEmail'),
        );
    return _textResult('Email change requested successfully.');
  }

  Future<CallToolResult> _confirmEmailChange(Map<String, dynamic> args) async {
    await _pb.collection(_optionalString(args, 'collection') ?? 'users').confirmEmailChange(
          _requiredString(args, 'token'),
          _requiredString(args, 'password'),
        );
    return _textResult('Email change confirmed successfully.');
  }

  Future<CallToolResult> _impersonateUser(Map<String, dynamic> args) async {
    await _ensureAdminAuth();

    final client = await _pb.collection(_optionalString(args, 'collection') ?? 'users').impersonate(
          _requiredString(args, 'id'),
          _optionalNum(args, 'duration') ?? 3600,
        );

    return _resultAny({
      'token': client.authStore.token,
      'record': client.authStore.record?.toJson(),
      'isValid': client.authStore.isValid,
    });
  }

  Future<CallToolResult> _createUser(Map<String, dynamic> args) async {
    final result = await _pb.collection(_optionalString(args, 'collection') ?? 'users').create(
      body: {
        'email': _requiredString(args, 'email'),
        'password': _requiredString(args, 'password'),
        'passwordConfirm': _requiredString(args, 'passwordConfirm'),
        if (_optionalString(args, 'name') case final name?) 'name': name,
      },
    );
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _createCollection(Map<String, dynamic> args) async {
    await _ensureAdminAuth();

    final fields = _listOfMap(args['fields']);
    final defaultFields = <Map<String, dynamic>>[
      {
        'hidden': false,
        'id': 'autodate_created',
        'name': 'created',
        'onCreate': true,
        'onUpdate': false,
        'presentable': false,
        'system': false,
        'type': 'autodate',
      },
      {
        'hidden': false,
        'id': 'autodate_updated',
        'name': 'updated',
        'onCreate': true,
        'onUpdate': true,
        'presentable': false,
        'system': false,
        'type': 'autodate',
      },
    ];

    final body = Map<String, dynamic>.from(args)
      ..['fields'] = <Map<String, dynamic>>[...fields, ...defaultFields];

    final result = await _pb.collections.create(body: body);
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _updateCollection(Map<String, dynamic> args) async {
    await _ensureAdminAuth();

    final idOrName = _requiredString(args, 'collectionIdOrName');
    final body = Map<String, dynamic>.from(args)..remove('collectionIdOrName');

    final result = await _pb.collections.update(idOrName, body: body);
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _deleteCollection(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    await _pb.collections.delete(_requiredString(args, 'collectionIdOrName'));
    return _textResult('Collection deleted successfully.');
  }

  Future<CallToolResult> _truncateCollection(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    await _pb.collections.truncate(_requiredString(args, 'collectionIdOrName'));
    return _textResult('Collection truncated successfully.');
  }

  Future<CallToolResult> _listCollections(Map<String, dynamic> args) async {
    await _ensureAdminAuth();

    final filter = _optionalString(args, 'filter');
    if (filter != null && filter.isNotEmpty) {
      final item = await _pb.collections.getFirstListItem(filter);
      return _resultAny(item.toJson());
    }

    final result = await _pb.collections.getList(
      page: _optionalInt(args, 'page') ?? 1,
      perPage: _optionalInt(args, 'perPage') ?? 100,
      sort: _optionalString(args, 'sort'),
    );

    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _getCollection(Map<String, dynamic> args) async {
    await _ensureAdminAuth();

    final fields = _optionalString(args, 'fields');
    final result = await _pb.collections.getOne(
      _requiredString(args, 'collectionIdOrName'),
      query: {
        if (fields != null && fields.isNotEmpty) 'fields': fields,
      },
    );

    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _getCollectionScaffolds(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    final result = await _pb.collections.getScaffolds();
    return _resultAny(result.map((k, v) => MapEntry(k, v.toJson())));
  }

  Future<CallToolResult> _backupDatabase(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    await _pb.backups.create(_optionalString(args, 'name') ?? '');
    return _textResult('Backup created successfully.');
  }

  Future<CallToolResult> _listBackups(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    final result = await _pb.backups.getFullList();
    return _resultAny(result.map((e) => e.toJson()).toList(growable: false));
  }

  Future<CallToolResult> _deleteBackup(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    await _pb.backups.delete(_requiredString(args, 'key'));
    return _textResult('Backup deleted successfully.');
  }

  Future<CallToolResult> _restoreBackup(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    await _pb.backups.restore(_requiredString(args, 'key'));
    return _textResult('Backup restore started successfully.');
  }

  Future<CallToolResult> _listLogs(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    final result = await _pb.logs.getList(
      page: _optionalInt(args, 'page') ?? 1,
      perPage: _optionalInt(args, 'perPage') ?? 30,
      filter: _optionalString(args, 'filter'),
      sort: _optionalString(args, 'sort'),
    );
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _getLog(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    final result = await _pb.logs.getOne(_requiredString(args, 'id'));
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _getLogsStats(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    final result = await _pb.logs.getStats(query: {
      if (_optionalString(args, 'filter') case final filter?) 'filter': filter,
    });
    return _resultAny(result.map((e) => e.toJson()).toList(growable: false));
  }

  Future<CallToolResult> _listCronJobs(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    final result = await _pb.crons.getFullList(query: {
      if (_optionalString(args, 'fields') case final fields?) 'fields': fields,
    });
    return _resultAny(result.map((e) => e.toJson()).toList(growable: false));
  }

  Future<CallToolResult> _runCronJob(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    await _pb.crons.run(_requiredString(args, 'jobId'));
    return _textResult('Cron job triggered successfully.');
  }

  Future<CallToolResult> _healthCheck(Map<String, dynamic> args) async {
    final result = await _pb.health.check();
    return _resultAny(result.toJson());
  }

  Future<CallToolResult> _getSettings(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    final result = await _pb.settings.getAll();
    return _resultAny(result);
  }

  Future<CallToolResult> _updateSettings(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    final result = await _pb.settings.update(body: _requiredMap(args, 'data'));
    return _resultAny(result);
  }

  Future<CallToolResult> _testS3Settings(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    await _pb.settings.testS3(body: _optionalMap(args, 'data') ?? const <String, dynamic>{});
    return _textResult('S3 settings test completed successfully.');
  }

  Future<CallToolResult> _sendTestEmail(Map<String, dynamic> args) async {
    await _ensureAdminAuth();
    await _pb.settings.testEmail(
      _requiredString(args, 'toEmail'),
      _requiredString(args, 'template'),
      collection: _optionalString(args, 'collection'),
      body: _optionalMap(args, 'data') ?? const <String, dynamic>{},
    );
    return _textResult('Test email request sent successfully.');
  }

  CallToolResult _resultAny(dynamic value) {
    return CallToolResult(
      content: [
        TextContent(
          text: const JsonEncoder.withIndent('  ').convert(_jsonSafe(value)),
        ),
      ],
    );
  }

  CallToolResult _textResult(String value) {
    return CallToolResult(content: [TextContent(text: value)]);
  }

  dynamic _jsonSafe(dynamic value) {
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _jsonSafe(v)));
    }
    if (value is Iterable) {
      return value.map(_jsonSafe).toList(growable: false);
    }
    if (value is Jsonable) {
      return _jsonSafe(value.toJson());
    }
    return value.toString();
  }

  String _requiredString(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw ArgumentError('Missing required string argument: $key');
  }

  String? _optionalString(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) {
      return null;
    }
    if (value is String) {
      return value;
    }
    return value.toString();
  }

  int? _optionalInt(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value.toString());
  }

  num? _optionalNum(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) {
      return null;
    }
    if (value is num) {
      return value;
    }
    return num.tryParse(value.toString());
  }

  Map<String, dynamic> _requiredMap(Map<String, dynamic> args, String key) {
    final value = _optionalMap(args, key);
    if (value != null) {
      return value;
    }
    throw ArgumentError('Missing required object argument: $key');
  }

  Map<String, dynamic>? _optionalMap(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) {
      return null;
    }
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v));
    }
    return null;
  }

  Map<String, String>? _optionalStringMap(Map<String, dynamic> args, String key) {
    final value = _optionalMap(args, key);
    if (value == null) {
      return null;
    }
    return value.map((k, v) => MapEntry(k, v.toString()));
  }

  List<Map<String, dynamic>> _listOfMap(dynamic value) {
    if (value is! List) {
      throw ArgumentError('Expected an array of objects');
    }
    return value.map<Map<String, dynamic>>((item) {
      if (item is Map<String, dynamic>) {
        return item;
      }
      if (item is Map) {
        return item.map((k, v) => MapEntry(k.toString(), v));
      }
      throw ArgumentError('Each array item must be an object');
    }).toList(growable: false);
  }
}

class _ToolPolicy {
  const _ToolPolicy({required this.write, required this.admin});

  final bool write;
  final bool admin;
}

List<String> flattenErrors(Object? errors) {
  if (errors == null) {
    return const [];
  }

  if (errors is String) {
    return [errors];
  }

  if (errors is Iterable) {
    return errors.expand(flattenErrors).toList(growable: false);
  }

  if (errors is ClientException) {
    return [
      errors.toString(),
      ...flattenErrors(errors.response),
      ...flattenErrors(errors.originalError),
    ];
  }

  if (errors is Map) {
    final result = <String>[];
    final message = errors['message'];
    if (message is String && message.isNotEmpty) {
      result.add(message);
    }
    for (final entry in errors.entries) {
      result.addAll(flattenErrors(entry.value));
    }
    return result;
  }

  return [errors.toString()];
}

String pocketbaseErrorMessage(Object? errors) {
  final messages = flattenErrors(errors)
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet()
      .toList(growable: false);

  return messages.isEmpty ? 'Unknown PocketBase error' : messages.join('\n');
}
