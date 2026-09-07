import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:room_capture/room_capture.dart';
import 'package:uuid/uuid.dart';

import '../mapping/depth_model.dart';
import '../mapping/geometry.dart';
import '../mapping/ply.dart';
import '../sync/cloud.dart';

class SavedCapture {
  SavedCapture(this.directory, this.manifest, this.synced) {
    final id = manifest['id'];
    final date = manifest['createdAt'];
    final count = manifest['pointCount'];
    final duration = manifest['durationSeconds'];
    if (id is! String ||
        id.isEmpty ||
        date is! String ||
        DateTime.tryParse(date) == null ||
        count is! int ||
        count < 0 ||
        count > 100000 ||
        duration is! int ||
        duration < 0) {
      throw const FormatException('This saved room has incomplete metadata.');
    }
  }
  final Directory directory;
  final Map<String, dynamic> manifest;
  bool synced;
  String get id => manifest['id'] as String;
  int get count => manifest['pointCount'] as int;
  DateTime get created =>
      DateTime.parse(manifest['createdAt'] as String).toLocal();

  Future<List<Point3>> loadPoints() async {
    final file = File('${directory.path}/points.ply');
    if (await file.length() > 32 * 1024 * 1024) {
      throw const FormatException('This point cloud is too large to open.');
    }
    final points = await compute(readRoomPoints, await file.readAsString());
    if (points.length != count) {
      throw const FormatException(
        'This room does not match its saved point count.',
      );
    }
    return points;
  }
}

class SessionController extends ChangeNotifier with WidgetsBindingObserver {
  final capture = RoomCapture();
  final cloud = CloudSync();
  final map = VoxelMap();
  final _model = DepthModel();
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Timer? _timer;
  Directory? _recordingDirectory;
  IOSink? _trajectory;
  DateTime? _started;
  bool ready = false, recording = false, busy = false, tracking = false;
  bool modelReady = false, syncing = false, _mapping = false, _closed = false;
  bool _foreground = true;
  int _epoch = 0;
  Future<void>? _mappingWork;
  String message = 'Preparing camera';
  String modelStatus = 'Loading depth model';
  String syncStatus = 'Saved on this device';
  MappingFrame? latestFrame;
  List<SavedCapture> saved = [];
  int get seconds =>
      _started == null ? 0 : DateTime.now().difference(_started!).inSeconds;

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    await reloadSaved();
    // Capture remains usable with tracked sparse points if ML cannot initialise.
    try {
      await _model.load();
      modelReady = true;
      modelStatus = 'On-device AI ready';
    } catch (_) {
      modelStatus = 'AI unavailable · tracked points only';
    }
    _subscription = capture.frames.listen(
      _onEvent,
      onError: (Object error) {
        message = 'Camera interrupted. Stop and retry the capture.';
        _notify();
        if (recording) unawaited(finish());
      },
    );
    await startCamera();
  }

  Future<void> startCamera() async {
    if (busy || recording || _closed) return;
    busy = true;
    message = 'Checking camera access';
    _notify();
    try {
      final permission = await Permission.camera.request();
      if (!permission.isGranted) {
        ready = false;
        message = permission.isPermanentlyDenied
            ? 'Camera access is off. Enable it in Settings, then retry.'
            : 'Allow camera access to scan a room.';
        return;
      }
      await capture.start();
      ready = true;
      message = 'Move slowly so the camera can track the room';
    } catch (error) {
      ready = false;
      message = _friendly(error);
    } finally {
      busy = false;
      _notify();
    }
  }

  String _friendly(Object error) {
    final text = error.toString();
    if (text.contains('ar_installing')) {
      return 'Finish installing Google Play Services for AR, then retry.';
    }
    if (text.contains('unsupported')) {
      return 'Room tracking is unavailable on this device.';
    }
    if (text.contains('camera')) {
      return 'Camera unavailable. Close other camera apps and retry.';
    }
    return 'Capture could not start. Check camera access and try again.';
  }

  void _onEvent(Map<String, dynamic> event) {
    if (_closed || !_foreground) return;
    if (event['error'] != null) {
      message = event['error'] as String;
      if (recording) unawaited(finish());
      _notify();
      return;
    }
    try {
      final frame = MappingFrame(event);
      if (!frame.valid) return;
      latestFrame = frame;
      tracking = frame.tracking;
      message = tracking
          ? 'Tracking room'
          : 'Tracking paused · move slowly toward a textured surface';
      if (recording && frame.tracking) {
        map.addTracked(frame);
        _trajectory?.writeln(
          jsonEncode({
            'timestamp': frame.timestamp,
            'cameraToWorld': frame.pose,
            'intrinsics256': frame.intrinsics,
          }),
        );
        if (modelReady && frame.rgb != null && !_mapping) {
          _mappingWork = _integrate(frame, _epoch);
        }
      }
      _notify();
    } catch (_) {
      message = 'A camera frame was incomplete; waiting for the next frame';
      _notify();
    }
  }

  Future<void> _integrate(MappingFrame frame, int epoch) async {
    _mapping = true;
    try {
      final prediction = await _model.predict(frame.rgb!);
      if (_closed || epoch != _epoch) return;
      final fit = map.addPredicted(frame, prediction);
      modelStatus = fit == null
          ? 'AI waiting for reliable depth anchors'
          : 'AI mapping · ${(fit.relativeError * 100).toStringAsFixed(0)}% fit residual';
    } catch (_) {
      modelStatus = 'AI frame skipped · tracked points retained';
    } finally {
      _mapping = false;
      _notify();
    }
  }

  Future<void> begin() async {
    if (!ready || busy || recording || !_foreground) return;
    busy = true;
    _notify();
    try {
      _epoch++;
      await _mappingWork;
      map.clear();
      await capture.reset();
      final root = await getApplicationSupportDirectory();
      final directory = Directory('${root.path}/captures/${const Uuid().v4()}');
      await directory.create(recursive: true);
      _recordingDirectory = directory;
      _trajectory = File('${directory.path}/trajectory.jsonl').openWrite();
      // Creation before capture makes interrupted recordings discoverable.
      await File('${directory.path}/incomplete.json').writeAsString(
        jsonEncode({'createdAt': DateTime.now().toUtc().toIso8601String()}),
        flush: true,
      );
      await capture.record(directory.path);
      _started = DateTime.now();
      recording = true;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        _notify();
        if (seconds >= 120) unawaited(finish());
      });
    } catch (error) {
      await _trajectory?.close();
      _trajectory = null;
      message = _friendly(error);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> finish() async {
    if (!recording || busy) return;
    busy = true;
    recording = false;
    _timer?.cancel();
    _notify();
    try {
      final duration = seconds;
      final result = await capture.stopRecording();
      await _mappingWork;
      await _trajectory?.flush();
      await _trajectory?.close();
      _trajectory = null;
      final directory = _recordingDirectory!;
      final video = File('${directory.path}/capture.mp4');
      if (result == null ||
          !await video.exists() ||
          await video.length() == 0 ||
          map.length == 0) {
        throw StateError(
          'Capture has no usable video or tracked points. The partial files are retained.',
        );
      }
      await File(
        '${directory.path}/points.ply',
      ).writeAsString(map.toPly(), flush: true);
      final manifest = {
        'schemaVersion': 1,
        'id': directory.path.split(Platform.pathSeparator).last,
        'createdAt': _started!.toUtc().toIso8601String(),
        'durationSeconds': duration,
        'pointCount': map.length,
        'coordinateSystem': 'right-handed; Y up; metres; camera looks -Z',
        'format': 'rgb-video+camera-poses+estimated-point-cloud',
        'stereoscopic': false,
        'audio': false,
        'model': modelReady ? 'MiDaS v2.1 small' : 'tracked-feature-points',
        'videoSource': Platform.isAndroid
            ? 'ARCore dataset'
            : 'ARKit capturedImage',
        'poseClock': 'native monotonic frame timestamp, seconds',
        'videoTiming': {...result}..remove('path'),
      };
      await File(
        '${directory.path}/manifest.json',
      ).writeAsString(jsonEncode(manifest), flush: true);
      await File('${directory.path}/incomplete.json').delete();
      message = 'Capture saved on this device';
      await reloadSaved();
    } catch (error) {
      message =
          'Could not finalise this capture. Partial files remain on this device.';
    } finally {
      try {
        await _trajectory?.close();
      } catch (_) {
        /* Preserve partial files. */
      }
      _trajectory = null;
      _started = null;
      busy = false;
      _notify();
    }
  }

  Future<void> reloadSaved() async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory('${root.path}/captures');
    saved = [];
    if (!await directory.exists()) return;
    await for (final entry in directory.list()) {
      if (entry is! Directory) continue;
      try {
        final manifest =
            jsonDecode(await File('${entry.path}/manifest.json').readAsString())
                as Map<String, dynamic>;
        saved.add(
          SavedCapture(
            entry,
            manifest,
            await File('${entry.path}/synced.json').exists(),
          ),
        );
      } catch (_) {
        /* Incomplete captures are retained; never call them finished. */
      }
    }
    saved.sort((a, b) => b.created.compareTo(a.created));
    _notify();
  }

  Future<void> sync(SavedCapture item) async {
    if (syncing) return;
    syncing = true;
    syncStatus = 'Preparing private upload';
    _notify();
    try {
      await cloud.upload(item.directory, (status) {
        syncStatus = status;
        _notify();
      });
      item.synced = true;
      syncStatus = 'Cloud copy verified';
    } catch (error) {
      syncStatus = error is StateError
          ? error.message.toString()
          : 'Sync interrupted. Your capture is saved; tap Sync to retry.';
    } finally {
      syncing = false;
      _notify();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_background());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(startCamera());
    }
  }

  Future<void> _background() async {
    await finish();
    // Do not race a resumed app with a delayed pause completion.
    if (!_foreground) {
      try {
        await capture.pause();
      } catch (_) {
        /* Already unavailable. */
      }
      ready = false;
      _notify();
      if (_foreground) await startCamera();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _epoch++;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(capture.dispose().catchError((Object _) {}));
    unawaited(_cleanupModel());
    super.dispose();
  }

  Future<void> _cleanupModel() async {
    await _mappingWork;
    await _model.close();
    await _trajectory?.close();
  }
}
