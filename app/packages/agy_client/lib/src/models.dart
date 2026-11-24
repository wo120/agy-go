import 'dart:convert';

class BridgeRemoteException implements Exception {
  const BridgeRemoteException(this.code, this.message);

  final String code;
  final String message;

  bool get isDesktopOffline => code == 'DESKTOP_OFFLINE';
  bool get isUnauthorized => code == 'UNAUTHORIZED';
  bool get isPathForbidden => code == 'PATH_FORBIDDEN';

  @override
  String toString() => 'BridgeRemoteException($code): $message';
}

class CarrierException implements Exception {
  const CarrierException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'CarrierException: $message${cause != null ? ' ($cause)' : ''}';
}

class PairingPayload {
  const PairingPayload({
    required this.version,
    required this.hostName,
    required this.endpoints,
    required this.token,
  });

  final int version;
  final String hostName;
  final List<String> endpoints;
  final String token;

  factory PairingPayload.fromJson(Map<String, dynamic> json) {
    return PairingPayload(
      version: (json['v'] as num?)?.toInt() ?? 1,
      hostName: (json['hostName'] as String?) ?? 'AntigravityHost',
      endpoints: ((json['endpoints'] as List?) ?? const []).map((e) => e.toString()).toList(),
      token: (json['token'] as String?) ?? '',
    );
  }

  static PairingPayload parseQr(String raw) {
    final decoded = jsonDecode(raw.trim());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid pairing QR payload');
    }
    final payload = PairingPayload.fromJson(decoded);
    if (payload.endpoints.isEmpty || payload.token.isEmpty) {
      throw const FormatException('Pairing payload missing endpoints or token');
    }
    return payload;
  }

  Map<String, dynamic> toJson() => {
        'v': version,
        'hostName': hostName,
        'endpoints': endpoints,
        'token': token,
      };
}

class WorkspaceInfo {
  const WorkspaceInfo({
    required this.kind,
    required this.label,
    this.rootPath,
  });

  final String kind; // "workspace" | "global"
  final String label;
  final String? rootPath;

  bool get isGlobal => kind == 'global';

  factory WorkspaceInfo.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const WorkspaceInfo(kind: 'global', label: '通用对话');
    }
    return WorkspaceInfo(
      kind: (json['kind'] as String?) ?? 'global',
      label: (json['label'] as String?) ?? '通用对话',
      rootPath: json['rootPath'] as String?,
    );
  }
}

class PoolQuota {
  const PoolQuota({
    required this.poolId,
    required this.displayName,
    required this.remaining5hPct,
    required this.reset5hAt,
    required this.remaining7dPct,
    required this.reset7dAt,
    required this.level,
    required this.source,
  });

  final String poolId;
  final String displayName;
  final int remaining5hPct;
  final int? reset5hAt;
  final int remaining7dPct;
  final int? reset7dAt;
  final String level; // "full" | "normal" | "warning"
  final String source;

  factory PoolQuota.fromJson(Map<String, dynamic> json) {
    return PoolQuota(
      poolId: (json['poolId'] as String?) ?? '',
      displayName: (json['displayName'] as String?) ?? '',
      remaining5hPct: (json['remaining5hPct'] as num?)?.toInt() ?? 100,
      reset5hAt: (json['reset5hAt'] as num?)?.toInt(),
      remaining7dPct: (json['remaining7dPct'] as num?)?.toInt() ?? 100,
      reset7dAt: (json['reset7dAt'] as num?)?.toInt(),
      level: (json['level'] as String?) ?? 'full',
      source: (json['source'] as String?) ?? 'ledger',
    );
  }
}

class QuotaSnapshot {
  const QuotaSnapshot({
    required this.subscriptionTier,
    required this.updatedAt,
    required this.pools,
  });

  final String subscriptionTier;
  final int updatedAt;
  final List<PoolQuota> pools;

  factory QuotaSnapshot.fromJson(Map<String, dynamic> json) {
    return QuotaSnapshot(
      subscriptionTier: (json['subscriptionTier'] as String?) ?? 'Google AI Ultra',
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      pools: ((json['pools'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PoolQuota.fromJson)
          .toList(),
    );
  }
}

class SessionCard {
  const SessionCard({
    required this.conversationId,
    required this.title,
    required this.preview,
    required this.stepCount,
    required this.lastModifiedUnix,
    required this.workspace,
    required this.status,
    required this.running,
    required this.subagentCount,
    required this.artifactCount,
    this.model,
    this.modelDisplay,
    required this.pinned,
    required this.pinnedOrder,
    required this.unread,
    required this.needsConfirm,
  });

  final String conversationId;
  final String title;
  final String preview;
  final int stepCount;
  final int lastModifiedUnix;
  final WorkspaceInfo workspace;
  final String status;
  final bool running;
  final int subagentCount;
  final int artifactCount;
  final String? model;
  final String? modelDisplay;
  final bool pinned;
  final int pinnedOrder;
  final bool unread;
  final bool needsConfirm;

  factory SessionCard.fromJson(Map<String, dynamic> json) {
    return SessionCard(
      conversationId: (json['conversationId'] as String?) ?? '',
      title: (json['title'] as String?) ?? '未命名对话',
      preview: (json['preview'] as String?) ?? '',
      stepCount: (json['stepCount'] as num?)?.toInt() ?? 0,
      lastModifiedUnix: (json['lastModifiedUnix'] as num?)?.toInt() ?? 0,
      workspace: WorkspaceInfo.fromJson(json['workspace'] as Map<String, dynamic>?),
      status: (json['status'] as String?) ?? '',
      running: (json['running'] as bool?) ?? false,
      subagentCount: (json['subagentCount'] as num?)?.toInt() ?? 0,
      artifactCount: (json['artifactCount'] as num?)?.toInt() ?? 0,
      model: json['model'] as String?,
      modelDisplay: json['modelDisplay'] as String?,
      pinned: (json['pinned'] as bool?) ?? false,
      pinnedOrder: (json['pinnedOrder'] as num?)?.toInt() ?? 0,
      unread: (json['unread'] as bool?) ?? false,
      needsConfirm: (json['needsConfirm'] as bool?) ?? false,
    );
  }
}

class ProjectGroup {
  const ProjectGroup({
    required this.workspace,
    required this.latestActiveUnix,
    required this.sessions,
  });

  final WorkspaceInfo workspace;
  final int latestActiveUnix;
  final List<SessionCard> sessions;

  factory ProjectGroup.fromJson(Map<String, dynamic> json) {
    return ProjectGroup(
      workspace: WorkspaceInfo.fromJson(json['workspace'] as Map<String, dynamic>?),
      latestActiveUnix: (json['latestActiveUnix'] as num?)?.toInt() ?? 0,
      sessions: ((json['sessions'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SessionCard.fromJson)
          .toList(),
    );
  }
}

class SessionListResult {
  const SessionListResult({
    required this.mode,
    required this.pinned,
    required this.regular,
    required this.groups,
  });

  final String mode;
  final List<SessionCard> pinned;
  final List<SessionCard> regular;
  final List<ProjectGroup> groups;

  factory SessionListResult.fromJson(Map<String, dynamic> json) {
    return SessionListResult(
      mode: (json['mode'] as String?) ?? 'desktop',
      pinned: ((json['pinned'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SessionCard.fromJson)
          .toList(),
      regular: ((json['regular'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SessionCard.fromJson)
          .toList(),
      groups: ((json['groups'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ProjectGroup.fromJson)
          .toList(),
    );
  }
}

class SearchHit {
  const SearchHit({
    required this.conversationId,
    required this.title,
    required this.workspace,
    required this.snippet,
    required this.lastModifiedUnix,
  });

  final String conversationId;
  final String title;
  final String workspace;
  final String snippet;
  final int lastModifiedUnix;

  factory SearchHit.fromJson(Map<String, dynamic> json) {
    return SearchHit(
      conversationId: (json['conversationId'] as String?) ?? '',
      title: (json['title'] as String?) ?? '未命名对话',
      workspace: (json['workspace'] as String?) ?? '',
      snippet: (json['snippet'] as String?) ?? '',
      lastModifiedUnix: (json['lastModifiedUnix'] as num?)?.toInt() ?? 0,
    );
  }
}

class ToolCallItem {
  const ToolCallItem({required this.name, this.args = const {}});

  final String name;
  final Map<String, dynamic> args;

  factory ToolCallItem.fromJson(Map<String, dynamic> json) {
    return ToolCallItem(
      name: (json['name'] as String?) ?? '',
      args: (json['args'] as Map<String, dynamic>?) ?? const {},
    );
  }
}

class TranscriptStep {
  const TranscriptStep({
    required this.stepIndex,
    required this.source,
    required this.type,
    required this.status,
    required this.createdAtUnix,
    this.content = '',
    this.thinking = '',
    this.model = '',
    this.modelDisplay = '',
    this.toolCalls = const [],
  });

  final int stepIndex;
  final String source;
  final String type;
  final String status;
  final int createdAtUnix;
  final String content;
  final String thinking;
  final String model;
  final String modelDisplay;
  final List<ToolCallItem> toolCalls;

  factory TranscriptStep.fromJson(Map<String, dynamic> json) {
    return TranscriptStep(
      stepIndex: (json['step_index'] as num?)?.toInt() ?? 0,
      source: (json['source'] as String?) ?? '',
      type: (json['type'] as String?) ?? '',
      status: (json['status'] as String?) ?? '',
      createdAtUnix: (json['created_at_unix'] as num?)?.toInt() ?? 0,
      content: (json['content'] as String?) ?? '',
      thinking: (json['thinking'] as String?) ?? '',
      model: (json['model'] as String?) ?? '',
      modelDisplay: (json['model_display'] as String?) ?? '',
      toolCalls: ((json['tool_calls'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ToolCallItem.fromJson)
          .toList(),
    );
  }
}

class ArtifactItem {
  const ArtifactItem({
    required this.name,
    required this.relPath,
    required this.fullPath,
    required this.sizeBytes,
    required this.modTime,
    required this.kind,
    required this.mimeType,
  });

  final String name;
  final String relPath;
  final String fullPath;
  final int sizeBytes;
  final int modTime;
  final String kind;
  final String mimeType;

  bool get isImage => kind == 'image';

  factory ArtifactItem.fromJson(Map<String, dynamic> json) {
    return ArtifactItem(
      name: (json['name'] as String?) ?? '',
      relPath: (json['relPath'] as String?) ?? '',
      fullPath: (json['fullPath'] as String?) ?? '',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      modTime: (json['modTime'] as num?)?.toInt() ?? 0,
      kind: (json['kind'] as String?) ?? 'text',
      mimeType: (json['mimeType'] as String?) ?? 'application/octet-stream',
    );
  }
}

class TextContentPage {
  const TextContentPage({
    required this.path,
    required this.name,
    required this.kind,
    required this.mimeType,
    required this.content,
    required this.offset,
    required this.totalBytes,
    required this.truncated,
  });

  final String path;
  final String name;
  final String kind;
  final String mimeType;
  final String content;
  final int offset;
  final int totalBytes;
  final bool truncated;

  factory TextContentPage.fromJson(Map<String, dynamic> json) {
    return TextContentPage(
      path: (json['path'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      kind: (json['kind'] as String?) ?? 'text',
      mimeType: (json['mimeType'] as String?) ?? 'text/plain',
      content: (json['content'] as String?) ?? '',
      offset: (json['offset'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      truncated: (json['truncated'] as bool?) ?? false,
    );
  }
}

class AgentAlert {
  const AgentAlert({
    required this.alertId,
    required this.kind,
    required this.conversationId,
    required this.title,
    required this.workspace,
    required this.body,
    this.quickReplies = const [],
    required this.createdAt,
  });

  final String alertId;
  final String kind; // "NEED_CONFIRM" | "TASK_COMPLETED"
  final String conversationId;
  final String title;
  final String workspace;
  final String body;
  final List<String> quickReplies;
  final int createdAt;

  factory AgentAlert.fromJson(Map<String, dynamic> json) {
    return AgentAlert(
      alertId: (json['alertId'] as String?) ?? '',
      kind: (json['kind'] as String?) ?? 'TASK_COMPLETED',
      conversationId: (json['conversationId'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      workspace: (json['workspace'] as String?) ?? '',
      body: (json['body'] as String?) ?? '',
      quickReplies: ((json['quickReplies'] as List?) ?? const []).map((e) => e.toString()).toList(),
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class EndpointProbeResult {
  const EndpointProbeResult({
    required this.endpoint,
    required this.rttMs,
    required this.isDirect,
    required this.hostName,
    required this.desktopOnline,
  });

  final String endpoint;
  final int rttMs;
  final bool isDirect;
  final String hostName;
  final bool desktopOnline;
}
