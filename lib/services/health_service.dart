import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:health/health.dart';

const _kChannel = MethodChannel('com.example.bike_track/health_settings');

class HealthActivity {
  final String name;
  final DateTime startTime;
  final double distanceKm;
  final int durationMinutes;

  const HealthActivity({
    required this.name,
    required this.startTime,
    required this.distanceKm,
    required this.durationMinutes,
  });
}

enum HealthConnectStatus { available, notInstalled }

class HealthService {
  final _health = Health();

  static const _types = [HealthDataType.WORKOUT];

  static Future<void> configure() async {
    await Health().configure();
  }

  static bool _isCycling(HealthWorkoutActivityType type) {
    return type == HealthWorkoutActivityType.BIKING;
  }

  Future<HealthConnectStatus> checkAvailability() async {
    try {
      final status = await _health.getHealthConnectSdkStatus();
      if (status == HealthConnectSdkStatus.sdkAvailable) {
        return HealthConnectStatus.available;
      }
      return HealthConnectStatus.notInstalled;
    } catch (_) {
      return HealthConnectStatus.notInstalled;
    }
  }

  Future<void> promptInstall() async {
    await _health.installHealthConnect();
  }

  Future<void> openPermissionsScreen() async {
    try {
      await _kChannel.invokeMethod('openHCPermissions');
    } catch (e) {
      debugPrint('openPermissionsScreen: $e');
    }
  }

  Future<bool> hasPermissions() async {
    try {
      return (await _health.hasPermissions(_types)) == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestPermissions() async {
    try {
      return await _health.requestAuthorization(_types);
    } catch (e) {
      debugPrint('HealthService.requestPermissions: $e');
      return false;
    }
  }

  Future<List<HealthActivity>> getCyclingActivities({int daysBack = 90}) async {
    final now = DateTime.now();
    final start = now.subtract(Duration(days: daysBack));

    final points = await _health.getHealthDataFromTypes(
      startTime: start,
      endTime: now,
      types: _types,
    );

    final activities = <HealthActivity>[];
    for (final point in points) {
      if (point.type != HealthDataType.WORKOUT) continue;
      final value = point.value;
      if (value is! WorkoutHealthValue) continue;
      if (!_isCycling(value.workoutActivityType)) continue;

      final distM = value.totalDistance ?? 0.0;
      final duration = point.dateTo.difference(point.dateFrom).inMinutes;

      activities.add(HealthActivity(
        name: 'Cyklistika',
        startTime: point.dateFrom,
        distanceKm: distM / 1000.0,
        durationMinutes: duration,
      ));
    }

    activities.sort((a, b) => b.startTime.compareTo(a.startTime));
    return activities;
  }
}
