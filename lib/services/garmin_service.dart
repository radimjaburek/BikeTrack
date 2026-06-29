import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// Nastav URL svého backendu po nasazení
const _kBackendUrl = 'https://your-backend-server.com';
const _kCallbackScheme = 'biketrack';
const _kSessionKey = 'garmin_session_id';

class GarminActivity {
  final String activityId;
  final String name;
  final String type;
  final DateTime? startTime;
  final int durationInSeconds;
  final double distanceInMeters;
  final int? heartRate;
  final int? calories;

  const GarminActivity({
    required this.activityId,
    required this.name,
    required this.type,
    required this.startTime,
    required this.durationInSeconds,
    required this.distanceInMeters,
    this.heartRate,
    this.calories,
  });

  double get distanceKm => distanceInMeters / 1000;
  int get durationMinutes => durationInSeconds ~/ 60;

  factory GarminActivity.fromJson(Map<String, dynamic> json) {
    final epochSec = json['startTimeInSeconds'] as int?;
    final offset = json['startTimeOffsetInSeconds'] as int? ?? 0;
    DateTime? start;
    if (epochSec != null) {
      start = DateTime.fromMillisecondsSinceEpoch(
        (epochSec + offset) * 1000,
        isUtc: true,
      ).toLocal();
    }
    return GarminActivity(
      activityId: json['activityId']?.toString() ?? '',
      name: json['activityName'] as String? ?? 'Aktivita',
      type: json['activityType'] as String? ?? 'CYCLING',
      startTime: start,
      durationInSeconds: json['durationInSeconds'] as int? ?? 0,
      distanceInMeters: (json['distanceInMeters'] as num?)?.toDouble() ?? 0,
      heartRate: json['averageHeartRateInBeatsPerMinute'] as int?,
      calories: json['calories'] as int?,
    );
  }
}

class GarminService {
  String? _sessionId;

  static bool _isCycling(String type) {
    final t = type.toUpperCase();
    return t.contains('CYCLING') || t.contains('BIKE') || t == 'GRAVEL';
  }

  Future<String?> _loadSession() async {
    if (_sessionId != null) return _sessionId;
    final prefs = await SharedPreferences.getInstance();
    _sessionId = prefs.getString(_kSessionKey);
    return _sessionId;
  }

  Future<void> _saveSession(String id) async {
    _sessionId = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSessionKey, id);
  }

  Future<bool> isAuthenticated() async => (await _loadSession()) != null;

  /// Otevře Garmin OAuth přes backend. Vrátí true při úspěchu.
  Future<bool> authenticate() async {
    try {
      final initRes = await http.get(Uri.parse('$_kBackendUrl/auth/garmin/init'));
      if (initRes.statusCode != 200) return false;

      final authUrl =
          (jsonDecode(initRes.body) as Map<String, dynamic>)['auth_url'] as String?;
      if (authUrl == null) return false;

      final callbackUrl = await FlutterWebAuth2.authenticate(
        url: authUrl,
        callbackUrlScheme: _kCallbackScheme,
      );

      final uri = Uri.parse(callbackUrl);
      if (uri.host != 'auth-success') return false;

      final sessionId = uri.queryParameters['session_id'];
      if (sessionId == null) return false;

      await _saveSession(sessionId);
      return true;
    } catch (e) {
      debugPrint('GarminService.authenticate: $e');
      return false;
    }
  }

  /// Stáhne cyklistické aktivity z backendu.
  Future<List<GarminActivity>> fetchActivities() async {
    final sessionId = await _loadSession();
    if (sessionId == null) throw Exception('Nejsi přihlášen k Garmin');

    final res = await http.get(
      Uri.parse('$_kBackendUrl/activities'),
      headers: {'Authorization': 'Bearer $sessionId'},
    );

    if (res.statusCode == 401) {
      await logout();
      throw Exception('Garmin session vypršela – přihlas se znovu');
    }
    if (res.statusCode != 200) {
      throw Exception('Backend chyba ${res.statusCode}');
    }

    final list = (jsonDecode(res.body) as Map<String, dynamic>)['activities'] as List;
    return list
        .cast<Map<String, dynamic>>()
        .where((a) => _isCycling(a['activityType'] as String? ?? ''))
        .map(GarminActivity.fromJson)
        .toList();
  }

  Future<void> logout() async {
    _sessionId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSessionKey);
  }
}
