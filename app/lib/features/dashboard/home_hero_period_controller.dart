import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum HeroPeriod { day, week, month }

/// A device preference, loaded before Home's first frame.
class HomeHeroPeriodController extends StateNotifier<HeroPeriod> {
  HomeHeroPeriodController() : super(_initial);

  static const preferenceKey = 'home_hero_period';
  static HeroPeriod _initial = HeroPeriod.month;
  static Future<void> _pendingWrite = Future<void>.value();

  static Future<void> preload() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getString(preferenceKey);
    _initial = HeroPeriod.values.firstWhere(
      (period) => period.name == saved,
      orElse: () => HeroPeriod.month,
    );
  }

  Future<void> select(HeroPeriod period) {
    state = period;
    _initial = period;
    // Rapid taps and replacement provider scopes must persist in tap order.
    final write = _pendingWrite.then((_) async {
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.setString(preferenceKey, period.name)) {
        throw StateError('home_period_not_saved');
      }
    });
    _pendingWrite =
        write.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return write;
  }
}
