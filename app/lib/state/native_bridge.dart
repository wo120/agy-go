import 'dart:io';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef NotificationReplyHandler = Future<void> Function(String conversationId, String replyText);
typedef NotificationTapHandler = void Function(String conversationId);

/// Bridges Dart state to Android Kotlin AlwaysOnService & AlertNotifier via MethodChannel.
class NativeBridge {
  NativeBridge._();

  static final NativeBridge instance = NativeBridge._();
  static const MethodChannel _channel = MethodChannel('agy/native');

  @visibleForTesting
  bool? forceAndroidForTest;

  bool get _isAndroid => forceAndroidForTest ?? Platform.isAndroid;

  NotificationReplyHandler? onNotificationReply;
  NotificationTapHandler? onNotificationTap;
  bool _initialized = false;

  void init() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onNotificationReply':
          final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
          final convId = (args['conversationId'] as String?) ?? '';
          final text = (args['text'] as String?) ?? '';
          if (convId.isNotEmpty && text.isNotEmpty && onNotificationReply != null) {
            await onNotificationReply!(convId, text);
          }
          return true;
        case 'onNotificationTap':
          final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
          final convId = (args['conversationId'] as String?) ?? '';
          if (convId.isNotEmpty && onNotificationTap != null) {
            onNotificationTap!(convId);
          }
          return true;
      }
      return null;
    });
  }

  Future<void> startAlwaysOnService({required String hostName, required String statusText}) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('startAlwaysOnService', {
        'hostName': hostName,
        'statusText': statusText,
      });
    } catch (_) {}
  }

  Future<void> stopAlwaysOnService() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('stopAlwaysOnService');
    } catch (_) {}
  }

  Future<void> showAgentAlert(AgentAlert alert) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('showAgentAlert', {
        'alertId': alert.alertId,
        'kind': alert.kind,
        'conversationId': alert.conversationId,
        'title': alert.title,
        'workspace': alert.workspace,
        'body': alert.body,
        'quickReplies': alert.quickReplies,
      });
    } catch (_) {}
  }

  Future<void> requestPermissions() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('requestPermissions');
    } catch (_) {}
  }

  Future<void> openBatteryOptimizationSettings() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('openBatterySettings');
    } catch (_) {}
  }
}
