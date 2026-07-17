import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
// Hide google_fonts' own `Config` — it collides with our app's Config.
import 'package:google_fonts/google_fonts.dart' hide Config;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:url_launcher/url_launcher.dart';
import 'api/client.dart';
import 'config.dart';
import 'theme/halved_brand.dart';

import 'local/local_database.dart';
import 'sync/sync_service.dart';
import 'providers/auth_provider.dart';
import 'providers/round_provider.dart';
import 'providers/message_provider.dart';
import 'providers/settings_provider.dart';
import 'services/push_service.dart';
import 'screens/stableford_setup_screen.dart';
import 'screens/login_screen.dart';
import 'screens/otp_verify_screen.dart';
import 'screens/profile_setup_screen.dart';
import 'screens/onboarding_wizard.dart';
import 'screens/tournament_list_screen.dart';
import 'screens/round_screen.dart';
import 'screens/round_feed_screen.dart';
import 'widgets/round_landscape_scorecard.dart';
import 'screens/sixes_setup_screen.dart';
import 'screens/points_531_setup_screen.dart';
import 'screens/vegas_setup_screen.dart';
import 'screens/fourball_setup_screen.dart';
import 'screens/points_531_screen.dart';
import 'screens/skins_setup_screen.dart';
import 'screens/spots_setup_screen.dart';
import 'screens/honors_setup_screen.dart';
import 'screens/skins_screen.dart';
import 'screens/wolf_setup_screen.dart';
import 'screens/wolf_screen.dart';
import 'screens/rabbit_setup_screen.dart';
import 'screens/rabbit_screen.dart';
import 'screens/triple_cup_setup_screen.dart';
import 'screens/triple_cup_screen.dart';
import 'screens/multi_skins_setup_screen.dart';
import 'screens/multi_skins_screen.dart';
import 'screens/nassau_setup_screen.dart';
import 'screens/nassau_screen.dart';
import 'screens/leaderboard_screen.dart';
import 'screens/casual_rounds_list_screen.dart';
import 'screens/support_lookup_screen.dart';
import 'screens/game_suggestion_screen.dart';
import 'utils/deep_links.dart';
import 'utils/route_observer.dart';
import 'screens/irish_rumble_setup_screen.dart';
import 'screens/pink_ball_setup_screen.dart';
import 'screens/pink_ball_screen.dart';
import 'screens/tournament_low_net_setup_screen.dart';
import 'screens/setup_round_players_screen.dart';
import 'screens/tournament_leaderboard_screen.dart';
import 'screens/match_play_setup_screen.dart';
import 'screens/match_play_screen.dart';
import 'screens/course_search_screen.dart';
import 'screens/score_entry_screen.dart';
import 'screens/three_person_match_setup_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/quota_nassau_screen.dart';
import 'screens/confirm_tees_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/manage_courses_screen.dart';

/// The app-wide Halved brand theme (docs/Halved-Brand-Guidelines.md): light
/// sage surface, pine structure, bright-mint reserved for CTAs / the FAB, and
/// Schibsted Grotesk (headings) + Spline Sans (body). Selected state stays ONE
/// thing app-wide — pine fill, white text — per the earlier design reviews.
///
/// The palette + reusable widgets live in theme/halved_brand.dart; this wires
/// the same tokens into the global ThemeData so every screen inherits them.
ThemeData _halvedTheme(Brightness brightness) {
  // Dark mode is currently unused (themeMode is forced light); keep a basic
  // seeded dark theme so the app still compiles if it's ever enabled.
  if (brightness == Brightness.dark) {
    return ThemeData(
      colorScheme:
          ColorScheme.fromSeed(seedColor: Halved.pine, brightness: brightness),
      useMaterial3: true,
    );
  }

  final scheme = ColorScheme.fromSeed(
    seedColor: Halved.pine,
    brightness: Brightness.light,
  ).copyWith(
    primary:        Halved.pine,
    onPrimary:      Colors.white,
    secondary:      Halved.mint,
    onSecondary:    Colors.white,
    tertiary:       Halved.brightMint,
    onTertiary:     Halved.deepPine,
    surface:        Halved.card,      // white cards / sheets / dialogs
    onSurface:      Halved.deepPine,
    onSurfaceVariant: Halved.muted,
    outline:        const Color(0xFFB7C3BB),
    outlineVariant: Halved.cardBorder,
    surfaceContainerLowest:  Colors.white,
    surfaceContainerLow:     const Color(0xFFF4F7F4),
    surfaceContainer:        const Color(0xFFEDF2ED),
    surfaceContainerHigh:    const Color(0xFFE7EEE8),
    surfaceContainerHighest: const Color(0xFFE1EAE2),
    error:          Halved.warning,
  );

  // Body/labels in Spline Sans; headings (display/headline/title) in Schibsted
  // Grotesk. Sizes come from the M3 defaults; only the family + weight change.
  final spline = GoogleFonts.splineSansTextTheme();
  TextStyle grotesk(TextStyle? s) =>
      GoogleFonts.schibstedGrotesk(textStyle: s, fontWeight: FontWeight.w600);
  final textTheme = spline.copyWith(
    displayLarge:   grotesk(spline.displayLarge),
    displayMedium:  grotesk(spline.displayMedium),
    displaySmall:   grotesk(spline.displaySmall),
    headlineLarge:  grotesk(spline.headlineLarge),
    headlineMedium: grotesk(spline.headlineMedium),
    headlineSmall:  grotesk(spline.headlineSmall),
    titleLarge:     grotesk(spline.titleLarge),
    titleMedium:    grotesk(spline.titleMedium),
    titleSmall:     grotesk(spline.titleSmall),
  ).apply(bodyColor: Halved.deepPine, displayColor: Halved.deepPine);

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: Halved.surface,
    textTheme: textTheme,
    dividerTheme: const DividerThemeData(color: Halved.cardBorder),
    appBarTheme: AppBarTheme(
      backgroundColor: Halved.surface,
      foregroundColor: Halved.deepPine,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      iconTheme: const IconThemeData(color: Halved.deepPine),
      titleTextStyle: GoogleFonts.schibstedGrotesk(
          fontSize: 20, fontWeight: FontWeight.w600, color: Halved.deepPine),
    ),
    cardTheme: CardThemeData(
      color: Halved.card,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Halved.rCard),
        side: const BorderSide(color: Halved.cardBorder, width: 1.5),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Halved.card,
      selectedColor: Halved.pine,
      side: const BorderSide(color: Halved.cardBorder),
      showCheckmark: false,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Halved.rChip),
      ),
      // Normal / bare chips: deep-pine label on the white fill. A plain
      // TextStyle (not WidgetStateTextStyle) is required — non-interactive
      // Chips don't resolve a stateful style, so its colour fell back to null
      // and the label rendered white-on-white.
      labelStyle: const TextStyle(
          color: Halved.deepPine, fontWeight: FontWeight.w500),
      // Selected ChoiceChip/FilterChip fill pine (dark) → white label so it
      // stays readable. (GameSelectableChip sets its own colours regardless.)
      secondaryLabelStyle: const TextStyle(
          color: Colors.white, fontWeight: FontWeight.w600),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Halved.pine,
        side: const BorderSide(color: Halved.pine, width: 1.5),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.surface),
        foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? scheme.onPrimary
                : scheme.onSurface),
      ),
    ),
    // FAB is a primary "create" action → bright-mint CTA, deep-pine icon/label.
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Halved.brightMint,
      foregroundColor: Halved.deepPine,
    ),
  );
}

/// Global navigator key — lets AuthProvider redirect to /login on 401
/// from outside the widget tree.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// True once the splash has handed off to a real screen (home or login), so
/// deep-link navigation can safely push on top without the splash's
/// pushReplacement clobbering it. Watched deep-links wait for this.
bool gDeepLinkReady = false;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load the real build version from the bundle so Config.appVersion matches
  // pubspec (drives the About dialog + the force-upgrade compatibility check).
  await Config.init();

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
  debugPrint('[WATCHLINK] main: after restoreSession isLoggedIn=${auth.isLoggedIn}');

  final settings = SettingsProvider();
  await settings.load();

  // Push notifications (FCM). Guarded — a build without the native Firebase
  // setup simply has no push; the app runs normally.
  await PushService.initFirebase();
  PushService.attach(auth, navigatorKey);

  // Universal links (halved.golf/watch/<token>/ → open the round's leaderboard).
  // Guarded — no-op on platforms/builds without the association set up.
  unawaited(DeepLinkService(auth).start());

  runApp(GolfApp(auth: auth, localDb: localDb, settings: settings));
}

/// Setup-screen route args may be a plain int (the foursome/round id) or a Map
/// `{'id': int, 'returnToHub': bool}` (round creation / "Edit Configuration",
/// which lands back on the /round launch page).  These read either shape.
int _routeId(Object? a) =>
    a is Map ? (a['id'] ?? a['foursomeId'] ?? a['roundId']) as int : a as int;
bool _routeReturnToHub(Object? a) => a is Map && a['returnToHub'] == true;

class GolfApp extends StatefulWidget {
  final AuthProvider     auth;
  final LocalDatabase    localDb;
  final SettingsProvider settings;

  const GolfApp({
    super.key,
    required this.auth,
    required this.localDb,
    required this.settings,
  });

  @override
  State<GolfApp> createState() => _GolfAppState();
}

class _GolfAppState extends State<GolfApp> {
  /// Tracks the previous logged-in state so `_onAuthChanged` can fire the
  /// logout redirect only on an actual logged-in → logged-out transition.
  /// Without this flag, `AuthProvider.login()`'s first `notifyListeners()`
  /// (which fires while `_token` is still null, just to show the spinner)
  /// would be treated as a logout and would `pushNamedAndRemoveUntil('/login')`,
  /// disposing the LoginScreen mid-submit.  The in-flight submit would then
  /// complete on a `mounted == false` widget and silently skip the
  /// navigation to `/tournaments`, forcing the user to sign in twice.
  bool _wasLoggedIn = false;

  @override
  void initState() {
    super.initState();
    _wasLoggedIn = widget.auth.isLoggedIn;
    debugPrint('[WATCHLINK] AuthGate.initState: isLoggedIn=$_wasLoggedIn');
    widget.auth.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    widget.auth.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    final isLoggedIn = widget.auth.isLoggedIn;
    debugPrint('[WATCHLINK] AuthGate._onAuthChanged: was=$_wasLoggedIn now=$isLoggedIn');
    if (_wasLoggedIn && !isLoggedIn) {
      debugPrint('[WATCHLINK] AuthGate: logout transition -> pushing /login');
      // Clear cached data on sign-out so another user doesn't see it.
      widget.localDb.clearAll();
      navigatorKey.currentState?.pushNamedAndRemoveUntil(
        '/login',
        (_) => false,
      );
    }
    _wasLoggedIn = isLoggedIn;
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: widget.auth),
        ChangeNotifierProvider.value(value: widget.settings),

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
          update: (_, auth, __, prev) {
            prev!.updateClient(auth.client);
            // On sign-out, drop the previous user's cached round/scorecard so a
            // different login on this device doesn't see stale data.
            if (!auth.isLoggedIn) prev.clearForLogout();
            return prev;
          },
        ),

        // MessageProvider: per-round chat/event feed (one round at a time).
        ChangeNotifierProxyProvider2<AuthProvider, SyncService, MessageProvider>(
          create: (ctx) => MessageProvider(
            widget.auth.client,
            widget.localDb,
            ctx.read<SyncService>(),
          ),
          update: (_, auth, __, prev) => prev!..updateClient(auth.client),
        ),
      ],
      child: MaterialApp(
        navigatorKey:         navigatorKey,
        scaffoldMessengerKey: scaffoldMessengerKey,
        // Lets screens (e.g. the casual rounds list) refresh when the user
        // navigates back to them.
        navigatorObservers:   [appRouteObserver],
        title: 'Halved',
        debugShowCheckedModeBanner: false,
        theme:     _halvedTheme(Brightness.light),
        darkTheme: _halvedTheme(Brightness.dark),
        // The app's visuals are built around a light "paper scorecard" look
        // (white score-grid fills, hardcoded inks). Pin to light mode so Halved
        // always renders correctly even when the phone is set to dark mode.
        // (Revisit if/when the full theme-aware color refactor lands.)
        themeMode: ThemeMode.light,
        initialRoute: '/splash',
        // Override the default initial-route generation so Flutter doesn't
        // split '/splash' into ['/', '/splash'] and silently push a
        // LoginScreen at the bottom of the stack (via the onGenerateRoute
        // default case).  That hidden LoginScreen was the destination
        // every popUntil-to-isFirst was bottoming out on.
        onGenerateInitialRoutes: (initialRoute) {
          final route = _router(RouteSettings(name: initialRoute));
          return route == null ? const [] : [route];
        },
        onGenerateRoute: _router,
        onUnknownRoute: (settings) {
          // Last-resort fallback — log loudly so we catch any future
          // navigation to an unregistered route.  Don't return null
          // (that crashes the navigator); show LoginScreen but with a
          // real name so popUntil can still find it deliberately.
          debugPrint('[NAV-UNKNOWN] route=${settings.name} args=${settings.arguments}');
          developer.log(
            '[NAV-UNKNOWN] route=${settings.name} args=${settings.arguments}',
            name: 'NAV',
          );
          return MaterialPageRoute(
            settings: const RouteSettings(name: '/unknown'),
            builder: (_) => const LoginScreen(),
          );
        },
      ),
    );
  }

  // ---- Version check helpers ----

  /// Called when the splash animation finishes.  Checks client/server version
  /// compatibility and shows a blocking dialog when the app needs updating,
  /// then routes to login or tournaments.  Any network error is silently
  /// swallowed so an offline first launch still works.
  Future<void> _navigateAfterSplash() async {
    final destination = widget.auth.isLoggedIn ? '/tournaments' : '/login';
    debugPrint('[WATCHLINK] splash: isLoggedIn=${widget.auth.isLoggedIn} destination=$destination');

    try {
      // Use a short timeout so a slow server doesn't delay the startup.
      const shortTimeout = Duration(seconds: 8);
      final client = const ApiClient();          // no auth needed
      final data = await client.getVersion().timeout(shortTimeout);
      final minVersion = (data['min_client_version'] as String?) ?? '1.0.0';

      if (_isVersionOutdated(Config.appVersion, minVersion)) {
        final ctx = navigatorKey.currentContext;
        if (ctx != null) {
          // HARD block: non-dismissible, no way past it, and we never navigate
          // into the app. The only action opens the App Store to update.
          await showDialog<void>(
            context: ctx,
            barrierDismissible: false,
            builder: (dialogCtx) => PopScope(
              canPop: false,
              child: AlertDialog(
                title: const Text('Update Required'),
                content: Text(
                  'This version of the app (${Config.appVersion}) is no longer '
                  'supported.\n\nPlease update to version $minVersion or later '
                  'to continue.',
                ),
                actions: [
                  FilledButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse(Config.appStoreUrl),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.system_update),
                    label: const Text('Update'),
                  ),
                ],
              ),
            ),
          );
        }
        // Outdated builds never proceed into the app (the dialog above blocks
        // when a context exists; this guards the no-context edge too).
        return;
      }
    } catch (_) {
      // Network unavailable or server error — proceed without blocking.
    }

    navigatorKey.currentState?.pushReplacementNamed(destination);
    // The app is now on a real screen — safe for a stashed watch deep-link to
    // push the round leaderboard on top.
    gDeepLinkReady = true;
  }

  /// Returns true if [current] is strictly older than [minimum].
  /// Compares dot-separated integer segments, e.g. "1.0.0" vs "1.1.0".
  bool _isVersionOutdated(String current, String minimum) {
    int _seg(String v, int i) {
      final parts = v.split('.');
      return i < parts.length ? (int.tryParse(parts[i]) ?? 0) : 0;
    }
    for (int i = 0; i < 3; i++) {
      final c = _seg(current, i);
      final m = _seg(minimum, i);
      if (c < m) return true;
      if (c > m) return false;
    }
    return false; // equal
  }

  Route<dynamic>? _router(RouteSettings settings) {
    // Helper: always propagate `settings` to the MaterialPageRoute so the
    // navigator preserves route names.  Without this, `r.settings.name`
    // comes back null on every route and popUntil predicates like
    // `r.settings.name == '/tournaments'` are dead — the navigator pops
    // all the way down to whatever happens to be at the bottom of the
    // stack, which is how users were ending up on a hidden LoginScreen.
    MaterialPageRoute<dynamic> page(WidgetBuilder builder) =>
        MaterialPageRoute(settings: settings, builder: builder);

    switch (settings.name) {
      case '/splash':
        return page((_) => SplashScreen(
              onComplete: () => _navigateAfterSplash(),
            ));
      case '/login':
        debugPrint('[WATCHLINK] router: building /login (StackTrace below)\n'
            '${StackTrace.current}');
        return page((_) => const LoginScreen());
      case '/verify-otp':
        final args = settings.arguments as Map? ?? const {};
        return page((_) => OtpVerifyScreen(
              phone:     args['phone'] as String? ?? '',
              name:      args['name'] as String?,
              debugCode: args['debugCode'] as String?,
            ));
      case '/profile-setup':
        return page((_) => const ProfileSetupScreen());
      case '/onboarding':
        return page((_) => const OnboardingWizard());
      case '/tournaments':
        return page((_) => const TournamentListScreen());
      case '/casual-rounds':
        return page((_) => const CasualRoundsListScreen());
      case '/support-lookup':
        return page((_) => const SupportLookupScreen());
      case '/suggest-game':
        return page((_) => const GameSuggestionScreen());
      case '/settings':
        return page((_) => const SettingsScreen());
      case '/manage-courses':
        return page((_) => const ManageCoursesScreen());
      case '/round':
        final roundId = settings.arguments as int;
        return page((_) => RoundScreen(roundId: roundId));
      case '/round-feed':
        // Arguments may be a plain int (roundId) or a Map with {roundId, title}.
        final args = settings.arguments;
        final roundId = args is Map ? args['roundId'] as int : args as int;
        final title   = args is Map ? args['title'] as String? : null;
        return page((_) => RoundFeedScreen(roundId: roundId, title: title));
      case '/sixes-setup':
        return page((_) => SixesSetupScreen(
              foursomeId: _routeId(settings.arguments),
              returnToHub: _routeReturnToHub(settings.arguments)));
      case '/points-531-setup':
        return page((_) => Points531SetupScreen(
              foursomeId: _routeId(settings.arguments),
              returnToHub: _routeReturnToHub(settings.arguments)));
      case '/vegas-setup':
        return page((_) => VegasSetupScreen(
              foursomeId: _routeId(settings.arguments),
              returnToHub: _routeReturnToHub(settings.arguments)));
      case '/fourball-setup':
        return page((_) => FourballSetupScreen(
              foursomeId: _routeId(settings.arguments),
              returnToHub: _routeReturnToHub(settings.arguments)));
      case '/points-531':
        final foursomeId = settings.arguments as int;
        return page((_) => RoundLandscapeScorecard(
              foursomeId: foursomeId,
              child: Points531Screen(foursomeId: foursomeId)));
      case '/skins-setup':
        // Args may be a plain int (foursomeId) or a Map with
        // {'id': int, 'returnToHub': bool} (round creation / Edit Config).
        final a = settings.arguments;
        final foursomeId  = a is Map ? a['id'] as int : a as int;
        final returnToHub = a is Map && a['returnToHub'] == true;
        return page((_) => SkinsSetupScreen(
              foursomeId: foursomeId, returnToHub: returnToHub));
      case '/skins':
        final foursomeId = settings.arguments as int;
        return page((_) => RoundLandscapeScorecard(
              foursomeId: foursomeId,
              child: SkinsScreen(foursomeId: foursomeId)));
      case '/spots-setup':
        final a = settings.arguments;
        final foursomeId  = a is Map ? a['id'] as int : a as int;
        final returnToHub = a is Map && a['returnToHub'] == true;
        return page((_) => SpotsSetupScreen(
              foursomeId: foursomeId, returnToHub: returnToHub));
      case '/honors-setup':
        // Side game: args are {'id': int, 'returnToHub': bool} (or a plain int).
        final a = settings.arguments;
        final foursomeId  = a is Map ? a['id'] as int : a as int;
        final returnToHub = a is! Map || a['returnToHub'] == true;
        return page((_) => HonorsSetupScreen(
              foursomeId: foursomeId, returnToHub: returnToHub));
      case '/wolf-setup':
        return page((_) => WolfSetupScreen(
              foursomeId: _routeId(settings.arguments),
              returnToHub: _routeReturnToHub(settings.arguments)));
      case '/wolf':
        final foursomeId = settings.arguments as int;
        return page((_) => RoundLandscapeScorecard(
              foursomeId: foursomeId,
              child: WolfScreen(foursomeId: foursomeId)));
      case '/rabbit-setup':
        return page((_) => RabbitSetupScreen(
              foursomeId: _routeId(settings.arguments),
              returnToHub: _routeReturnToHub(settings.arguments)));
      case '/rabbit':
        final foursomeId = settings.arguments as int;
        return page((_) => RoundLandscapeScorecard(
              foursomeId: foursomeId,
              child: RabbitScreen(foursomeId: foursomeId)));
      case '/triple-cup-setup':
        return page((_) => TripleCupSetupScreen(
              foursomeId: _routeId(settings.arguments),
              returnToHub: _routeReturnToHub(settings.arguments)));
      case '/triple-cup':
        final foursomeId = settings.arguments as int;
        return page((_) => RoundLandscapeScorecard(
              foursomeId: foursomeId,
              child: TripleCupScreen(foursomeId: foursomeId)));
      case '/multi-skins-setup':
        return page((_) => MultiSkinsSetupScreen(
              roundId: _routeId(settings.arguments),
              returnToHub: _routeReturnToHub(settings.arguments)));
      case '/multi-skins':
        final roundId = settings.arguments as int;
        return page((_) => MultiSkinsScreen(roundId: roundId));
      case '/nassau-setup':
        return page((_) => NassauSetupScreen(
              foursomeId: _routeId(settings.arguments),
              returnToHub: _routeReturnToHub(settings.arguments)));
      case '/nassau-setup-18':
        return page((_) => NassauSetupScreen(
              foursomeId: _routeId(settings.arguments),
              overallOnly: true,
              returnToHub: _routeReturnToHub(settings.arguments)));
      case '/nassau-nine-setup':
        return page((_) => NassauSetupScreen(
              foursomeId: _routeId(settings.arguments),
              singleMatch: true,
              returnToHub: _routeReturnToHub(settings.arguments)));
      case '/nassau':
        final foursomeId = settings.arguments as int;
        return page((_) => RoundLandscapeScorecard(
              foursomeId: foursomeId,
              child: NassauScreen(foursomeId: foursomeId)));
      case '/leaderboard':
        // Arguments may be a plain int (legacy) or a Map with
        // {'roundId': int, 'initialTabKey': String?}.
        final args = settings.arguments;
        final roundId = args is Map ? args['roundId'] as int : args as int;
        final initialTabKey =
            args is Map ? args['initialTabKey'] as String? : null;
        return page((_) => LeaderboardScreen(
              roundId: roundId,
              initialTabKey: initialTabKey,
            ));
      case '/irish-rumble-setup':
        final roundId = settings.arguments as int;
        return page((_) => IrishRumbleSetupScreen(roundId: roundId));
      case '/low-net-setup':
        return page((_) => LowNetSetupScreen(
              roundId: _routeId(settings.arguments),
              returnToHub: _routeReturnToHub(settings.arguments)));
      case '/stableford-setup':
        return page((_) => StablefordSetupScreen(
              roundId: _routeId(settings.arguments),
              returnToHub: _routeReturnToHub(settings.arguments)));
      case '/pink-ball-setup':
        final roundId = settings.arguments as int;
        return page((_) => PinkBallSetupScreen(roundId: roundId));
      case '/pink-ball':
        final foursomeId = settings.arguments as int;
        return page((_) => RoundLandscapeScorecard(
              foursomeId: foursomeId,
              child: PinkBallScreen(foursomeId: foursomeId)));
      case '/tournament-leaderboard':
        final args           = settings.arguments as Map<String, dynamic>;
        final tournamentId   = args['tournamentId'] as int;
        final tournamentName = args['tournamentName'] as String? ?? '';
        return page((_) => TournamentLeaderboardScreen(
              tournamentId: tournamentId, tournamentName: tournamentName));
      case '/tournament-low-net-setup':
        final tournamentId = settings.arguments as int;
        return page((_) =>
            TournamentLowNetSetupScreen(tournamentId: tournamentId));
      case '/setup-round-players':
        final roundId = settings.arguments as int;
        return page((_) => SetupRoundPlayersScreen(roundId: roundId));
      case '/match-play-setup':
        // Arguments may be a plain int (legacy) or a Map with extra context.
        final args = settings.arguments;
        final int       foursomeId;
        final List<int> allMatchPlayIds;
        final List<int> peerIds;
        if (args is Map) {
          foursomeId      = _routeId(args);
          allMatchPlayIds = List<int>.from(args['allMatchPlayIds'] as List? ?? []);
          peerIds         = List<int>.from(args['peerIds']         as List? ?? []);
        } else {
          foursomeId      = args as int;
          allMatchPlayIds = [];
          peerIds         = [];
        }
        return page((_) => MatchPlaySetupScreen(
              foursomeId:      foursomeId,
              allMatchPlayIds: allMatchPlayIds,
              peerIds:         peerIds,
              returnToHub:     _routeReturnToHub(args),
            ));
      case '/match-play':
        final foursomeId = settings.arguments as int;
        return page((_) => RoundLandscapeScorecard(
              foursomeId: foursomeId,
              child: MatchPlayScreen(foursomeId: foursomeId)));
      case '/three-person-match-setup':
        return page((_) => ThreePersonMatchSetupScreen(
              foursomeId: _routeId(settings.arguments),
              returnToHub: _routeReturnToHub(settings.arguments)));
      case '/course-search':
        return page((_) => const CourseSearchScreen());
      case '/score-entry':
        final foursomeId = settings.arguments as int;
        return page((_) => RoundLandscapeScorecard(
              foursomeId: foursomeId,
              child: ScoreEntryScreen(foursomeId: foursomeId)));
      case '/confirm-tees':
        final foursomeId = settings.arguments as int;
        return page((_) => ConfirmTeesScreen(foursomeId: foursomeId));
      case '/quota-nassau':
        final foursomeId = settings.arguments as int;
        return page((_) => RoundLandscapeScorecard(
              foursomeId: foursomeId,
              child: QuotaNassauScreen(foursomeId: foursomeId)));
      default:
        // Unknown route — let MaterialApp.onUnknownRoute handle it (with
        // logging) so we never silently drop the user on a stray
        // LoginScreen the way the old default branch did.
        return null;
    }
  }
}
