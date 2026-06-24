import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:xml/xml.dart';

// Zaregistruj svou aplikaci na https://www.strava.com/settings/api
// a vyplň níže client_id a client_secret.
const _stravaClientId = 'YOUR_CLIENT_ID';
const _stravaClientSecret = 'YOUR_CLIENT_SECRET';

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

// ── GPX parsing ───────────────────────────────────────────────────────────────

double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * pi / 180;
  final dLon = (lon2 - lon1) * pi / 180;
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180) *
          cos(lat2 * pi / 180) *
          sin(dLon / 2) *
          sin(dLon / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

_Route? _parseGpx(String content, String fileName) {
  try {
    final doc = XmlDocument.parse(content);
    final trkName = doc.findAllElements('name').firstOrNull?.innerText.trim();
    final timeStr = doc.findAllElements('time').firstOrNull?.innerText.trim();
    final DateTime? date = timeStr != null ? DateTime.tryParse(timeStr) : null;
    final points = doc.findAllElements('trkpt').toList();
    double dist = 0;
    for (int i = 1; i < points.length; i++) {
      final lat1 =
          double.tryParse(points[i - 1].getAttribute('lat') ?? '') ?? 0;
      final lon1 =
          double.tryParse(points[i - 1].getAttribute('lon') ?? '') ?? 0;
      final lat2 = double.tryParse(points[i].getAttribute('lat') ?? '') ?? 0;
      final lon2 = double.tryParse(points[i].getAttribute('lon') ?? '') ?? 0;
      dist += _haversineKm(lat1, lon1, lat2, lon2);
    }
    return _Route(
      name: (trkName != null && trkName.isNotEmpty) ? trkName : fileName,
      date: date,
      distanceKm: dist,
    );
  } catch (_) {
    return null;
  }
}

// ── Profile page ──────────────────────────────────────────────────────────────

class _ProfilePage extends StatefulWidget {
  const _ProfilePage();

  @override
  State<_ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<_ProfilePage> {
  final List<_Route> _routes = [];
  bool _stravaLoading = false;
  StreamSubscription? _intentSub;

  static const _bikeTypes = {
    'Ride', 'VirtualRide', 'MountainBikeRide',
    'GravelRide', 'EBikeRide', 'EMountainBikeRide',
  };

  @override
  void initState() {
    super.initState();
    // Příjem GPX sdíleného z Garmin Connect (app bylo zavřené)
    ReceiveSharingIntent.instance
        .getInitialMedia()
        .then(_handleSharedFiles);
    // Příjem GPX sdíleného z Garmin Connect (app běží na pozadí)
    _intentSub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_handleSharedFiles);
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    super.dispose();
  }

  Future<void> _handleSharedFiles(List<SharedMediaFile> files) async {
    for (final f in files) {
      final path = f.path;
      if (!path.toLowerCase().endsWith('.gpx')) continue;
      try {
        final content = await File(path).readAsString();
        final name = path.split('/').last;
        final route = _parseGpx(content, name);
        if (route != null && mounted) {
          setState(() => _routes.add(route));
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Přidána: ${route.name}'),
            backgroundColor: const Color(0xFF00FF41),
            behavior: SnackBarBehavior.floating,
          ));
        }
      } catch (_) {}
    }
  }

  // ── Strava OAuth ────────────────────────────────────────────────────────────

  Future<void> _loadStrava() async {
    setState(() => _stravaLoading = true);
    try {
      final authUri = Uri.https('www.strava.com', '/oauth/mobile/authorize', {
        'client_id': _stravaClientId,
        'redirect_uri': 'biketrack://oauth-callback',
        'response_type': 'code',
        'approval_prompt': 'auto',
        'scope': 'activity:read_all',
      });

      final result = await FlutterWebAuth2.authenticate(
        url: authUri.toString(),
        callbackUrlScheme: 'biketrack',
      );

      final code = Uri.parse(result).queryParameters['code'];
      if (code == null) throw Exception('Chybí kód od Strava');

      final tokenRes = await http.post(
        Uri.https('www.strava.com', '/oauth/token'),
        body: {
          'client_id': _stravaClientId,
          'client_secret': _stravaClientSecret,
          'code': code,
          'grant_type': 'authorization_code',
        },
      );
      if (tokenRes.statusCode != 200) {
        throw Exception('Token chyba ${tokenRes.statusCode}');
      }

      final token =
          (jsonDecode(tokenRes.body) as Map)['access_token'] as String?;
      if (token == null) throw Exception('Chybí access_token');

      final after = DateTime.now()
              .subtract(const Duration(days: 90))
              .millisecondsSinceEpoch ~/
          1000;

      final actRes = await http.get(
        Uri.https('www.strava.com', '/api/v3/athlete/activities', {
          'per_page': '100',
          'after': '$after',
        }),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (actRes.statusCode != 200) {
        throw Exception('API chyba ${actRes.statusCode}');
      }

      final all =
          (jsonDecode(actRes.body) as List).cast<Map<String, dynamic>>();
      final rides = all
          .where((a) => _bikeTypes.contains(a['type']))
          .map((a) => _Route(
                name: a['name'] as String? ?? 'Jízda',
                date: DateTime.tryParse(
                    a['start_date_local'] as String? ?? ''),
                distanceKm: ((a['distance'] as num?) ?? 0) / 1000,
              ))
          .toList();

      if (!mounted) return;
      if (rides.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Žádné jízdy za posledních 90 dní'),
          backgroundColor: Color(0xFF333333),
          behavior: SnackBarBehavior.floating,
        ));
        return;
      }
      _showRidesSheet(rides);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Strava: $e'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _stravaLoading = false);
    }
  }

  void _showRidesSheet(List<_Route> rides) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D0D0D),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        expand: false,
        builder: (_, scroll) => Column(children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[700],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(children: [
              Text('${rides.length} jízd ze Strava',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              TextButton(
                onPressed: () {
                  setState(() => _routes.addAll(rides));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('${rides.length} tras přidáno'),
                    backgroundColor: const Color(0xFF00FF41),
                    behavior: SnackBarBehavior.floating,
                  ));
                },
                child: const Text('Přidat vše',
                    style: TextStyle(color: Color(0xFF00FF41))),
              ),
            ]),
          ),
          const Divider(height: 1, color: Color(0xFF1A1A1A)),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              itemCount: rides.length,
              itemBuilder: (_, i) {
                final r = rides[i];
                final d = r.date;
                return ListTile(
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF111111),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.directions_bike,
                        color: Color(0xFF00FF41), size: 20),
                  ),
                  title: Text(r.name,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    d != null
                        ? '${d.day}.${d.month}.${d.year}  ·  ${r.distanceKm.toStringAsFixed(1)} km'
                        : '${r.distanceKm.toStringAsFixed(1)} km',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.add_circle,
                        color: Color(0xFF00FF41), size: 28),
                    onPressed: () {
                      setState(() => _routes.add(r));
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(
                        content: Text('Trasa přidána'),
                        backgroundColor: Color(0xFF00FF41),
                        behavior: SnackBarBehavior.floating,
                      ));
                    },
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  // ── Garmin instructions ─────────────────────────────────────────────────────

  void _showGarminHelp() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D0D0D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              color: Colors.grey[700],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.watch, color: Color(0xFF0066CC), size: 22),
            ),
            const SizedBox(width: 12),
            const Text('Sdílení z Garmin Connect',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 20),
          _garminStep('1', 'Otevři Garmin Connect a tap na aktivitu'),
          _garminStep('2', 'Klikni na ··· (tři tečky) vpravo nahoře'),
          _garminStep('3', 'Vyber „Sdílet aktivitu"'),
          _garminStep('4', 'Tap „Exportovat soubor" → vyber GPX'),
          _garminStep('5', 'Ze sdílení vyber BikeTrack'),
          const SizedBox(height: 4),
          Text(
            'Aktivita se přidá automaticky hned po sdílení.',
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
        ]),
      ),
    );
  }

  Widget _garminStep(String num, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: const Color(0xFF0066CC),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Text(num,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(text,
                style: const TextStyle(fontSize: 14, height: 1.4)),
          ),
        ),
      ]),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final totalKm = _routes.fold(0.0, (s, r) => s + r.distanceKm);
    return Column(children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        color: const Color(0xFF0A0A0A),
        child: Row(children: [
          const Icon(Icons.route, color: Color(0xFF00FF41), size: 16),
          const SizedBox(width: 8),
          Text('${_routes.length} tras  ·  ${totalKm.toStringAsFixed(1)} km',
              style: TextStyle(color: Colors.grey[400], fontSize: 13)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _stravaLoading ? null : _loadStrava,
            icon: _stravaLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.directions_bike),
            label:
                Text(_stravaLoading ? 'Načítám...' : 'Načíst jízdy ze Strava'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFC4C02),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _showGarminHelp,
            icon: const Icon(Icons.watch, size: 18),
            label: const Text('Přidat z Garmin Connect'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF0066CC),
              side: const BorderSide(color: Color(0xFF0066CC), width: 1),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ),
      const Divider(height: 1, color: Color(0xFF1A1A1A)),
      Expanded(
        child: _routes.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.directions_bike,
                    size: 64, color: Colors.grey[800]),
                const SizedBox(height: 12),
                const Text('Žádné trasy',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(
                  'Načti ze Strava nebo sdílej\naktivitu z Garmin Connect',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.grey[600], fontSize: 13, height: 1.5),
                ),
              ]))
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _routes.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: Color(0xFF1A1A1A)),
                itemBuilder: (context, i) {
                  final r = _routes[i];
                  final dateStr = r.date != null
                      ? '${r.date!.day}.${r.date!.month}.${r.date!.year}'
                      : '—';
                  return Dismissible(
                    key: ValueKey(
                        '${r.date?.millisecondsSinceEpoch ?? i}_${r.name}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      color: Colors.red[900],
                      child: const Icon(Icons.delete_outline,
                          color: Colors.white),
                    ),
                    onDismissed: (_) =>
                        setState(() => _routes.removeAt(i)),
                    child: ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xFF111111),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.directions_bike,
                            color: Color(0xFF00FF41), size: 20),
                      ),
                      title: Text(r.name,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          '$dateStr  ·  ${r.distanceKm.toStringAsFixed(2)} km',
                          style: TextStyle(
                              color: Colors.grey[600], fontSize: 11)),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}
