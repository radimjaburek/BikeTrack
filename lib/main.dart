import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';
import 'package:file_picker/file_picker.dart';
import 'package:xml/xml.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

void main() => runApp(const BikeTrackApp());

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
  final List<_GpxRoute> _routes = [];
  StreamSubscription<List<SharedMediaFile>>? _shareSub;

  @override
  void initState() {
    super.initState();
    _shareSub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_onShared, onError: (_) {});
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      if (files.isNotEmpty) {
        _onShared(files);
        ReceiveSharingIntent.instance.reset();
      }
    });
  }

  Future<void> _onShared(List<SharedMediaFile> files) async {
    final added = <_GpxRoute>[];
    for (final f in files) {
      if (!f.path.toLowerCase().endsWith('.gpx')) continue;
      try {
        final content = await File(f.path).readAsString();
        final route = _parseGpx(content, f.path.split('/').last);
        if (route != null) added.add(route);
      } catch (_) {}
    }
    if (added.isNotEmpty && mounted) {
      setState(() { _routes.addAll(added); _currentIndex = 1; });
    }
  }

  void _addRoutes(List<_GpxRoute> routes) => setState(() => _routes.addAll(routes));
  void _removeRoute(int i) => setState(() => _routes.removeAt(i));

  @override
  void dispose() {
    _shareSub?.cancel();
    super.dispose();
  }

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
        children: [
          const MapPage(),
          _ProfilePage(routes: _routes, onAdd: _addRoutes, onRemove: _removeRoute),
        ],
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
  double stepLng(double refLat) => sizeM / (111320.0 * cos(refLat * pi / 180.0));
  int rowOf(double lat) => (lat / stepLat).floor();
  int colOf(double lng, double refLat) => (lng / stepLng(refLat)).floor();
  String cellKey(int row, int col) => '${sizeM.toInt()}_${row}_$col';
}

// 10m → 1 km (100×100 of 10m) → 100 km (100×100 of 1km)
const _levels = [
  _Level(sizeM: 10,     minZoom: 16, lineColor: Color(0x2200FF41), strokeWidth: 0.4),
  _Level(sizeM: 1000,   minZoom: 11, lineColor: Color(0x330088FF), strokeWidth: 0.8),
  _Level(sizeM: 10000,  minZoom:  8, lineColor: Color(0x33FF3300), strokeWidth: 1.6),
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

    // Filled clicked cells
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

    // Grid lines — fine first, coarse on top
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
        canvas.drawLine(_s(LatLng(lat, bounds.west)), _s(LatLng(lat, bounds.east)), paint);
      }

      final c0 = (bounds.west / sLng).floor();
      final c1 = (bounds.east / sLng).ceil();
      for (int c = c0; c <= c1; c++) {
        final lng = c * sLng;
        canvas.drawLine(_s(LatLng(bounds.south, lng)), _s(LatLng(bounds.north, lng)), paint);
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
    final key = lv.cellKey(lv.rowOf(point.latitude), lv.colOf(point.longitude, refLat));
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
      style: active ? IconButton.styleFrom(backgroundColor: Colors.white12) : null,
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
          MarkerLayer(markers: [
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
                    BoxShadow(color: Colors.blue, blurRadius: 8, spreadRadius: 2),
                  ],
                ),
              ),
            ),
          ]),
      ],
    );

    if (_mapType == _MapType.neon) {
      map = ColorFiltered(
        colorFilter: const ColorFilter.matrix([
          2.0, 0,   0,   0, -80,
          0,   2.0, 0,   0, -80,
          0,   0,   2.0, 0, -80,
          0,   0,   0,   1,   0,
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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

// ── Imported route model ──────────────────────────────────────────────────────

class _GpxRoute {
  final String name;
  final DateTime? date;
  final double distanceKm;
  final int pointCount;

  const _GpxRoute({
    required this.name,
    required this.date,
    required this.distanceKm,
    required this.pointCount,
  });
}

double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * pi / 180;
  final dLon = (lon2 - lon1) * pi / 180;
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLon / 2) * sin(dLon / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

_GpxRoute? _parseGpx(String content, String fileName) {
  try {
    final doc = XmlDocument.parse(content);
    final trkName = doc.findAllElements('name').firstOrNull?.innerText.trim();
    final timeStr = doc.findAllElements('time').firstOrNull?.innerText.trim();
    final DateTime? date = timeStr != null ? DateTime.tryParse(timeStr) : null;
    final points = doc.findAllElements('trkpt').toList();
    double dist = 0;
    for (int i = 1; i < points.length; i++) {
      final lat1 = double.tryParse(points[i - 1].getAttribute('lat') ?? '') ?? 0;
      final lon1 = double.tryParse(points[i - 1].getAttribute('lon') ?? '') ?? 0;
      final lat2 = double.tryParse(points[i].getAttribute('lat') ?? '') ?? 0;
      final lon2 = double.tryParse(points[i].getAttribute('lon') ?? '') ?? 0;
      dist += _haversineKm(lat1, lon1, lat2, lon2);
    }
    return _GpxRoute(
      name: (trkName != null && trkName.isNotEmpty) ? trkName : fileName,
      date: date,
      distanceKm: dist,
      pointCount: points.length,
    );
  } catch (_) {
    return null;
  }
}

// ── Profile page ──────────────────────────────────────────────────────────────

class _ProfilePage extends StatefulWidget {
  final List<_GpxRoute> routes;
  final void Function(List<_GpxRoute>) onAdd;
  final void Function(int) onRemove;
  const _ProfilePage({required this.routes, required this.onAdd, required this.onRemove});

  @override
  State<_ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<_ProfilePage> {
  bool _loading = false;

  Future<void> _pickFile() async {
    setState(() => _loading = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any, allowMultiple: true, withData: true);
      if (result == null) return;
      final added = <_GpxRoute>[];
      for (final f in result.files) {
        if (!f.name.toLowerCase().endsWith('.gpx')) continue;
        final bytes = f.bytes;
        if (bytes == null) continue;
        final route = _parseGpx(String.fromCharCodes(bytes), f.name);
        if (route != null) added.add(route);
      }
      if (added.isNotEmpty) {
        widget.onAdd(added);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${added.length} trasa přidána'),
            backgroundColor: const Color(0xFF00FF41),
            behavior: SnackBarBehavior.floating,
          ));
        }
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final routes = widget.routes;
    final totalKm = routes.fold(0.0, (s, r) => s + r.distanceKm);

    return Scaffold(
      backgroundColor: Colors.black,
      floatingActionButton: FloatingActionButton(
        onPressed: _loading ? null : _pickFile,
        backgroundColor: const Color(0xFF00FF41),
        foregroundColor: Colors.black,
        child: _loading
            ? const SizedBox(width: 22, height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black))
            : const Icon(Icons.add),
      ),
      body: routes.isEmpty
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.directions_bike, size: 72, color: Colors.grey[800]),
                const SizedBox(height: 16),
                const Text('Žádné trasy',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text('Sdílej GPX z Garmin Connect\nnebo klepni na +',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey[600], fontSize: 14, height: 1.5)),
              ]),
            )
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(children: [
                  const Icon(Icons.route, color: Color(0xFF00FF41), size: 16),
                  const SizedBox(width: 8),
                  Text('${routes.length} tras  ·  ${totalKm.toStringAsFixed(1)} km',
                      style: TextStyle(color: Colors.grey[400], fontSize: 13)),
                ]),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: routes.length,
                  separatorBuilder: (_, i2) =>
                      const Divider(height: 1, indent: 72, color: Color(0xFF1A1A1A)),
                  itemBuilder: (context, i) {
                    final r = routes[i];
                    final dateStr = r.date != null
                        ? '${r.date!.day}.${r.date!.month}.${r.date!.year}'
                        : '—';
                    return Dismissible(
                      key: ValueKey('$i${r.name}'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        color: Colors.red[900],
                        child: const Icon(Icons.delete_outline, color: Colors.white),
                      ),
                      onDismissed: (_) => widget.onRemove(i),
                      child: ListTile(
                        leading: Container(
                          width: 44, height: 44,
                          decoration: BoxDecoration(
                            color: const Color(0xFF111111),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.directions_bike,
                              color: Color(0xFF00FF41), size: 22),
                        ),
                        title: Text(r.name,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            '$dateStr  ·  ${r.distanceKm.toStringAsFixed(2)} km',
                            style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                      ),
                    );
                  },
                ),
              ),
            ]),
    );
  }
}
