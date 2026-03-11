import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class VoiceApiService {
  VoiceApiService({required String Function() baseUrl})
      : _baseUrlGetter = baseUrl;

  final String Function() _baseUrlGetter;
  String get baseUrl => _baseUrlGetter();

  Uri _uri(String path) {
    final String normalizedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final String normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$normalizedBase$normalizedPath');
  }

  Future<Map<String, dynamic>> setNoiseFloor(
      {required File ambientAudio}) async {
    final request = http.MultipartRequest('POST', _uri('/api/noise-floor'));
    request.files.add(
      await http.MultipartFile.fromPath('ambient_audio', ambientAudio.path),
    );

    final streamed = await request.send();
    final responseBody = await streamed.stream.bytesToString();
    return _handleJsonResponse(streamed.statusCode, responseBody);
  }

  Future<Map<String, dynamic>> enroll({
    required String ownerId,
    required List<File> samples,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/api/enroll'));
    request.fields['owner_id'] = ownerId;

    for (final sample in samples) {
      request.files.add(
        await http.MultipartFile.fromPath('audio_samples', sample.path),
      );
    }

    final streamed = await request.send();
    final responseBody = await streamed.stream.bytesToString();
    return _handleJsonResponse(streamed.statusCode, responseBody);
  }

  Future<Map<String, dynamic>> train({
    required String ownerId,
    required File sample,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/api/train'));
    request.fields['owner_id'] = ownerId;
    request.files.add(
      await http.MultipartFile.fromPath('audio_sample', sample.path),
    );

    final streamed = await request.send();
    final responseBody = await streamed.stream.bytesToString();
    return _handleJsonResponse(streamed.statusCode, responseBody);
  }

  Future<Map<String, dynamic>> verify({
    required String ownerId,
    required File sample,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/api/verify'));
    request.fields['owner_id'] = ownerId;
    request.files.add(
      await http.MultipartFile.fromPath('audio_sample', sample.path),
    );

    final streamed = await request.send();
    final responseBody = await streamed.stream.bytesToString();
    return _handleJsonResponse(streamed.statusCode, responseBody);
  }

  /// Verify voice identity only — no Whisper transcription, no backend command dispatch.
  /// Use this in management/testing screens; use [verify] for the voice command FAB.
  Future<Map<String, dynamic>> verifyOnly({
    required String ownerId,
    required File sample,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/api/verify-only'));
    request.fields['owner_id'] = ownerId;
    request.files.add(
      await http.MultipartFile.fromPath('audio_sample', sample.path),
    );

    final streamed = await request.send();
    final responseBody = await streamed.stream.bytesToString();
    return _handleJsonResponse(streamed.statusCode, responseBody);
  }

  Future<List<Map<String, dynamic>>> listProfiles() async {
    final resp = await http.get(_uri('/api/voice-profiles'));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Request failed (${resp.statusCode}): ${resp.body}');
    }

    final decoded = jsonDecode(resp.body);
    if (decoded is List) {
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (decoded is Map && decoded['profiles'] is List) {
      return (decoded['profiles'] as List)
          .whereType<Map<String, dynamic>>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }

    throw Exception('Unexpected response format: $decoded');
  }

  Future<Map<String, dynamic>> calibrate({
    required String ownerId,
    required List<File> samples,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/api/calibrate'));
    request.fields['owner_id'] = ownerId;

    for (final sample in samples) {
      request.files.add(
        await http.MultipartFile.fromPath('audio_samples', sample.path),
      );
    }

    final streamed = await request.send();
    final responseBody = await streamed.stream.bytesToString();
    return _handleJsonResponse(streamed.statusCode, responseBody);
  }

  Map<String, dynamic> _handleJsonResponse(int statusCode, String body) {
    if (body.isEmpty) {
      if (statusCode >= 200 && statusCode < 300) {
        return <String, dynamic>{'status': 'ok'};
      }
      throw Exception('Server returned status $statusCode with empty body');
    }

    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Unexpected response format: $decoded');
    }

    if (statusCode >= 200 && statusCode < 300) {
      return decoded;
    }

    final detail = decoded['detail'] ?? decoded['error'] ?? body;
    throw Exception('Request failed ($statusCode): $detail');
  }

  // ==================== Anti-Spoof Training ====================

  /// Upload real spoof audio samples to retrain anti-spoof model for an owner.
  Future<Map<String, dynamic>> trainAntiSpoof({
    required String ownerId,
    required List<File> spoofSamples,
  }) async {
    final request =
        http.MultipartRequest('POST', _uri('/api/anti-spoof/train'));
    request.fields['owner_id'] = ownerId;

    for (final sample in spoofSamples) {
      request.files.add(
        await http.MultipartFile.fromPath('spoof_samples', sample.path),
      );
    }

    final streamed = await request.send();
    final responseBody = await streamed.stream.bytesToString();
    return _handleJsonResponse(streamed.statusCode, responseBody);
  }

  /// Get anti-spoof training history/stats for an owner.
  Future<Map<String, dynamic>> getAntiSpoofHistory({
    required String ownerId,
  }) async {
    final uri = _uri('/api/anti-spoof/history');
    final fullUri = uri.replace(queryParameters: {'owner_id': ownerId});
    final resp = await http.get(fullUri);
    final responseBody = resp.body;
    return _handleJsonResponse(resp.statusCode, responseBody);
  }

  // ==================== Admin: Sample Details & Delete ====================

  /// List detailed sample info for an owner.
  Future<Map<String, dynamic>> listOwnerSamples({
    required String ownerId,
  }) async {
    final resp = await http.get(_uri('/api/voice-profiles/$ownerId/samples'));
    return _handleJsonResponse(resp.statusCode, resp.body);
  }

  /// Delete a single voice sample for an owner.
  Future<Map<String, dynamic>> deleteSample({
    required String ownerId,
    required String filename,
  }) async {
    final resp = await http
        .delete(_uri('/api/voice-profiles/$ownerId/samples/$filename'));
    return _handleJsonResponse(resp.statusCode, resp.body);
  }

  /// Delete entire voice profile for an owner.
  Future<Map<String, dynamic>> deleteProfile({
    required String ownerId,
  }) async {
    final resp = await http.delete(_uri('/api/voice-profiles/$ownerId'));
    return _handleJsonResponse(resp.statusCode, resp.body);
  }
}
