import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How often every host is pinged.
const _pingInterval = Duration(seconds: 5);

/// A host is reported down only after this long without a successful ping.
const _downThreshold = Duration(seconds: 10);

const _notifChannelId = 'link_monitor_v1';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final monitor = MonitorService(prefs);
  await monitor.init();
  runApp(LinkMonitorApp(monitor: monitor));
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

class HostEntry {
  HostEntry({
    required this.name,
    required this.ip,
    required this.addedAt,
    this.isUp,
    this.latencyMs,
    this.lastSuccess,
    this.downNotified = false,
  });

  String name;
  String ip;
  bool? isUp; // null = not checked yet
  int? latencyMs;
  DateTime? lastSuccess;
  DateTime addedAt;
  bool downNotified;

  Map<String, dynamic> toJson() => {
        'name': name,
        'ip': ip,
        'addedAt': addedAt.millisecondsSinceEpoch,
      };

  factory HostEntry.fromJson(Map<String, dynamic> j) => HostEntry(
        name: (j['name'] ?? '').toString(),
        ip: (j['ip'] ?? '').toString(),
        addedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['addedAt'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch),
      );
}

// ---------------------------------------------------------------------------
// Ping
// ---------------------------------------------------------------------------

/// Returns latency in ms, or null when the host did not answer.
Future<int?> pingHost(String ip) async {
  // 1) Try the OS ping binary (ICMP, no root needed on Android).
  try {
    final args = Platform.isWindows
        ? ['-n', '1', '-w', '2000', ip]
        : ['-c', '1', '-W', '2', ip];
    final res =
        await Process.run('ping', args).timeout(const Duration(seconds: 5));
    if (res.exitCode == 0) {
      final m = RegExp(r'time[=<]([\d.]+)\s?ms')
          .firstMatch(res.stdout.toString());
      if (m != null) return double.parse(m.group(1)!).round();
      return 0;
    }
  } catch (_) {
    // fall through to TCP fallback
  }

  // 2) Fallback: TCP connect to common ports (works when the ping binary
  //    is missing but the network stack is reachable).
  for (final port in [80, 443]) {
    try {
      final sw = Stopwatch()..start();
      final socket = await Socket.connect(ip, port,
          timeout: const Duration(seconds: 2));
      socket.destroy();
      return sw.elapsedMilliseconds;
    } catch (_) {}
  }
  return null;
}

// ---------------------------------------------------------------------------
// Monitor service
// ---------------------------------------------------------------------------

class MonitorService extends ChangeNotifier {
  MonitorService(this._prefs);

  final SharedPreferences _prefs;
  final FlutterLocalNotificationsPlugin _notif =
      FlutterLocalNotificationsPlugin();

  final List<HostEntry> hosts = [];
  Timer? _timer;
  bool _checking = false;

  int get upCount => hosts.where((h) => h.isUp == true).length;
  int get downCount => hosts.where((h) => h.isUp == false).length;

  Future<void> init() async {
    _load();
    await _initNotifications();
    await _requestPermission();
    _timer = Timer.periodic(_pingInterval, (_) => _checkAll());
    unawaited(_checkAll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Public entry used by pull-to-refresh.
  Future<void> checkNow() => _checkAll();

  // -- persistence ----------------------------------------------------------

  void _load() {
    try {
      final raw = _prefs.getString('hosts_v1');
      if (raw == null) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      hosts
        ..clear()
        ..addAll(list.map(HostEntry.fromJson).where((h) => h.ip.isNotEmpty));
    } catch (_) {}
  }

  void _save() {
    try {
      _prefs.setString(
          'hosts_v1', jsonEncode(hosts.map((h) => h.toJson()).toList()));
    } catch (_) {}
  }

  // -- notifications --------------------------------------------------------

  Future<void> _initNotifications() async {
    // Desktop platforms (Linux/Windows/macOS) have no notification setup
    // here; skip quietly instead of crashing startup.
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _notif.initialize(settings: settings);
      const channel = AndroidNotificationChannel(
        _notifChannelId,
        'Link Monitor',
        description: 'Link up/down alerts',
        importance: Importance.high,
      );
      await _notif
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);
    } catch (_) {}
  }

  Future<void> _requestPermission() async {
    await _notif
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  int _idFor(String ip, int salt) => (ip.hashCode ^ salt) & 0x7fffffff;

  Future<void> _notifyDown(HostEntry h) => _notif.show(
        id: _idFor(h.ip, 0xD09A),
        title: '${h.name} link is down',
        body: 'No ping reply for 10 seconds \u2022 ${h.ip}',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _notifChannelId,
            'Link Monitor',
            channelDescription: 'Link up/down alerts',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );

  Future<void> _notifyUp(HostEntry h) => _notif.show(
        id: _idFor(h.ip, 0x9E11),
        title: '${h.name} link is back up',
        body: 'Ping reply received \u2022 ${h.ip}',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _notifChannelId,
            'Link Monitor',
            channelDescription: 'Link up/down alerts',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );

  // -- monitoring loop ------------------------------------------------------

  Future<void> _checkAll() async {
    if (_checking || hosts.isEmpty) return;
    _checking = true;
    try {
      await Future.wait(hosts.map(_pingAndUpdate));
    } finally {
      _checking = false;
      _save();
      notifyListeners();
    }
  }

  Future<void> _pingAndUpdate(HostEntry h) async {
    final ms = await pingHost(h.ip);
    final now = DateTime.now();
    if (ms != null) {
      final wasDown = h.isUp == false;
      h.isUp = true;
      h.latencyMs = ms;
      h.lastSuccess = now;
      h.downNotified = false;
      if (wasDown) {
        try {
          await _notifyUp(h);
        } catch (_) {}
      }
    } else {
      h.isUp = false;
      h.latencyMs = null;
      final ref = h.lastSuccess ?? h.addedAt;
      if (!h.downNotified && now.difference(ref) >= _downThreshold) {
        h.downNotified = true;
        try {
          await _notifyDown(h);
        } catch (_) {}
      }
    }
  }

  // -- mutations ------------------------------------------------------------

  /// Imports Name/IP rows from an .xlsx/.xls file. Returns a status message.
  Future<String> importExcel() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
      );
      if (files.isEmpty) {
        return 'No file selected';
      }
      final bytes = await files.first.readAsBytes();
      final excel = Excel.decodeBytes(bytes);
      if (excel.tables.isEmpty) return 'No sheets found in file';
      final rows = excel.tables[excel.tables.keys.first]!.rows;
      if (rows.isEmpty) return 'Sheet is empty';

      int start = 0;
      final head = rows.first
          .map((c) => (c?.value?.toString() ?? '').toLowerCase())
          .join(' ');
      if (head.contains('name') ||
          head.contains('ip') ||
          head.contains('host')) {
        start = 1;
      }

      int added = 0;
      for (var i = start; i < rows.length; i++) {
        final row = rows[i];
        final name =
            row.isNotEmpty ? (row[0]?.value?.toString().trim() ?? '') : '';
        final ip =
            row.length > 1 ? (row[1]?.value?.toString().trim() ?? '') : '';
        if (ip.isEmpty) continue;
        if (hosts.any((h) => h.ip == ip)) continue;
        hosts.add(HostEntry(
          name: name.isEmpty ? ip : name,
          ip: ip,
          addedAt: DateTime.now(),
        ));
        added++;
      }
      _save();
      notifyListeners();
      unawaited(_checkAll());
      return added == 0
          ? 'No new hosts found (duplicates skipped)'
          : 'Added $added host${added == 1 ? '' : 's'}';
    } catch (e) {
      return 'Could not read file: $e';
    }
  }

  void loadDemo() {
    for (final d in [
      ('Google DNS', '8.8.8.8'),
      ('Cloudflare DNS', '1.1.1.1'),
      ('Demo Down Host', '192.0.2.1'),
    ]) {
      if (hosts.any((h) => h.ip == d.$2)) continue;
      hosts.add(HostEntry(name: d.$1, ip: d.$2, addedAt: DateTime.now()));
    }
    _save();
    notifyListeners();
    unawaited(_checkAll());
  }

  void removeHost(HostEntry h) {
    hosts.remove(h);
    _save();
    notifyListeners();
  }

  void clearAll() {
    hosts.clear();
    _save();
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// UI
// ---------------------------------------------------------------------------

class LinkMonitorApp extends StatelessWidget {
  const LinkMonitorApp({super.key, required this.monitor});

  final MonitorService monitor;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Link Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF070B16),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF22D3EE),
          brightness: Brightness.dark,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF111A2E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF1E2A45)),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
        ),
      ),
      home: HomeScreen(monitor: monitor),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.monitor});

  final MonitorService monitor;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0E1B3D), Color(0xFF070B16)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF22D3EE), Color(0xFF3B82F6)],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.radar, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Link Monitor',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
                Text('live ping status',
                    style: TextStyle(fontSize: 12, color: Colors.white60)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'About',
            icon: const Icon(Icons.info_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AboutPage()),
            ),
          ),
          IconButton(
            tooltip: 'Clear all',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => _confirmClear(context),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.2,
            colors: [Color(0xFF0E1B3D), Color(0xFF070B16)],
          ),
        ),
        child: SafeArea(
          child: ListenableBuilder(
            listenable: monitor,
            builder: (context, _) => Column(
              children: [
                _StatsRow(monitor: monitor),
                Expanded(
                  child: monitor.hosts.isEmpty
                      ? _EmptyState(monitor: monitor)
                      : RefreshIndicator(
                          onRefresh: () => monitor.checkNow(),
                          child: ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                            itemCount: monitor.hosts.length,
                            itemBuilder: (context, i) {
                              final h = monitor.hosts[i];
                              return Dismissible(
                                key: ValueKey(h.ip),
                                direction: DismissDirection.endToStart,
                                background: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 24),
                                  decoration: BoxDecoration(
                                    color:
                                        Colors.red.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: const Icon(Icons.delete_outline,
                                      color: Colors.redAccent),
                                ),
                                onDismissed: (_) => monitor.removeHost(h),
                                child: _HostCard(host: h),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final msg = await monitor.importExcel();
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(msg)));
          }
        },
        icon: const Icon(Icons.upload_file),
        label: const Text('Import Excel'),
      ),
    );
  }

  void _confirmClear(BuildContext context) {
    if (monitor.hosts.isEmpty) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all hosts?'),
        content:
            const Text('This removes every monitored IP from the list.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              monitor.clearAll();
              Navigator.pop(ctx);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.monitor});

  final MonitorService monitor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          _StatCard(
              label: 'UP',
              value: monitor.upCount,
              color: const Color(0xFF34D399)),
          const SizedBox(width: 12),
          _StatCard(
              label: 'DOWN',
              value: monitor.downCount,
              color: const Color(0xFFF87171)),
          const SizedBox(width: 12),
          _StatCard(
              label: 'TOTAL',
              value: monitor.hosts.length,
              color: const Color(0xFF22D3EE)),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard(
      {required this.label, required this.value, required this.color});

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Text('$value',
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: color)),
              const SizedBox(height: 2),
              Text(label,
                  style: const TextStyle(
                      fontSize: 11,
                      letterSpacing: 2,
                      color: Colors.white60)),
            ],
          ),
        ),
      ),
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({required this.host});

  final HostEntry host;

  @override
  Widget build(BuildContext context) {
    final up = host.isUp;
    final dotColor = up == null
        ? Colors.grey
        : up
            ? const Color(0xFF34D399)
            : const Color(0xFFF87171);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: dotColor,
            boxShadow: [
              BoxShadow(
                  color: dotColor.withValues(alpha: 0.8),
                  blurRadius: 10,
                  spreadRadius: 2),
            ],
          ),
        ),
        title: Text(host.name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(_subtitle(),
            style: const TextStyle(color: Colors.white60, fontSize: 13)),
        trailing: _StatusPill(up: up),
      ),
    );
  }

  String _subtitle() {
    if (host.isUp == true) {
      return '${host.ip} \u2022 ${host.latencyMs ?? 0} ms \u2022 seen ${_ago(host.lastSuccess)}';
    }
    if (host.isUp == false) {
      return '${host.ip} \u2022 no reply \u2022 last seen ${_ago(host.lastSuccess)}';
    }
    return '${host.ip} \u2022 checking\u2026';
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.up});

  final bool? up;

  @override
  Widget build(BuildContext context) {
    final text = up == null ? 'WAIT' : up! ? 'UP' : 'DOWN';
    final color = up == null
        ? Colors.grey
        : up!
            ? const Color(0xFF34D399)
            : const Color(0xFFF87171);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(text,
          style: TextStyle(
              color: color, fontWeight: FontWeight.bold, fontSize: 12)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.monitor});

  final MonitorService monitor;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF22D3EE).withValues(alpha: 0.1),
              ),
              child: const Icon(Icons.radar,
                  size: 56, color: Color(0xFF22D3EE)),
            ),
            const SizedBox(height: 20),
            const Text('No hosts yet',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              'Import an Excel sheet with Name in column A and IP in column B, and Link Monitor will ping them continuously.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () async {
                final msg = await monitor.importExcel();
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(msg)));
                }
              },
              icon: const Icon(Icons.upload_file),
              label: const Text('Import Excel'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: monitor.loadDemo,
              child: const Text('or load demo data'),
            ),
          ],
        ),
      ),
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [Color(0xFF22D3EE), Color(0xFF3B82F6)],
                      ),
                    ),
                    child: const Icon(Icons.radar,
                        size: 44, color: Colors.white),
                  ),
                  const SizedBox(height: 16),
                  const Text('Link Monitor',
                      style: TextStyle(
                          fontSize: 24, fontWeight: FontWeight.bold)),
                  const Text('v1.0.0',
                      style: TextStyle(color: Colors.white60)),
                  const SizedBox(height: 12),
                  const Text(
                    'Continuously pings every IP from your Excel list and alerts you the moment a link stays down for 10 seconds.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Card(
            child: ListTile(
              leading: Icon(Icons.code, color: Color(0xFF22D3EE)),
              title: Text('Developer'),
              subtitle: Text('Shivam Bhalla',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: Colors.white)),
            ),
          ),
          const Card(
            child: ListTile(
              leading:
                  Icon(Icons.table_chart_outlined, color: Color(0xFF34D399)),
              title: Text('Excel import'),
              subtitle: Text(
                  'Column A = Name, Column B = IP address. Header row is detected automatically.'),
            ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.notifications_active_outlined,
                  color: Color(0xFFF87171)),
              title: Text('Down alerts'),
              subtitle: Text(
                  'Get a notification when a host stops replying for 10 seconds, and another when it comes back up.'),
            ),
          ),
          const Card(
            child: ListTile(
              leading:
                  Icon(Icons.devices_outlined, color: Color(0xFFA78BFA)),
              title: Text('Cross-platform'),
              subtitle: Text(
                  'Built with Flutter \u2014 runs on Android, iOS, Windows, macOS and Linux.'),
            ),
          ),
        ],
      ),
    );
  }
}

String _ago(DateTime? t) {
  if (t == null) return 'never';
  final s = DateTime.now().difference(t).inSeconds;
  if (s < 5) return 'just now';
  if (s < 60) return '${s}s ago';
  final m = s ~/ 60;
  if (m < 60) return '${m}m ago';
  return '${m ~/ 60}h ago';
}
