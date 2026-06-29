import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/health_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await HealthService.configure();
  runApp(const BikeTrackApp());
}

class BikeTrackApp extends StatelessWidget {
  const BikeTrackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BikeTrack',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const MainPage(),
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BikeTrack'),
        centerTitle: true,
        backgroundColor: Colors.black,
        foregroundColor: const Color(0xFF00FF41),
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: const [MapPage(), _ProfilePage()],
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: Colors.black,
        selectedItemColor: const Color(0xFF00FF41),
        unselectedItemColor: Colors.grey,
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Mapa'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profil'),
        ],
      ),
    );
  }
}

// ── Map type ──────────────────────────────────────────────────────────────────

enum _MapType { dark, satellite, neon }

// ── Grid ──────────────────────────────────────────────────────────────────────

class _Level {
  final double sizeM;
  final double minZoom;
  final Color lineColor;
  final double strokeWidth;

  const _Level({
    required this.sizeM,
    required this.minZoom,
    required this.lineColor,
    required this.strokeWidth,
  });

  double get stepLat => sizeM / 111320.0;
  double stepLng(double refLat) =>
      sizeM / (111320.0 * cos(refLat * pi / 180.0));
  int rowOf(double lat) => (lat / stepLat).floor();
  int colOf(double lng, double refLat) => (lng / stepLng(refLat)).floor();
  String cellKey(int row, int col) => '${sizeM.toInt()}_${row}_$col';
}

const _levels = [
  _Level(
    sizeM: 10,
    minZoom: 16,
    lineColor: Color(0x2200FF41),
    strokeWidth: 0.4,
  ),
  _Level(
    sizeM: 1000,
    minZoom: 11,
    lineColor: Color(0x330088FF),
    strokeWidth: 0.8,
  ),
  _Level(
    sizeM: 10000,
    minZoom: 8,
    lineColor: Color(0x33FF3300),
    strokeWidth: 1.6,
  ),
];

_Level? _activeLevel(double zoom) {
  for (final lv in _levels) {
    if (zoom >= lv.minZoom) return lv;
  }
  return null;
}

// ── Grid painter ──────────────────────────────────────────────────────────────

class _GridPainter extends CustomPainter {
  final MapCamera camera;
  final Set<String> clicked;

  _GridPainter({required this.camera, required this.clicked});

  Offset _s(LatLng ll) => camera.latLngToScreenOffset(ll);

  @override
  void paint(Canvas canvas, Size size) {
    final zoom = camera.zoom;
    final bounds = camera.visibleBounds;
    final refLat = camera.center.latitude.clamp(-85.0, 85.0);

    if (clicked.isNotEmpty) {
      final fillPaint = Paint()
        ..color = const Color(0x6600FF41)
        ..style = PaintingStyle.fill;
      for (final key in clicked) {
        final parts = key.split('_');
        if (parts.length != 3) continue;
        final sizeM = double.tryParse(parts[0]);
        final row = int.tryParse(parts[1]);
        final col = int.tryParse(parts[2]);
        if (sizeM == null || row == null || col == null) continue;
        final lv = _levels.where((l) => l.sizeM == sizeM).firstOrNull;
        if (lv == null || zoom < lv.minZoom) continue;
        final sLat = lv.stepLat;
        final sLng = lv.stepLng(refLat);
        final lat0 = row * sLat;
        final lng0 = col * sLng;
        final a = _s(LatLng(lat0, lng0));
        final b = _s(LatLng(lat0 + sLat, lng0));
        final c = _s(LatLng(lat0 + sLat, lng0 + sLng));
        final d = _s(LatLng(lat0, lng0 + sLng));
        canvas.drawPath(
          Path()
            ..moveTo(a.dx, a.dy)
            ..lineTo(b.dx, b.dy)
            ..lineTo(c.dx, c.dy)
            ..lineTo(d.dx, d.dy)
            ..close(),
          fillPaint,
        );
      }
    }

    for (final lv in _levels) {
      if (zoom < lv.minZoom) continue;
      final paint = Paint()
        ..color = lv.lineColor
        ..strokeWidth = lv.strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.square;
      final sLat = lv.stepLat;
      final sLng = lv.stepLng(refLat);

      final r0 = (bounds.south / sLat).floor();
      final r1 = (bounds.north / sLat).ceil();
      for (int r = r0; r <= r1; r++) {
        final lat = r * sLat;
        canvas.drawLine(
          _s(LatLng(lat, bounds.west)),
          _s(LatLng(lat, bounds.east)),
          paint,
        );
      }

      final c0 = (bounds.west / sLng).floor();
      final c1 = (bounds.east / sLng).ceil();
      for (int c = c0; c <= c1; c++) {
        final lng = c * sLng;
        canvas.drawLine(
          _s(LatLng(bounds.south, lng)),
          _s(LatLng(bounds.north, lng)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => true;
}

// ── Grid layer ────────────────────────────────────────────────────────────────

class _GridLayer extends StatelessWidget {
  final Set<String> clicked;
  const _GridLayer({required this.clicked});

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return RepaintBoundary(
      child: CustomPaint(
        painter: _GridPainter(camera: camera, clicked: clicked),
        child: const SizedBox.expand(),
      ),
    );
  }
}

// ── Map page ──────────────────────────────────────────────────────────────────

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final _ctrl = MapController();
  final _clicked = <String>{};
  LatLng? _myLocation;
  bool _centeredOnce = false;
  _MapType _mapType = _MapType.dark;

  @override
  void initState() {
    super.initState();
    _startLocation();
  }

  Future<void> _startLocation() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
    ).listen((pos) {
      final loc = LatLng(pos.latitude, pos.longitude);
      setState(() => _myLocation = loc);
      if (!_centeredOnce) {
        _centeredOnce = true;
        _ctrl.move(loc, 16.0);
      }
    });
  }

  void _onTap(TapPosition _, LatLng point) {
    final lv = _activeLevel(_ctrl.camera.zoom);
    if (lv == null) return;
    final refLat = _ctrl.camera.center.latitude;
    final key = lv.cellKey(
      lv.rowOf(point.latitude),
      lv.colOf(point.longitude, refLat),
    );
    setState(() {
      if (!_clicked.remove(key)) _clicked.add(key);
    });
  }

  Widget _buildTiles() {
    if (_mapType == _MapType.satellite) {
      return TileLayer(
        urlTemplate:
            'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
        userAgentPackageName: 'com.example.bike_track',
      );
    }
    return TileLayer(
      urlTemplate: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
      subdomains: const ['a', 'b', 'c', 'd'],
      userAgentPackageName: 'com.example.bike_track',
    );
  }

  Widget _mapBtn(_MapType type, IconData icon, String tooltip) {
    final active = _mapType == type;
    return IconButton(
      onPressed: () => setState(() => _mapType = type),
      icon: Icon(icon),
      tooltip: tooltip,
      iconSize: 20,
      color: active ? const Color(0xFF00FF41) : Colors.grey,
      style: active
          ? IconButton.styleFrom(backgroundColor: Colors.white12)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget map = FlutterMap(
      mapController: _ctrl,
      options: MapOptions(
        initialCenter: const LatLng(50.0, 15.0),
        initialZoom: 6.0,
        onTap: _onTap,
      ),
      children: [
        _buildTiles(),
        _GridLayer(clicked: _clicked),
        if (_myLocation != null)
          MarkerLayer(
            markers: [
              Marker(
                point: _myLocation!,
                width: 20,
                height: 20,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.blueAccent, width: 3),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.blue,
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
      ],
    );

    if (_mapType == _MapType.neon) {
      map = ColorFiltered(
        colorFilter: const ColorFilter.matrix([
          2.0, 0, 0, 0, -80,
          0, 2.0, 0, 0, -80,
          0, 0, 2.0, 0, -80,
          0, 0, 0, 1, 0,
        ]),
        child: map,
      );
    }

    return Stack(
      children: [
        map,
        Positioned(
          top: 8,
          right: 8,
          child: Card(
            color: Colors.black87,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _mapBtn(_MapType.dark, Icons.dark_mode, 'Tmavá'),
                _mapBtn(_MapType.satellite, Icons.satellite_alt, 'Satelit'),
                _mapBtn(_MapType.neon, Icons.auto_awesome, 'Neon'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Route model ───────────────────────────────────────────────────────────────

class _Route {
  final String name;
  final DateTime? date;
  final double distanceKm;

  const _Route({
    required this.name,
    required this.date,
    required this.distanceKm,
  });
}


// ── Profile page ──────────────────────────────────────────────────────────────

class _ProfilePage extends StatefulWidget {
  const _ProfilePage();

  @override
  State<_ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<_ProfilePage> {
  final List<_Route> _routes = [];
  bool _hcConnected = false;
  bool _connecting = false;
  bool _loadingActivities = false;
  final _health = HealthService();

  static const _prefKey = 'hc_connected';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final hasPerms = await _health.hasPermissions();
    if (!mounted) return;
    if (hasPerms) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, true);
      setState(() => _hcConnected = true);
      _loadActivities();
    }
  }

  Future<void> _connect() async {
    setState(() => _connecting = true);
    try {
      final already = await _health.hasPermissions();
      if (!mounted) return;
      if (already) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_prefKey, true);
        setState(() => _hcConnected = true);
        _loadActivities();
        return;
      }

      final granted = await _health.requestPermissions();
      if (!mounted) return;
      if (granted) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_prefKey, true);
        setState(() => _hcConnected = true);
        _loadActivities();
      } else {
        await _health.openPermissionsScreen();
      }
    } catch (_) {
      if (!mounted) return;
      await _health.promptInstall();
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _disconnect() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, false);
    setState(() {
      _hcConnected = false;
      _routes.clear();
    });
  }

  Future<void> _loadActivities() async {
    setState(() => _loadingActivities = true);
    try {
      final activities = await _health.getCyclingActivities();
      if (!mounted) return;
      setState(() {
        _routes
          ..clear()
          ..addAll(activities.map((a) => _Route(
                name: a.name,
                date: a.startTime,
                distanceKm: a.distanceKm,
              )));
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingActivities = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalKm = _routes.fold(0.0, (s, r) => s + r.distanceKm);

    return Column(children: [
      // ── Připojení ──────────────────────────────────────────────────────────
      _HcCard(
        connected: _hcConnected,
        loading: _connecting,
        onConnect: _connect,
        onDisconnect: _disconnect,
      ),
      // ── Garmin info ────────────────────────────────────────────────────────
      if (_hcConnected)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Row(children: [
            const Icon(Icons.watch, color: Color(0xFF0066CC), size: 14),
            const SizedBox(width: 6),
            Text('Garmin Connect synchronizuje automaticky',
                style: TextStyle(fontSize: 11, color: Colors.grey[600])),
          ]),
        ),
      // ── Stats ──────────────────────────────────────────────────────────────
      if (_hcConnected)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF0A0A0A),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            const Icon(Icons.route, color: Color(0xFF00FF41), size: 14),
            const SizedBox(width: 8),
            Text('${_routes.length} tras · ${totalKm.toStringAsFixed(1)} km',
                style: TextStyle(color: Colors.grey[400], fontSize: 13)),
            if (_loadingActivities) ...[
              const SizedBox(width: 10),
              const SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFF00FF41)),
              ),
            ],
          ]),
        ),
      const SizedBox(height: 8),
      const Divider(height: 1, color: Color(0xFF1A1A1A)),
      // ── Trasy ──────────────────────────────────────────────────────────────
      Expanded(
        child: _routes.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.directions_bike, size: 56, color: Colors.grey[800]),
                const SizedBox(height: 12),
                Text(
                  _hcConnected
                      ? 'Žádné cyklistické aktivity\nv Health Connect'
                      : 'Připoj Health Connect\na jízdy se načtou automaticky',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.grey[600], fontSize: 13, height: 1.5),
                ),
              ]))
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: _routes.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: Color(0xFF1A1A1A)),
                itemBuilder: (context, i) {
                  final r = _routes[i];
                  final d = r.date;
                  final dateStr =
                      d != null ? '${d.day}.${d.month}.${d.year}' : '—';
                  return ListTile(
                    leading: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: const Color(0xFF111111),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.directions_bike,
                          color: Color(0xFF00FF41), size: 18),
                    ),
                    title: Text(r.name,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '$dateStr · ${r.distanceKm.toStringAsFixed(2)} km',
                        style:
                            TextStyle(color: Colors.grey[600], fontSize: 11)),
                  );
                },
              ),
      ),
    ]);
  }
}

// ── Health Connect card ───────────────────────────────────────────────────────

class _HcCard extends StatelessWidget {
  final bool connected;
  final bool loading;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  const _HcCard({
    required this.connected,
    required this.loading,
    required this.onConnect,
    required this.onDisconnect,
  });

  static const _blue = Color(0xFF1A73E8);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: connected
              ? _blue.withValues(alpha: 0.5)
              : const Color(0xFF1F1F1F),
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: _blue.withValues(alpha: connected ? 0.2 : 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.health_and_safety, color: _blue, size: 22),
        ),
        title: Row(children: [
          const Text('Health Connect',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          if (connected) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF00FF41).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('Připojeno',
                  style: TextStyle(
                      fontSize: 10,
                      color: Color(0xFF00FF41),
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2)),
            ),
          ],
        ]),
        subtitle: connected
            ? null
            : const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text('Klikni pro připojení',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ),
        trailing: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: _blue),
              )
            : connected
                ? IconButton(
                    icon: Icon(Icons.link_off,
                        color: Colors.grey[600], size: 18),
                    onPressed: onDisconnect,
                    tooltip: 'Odpojit',
                  )
                : FilledButton(
                    onPressed: onConnect,
                    style: FilledButton.styleFrom(
                      backgroundColor: _blue,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Připojit',
                        style: TextStyle(fontSize: 12)),
                  ),
      ),
    );
  }
}


