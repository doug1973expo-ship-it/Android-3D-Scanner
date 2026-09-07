import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class CloudSync {
  static const api = String.fromEnvironment('API_URL');
  static const issuer = String.fromEnvironment('OIDC_ISSUER');
  static const clientId = String.fromEnvironment('OIDC_CLIENT_ID');
  static const redirect = 'app.roomscope://oauthredirect';
  static const scopes = ['openid', 'email', 'profile', 'roomscope/sync'];
  static const _storage = FlutterSecureStorage();
  static const _auth = FlutterAppAuth();
  bool get configured =>
      [api, issuer].every((value) {
        final uri = Uri.tryParse(value);
        return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            uri.query.isEmpty &&
            uri.fragment.isEmpty;
      }) &&
      clientId.isNotEmpty;

  Future<void> signIn() async {
    if (!configured) {
      throw StateError('Cloud sync has not been configured yet.');
    }
    final result = await _auth.authorizeAndExchangeCode(
      AuthorizationTokenRequest(
        clientId,
        redirect,
        issuer: issuer,
        scopes: scopes,
        promptValues: ['login'],
      ),
    );
    await _save(
      result.accessToken,
      result.refreshToken,
      result.accessTokenExpirationDateTime,
    );
  }

  Future<void> signOut() => _storage.delete(key: 'roomscope.tokens');
  Future<void> _save(String? access, String? refresh, DateTime? expiry) async {
    if (access == null || expiry == null) {
      throw StateError('Sign in did not return a usable session.');
    }
    await _storage.write(
      key: 'roomscope.tokens',
      value: jsonEncode({
        'access': access,
        'refresh': refresh,
        'expiry': expiry.toUtc().toIso8601String(),
      }),
    );
  }

  Future<String> _token() async {
    final raw = await _storage.read(key: 'roomscope.tokens');
    if (raw == null) throw StateError('Sign in to sync this capture.');
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (DateTime.parse(
      data['expiry'] as String,
    ).isAfter(DateTime.now().toUtc().add(const Duration(minutes: 1)))) {
      return data['access'] as String;
    }
    final refresh = data['refresh'] as String?;
    if (refresh == null) throw StateError('Please sign in again.');
    final result = await _auth.token(
      TokenRequest(
        clientId,
        redirect,
        issuer: issuer,
        refreshToken: refresh,
        scopes: scopes,
      ),
    );
    await _save(
      result.accessToken,
      result.refreshToken ?? refresh,
      result.accessTokenExpirationDateTime,
    );
    return result.accessToken!;
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> data,
  ) async {
    final token = await _token();
    final result = await http
        .post(
          Uri.parse('$api$path'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(data),
        )
        .timeout(const Duration(seconds: 30));
    if (result.statusCode == 401 || result.statusCode == 403) {
      throw StateError(
        'Your cloud session was rejected. Please sign in again.',
      );
    }
    if (result.statusCode != 200) {
      throw StateError('Cloud request failed (${result.statusCode}).');
    }
    return jsonDecode(result.body) as Map<String, dynamic>;
  }

  Future<void> upload(Directory directory, void Function(String) status) async {
    if (!configured) {
      throw StateError('Cloud sync has not been configured yet.');
    }
    final manifest =
        jsonDecode(await File('${directory.path}/manifest.json').readAsString())
            as Map<String, dynamic>;
    const names = [
      'capture.mp4',
      'points.ply',
      'trajectory.jsonl',
      'manifest.json',
    ];
    final files = <Map<String, dynamic>>[];
    for (final name in names) {
      final file = File('${directory.path}/$name');
      final size = await file.length();
      if (size <= 0 || size > 256 * 1024 * 1024) {
        throw StateError('$name is empty or larger than 256 MiB.');
      }
      final digest = await sha256.bind(file.openRead()).first;
      files.add({
        'name': name,
        'size': size,
        'sha256': base64Encode(digest.bytes),
      });
    }
    // A saved scan and its files are immutable. Retrying the same ID is idempotent.
    final request = await _post('/scans', {
      'scanId': manifest['id'],
      'files': files,
    });
    if (request['complete'] == true) {
      await _markSynced(directory);
      return;
    }
    for (final raw in request['uploads'] as List) {
      final item = Map<String, dynamic>.from(raw as Map);
      final name = item['name'] as String;
      if (!names.contains(name)) {
        throw StateError('Cloud returned an unexpected filename.');
      }
      final url = Uri.parse(item['url'] as String);
      if (url.scheme != 'https' ||
          !url.host.endsWith('.amazonaws.com') ||
          url.userInfo.isNotEmpty) {
        throw StateError('Cloud returned an invalid upload destination.');
      }
      status('Uploading $name');
      final upload = http.MultipartRequest('POST', url)
        ..followRedirects = false
        ..fields.addAll(Map<String, String>.from(item['fields'] as Map))
        ..files.add(
          await http.MultipartFile.fromPath(
            'file',
            '${directory.path}/$name',
            filename: name,
          ),
        );
      final client = http.Client();
      try {
        final result = await client
            .send(upload)
            .timeout(const Duration(minutes: 4));
        await result.stream.drain<void>().timeout(const Duration(seconds: 30));
        if (result.statusCode != 204 && result.statusCode != 201) {
          throw StateError(
            'Upload failed (${result.statusCode}). Your local capture is saved.',
          );
        }
      } finally {
        client.close();
      }
    }
    status('Verifying uploaded files');
    await _post('/scans/${manifest['id']}/complete', {});
    await _markSynced(directory);
  }

  Future<void> _markSynced(Directory directory) async {
    await File('${directory.path}/synced.json').writeAsString(
      jsonEncode({'completedAt': DateTime.now().toUtc().toIso8601String()}),
      flush: true,
    );
  }
}
