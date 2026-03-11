import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config.dart' as config;
import 'connectivity_service.dart';

class FaceAuthService {
  /// Step 1: Upload video → Face AI
  static Future<String?> recognizeByVideo(File videoFile) async {
    final uri = Uri.parse(
        '${connectivityService.faceAiBaseUrl}${config.faceRecognizeVideoPath}');

    final request = http.MultipartRequest('POST', uri);
    request.files.add(
      await http.MultipartFile.fromPath('file', videoFile.path),
    );

    final response = await request.send();

    if (response.statusCode == 200) {
      final body = await response.stream.bytesToString();
      final data = jsonDecode(body);
      return data['identity'];
    }
    return null;
  }

  /// Step 2: identity → backend_account
  static Future<Map<String, dynamic>?> loginByFace(String identity) async {
    final url = connectivityService.uri(config.loginByFacePath);

    final response = await http.post(
      url,
      headers: connectivityService.buildHeaders(),
      body: jsonEncode({'identity': identity}),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    return null;
  }
}
