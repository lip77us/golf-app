import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/auth_provider.dart';
import 'providers/round_provider.dart';
import 'screens/login_screen.dart';
import 'screens/tournament_list_screen.dart';
import 'screens/round_screen.dart';
import 'screens/scorecard_screen.dart';
import 'screens/leaderboard_screen.dart';

/// Global navigator key so we can redirect to /login from outside widget tree
/// (e.g. when a 401 triggers AuthProvider.logout from inside ApiClient).
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final auth = AuthProvider();
  await auth.restoreSession();   // re-hydrate token from shared_prefs
  runApp(GolfApp(auth: auth));
}

class GolfApp extends StatefulWidget {
  final AuthProvider auth;
  const GolfApp({super.key, required this.auth});

  @override
  State<GolfApp> createState() => _GolfAppState();
}

class _GolfAppState extends State<GolfApp> {
  @override
  void initState() {
    super.initState();
    // Listen for auth changes — when the user is signed out (including silent
    // 401 logouts) push them back to /login and clear the navigation stack.
    widget.auth.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    widget.auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (!widget.auth.isLoggedIn) {
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
        // RoundProvider is created fresh, using the auth client
        ChangeNotifierProxyProvider<AuthProvider, RoundProvider>(
          create: (_) => RoundProvider(widget.auth.client),
          update: (_, a, prev) => prev!..updateClient(a.client),
        ),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'Golf App',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF2E7D32), // golf green
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
        return MaterialPageRoute(
            builder: (_) => const TournamentListScreen());

      case '/round':
        final roundId = settings.arguments as int;
        return MaterialPageRoute(
            builder: (_) => RoundScreen(roundId: roundId));

      case '/scorecard':
        final foursomeId = settings.arguments as int;
        return MaterialPageRoute(
            builder: (_) => ScorecardScreen(foursomeId: foursomeId));

      case '/leaderboard':
        final roundId = settings.arguments as int;
        return MaterialPageRoute(
            builder: (_) => LeaderboardScreen(roundId: roundId));

      default:
        return MaterialPageRoute(builder: (_) => const LoginScreen());
    }
  }
}
