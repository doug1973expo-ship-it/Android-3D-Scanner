import 'dart:convert';

import 'geometry.dart';

/// Reads the bounded, coloured ASCII point clouds written by RoomScope.
List<Point3> readRoomPoints(String text) {
  final lines = const LineSplitter().convert(text);
  if (lines.length < 3 || lines[0] != 'ply' || lines[1] != 'format ascii 1.0') {
    throw const FormatException(
      'This room has an unsupported point-cloud format.',
    );
  }
  int? count;
  var dataStart = -1;
  final properties = <String>[];
  for (var i = 2; i < lines.length && i < 100; i++) {
    final line = lines[i].trim();
    if (line.startsWith('comment ') || line.isEmpty) continue;
    if (line.startsWith('element vertex ')) {
      if (count != null) {
        throw const FormatException('Duplicate vertex header.');
      }
      count = int.tryParse(line.substring('element vertex '.length));
      if (count == null || count < 0 || count > 100000) {
        throw const FormatException('This room has an invalid point count.');
      }
    } else if (line.startsWith('property ')) {
      properties.add(line);
    } else if (line == 'end_header') {
      dataStart = i + 1;
      break;
    } else {
      throw const FormatException(
        'This room has an unsupported point-cloud header.',
      );
    }
  }
  const expected = [
    'property float x',
    'property float y',
    'property float z',
    'property uchar red',
    'property uchar green',
    'property uchar blue',
  ];
  if (count == null ||
      dataStart < 0 ||
      properties.join('\n') != expected.join('\n') ||
      lines.length - dataStart != count) {
    throw const FormatException('This room has incomplete point-cloud data.');
  }
  return List<Point3>.generate(count, (i) {
    final values = lines[dataStart + i].trim().split(RegExp(r'\s+'));
    if (values.length != 6) throw const FormatException('Incomplete point.');
    final xyz = values.take(3).map(double.tryParse).toList();
    final rgb = values.skip(3).map(int.tryParse).toList();
    if (xyz.any((n) => n == null || !n.isFinite) ||
        rgb.any((n) => n == null || n < 0 || n > 255)) {
      throw const FormatException('Invalid point coordinates or colour.');
    }
    return Point3(xyz[0]!, xyz[1]!, xyz[2]!, rgb[0]!, rgb[1]!, rgb[2]!);
  }, growable: false);
}
