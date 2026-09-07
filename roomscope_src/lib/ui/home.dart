import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:room_capture/room_capture.dart';

import '../capture/session_controller.dart';
import '../mapping/geometry.dart';

const mint = Color(0xff67e8ba);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final controller = SessionController();
  int tab = 0;
  bool showMap = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(controller.initialize()),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    try {
      await controller.cloud.signIn();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Signed in. Choose a capture to sync.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sign in was cancelled or could not finish.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            title: const Row(
              children: [
                Icon(Icons.view_in_ar, color: mint),
                SizedBox(width: 10),
                Text(
                  'RoomScope',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: _Pill(
                    controller.recording ? '● RECORDING' : 'ON DEVICE',
                    color: controller.recording ? Colors.redAccent : mint,
                  ),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: IndexedStack(
              index: tab,
              children: [_capturePage(), _libraryPage(), _cloudPage()],
            ),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (index) => setState(() => tab = index),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.center_focus_strong),
                label: 'Capture',
              ),
              NavigationDestination(
                icon: Icon(Icons.grid_view_rounded),
                label: 'My rooms',
              ),
              NavigationDestination(
                icon: Icon(Icons.cloud_outlined),
                label: 'Private sync',
              ),
            ],
          ),
        ),
      );

  Widget _capturePage() => Padding(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Make space tangible.',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            const Text(
              'Video + a 3D map of your room',
              style: TextStyle(color: Colors.white60),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(
                      color: Color(0xff192630),
                      child: RoomCameraPreview(),
                    ),
                    if (showMap)
                      ColoredBox(
                        color: const Color(0xff111b24),
                        child: CloudViewer(
                          points: controller.map.points.toList(),
                        ),
                      ),
                    if (!controller.ready)
                      ColoredBox(
                        color: const Color(0xee14212b),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.camera_alt_outlined,
                                  color: mint,
                                  size: 54,
                                ),
                                const SizedBox(height: 18),
                                Text(
                                  controller.message,
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 16),
                                Wrap(
                                  spacing: 10,
                                  alignment: WrapAlignment.center,
                                  children: [
                                    FilledButton(
                                      onPressed: controller.busy
                                          ? null
                                          : controller.startCamera,
                                      child: const Text('Retry camera'),
                                    ),
                                    TextButton(
                                      onPressed: openAppSettings,
                                      child: const Text('Settings'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      top: 14,
                      left: 14,
                      child: _Pill(
                        showMap ? '3D POINT CLOUD' : 'LIVE CAMERA',
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: IconButton.filledTonal(
                        tooltip: showMap ? 'Show camera' : 'Explore 3D map',
                        onPressed: () => setState(() => showMap = !showMap),
                        icon: Icon(
                          showMap ? Icons.videocam_outlined : Icons.view_in_ar,
                        ),
                      ),
                    ),
                    if (controller.ready && !showMap)
                      const Center(
                        child: Icon(Icons.add, color: Colors.white54, size: 28),
                      ),
                    Positioned(
                      bottom: 14,
                      left: 14,
                      right: 14,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xcc0c1117),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          showMap
                              ? 'Drag to orbit · pinch to zoom'
                              : controller.message,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _metric('POINTS', controller.map.length.toString()),
                _metric(
                  'DURATION',
                  '${controller.seconds ~/ 60}:${(controller.seconds % 60).toString().padLeft(2, '0')}',
                ),
                _metric('TRACKING', controller.tracking ? 'Good' : 'Waiting'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              controller.modelStatus,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor:
                    controller.recording ? Colors.redAccent : mint,
                foregroundColor: const Color(0xff0a1713),
              ),
              onPressed: controller.busy
                  ? null
                  : controller.recording
                      ? controller.finish
                      : controller.ready
                          ? controller.begin
                          : null,
              icon: Icon(
                controller.recording
                    ? Icons.stop_rounded
                    : Icons.fiber_manual_record,
              ),
              label: Text(
                controller.busy
                    ? 'Please wait…'
                    : controller.recording
                        ? 'Finish capture'
                        : 'Start room capture',
              ),
            ),
            const SizedBox(height: 7),
            const Text(
              'Silent video · up to 2 minutes · saved locally',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
      );

  Widget _metric(String label, String value) => Expanded(
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 19),
            ),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 10,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      );

  Widget _libraryPage() => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your rooms',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Captures stay here until you choose to sync.',
              style: TextStyle(color: Colors.white60),
            ),
            const SizedBox(height: 20),
            if (controller.saved.isEmpty)
              const Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.layers_outlined, size: 70, color: mint),
                      SizedBox(height: 20),
                      Text('Your first room starts with a scan.'),
                      SizedBox(height: 8),
                      Text(
                        'Walk slowly and include textured surfaces.',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: controller.saved.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final item = controller.saved[index];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            const Icon(Icons.view_in_ar, color: mint, size: 36),
                            const SizedBox(width: 14),
                            Expanded(
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => Navigator.of(context).push<void>(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        SavedRoomScreen(capture: item),
                                  ),
                                ),
                                child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 4),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Room · ${item.created.day}/${item.created.month}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        '${item.count} points · ${item.manifest['durationSeconds']}s',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.white60,
                                        ),
                                      ),
                                      Text(
                                        item.synced
                                            ? 'Cloud copy verified'
                                            : 'On this device',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: mint,
                                        ),
                                      ),
                                      const Padding(
                                        padding: EdgeInsets.only(top: 8),
                                        child: Text(
                                          'Open 3D room',
                                          style: TextStyle(color: mint),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Sync capture',
                              onPressed: controller.syncing
                                  ? null
                                  : () => controller.sync(item),
                              icon: Icon(
                                item.synced
                                    ? Icons.cloud_done_outlined
                                    : Icons.cloud_upload_outlined,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            Text(
              controller.syncStatus,
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ],
        ),
      );

  Widget _cloudPage() => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 20),
          const Icon(Icons.cloud_done_outlined, color: mint, size: 76),
          const SizedBox(height: 24),
          const Text(
            'A private home\nfor your spaces.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          const Text(
            'Room mapping happens on your device. Only captures you choose '
            'are uploaded to your account.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, height: 1.6),
          ),
          const SizedBox(height: 28),
          const ListTile(
            leading: Icon(Icons.lock_outline, color: mint),
            title: Text('Encrypted uploads'),
            subtitle: Text('Files are checked before sync is marked complete.'),
          ),
          const ListTile(
            leading: Icon(Icons.account_circle_outlined, color: mint),
            title: Text('Your account, your captures'),
            subtitle: Text('Each account has its own private cloud storage.'),
          ),
          const ListTile(
            leading: Icon(Icons.offline_bolt_outlined, color: mint),
            title: Text('Capture offline'),
            subtitle: Text('You can sync saved rooms when you are connected.'),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: controller.cloud.configured ? _login : null,
            child: const Text('Sign in to sync'),
          ),
          if (!controller.cloud.configured)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Cloud sync is not available in this build. You can still '
                'save captures on this device.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
            ),
          TextButton(
            onPressed: () async {
              await controller.cloud.signOut();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Signed out on this device.')),
              );
            },
            child: const Text('Sign out'),
          ),
        ],
      );
}

class SavedRoomScreen extends StatefulWidget {
  const SavedRoomScreen({required this.capture, super.key});
  final SavedCapture capture;

  @override
  State<SavedRoomScreen> createState() => _SavedRoomScreenState();
}

class _SavedRoomScreenState extends State<SavedRoomScreen> {
  late final Future<List<Point3>> _points = widget.capture.loadPoints();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Saved room')),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '${widget.capture.count} points · '
                  '${widget.capture.created.day}/${widget.capture.created.month} · '
                  '${widget.capture.manifest['durationSeconds']}s',
                ),
              ),
              Expanded(
                child: FutureBuilder<List<Point3>>(
                  future: _points,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'This room could not be opened. Its saved files '
                            'are still on this device.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return CloudViewer(points: snapshot.data!);
                  },
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'Drag to orbit · pinch to zoom',
                  style: TextStyle(color: Colors.white60),
                ),
              ),
            ],
          ),
        ),
      );
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {this.color = Colors.white});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xcc0c1117),
          borderRadius: BorderRadius.circular(30),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: .6,
          ),
        ),
      );
}

class CloudViewer extends StatefulWidget {
  const CloudViewer({required this.points, super.key});
  final List<Point3> points;

  @override
  State<CloudViewer> createState() => _CloudViewerState();
}

class _CloudViewerState extends State<CloudViewer> {
  double yaw = .25;
  double pitch = -.2;
  double zoom = 70;
  double _startZoom = 70;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onScaleStart: (_) => _startZoom = zoom,
        onScaleUpdate: (event) => setState(() {
          yaw += event.focalPointDelta.dx * .008;
          pitch = (pitch + event.focalPointDelta.dy * .008).clamp(-1.4, 1.4);
          zoom = (_startZoom * event.scale).clamp(10, 240);
        }),
        child: CustomPaint(
          painter: _CloudPainter(widget.points, yaw, pitch, zoom),
          child: widget.points.isEmpty
              ? const Center(
                  child: Text(
                    'Tracked points appear here during capture.',
                    style: TextStyle(color: Colors.white54),
                  ),
                )
              : const SizedBox.expand(),
        ),
      );
}

class _CloudPainter extends CustomPainter {
  _CloudPainter(this.points, this.yaw, this.pitch, this.zoom);
  final List<Point3> points;
  final double yaw;
  final double pitch;
  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: .06)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 30) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 30) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (points.isEmpty) return;

    var cx = 0.0;
    var cy = 0.0;
    var cz = 0.0;
    for (final p in points) {
      cx += p.x;
      cy += p.y;
      cz += p.z;
    }
    cx /= points.length;
    cy /= points.length;
    cz /= points.length;

    final step = math.max(1, (points.length / 6000).ceil());
    final paint = Paint();
    for (var i = 0; i < points.length; i += step) {
      final p = points[i];
      final x =
          (p.x - cx) * math.cos(yaw) + (p.z - cz) * math.sin(yaw);
      final z =
          -(p.x - cx) * math.sin(yaw) + (p.z - cz) * math.cos(yaw);
      final y = (p.y - cy) * math.cos(pitch) - z * math.sin(pitch);
      paint.color = Color.fromARGB(210, p.r, p.g, p.b);
      canvas.drawCircle(
        Offset(size.width / 2 + x * zoom, size.height / 2 - y * zoom),
        1.4,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CloudPainter oldDelegate) => true;
}
