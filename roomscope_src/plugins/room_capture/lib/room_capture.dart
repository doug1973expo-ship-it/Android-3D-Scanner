import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

class RoomCapture {
  static const _methods = MethodChannel('roomscope/capture');
  static const _events = EventChannel('roomscope/frames');
  Stream<Map<String, dynamic>> get frames => _events
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));
  Future<void> start() => _methods.invokeMethod<void>('start');
  Future<void> pause() => _methods.invokeMethod<void>('pause');
  Future<void> reset() => _methods.invokeMethod<void>('reset');
  Future<void> record(String directory) =>
      _methods.invokeMethod<void>('record', {'directory': directory});
  Future<Map<String, dynamic>?> stopRecording() async {
    final value = await _methods.invokeMapMethod<String, dynamic>(
      'stopRecording',
    );
    return value;
  }

  Future<void> dispose() => _methods.invokeMethod<void>('dispose');
}

class RoomCameraPreview extends StatelessWidget {
  const RoomCameraPreview({super.key});
  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      // Keep ARCore's GLSurfaceView in the native view hierarchy.
      return PlatformViewLink(
        viewType: 'roomscope/preview',
        surfaceFactory: (context, controller) => AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        ),
        onCreatePlatformView: (params) =>
            PlatformViewsService.initExpensiveAndroidView(
                id: params.id,
                viewType: 'roomscope/preview',
                layoutDirection: TextDirection.ltr,
                onFocus: () => params.onFocusChanged(true),
              )
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
              ..create(),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return const UiKitView(viewType: 'roomscope/preview');
    }
    return const Center(child: Text('Camera capture requires Android or iOS.'));
  }
}
