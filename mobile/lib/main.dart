import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'local/local_database.dart';
import 'sync/sync_service.dart';
import 'providers/auth_provider.dart';
import 'providers/round_provider.dart';
import 'screens/login_screen.dart';
import 'screens/tournament_list_screen.dart';
import 'screens/round_screen.dart';
import 'screens/scorecard_screen.dart';
import 'screens/sixes_screen.dart';
import 'screens/sixes_setup_screen.dart';
import 'screens/leaderboard_screen.dart';

/// Global navigator key — lets AuthProvider redirect to /login on 401
/// from outside the widget tree.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // sqflite's method channel only works on iOS/Android.
  // On macOS / Windows / Linux we need the FFI implementation instead.
  if (!Platform.isAndroid && !Platform.isIOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // Open the local SQLite database before anything else runs.
  final localDb = LocalDatabase();
  await localDb.init();

  final auth = AuthProvider();
  await auth.restoreSession();

  runApp(GolfApp(auth: auth, localDb: localDb));
}

class GolfApp extends StatefulWidget {
  final AuthProvider  auth;
  final LocalDatabase localDb;

  const GolfApp({super.key, required this.auth, required this.localDb});

  @override
  State<GolfApp> createState() => _GolfAppState();
}

class _GolfAppState extends State<GolfApp> {
  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    widget.auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (!widget.auth.isLoggedIn) {
      // Clear cached data on sign-out so another user doesn't see it.
      widget.localDb.clearAll();
      navigatorKey.currentState?.pushNamedAndRemoveUntil(
        '/login',
        (_) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: widget.auth),

        // SyncService: monitors connectivity + drains the pending queue.
        // Created once; updated when the auth token changes.
        ChangeNotifierProxyProvider<AuthProvider, SyncService>(
          create: (ctx) => SyncService(
            db:     widget.localDb,
            client: widget.auth.client,
          ),
          update: (_, auth, prev) => prev!..updateClient(auth.client),
        ),

        // RoundProvider now receives both the local DB and the SyncService.
        ChangeNotifierProxyProvider2<AuthProvider, SyncService, RoundProvider>(
          create: (ctx) => RoundProvider(
            widget.auth.client,
            widget.localDb,
            ctx.read<SyncService>(),
          ),
          update: (_, auth, __, prev) => prev!..updateClient(auth.client),
        ),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'Golf App',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF2E7D32),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF2E7D32),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        initialRoute: widget.auth.isLoggedIn ? '/tournaments' : '/login',
        onGenerateRoute: _router,
      ),
    );
  }

  Route<dynamic>? _router(RouteSettings settings) {
    switch (settings.name) {
      case '/login':
        return MaterialPageRoute(builder: (_) => const LoginScreen());
      case '/tournaments':
        return MaterialPageRoute(builder: (_) => const TournamentListScreen());
      case '/round':
        final roundId = settings.arguments as int;
        return MaterialPageRoute(builder: (_) => RoundScreen(roundId: roundId));
      case '/scorecard':
        final foursomeId = settings.arguments as int;
        return MaterialPageRoute(
            builder: (_) => ScorecardScreen(foursomeId: foursomeId));
      case '/sixes-setup':
        final foursomeId = settings.arguments as int;
        return MaterialPageRoute(
            builder: (_) => SixesSetupScreen(foursomeId: foursomeId));
      case '/sixes':
        final foursomeId = settings.arguments as int;
        return MaterialPageRoute(
            builder: (_) => SixesScreen(foursomeId: foursomeId));
      case '/leaderboard':
        final roundId = settings.arguments as int;
        return MaterialPageRoute(
            builder: (_) => LeaderboardScreen(roundId: roundId));
      default:
        return MaterialPageRoute(builder: (_) => const LoginScreen());
    }
  }
}
