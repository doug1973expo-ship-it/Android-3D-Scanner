import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

class DepthModel {
  Interpreter? _interpreter;
  IsolateInterpreter? _worker;
  bool get ready => _worker != null;

  Future<void> load() async {
    final interpreter = await Interpreter.fromAsset(
      'assets/models/midas_small.tflite',
      options: InterpreterOptions()..threads = 2,
    );
    final input = interpreter.getInputTensor(0);
    final output = interpreter.getOutputTensor(0);
    if (input.shape.join(',') != '1,256,256,3' ||
        output.shape.reduce((a, b) => a * b) != 256 * 256 ||
        input.type != TensorType.float32 ||
        output.type != TensorType.float32) {
      interpreter.close();
      throw StateError(
        'The bundled depth model has an incompatible tensor contract.',
      );
    }
    _interpreter = interpreter;
    _worker = await IsolateInterpreter.create(address: interpreter.address);
  }

  Future<List<double>> predict(Uint8List rgb) async {
    if (_worker == null || rgb.length != 256 * 256 * 3) {
      throw StateError('Depth model or RGB frame is unavailable.');
    }
    // Model-specific preprocessing from MiDaS's ClassifierFloatEfficientNet:
    // (RGB byte - 115) / 58. This is not MobileNet's [-1, 1] normalisation.
    final input = Float32List(rgb.length);
    for (var i = 0; i < rgb.length; i++) {
      input[i] = (rgb[i] - 115) / 58;
    }
    final output = Float32List(256 * 256);
    await _worker!.run(input.buffer, output.buffer);
    return output.toList(growable: false);
  }

  Future<void> close() async {
    await _worker?.close();
    _worker = null;
    _interpreter?.close();
    _interpreter = null;
  }
}
