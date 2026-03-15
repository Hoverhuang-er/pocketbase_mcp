import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:pocketbase_mcp_server/src/pocketbase_mcp_server.dart';
import 'package:toml/toml.dart';

StreamSubscription<LogRecord>? _logSubscription;
_FileLogWriter? _fileLogWriter;

Future<void> main() async {
  _configureLogging(const _RuntimeLogConfig(output: 'stderr', level: 'debug', days: 1));
  final bootstrapLog = Logger('PocketBaseMcpServerMain');

  final config = await _resolveConfig(bootstrapLog);
  _configureLogging(
    _RuntimeLogConfig(output: config.logOutput, level: config.logLevel, days: config.logDays),
  );

  final log = Logger('PocketBaseMcpServerMain');

  final accessModeRaw = config.pbMcpMode.trim().toLowerCase();
  final accessMode = switch (accessModeRaw) {
    'readonly' => AccessMode.readonly,
    'readwrite' => AccessMode.readwrite,
    _ => AccessMode.readonly,
  };
  if (accessModeRaw != 'readonly' && accessModeRaw != 'readwrite') {
    log.warning('Unknown PB_MCP_MODE "$accessModeRaw", fallback to readonly');
  }

  final allowedTools = (Platform.environment['PB_MCP_ALLOWED_TOOLS'] ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet();
  final deniedTools = (Platform.environment['PB_MCP_DENIED_TOOLS'] ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet();

  log.info('Starting PocketBase MCP server with mode=${accessMode.name}, '
      'connection=${config.connection}, '
      'allowedTools=${allowedTools.length}, deniedTools=${deniedTools.length}, '
      'logOutput=${config.logOutput}, logLevel=${config.logLevel}, logDays=${config.logDays}, '
      'healthEnabled=${config.healthEnabled}');

  final canConnect = await _checkPocketBaseConnection(config.pocketbaseUrl, log);
  if (!canConnect) {
    log.severe("Can't connect pocketbase");
    exitCode = 127;
    return;
  }

  final server = PocketBaseMcpServer(
    pocketbaseUrl: config.pocketbaseUrl,
    adminEmail: config.adminEmail,
    adminPassword: config.adminPassword,
    accessMode: accessMode,
    authConfig: McpAuthConfig(
      enabled: config.authEnabled,
      mode: config.authMode == 'oauth' ? McpAuthMode.oauth : McpAuthMode.token,
      bearerTokens: config.authBearerTokens,
    ),
    allowedTools: allowedTools,
    deniedTools: deniedTools,
  );

  ProcessSignal.sigint.watch().listen((_) {
    log.warning('Received SIGINT, shutting down');
    exit(0);
  });

  if (config.connection == 'streamablehttp') {
    final allowAllHosts =
        config.streamableAllowedHosts.isEmpty || config.streamableAllowedHosts.contains('*');
    final allowAllOrigins =
        config.streamableAllowedOrigins.isEmpty || config.streamableAllowedOrigins.contains('*');
    final effectiveDnsRebindingProtection =
        config.streamableEnableDnsRebindingProtection && !allowAllHosts && !allowAllOrigins;

    if (config.streamableEnableDnsRebindingProtection &&
        (allowAllHosts || allowAllOrigins)) {
      log.warning(
        'streamablehttp allowed_hosts/allowed_origins is wildcard (*), '
        'auto-disable DNS rebinding protection for full allow behavior.',
      );
    }

    await server.startStreamableHttp(
      host: config.streamableHost,
      port: config.streamablePort,
      path: config.streamablePath,
      healthEnabled: config.healthEnabled,
      enableDnsRebindingProtection: effectiveDnsRebindingProtection,
      allowedHosts: allowAllHosts ? null : config.streamableAllowedHosts,
      allowedOrigins: allowAllOrigins ? null : config.streamableAllowedOrigins,
    );
    return;
  }

  await server.start();
}

Future<_StartupConfig> _resolveConfig(Logger log) async {
  final tomlConfig = await _loadTomlConfig(log);
  if (tomlConfig != null) {
    log.info('Using configuration from mcp.toml');
    return tomlConfig;
  }

  final envUrl = (Platform.environment['POCKETBASE_URL'] ?? '').trim();
  final envEmail = (Platform.environment['POCKETBASE_ADMIN_EMAIL'] ?? '').trim();
  final envPassword = (Platform.environment['POCKETBASE_ADMIN_PASSWORD'] ?? '').trim();
  final envMode = (Platform.environment['PB_MCP_MODE'] ?? '').trim();
  final envConnection = (Platform.environment['MCP_CONNECTION'] ?? '').trim().toLowerCase();
  final envStreamableHost = (Platform.environment['MCP_STREAMABLEHTTP_HOST'] ?? '').trim();
  final envStreamablePortRaw = (Platform.environment['MCP_STREAMABLEHTTP_PORT'] ?? '').trim();
  final envStreamablePath = (Platform.environment['MCP_STREAMABLEHTTP_PATH'] ?? '').trim();
    final envStreamableEnableDnsRebindingProtection =
      (Platform.environment['MCP_STREAMABLEHTTP_ENABLE_DNS_REBINDING_PROTECTION'] ?? '')
        .trim()
        .toLowerCase();
    final envStreamableAllowedHostsRaw =
      (Platform.environment['MCP_STREAMABLEHTTP_ALLOWED_HOSTS'] ?? '').trim();
    final envStreamableAllowedOriginsRaw =
      (Platform.environment['MCP_STREAMABLEHTTP_ALLOWED_ORIGINS'] ?? '').trim();
  final envAuthEnabled = (Platform.environment['MCP_AUTH_ENABLED'] ?? '').trim().toLowerCase();
  final envAuthMode = (Platform.environment['MCP_AUTH_MODE'] ?? '').trim().toLowerCase();
  final envAuthBearerTokensRaw =
      (Platform.environment['MCP_AUTH_BEARER_TOKENS'] ?? '').trim();
  final envLogOutput = (Platform.environment['MCP_LOG_OUTPUT'] ?? '').trim().toLowerCase();
  final envLogLevel = (Platform.environment['MCP_LOG_LEVEL'] ?? '').trim().toLowerCase();
  final envLogDaysRaw = (Platform.environment['MCP_LOG_DAYS'] ?? '').trim();
  final envHealthEnabledRaw = (Platform.environment['MCP_HEALTH_ENABLED'] ?? '').trim().toLowerCase();

  final logOutput = _normalizeLogOutput(envLogOutput);
  final logLevel = _normalizeLogLevel(envLogLevel);
  final logDays = _normalizeLogDays(int.tryParse(envLogDaysRaw));
  final healthEnabled = envHealthEnabledRaw == 'true';

  if (envUrl.isNotEmpty && envEmail.isNotEmpty && envPassword.isNotEmpty) {
    log.info('Using configuration from environment variables');
    return _StartupConfig(
      pocketbaseUrl: envUrl,
      adminEmail: envEmail,
      adminPassword: envPassword,
      pbMcpMode: envMode.isEmpty ? 'readonly' : envMode,
      connection: envConnection == 'streamablehttp' ? 'streamablehttp' : 'stdio',
      streamableHost: envStreamableHost.isEmpty ? '127.0.0.1' : envStreamableHost,
      streamablePort: int.tryParse(envStreamablePortRaw) ?? 3000,
      streamablePath: envStreamablePath.isEmpty ? '/mcp' : envStreamablePath,
        streamableEnableDnsRebindingProtection:
          envStreamableEnableDnsRebindingProtection == 'false'
            ? false
            : true,
        streamableAllowedHosts: envStreamableAllowedHostsRaw
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet(),
        streamableAllowedOrigins: envStreamableAllowedOriginsRaw
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet(),
      authEnabled: envAuthEnabled == 'true',
      authMode: envAuthMode == 'oauth' ? 'oauth' : 'token',
      authBearerTokens: envAuthBearerTokensRaw
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet(),
      logOutput: logOutput,
      logLevel: logLevel,
      logDays: logDays,
      healthEnabled: healthEnabled,
    );
  }

  log.warning('mcp.toml and env config not complete, using default configuration');
  return const _StartupConfig(
    pocketbaseUrl: 'http://127.0.0.1:8090',
    adminEmail: 'admin@example.com',
    adminPassword: 'admin_password',
    pbMcpMode: 'readonly',
    connection: 'stdio',
    streamableHost: '127.0.0.1',
    streamablePort: 3000,
    streamablePath: '/mcp',
    streamableEnableDnsRebindingProtection: true,
    streamableAllowedHosts: <String>{},
    streamableAllowedOrigins: <String>{},
    authEnabled: false,
    authMode: 'token',
    authBearerTokens: <String>{},
    logOutput: 'stderr',
    logLevel: 'debug',
    logDays: 1,
    healthEnabled: false,
  );
}

Future<_StartupConfig?> _loadTomlConfig(Logger log) async {
  final file = File('mcp.toml');
  if (!await file.exists()) {
    return null;
  }

  try {
    final content = await file.readAsString();
    final map = TomlDocument.parse(content).toMap();

    String? readByPath(List<String> keys) {
      dynamic current = map;
      for (final key in keys) {
        if (current is Map && current.containsKey(key)) {
          current = current[key];
        } else {
          return null;
        }
      }
      if (current is String && current.trim().isNotEmpty) {
        return current.trim();
      }
      return null;
    }

    bool? readBoolByPath(List<String> keys) {
      dynamic current = map;
      for (final key in keys) {
        if (current is Map && current.containsKey(key)) {
          current = current[key];
        } else {
          return null;
        }
      }
      if (current is bool) {
        return current;
      }
      if (current is String) {
        final normalized = current.trim().toLowerCase();
        if (normalized == 'true') {
          return true;
        }
        if (normalized == 'false') {
          return false;
        }
      }
      return null;
    }

    int? readIntByPath(List<String> keys) {
      dynamic current = map;
      for (final key in keys) {
        if (current is Map && current.containsKey(key)) {
          current = current[key];
        } else {
          return null;
        }
      }
      if (current is int) {
        return current;
      }
      if (current is num) {
        return current.toInt();
      }
      if (current is String && current.trim().isNotEmpty) {
        return int.tryParse(current.trim());
      }
      return null;
    }

    Set<String>? readStringSetByPath(List<String> keys) {
      dynamic current = map;
      for (final key in keys) {
        if (current is Map && current.containsKey(key)) {
          current = current[key];
        } else {
          return null;
        }
      }

      if (current is List) {
        return current
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toSet();
      }

      if (current is String) {
        return current
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet();
      }

      return null;
    }

    final url = readByPath(['pocketbase', 'url']) ?? readByPath(['POCKETBASE_URL']);
    final email = readByPath(['pocketbase', 'admin_email']) ??
        readByPath(['POCKETBASE_ADMIN_EMAIL']);
    final password = readByPath(['pocketbase', 'admin_password']) ??
        readByPath(['POCKETBASE_ADMIN_PASSWORD']);
    final pbMcpMode = readByPath(['pocketbase', 'pb_mcp_mode']) ??
      readByPath(['pocketbase', 'PB_MCP_MODE']) ??
        readByPath(['PB_MCP_MODE']) ??
        'readonly';
    final connection = (readByPath(['connection']) ??
        readByPath(['pocketbase', 'connection']) ??
        readByPath(['mcp', 'connection']) ??
        'stdio')
      .toLowerCase();
    final streamableHost =
      readByPath(['streamablehttp', 'host']) ?? readByPath(['mcp', 'streamablehttp_host']) ?? '127.0.0.1';
    final streamablePort = readIntByPath(['streamablehttp', 'port']) ??
      readIntByPath(['mcp', 'streamablehttp_port']) ??
      3000;
    final streamablePath =
      readByPath(['streamablehttp', 'path']) ?? readByPath(['mcp', 'streamablehttp_path']) ?? '/mcp';
    final streamableEnableDnsRebindingProtection =
      readBoolByPath(['streamablehttp', 'enable_dns_rebinding_protection']) ??
      readBoolByPath(['mcp', 'streamablehttp_enable_dns_rebinding_protection']) ??
      true;
    final streamableAllowedHosts =
      readStringSetByPath(['streamablehttp', 'allowed_hosts']) ??
      readStringSetByPath(['mcp', 'streamablehttp_allowed_hosts']) ??
      <String>{};
    final streamableAllowedOrigins =
      readStringSetByPath(['streamablehttp', 'allowed_origins']) ??
      readStringSetByPath(['mcp', 'streamablehttp_allowed_origins']) ??
      <String>{};
    final authEnabled = readBoolByPath(['auth', 'enabled']) ??
      readBoolByPath(['mcp', 'auth_enabled']) ??
      false;
    final authMode = (readByPath(['auth', 'mode']) ?? readByPath(['mcp', 'auth_mode']) ?? 'token')
      .toLowerCase();
    final authBearerTokens = readStringSetByPath(['auth', 'bearer_tokens']) ??
      readStringSetByPath(['mcp', 'auth_bearer_tokens']) ??
      <String>{};
    final logOutput = _normalizeLogOutput(readByPath(['log', 'output']) ?? readByPath(['mcp', 'log_output']));
    final logLevel = _normalizeLogLevel(readByPath(['log', 'level']) ?? readByPath(['mcp', 'log_level']));
    final logDays = _normalizeLogDays(
      readIntByPath(['log', 'days']) ?? readIntByPath(['mcp', 'log_days']),
    );
    final healthEnabled = readBoolByPath(['health', 'enabled']) ??
      readBoolByPath(['mcp', 'health_enabled']) ??
      false;

    if (url != null && email != null && password != null) {
      return _StartupConfig(
        pocketbaseUrl: url,
        adminEmail: email,
        adminPassword: password,
        pbMcpMode: pbMcpMode,
      connection: connection == 'streamablehttp' ? 'streamablehttp' : 'stdio',
      streamableHost: streamableHost,
      streamablePort: streamablePort,
      streamablePath: streamablePath,
      streamableEnableDnsRebindingProtection: streamableEnableDnsRebindingProtection,
      streamableAllowedHosts: streamableAllowedHosts,
      streamableAllowedOrigins: streamableAllowedOrigins,
      authEnabled: authEnabled,
      authMode: authMode == 'oauth' ? 'oauth' : 'token',
      authBearerTokens: authBearerTokens,
      logOutput: logOutput,
      logLevel: logLevel,
      logDays: logDays,
      healthEnabled: healthEnabled,
      );
    }

    log.warning('mcp.toml exists but required keys are incomplete');
    return null;
  } catch (error, stackTrace) {
    log.warning('Failed to parse mcp.toml, fallback to next config source', error, stackTrace);
    return null;
  }
}

Future<bool> _checkPocketBaseConnection(String baseUrl, Logger log) async {
  final pb = PocketBase(baseUrl);
  try {
    await pb.health.check();
    log.info('PocketBase connectivity check passed: $baseUrl');
    return true;
  } catch (error, stackTrace) {
    log.severe('PocketBase connectivity check failed: $baseUrl', error, stackTrace);
    return false;
  }
}

class _StartupConfig {
  const _StartupConfig({
    required this.pocketbaseUrl,
    required this.adminEmail,
    required this.adminPassword,
    required this.pbMcpMode,
    required this.connection,
    required this.streamableHost,
    required this.streamablePort,
    required this.streamablePath,
    required this.streamableEnableDnsRebindingProtection,
    required this.streamableAllowedHosts,
    required this.streamableAllowedOrigins,
    required this.authEnabled,
    required this.authMode,
    required this.authBearerTokens,
    required this.logOutput,
    required this.logLevel,
    required this.logDays,
    required this.healthEnabled,
  });

  final String pocketbaseUrl;
  final String adminEmail;
  final String adminPassword;
  final String pbMcpMode;
  final String connection;
  final String streamableHost;
  final int streamablePort;
  final String streamablePath;
  final bool streamableEnableDnsRebindingProtection;
  final Set<String> streamableAllowedHosts;
  final Set<String> streamableAllowedOrigins;
  final bool authEnabled;
  final String authMode;
  final Set<String> authBearerTokens;
  final String logOutput;
  final String logLevel;
  final int logDays;
  final bool healthEnabled;
}

String _normalizeLogOutput(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'stdout':
      return 'stdout';
    case 'file':
      return 'file';
    case 'stderr':
    default:
      return 'stderr';
  }
}

String _normalizeLogLevel(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'info':
      return 'info';
    case 'error':
      return 'error';
    case 'debug':
    default:
      return 'debug';
  }
}

int _normalizeLogDays(int? raw) {
  if (raw == null || raw < 1) {
    return 1;
  }
  return raw;
}

Level _toRootLevel(String logLevel) {
  switch (logLevel) {
    case 'error':
      return Level.SEVERE;
    case 'info':
      return Level.INFO;
    case 'debug':
    default:
      return Level.ALL;
  }
}

class _RuntimeLogConfig {
  const _RuntimeLogConfig({
    required this.output,
    required this.level,
    required this.days,
  });

  final String output;
  final String level;
  final int days;
}

void _configureLogging(_RuntimeLogConfig config) {
  _logSubscription?.cancel();
  _logSubscription = null;

  _fileLogWriter?.close();
  _fileLogWriter = null;

  final normalizedOutput = _normalizeLogOutput(config.output);
  final normalizedLevel = _normalizeLogLevel(config.level);
  final normalizedDays = _normalizeLogDays(config.days);

  Logger.root.level = _toRootLevel(normalizedLevel);
  if (normalizedOutput == 'file') {
    _fileLogWriter = _FileLogWriter(retentionDays: normalizedDays);
    _fileLogWriter!.initialize();
  }

  _logSubscription = Logger.root.onRecord.listen((record) {
    final ts = record.time.toIso8601String();
    final buffer = StringBuffer()
      ..write('[$ts] ')
      ..write(record.level.name)
      ..write(' ')
      ..write(record.loggerName)
      ..write(': ')
      ..write(record.message);

    if (record.error != null) {
      buffer
        ..write('\nerror: ')
        ..write(record.error);
    }
    if (record.stackTrace != null) {
      buffer
        ..write('\n')
        ..write(record.stackTrace);
    }

    final line = buffer.toString();
    switch (normalizedOutput) {
      case 'stdout':
        stdout.writeln(line);
        break;
      case 'file':
        _fileLogWriter?.write(record.time, line);
        break;
      case 'stderr':
      default:
        stderr.writeln(line);
        break;
    }
  });
}

class _FileLogWriter {
  _FileLogWriter({required this.retentionDays});

  final int retentionDays;
  final File _activeFile = File('mcp.log');
  IOSink? _sink;
  DateTime? _activeLocalDay;

  void initialize() {
    final now = DateTime.now();
    _prepareActiveFile(now);
    _openSink();
    _cleanupArchivedFiles(now);
  }

  void write(DateTime timestamp, String line) {
    final localTime = timestamp.toLocal();
    _rotateIfNeeded(localTime);
    _sink?.writeln(line);
  }

  void close() {
    _sink?.close();
    _sink = null;
  }

  void _prepareActiveFile(DateTime now) {
    if (!_activeFile.existsSync()) {
      _activeLocalDay = DateTime(now.year, now.month, now.day);
      return;
    }

    final stat = _activeFile.statSync();
    final modifiedDay = DateTime(stat.modified.year, stat.modified.month, stat.modified.day);
    final today = DateTime(now.year, now.month, now.day);
    if (modifiedDay != today) {
      _archiveActiveFile(modifiedDay);
    }
    _activeLocalDay = today;
  }

  void _rotateIfNeeded(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    if (_activeLocalDay == null) {
      _activeLocalDay = today;
      return;
    }
    if (_activeLocalDay == today) {
      return;
    }

    _sink?.flush();
    _sink?.close();
    _sink = null;

    _archiveActiveFile(_activeLocalDay!);
    _activeLocalDay = today;
    _openSink();
    _cleanupArchivedFiles(now);
  }

  void _archiveActiveFile(DateTime day) {
    if (!_activeFile.existsSync()) {
      return;
    }
    final archiveName = 'mcp-${_yyyyMmDd(day)}.log';
    final archiveFile = File(archiveName);

    if (archiveFile.existsSync()) {
      final content = _activeFile.readAsStringSync();
      archiveFile.writeAsStringSync(content, mode: FileMode.append);
      _activeFile.deleteSync();
      return;
    }

    _activeFile.renameSync(archiveName);
  }

  void _cleanupArchivedFiles(DateTime now) {
    final cutoff = DateTime(now.year, now.month, now.day).subtract(Duration(days: retentionDays));
    final dir = Directory.current;
    for (final entity in dir.listSync()) {
      if (entity is! File) {
        continue;
      }
      final name = entity.uri.pathSegments.isEmpty
          ? entity.path
          : entity.uri.pathSegments.last;
      final match = RegExp(r'^mcp-(\d{4})-(\d{2})-(\d{2})\.log$').firstMatch(name);
      if (match == null) {
        continue;
      }
      final year = int.parse(match.group(1)!);
      final month = int.parse(match.group(2)!);
      final day = int.parse(match.group(3)!);
      final fileDay = DateTime(year, month, day);
      if (!fileDay.isAfter(cutoff)) {
        entity.deleteSync();
      }
    }
  }

  void _openSink() {
    _sink = _activeFile.openWrite(mode: FileMode.append);
  }

  String _yyyyMmDd(DateTime day) {
    final y = day.year.toString().padLeft(4, '0');
    final m = day.month.toString().padLeft(2, '0');
    final d = day.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
