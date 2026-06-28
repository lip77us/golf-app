import 'package:flutter/widgets.dart';

/// App-wide route observer. Screens that need to refresh when the user
/// navigates BACK to them (a route on top is popped) can mix in [RouteAware],
/// subscribe to this observer in `didChangeDependencies`, and override
/// `didPopNext()`.
///
/// Wired into `MaterialApp.navigatorObservers` in main.dart.
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();
