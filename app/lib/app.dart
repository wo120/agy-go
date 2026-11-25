import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/app_state.dart';
import 'state/native_bridge.dart';
import 'theme/levity_theme.dart';
import 'ui/chat/chat_screen.dart';
import 'ui/home/home_screen.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class AgyMobileApp extends ConsumerStatefulWidget {
  const AgyMobileApp({super.key});

  @override
  ConsumerState<AgyMobileApp> createState() => _AgyMobileAppState();
}

class _AgyMobileAppState extends ConsumerState<AgyMobileApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NativeBridge.instance.init();
    NativeBridge.instance.onNotificationTap = (conversationId) {
      rootNavigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => ChatScreen(conversationId: conversationId)),
      );
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(hostConnectionProvider.notifier).verifyConnection();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'AGY Go',
      debugShowCheckedModeBanner: false,
      theme: buildLevityTheme(),
      home: const HomeScreen(),
    );
  }
}
