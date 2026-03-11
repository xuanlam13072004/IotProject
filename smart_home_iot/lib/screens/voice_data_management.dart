import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart' as config;
import '../services/connectivity_service.dart';
import '../services/voice_api_service.dart';

class VoiceDataManagementScreen extends StatefulWidget {
  const VoiceDataManagementScreen({super.key});

  @override
  State<VoiceDataManagementScreen> createState() =>
      _VoiceDataManagementScreenState();
}

class _VoiceDataManagementScreenState extends State<VoiceDataManagementScreen>
    with SingleTickerProviderStateMixin {
  static const List<String> _steps = [
    'Owner',
    'Noise Floor',
    'Training',
    'Verify',
    'Anti-Spoof',
  ];

  String get _voiceServerBaseUrl => connectivityService.voiceBaseUrl;

  final TextEditingController _ownerController = TextEditingController();
  final AudioRecorder _recorder = AudioRecorder();
  late final VoiceApiService _voiceApi;
  late final AnimationController _waveCtrl;
  List<Map<String, dynamic>> _ownerProfiles = <Map<String, dynamic>>[];
  List<String> _ownerOptions = <String>[];
  String? _ownerLoadError;
  bool _ownerLoading = false;
  bool _isAdmin = false;

  bool _isRecording = false;
  bool _isBusy = false;
  _RecordTarget? _recordTarget;
  int _activeStepIndex = 0;

  File? _ambientSample;
  File? _trainingSample;
  final List<File> _trainingHistorySamples = <File>[];
  final List<File> _calibrationSamples = <File>[];
  String _calibrationOwnerId = '';
  int _trainingUploadedCount = 0;
  File? _verifySample;

  String? _lastMessage;
  Map<String, dynamic>? _lastVerifyResult;
  bool _noiseCalibrated = false;
  bool _ownerCalibrated = false;
  bool? _lastVerifyPassed;

  // Anti-spoof training state
  final List<File> _spoofSamples = <File>[];
  Map<String, dynamic>? _antiSpoofHistory;
  bool _antiSpoofHistoryLoading = false;

  @override
  void initState() {
    super.initState();
    _voiceApi =
        VoiceApiService(baseUrl: () => connectivityService.voiceBaseUrl);
    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
    _loadLoggedInUsername();
    _loadOwnerOptions();
  }

  Future<void> _loadLoggedInUsername() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('user_username') ?? '';
    final role = prefs.getString('user_role') ?? 'user';
    final admin = role == 'admin';
    if (mounted) setState(() => _isAdmin = admin);
    if (username.isNotEmpty && _ownerController.text.trim().isEmpty) {
      _ownerController.text = username;
      _onOwnerIdChanged(username);
    }
  }

  @override
  void dispose() {
    _ownerController.dispose();
    _recorder.dispose();
    _waveCtrl.dispose();
    super.dispose();
  }

  Future<void> _startRecord(_RecordTarget target) async {
    if (_isRecording || _isBusy) return;

    _setStepFromTarget(target);

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      _showSnack('Microphone permission is required.');
      return;
    }

    try {
      final tempDir = await getTemporaryDirectory();
      final filePath =
          '${tempDir.path}${Platform.pathSeparator}voice_${DateTime.now().millisecondsSinceEpoch}.wav';

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 128000,
        ),
        path: filePath,
      );
      setState(() {
        _isRecording = true;
        _recordTarget = target;
      });
    } catch (e) {
      _showSnack('Could not start recording: $e');
    }
  }

  Future<void> _stopRecord() async {
    if (!_isRecording || _recordTarget == null) return;

    try {
      final path = await _recorder.stop();
      if (path == null || path.isEmpty) {
        _showSnack('No audio file captured.');
      } else {
        final file = File(path);
        if (_recordTarget == _RecordTarget.ambient) {
          setState(() => _ambientSample = file);
          _showSnack('Ambient sample captured.');
        } else if (_recordTarget == _RecordTarget.train) {
          setState(() => _trainingSample = file);
          _showSnack('Voice training sample captured.');
        } else if (_recordTarget == _RecordTarget.verify) {
          setState(() => _verifySample = file);
          _showSnack('Verification sample captured.');
        } else if (_recordTarget == _RecordTarget.spoof) {
          setState(() => _spoofSamples.add(file));
          _showSnack('Spoof sample captured (${_spoofSamples.length}).');
        }
      }
    } catch (e) {
      _showSnack('Could not stop recording: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isRecording = false;
          _recordTarget = null;
        });
      }
    }
  }

  Future<void> _calibrateNoiseFloor() async {
    if (_ambientSample == null) {
      _showSnack('Record one ambient sample first.');
      return;
    }

    await _runBusy(() async {
      final res = await _voiceApi.setNoiseFloor(ambientAudio: _ambientSample!);
      setState(() {
        _lastMessage =
            'Noise floor calibrated. RMS: ${res['noise_floor_rms'] ?? 'N/A'}';
        _noiseCalibrated = true;
        _activeStepIndex = 1;
      });
    });
  }

  Future<void> _trainVoiceSample() async {
    final ownerId = _ownerController.text.trim();
    if (ownerId.isEmpty) {
      _showSnack('Owner ID is required.');
      return;
    }
    if (_trainingSample == null) {
      _showSnack('Record one training sample first.');
      return;
    }

    await _runBusy(() async {
      final trainingFile = _trainingSample!;
      final res = await _voiceApi.train(ownerId: ownerId, sample: trainingFile);

      final galleryCount = res['gallery_samples'];
      final snrDb = res['snr_db'];
      final storedSampleFile = res['stored_sample_file'];

      setState(() {
        _lastMessage =
            '${res['message'] ?? 'Voice training success.'}\nSNR: ${snrDb ?? '-'} dB\nGallery samples: ${galleryCount ?? '-'}\nStored sample: ${storedSampleFile ?? '-'}';
        _trainingUploadedCount += 1;
        _trainingHistorySamples.add(trainingFile);
        if (_trainingHistorySamples.length > 20) {
          _trainingHistorySamples.removeAt(0);
        }
        _trainingSample = null;
        _activeStepIndex = 2;
      });
      await _loadOwnerOptions();
    });
  }

  Future<void> _calibrateOwner() async {
    final ownerId = _ownerController.text.trim();
    if (ownerId.isEmpty) {
      _showSnack('Owner ID is required.');
      return;
    }

    if (_calibrationSamples.length < 3) {
      _showSnack(
          'Need at least 3 samples in Calibration Set to run calibrate.');
      return;
    }

    final start = _calibrationSamples.length - 3;
    final calibrationSamples = _calibrationSamples.sublist(start);

    await _runBusy(() async {
      final res = await _voiceApi.calibrate(
        ownerId: ownerId,
        samples: calibrationSamples,
      );
      final cal =
          (res['calibration'] as Map<String, dynamic>?) ?? <String, dynamic>{};

      setState(() {
        _lastMessage =
            'Owner calibration updated.\nSpeaker threshold: ${cal['speaker_threshold'] ?? '-'}\nAnti-spoof threshold: ${cal['anti_spoof_threshold'] ?? '-'}\nFusion threshold: ${cal['fusion_threshold'] ?? '-'}';
        _ownerCalibrated = true;
        _calibrationOwnerId = ownerId;
        _activeStepIndex = 2;
      });
    });
  }

  void _addCurrentSampleToCalibrationSet() {
    final ownerId = _ownerController.text.trim();
    if (ownerId.isEmpty) {
      _showSnack(
          'Please select an Owner ID before adding calibration samples.');
      return;
    }
    if (_trainingSample == null) {
      _showSnack('Please record a sample in the Training section first.');
      return;
    }

    setState(() {
      if (_calibrationOwnerId.isNotEmpty && _calibrationOwnerId != ownerId) {
        _calibrationSamples.clear();
      }
      _calibrationOwnerId = ownerId;
      _calibrationSamples.add(_trainingSample!);
      if (_calibrationSamples.length > 10) {
        _calibrationSamples.removeAt(0);
      }
    });
    _showSnack(
        'Sample added to Calibration Set (${_calibrationSamples.length}/3).');
  }

  void _clearCalibrationSet() {
    setState(() {
      _calibrationSamples.clear();
      _ownerCalibrated = false;
      _calibrationOwnerId = _ownerController.text.trim();
    });
  }

  Future<void> _trainAntiSpoof() async {
    final ownerId = _ownerController.text.trim();
    if (ownerId.isEmpty) {
      _showSnack('Owner ID is required.');
      return;
    }
    if (_spoofSamples.isEmpty) {
      _showSnack('Record at least 1 spoof sample first.');
      return;
    }

    await _runBusy(() async {
      final res = await _voiceApi.trainAntiSpoof(
        ownerId: ownerId,
        spoofSamples: _spoofSamples,
      );
      setState(() {
        _lastMessage = 'Anti-spoof retrain complete!\n'
            'Bonafide: ${res['num_bonafide'] ?? '-'}\n'
            'Spoof (simulated): ${res['num_spoof_simulated'] ?? '-'}\n'
            'Spoof (real): ${res['num_spoof_real'] ?? '-'}\n'
            'Spoof (new): ${res['num_spoof_real_new'] ?? '-'}\n'
            'Epochs: ${res['epochs'] ?? '-'}\n'
            'Loss: ${res['final_loss'] ?? '-'}';
        _spoofSamples.clear();
        _activeStepIndex = 4;
      });
      await _loadAntiSpoofHistory();
    });
  }

  Future<void> _loadAntiSpoofHistory() async {
    final ownerId = _ownerController.text.trim();
    if (ownerId.isEmpty) return;

    setState(() => _antiSpoofHistoryLoading = true);
    try {
      final res = await _voiceApi.getAntiSpoofHistory(ownerId: ownerId);
      setState(() => _antiSpoofHistory = res);
    } catch (_) {
      setState(() => _antiSpoofHistory = null);
    } finally {
      if (mounted) setState(() => _antiSpoofHistoryLoading = false);
    }
  }

  Future<void> _verifyOwner() async {
    final ownerId = _ownerController.text.trim();
    if (ownerId.isEmpty) {
      _showSnack('Owner ID is required.');
      return;
    }
    if (_verifySample == null) {
      _showSnack('Record one verification sample first.');
      return;
    }

    await _runBusy(() async {
      final res =
          await _voiceApi.verifyOnly(ownerId: ownerId, sample: _verifySample!);
      setState(() {
        _lastVerifyResult = res;
        _lastMessage = res['message']?.toString() ?? 'Verification finished.';
        _lastVerifyPassed = res['is_valid'] == true;
        _activeStepIndex = 3;
      });
    });
  }

  Future<void> _runBusy(Future<void> Function() fn) async {
    try {
      setState(() => _isBusy = true);
      await fn();
    } catch (e) {
      _showSnack('$e');
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadOwnerOptions() async {
    setState(() {
      _ownerLoading = true;
      _ownerLoadError = null;
    });

    try {
      final list = await _voiceApi.listProfiles();
      final filtered = list.where((e) {
        final id = (e['owner_id'] ?? '').toString();
        return id.isNotEmpty && !id.startsWith('anti_spoof');
      }).toList();

      final ids = filtered
          .map((e) => (e['owner_id'] ?? '').toString())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      setState(() {
        _ownerProfiles = filtered;
        _ownerOptions = ids;
      });
    } catch (e) {
      setState(() {
        _ownerLoadError = e.toString();
      });
    } finally {
      if (mounted) setState(() => _ownerLoading = false);
    }
  }

  Map<String, dynamic>? _profileForOwner(String ownerId) {
    if (ownerId.isEmpty) return null;
    try {
      return _ownerProfiles.firstWhere(
        (p) => (p['owner_id'] ?? '').toString() == ownerId,
      );
    } catch (_) {
      return null;
    }
  }

  int? _serverSampleCountFor(String ownerId) {
    final profile = _profileForOwner(ownerId);
    if (profile == null) return null;
    final dynamic raw = profile['sample_count'];
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  void _onOwnerIdChanged(String value) {
    final newOwner = value.trim();
    final oldOwner = _calibrationOwnerId.trim();

    setState(() {
      if (oldOwner.isNotEmpty && newOwner.isNotEmpty && oldOwner != newOwner) {
        _calibrationSamples.clear();
        _ownerCalibrated = false;
      }
      if (newOwner.isNotEmpty) {
        _calibrationOwnerId = newOwner;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _Palette.page,
      appBar: AppBar(
        backgroundColor: _Palette.page,
        elevation: 0,
        foregroundColor: _Palette.text,
        titleSpacing: 16,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'Voice Data Management',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
            ),
            SizedBox(height: 4),
            Text(
              'Enroll, calibrate, and verify voice securely.',
              style: TextStyle(fontSize: 13),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StepBar(currentIndex: _activeStepIndex, steps: _steps),
              const SizedBox(height: 18),
              _buildWorkflowGuide(),
              const SizedBox(height: 16),
              _buildOwnerStrip(),
              const SizedBox(height: 16),
              _buildAmbientCard(),
              const SizedBox(height: 16),
              _buildTrainingCard(),
              const SizedBox(height: 16),
              _buildVerifyCard(),
              const SizedBox(height: 16),
              _buildAntiSpoofCard(),
              if (_lastMessage != null) ...[
                const SizedBox(height: 16),
                _buildInfoCard(title: 'Activity', content: _lastMessage!),
              ],
              if (_lastVerifyResult != null) ...[
                const SizedBox(height: 12),
                _buildVerifyResult(_lastVerifyResult!),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOwnerStrip() {
    return _SoftCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _FrostIcon(icon: Icons.person, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isAdmin ? 'Owner ID (Admin)' : 'Owner ID',
                      style:
                          const TextStyle(fontSize: 13, color: _Palette.subtle),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFE0E0E0)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.lock_outline,
                              size: 16, color: _Palette.subtle),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _ownerController.text.trim().isEmpty
                                  ? 'Loading...'
                                  : _ownerController.text.trim(),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: _Palette.text,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (_isAdmin)
                IconButton(
                  tooltip: 'Refresh owners',
                  icon: _ownerLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  onPressed: _ownerLoading ? null : _loadOwnerOptions,
                ),
              PopupMenuButton<String>(
                tooltip: 'Voice API',
                color: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                itemBuilder: (_) => [
                  PopupMenuItem<String>(
                    value: 'api',
                    child: Text('API: $_voiceServerBaseUrl',
                        style: const TextStyle(fontSize: 13)),
                  ),
                ],
                child: const Icon(Icons.more_vert, color: _Palette.subtle),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (!_isAdmin)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFE3F2FD),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: const [
                  Icon(Icons.info_outline, size: 14, color: Color(0xFF1565C0)),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Owner ID is set from your login account and cannot be changed.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF1565C0)),
                    ),
                  ),
                ],
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                children: [
                  Icon(Icons.admin_panel_settings,
                      size: 14, color: Color(0xFF2E7D32)),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Admin can only select an existing Owner ID below, no manual input.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF2E7D32)),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          if (_isAdmin && _ownerOptions.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _ownerOptions
                  .map(
                    (id) => ChoiceChip(
                      label: Text(id),
                      selected: _ownerController.text.trim() == id,
                      onSelected: (_) {
                        _ownerController.text = id;
                        _onOwnerIdChanged(id);
                      },
                      selectedColor: _Palette.accent.withOpacity(0.2),
                      labelStyle: const TextStyle(color: _Palette.text),
                      backgroundColor: Colors.white,
                    ),
                  )
                  .toList(),
            )
          else if (_ownerLoadError != null)
            Text(
              'Failed to load list: $_ownerLoadError',
              style: const TextStyle(color: Colors.red, fontSize: 12),
            )
          else
            const Text(
              'No profiles yet; please enroll or retry when the backend is ready.',
              style: TextStyle(color: _Palette.subtle, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _buildWorkflowGuide() {
    return _SoftCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.info_outline, color: _Palette.accent, size: 20),
              SizedBox(width: 8),
              Text(
                'Usage Guide',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: _Palette.text,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Follow these steps in order:\n\n'
            '① Owner — Automatically set from your login account (Admin can select another user)\n\n'
            '② Noise Floor — Record ambient noise (5-10s), then press Calibrate\n\n'
            '③ Training — Record at least 2 real voice samples, press Record → Upload each time.\n'
            '   Each sample is also saved as bonafide for Anti-Spoof.\n\n'
            '④ Verify — Test voice verification (optional)\n\n'
            '⑤ Anti-Spoof — Record fake samples (speaker playback, TTS), then press Train Anti-Spoof.\n'
            '   ⚠ Requirement: server must have ≥ 2 real voice samples for this Owner (can be from previous sessions).',
            style: TextStyle(
              fontSize: 13,
              color: _Palette.subtle,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBonafideStatus() {
    final ownerId = _ownerController.text.trim();
    final profile = _profileForOwner(ownerId);
    final sampleCount = profile != null
        ? (int.tryParse(profile['sample_count']?.toString() ?? '') ?? 0)
        : 0;
    final ready = sampleCount >= 2;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ready ? const Color(0xFFE8F5E9) : const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            ready ? Icons.check_circle : Icons.warning_amber_rounded,
            color: ready ? Colors.green : Colors.orange,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ready
                  ? 'Enough real voice data on server ($sampleCount samples). You can Train Anti-Spoof now, including previously trained samples.'
                  : 'Not enough real voice data on server ($sampleCount/2 samples). Go back to Training to add more for this Owner.',
              style: TextStyle(
                fontSize: 12,
                color: ready ? Colors.green.shade800 : Colors.orange.shade800,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAmbientCard() {
    final hasSample = _ambientSample != null;
    return _SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            icon: Icons.graphic_eq,
            title: 'Step 1 · Noise Floor',
            caption:
                'Record ambient noise (5-10s) to filter background noise during voice processing.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusBadge(
                label: hasSample ? 'Captured' : 'No data',
                color: hasSample ? _Palette.badgeGreen : _Palette.badgeMuted,
                icon: hasSample ? Icons.check : Icons.timelapse,
              ),
              if (_noiseCalibrated)
                const _StatusBadge(
                  label: 'Calibrated',
                  color: _Palette.badgeGreen,
                  icon: Icons.done,
                ),
            ],
          ),
          const SizedBox(height: 14),
          _RecorderRow(
            target: _RecordTarget.ambient,
            startLabel: 'Start Noise Floor',
            isBusy: _isBusy,
            isRecording: _isRecording,
            recordTarget: _recordTarget,
            onStart: () => _startRecord(_RecordTarget.ambient),
            onStop: _stopRecord,
            waveController: _waveCtrl,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _GhostButton(
                label: 'Calibrate',
                icon: Icons.upload,
                onPressed: _isBusy || !hasSample ? null : _calibrateNoiseFloor,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  hasSample
                      ? 'File: ${_ambientSample!.path.split(Platform.pathSeparator).last}'
                      : 'Record a short ambient sample (5-10s).',
                  style: const TextStyle(color: _Palette.subtle, fontSize: 13),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTrainingCard() {
    final hasSample = _trainingSample != null;
    final calibrationReady = _calibrationSamples.length >= 3;
    final ownerId = _ownerController.text.trim();
    final serverSampleCount = _serverSampleCountFor(ownerId);
    final calibrationSetOwner =
        _calibrationOwnerId.isEmpty ? ownerId : _calibrationOwnerId;
    return _SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            icon: Icons.library_music,
            title: 'Step 2 · Training',
            caption:
                'Record at least 2 real voice samples to register your voiceprint. Each sample is also saved as bonafide for Anti-Spoof.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusBadge(
                label: hasSample ? 'Sample ready' : 'No data',
                color: hasSample ? _Palette.badgeBlue : _Palette.badgeMuted,
                icon: hasSample ? Icons.file_present : Icons.timelapse,
              ),
              if (_trainingUploadedCount > 0)
                _StatusBadge(
                  label: 'Uploaded $_trainingUploadedCount',
                  color: _Palette.badgeBlue,
                  icon: Icons.cloud_done,
                ),
              if (_ownerCalibrated)
                const _StatusBadge(
                  label: 'Calibrated',
                  color: _Palette.badgeGreen,
                  icon: Icons.verified,
                ),
              _StatusBadge(
                label: 'Calibration Set ${_calibrationSamples.length}/3',
                color: calibrationReady
                    ? _Palette.badgeGreen
                    : _Palette.badgeMuted,
                icon: calibrationReady ? Icons.done_all : Icons.queue_music,
              ),
            ],
          ),
          if (ownerId.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                serverSampleCount != null
                    ? 'Server has $serverSampleCount samples for ID "$ownerId"'
                    : 'Server has no samples for ID "$ownerId"',
                style: const TextStyle(color: _Palette.subtle, fontSize: 13),
              ),
            ),
          const SizedBox(height: 6),
          Text(
            'Calibrate in 3 steps: (1) Record a sample in Training, (2) press Add Calibrate Sample, (3) once you have 3 samples, press Calibrate Owner.',
            style: const TextStyle(color: _Palette.subtle, fontSize: 12),
          ),
          if (calibrationSetOwner.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Current Calibration Set for ID: $calibrationSetOwner',
                style: const TextStyle(color: _Palette.subtle, fontSize: 12),
              ),
            ),
          const SizedBox(height: 14),
          _RecorderRow(
            target: _RecordTarget.train,
            startLabel: 'Start Training',
            isBusy: _isBusy,
            isRecording: _isRecording,
            recordTarget: _recordTarget,
            onStart: () => _startRecord(_RecordTarget.train),
            onStop: _stopRecord,
            waveController: _waveCtrl,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _GhostButton(
                label: 'Train',
                icon: Icons.upload,
                onPressed: _isBusy || !hasSample ? null : _trainVoiceSample,
              ),
              _GhostButton(
                label: 'Add Calibrate Sample',
                icon: Icons.playlist_add,
                onPressed: _isBusy || !hasSample
                    ? null
                    : _addCurrentSampleToCalibrationSet,
              ),
              _GhostButton(
                label: 'Calibrate Owner',
                icon: Icons.tune,
                onPressed: _isBusy || !calibrationReady || ownerId.isEmpty
                    ? null
                    : _calibrateOwner,
              ),
              _GhostButton(
                label: 'Clear Set',
                icon: Icons.delete_sweep,
                onPressed: _isBusy || _calibrationSamples.isEmpty
                    ? null
                    : _clearCalibrationSet,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            hasSample
                ? 'Ready: ${_trainingSample!.path.split(Platform.pathSeparator).last}'
                : 'Record 1-3 clean sentences for best SNR.',
            style: const TextStyle(color: _Palette.subtle, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            calibrationReady
                ? 'Calibration set is ready, you can press Calibrate Owner.'
                : 'Need ${3 - _calibrationSamples.length} more sample(s) for Calibration Set.',
            style: const TextStyle(color: _Palette.subtle, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildVerifyCard() {
    final hasSample = _verifySample != null;
    return _SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            icon: Icons.verified_user,
            title: 'Step 3 · Verify',
            caption:
                'Check if the voice matches the registered owner. Training must be completed first.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusBadge(
                label: hasSample ? 'Sample ready' : 'No data',
                color: hasSample ? _Palette.badgeBlue : _Palette.badgeMuted,
                icon: hasSample ? Icons.playlist_add_check : Icons.timelapse,
              ),
              if (_lastVerifyPassed != null)
                _StatusBadge(
                  label: _lastVerifyPassed! ? 'Valid' : 'Rejected',
                  color: _lastVerifyPassed!
                      ? _Palette.badgeGreen
                      : _Palette.badgeRed,
                  icon: _lastVerifyPassed! ? Icons.check : Icons.close,
                ),
            ],
          ),
          const SizedBox(height: 14),
          _RecorderRow(
            target: _RecordTarget.verify,
            startLabel: 'Start Verify',
            isBusy: _isBusy,
            isRecording: _isRecording,
            recordTarget: _recordTarget,
            onStart: () => _startRecord(_RecordTarget.verify),
            onStop: _stopRecord,
            waveController: _waveCtrl,
          ),
          const SizedBox(height: 12),
          _GhostButton(
            label: 'Verify',
            icon: Icons.shield_moon,
            onPressed: _isBusy || !hasSample ? null : _verifyOwner,
          ),
          const SizedBox(height: 8),
          Text(
            hasSample
                ? 'Ready: ${_verifySample!.path.split(Platform.pathSeparator).last}'
                : 'Record a short phrase to verify ownership.',
            style: const TextStyle(color: _Palette.subtle, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard({required String title, required String content}) {
    return _SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: _Palette.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            content,
            style: const TextStyle(color: _Palette.subtle, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildVerifyResult(Map<String, dynamic> result) {
    final isValid = result['is_valid'] == true;
    return _SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isValid ? Icons.check_circle : Icons.cancel,
                color: isValid ? Colors.green : Colors.red,
              ),
              const SizedBox(width: 8),
              Text(
                isValid ? 'Verification Passed' : 'Verification Failed',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isValid ? Colors.green.shade700 : Colors.red.shade700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _kv('Owner', '${result['owner_id'] ?? '-'}'),
          _kv('Fusion score', '${result['fusion_score'] ?? '-'}'),
          _kv('Similarity score', '${result['similarity_score'] ?? '-'}'),
          _kv('Anti-spoof score', '${result['anti_spoof_score'] ?? '-'}'),
          _kv('SNR (dB)', '${result['snr_db'] ?? '-'}'),
        ],
      ),
    );
  }

  Widget _kv(String key, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '$key: $value',
        style: const TextStyle(color: _Palette.subtle),
      ),
    );
  }

  Widget _buildAntiSpoofCard() {
    final hasSamples = _spoofSamples.isNotEmpty;
    final ownerId = _ownerController.text.trim();
    final stats = _antiSpoofHistory?['training_stats'] as Map<String, dynamic>?;
    final totalReal = _antiSpoofHistory?['total_real_spoof_samples'];

    return _SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            icon: Icons.security,
            title: 'Step 4 · Anti-Spoof Training',
            caption:
                'Record fake samples (speaker playback, TTS) so the model can distinguish real from fake. Requires: ≥ 2 real voice samples trained.',
          ),
          const SizedBox(height: 8),
          _buildBonafideStatus(),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusBadge(
                label: hasSamples
                    ? '${_spoofSamples.length} sample(s)'
                    : 'No spoof data',
                color: hasSamples ? _Palette.badgeBlue : _Palette.badgeMuted,
                icon: hasSamples ? Icons.file_present : Icons.timelapse,
              ),
              if (totalReal != null)
                _StatusBadge(
                  label: 'Total real: $totalReal',
                  color: _Palette.badgeGreen,
                  icon: Icons.storage,
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Record fake samples (speaker playback of owner voice, TTS, etc.) so the model learns to distinguish real from fake.',
            style: TextStyle(color: _Palette.subtle, fontSize: 12),
          ),
          const SizedBox(height: 14),
          _RecorderRow(
            target: _RecordTarget.spoof,
            startLabel: 'Record Spoof',
            isBusy: _isBusy,
            isRecording: _isRecording,
            recordTarget: _recordTarget,
            onStart: () => _startRecord(_RecordTarget.spoof),
            onStop: _stopRecord,
            waveController: _waveCtrl,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _GhostButton(
                label: 'Train Anti-Spoof',
                icon: Icons.model_training,
                onPressed: _isBusy || !hasSamples || ownerId.isEmpty
                    ? null
                    : _trainAntiSpoof,
              ),
              _GhostButton(
                label: 'Clear Samples',
                icon: Icons.delete_sweep,
                onPressed: _isBusy || !hasSamples
                    ? null
                    : () {
                        setState(() => _spoofSamples.clear());
                        _showSnack('Spoof samples cleared.');
                      },
              ),
              _GhostButton(
                label: 'Refresh Stats',
                icon: Icons.refresh,
                onPressed:
                    _isBusy || _antiSpoofHistoryLoading || ownerId.isEmpty
                        ? null
                        : _loadAntiSpoofHistory,
              ),
            ],
          ),
          if (stats != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _Palette.page,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Last Training Stats',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: _Palette.text,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _kv('Bonafide', '${stats['num_bonafide'] ?? '-'}'),
                  _kv('Spoof (simulated)',
                      '${stats['num_spoof_simulated'] ?? '-'}'),
                  _kv('Spoof (real)', '${stats['num_spoof_real'] ?? '-'}'),
                  _kv('Epochs', '${stats['epochs'] ?? '-'}'),
                  _kv('Final Loss', '${stats['final_loss'] ?? '-'}'),
                  _kv('Trained at', '${stats['trained_at'] ?? '-'}'),
                ],
              ),
            ),
          ],
          if (_antiSpoofHistoryLoading)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _setStepFromTarget(_RecordTarget target) {
    setState(() {
      _activeStepIndex = switch (target) {
        _RecordTarget.ambient => 1,
        _RecordTarget.train => 2,
        _RecordTarget.verify => 3,
        _RecordTarget.spoof => 4,
      };
    });
  }
}

enum _RecordTarget { ambient, train, verify, spoof }

class _SoftCard extends StatelessWidget {
  const _SoftCard({required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _Palette.card,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [
          BoxShadow(
            color: Colors.white,
            offset: Offset(-8, -8),
            blurRadius: 18,
          ),
          BoxShadow(
            color: Color(0x1A1B2B45),
            offset: Offset(8, 12),
            blurRadius: 24,
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.caption,
  });

  final IconData icon;
  final String title;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _GradientIcon(icon: icon, size: 30),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: _Palette.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                caption,
                style: const TextStyle(
                  fontSize: 13,
                  color: _Palette.subtle,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _RecorderRow extends StatelessWidget {
  const _RecorderRow({
    required this.target,
    required this.startLabel,
    required this.isBusy,
    required this.isRecording,
    required this.recordTarget,
    required this.onStart,
    required this.onStop,
    required this.waveController,
  });

  final _RecordTarget target;
  final String startLabel;
  final bool isBusy;
  final bool isRecording;
  final _RecordTarget? recordTarget;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final AnimationController waveController;

  @override
  Widget build(BuildContext context) {
    final active = isRecording && recordTarget == target;
    return Row(
      children: [
        _MicButton(
          active: active,
          onTap: isBusy ? null : (active ? onStop : onStart),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: active
              ? Row(
                  children: [
                    Expanded(
                      child: _LiveWaveform(
                        controller: waveController,
                        color: _Palette.accent,
                        active: active,
                      ),
                    ),
                    const SizedBox(width: 10),
                    _GhostIconButton(
                      icon: Icons.stop,
                      onPressed: isBusy ? null : onStop,
                    ),
                  ],
                )
              : _PrimaryPillButton(
                  label: startLabel,
                  icon: Icons.mic,
                  onPressed: isBusy ? null : onStart,
                ),
        ),
      ],
    );
  }
}

class _MicButton extends StatelessWidget {
  const _MicButton({required this.active, required this.onTap});

  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? _Palette.record : _Palette.softIcon;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.white.withOpacity(0.9),
              offset: const Offset(-6, -6),
              blurRadius: 14,
            ),
            const BoxShadow(
              color: Color(0x1A1B2B45),
              offset: Offset(6, 8),
              blurRadius: 18,
            ),
          ],
        ),
        child: Icon(
          Icons.mic,
          color: color,
          size: 30,
        ),
      ),
    );
  }
}

class _PrimaryPillButton extends StatelessWidget {
  const _PrimaryPillButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(label),
      ),
      style: FilledButton.styleFrom(
        backgroundColor: _Palette.accent,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: _Palette.text,
        side: BorderSide(
          color: onPressed == null
              ? _Palette.subtle.withOpacity(0.4)
              : _Palette.softIcon,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
    );
  }
}

class _GhostIconButton extends StatelessWidget {
  const _GhostIconButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: _Palette.subtle,
        shape: const CircleBorder(),
      ),
      icon: Icon(icon, size: 22),
    );
  }
}

class _LiveWaveform extends StatelessWidget {
  const _LiveWaveform({
    required this.controller,
    required this.color,
    required this.active,
  });

  final AnimationController controller;
  final Color color;
  final bool active;

  @override
  Widget build(BuildContext context) {
    if (!active) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = controller.value;
        final bars = List<double>.generate(6, (i) {
          final phase = t * 2 * math.pi + (i * math.pi / 3);
          return 8 + 18 * (0.5 + 0.5 * math.sin(phase));
        });

        return SizedBox(
          height: 40,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: bars
                .map(
                  (h) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Container(
                      width: 6,
                      height: h,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        gradient: LinearGradient(
                          colors: [color, color.withOpacity(0.35)],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        );
      },
    );
  }
}

class _GradientIcon extends StatelessWidget {
  const _GradientIcon({required this.icon, required this.size});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        colors: [Color(0xFF63A4FF), Color(0xFF4BE1EC)],
      ).createShader(Rect.fromLTWH(0, 0, size, size)),
      child: Icon(icon, size: size, color: Colors.white),
    );
  }
}

class _FrostIcon extends StatelessWidget {
  const _FrostIcon({required this.icon, required this.size});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        shape: BoxShape.circle,
        boxShadow: const [
          BoxShadow(color: Colors.white, offset: Offset(-4, -4), blurRadius: 8),
          BoxShadow(
              color: Color(0x1A1B2B45), offset: Offset(4, 6), blurRadius: 12),
        ],
      ),
      child: Icon(icon, color: _Palette.subtle, size: size * 0.55),
    );
  }
}

class _StepBar extends StatelessWidget {
  const _StepBar({required this.currentIndex, required this.steps});

  final int currentIndex;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: steps.asMap().entries.map((entry) {
            final idx = entry.key;
            final label = entry.value;
            final active = idx == currentIndex;
            return Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    height: 6,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: active
                          ? const LinearGradient(
                              colors: [Color(0xFF63A4FF), Color(0xFF4BE1EC)],
                            )
                          : null,
                      color: active ? null : _Palette.subtle.withOpacity(0.22),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      color: active ? _Palette.accent : _Palette.subtle,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _Palette {
  static const Color page = Color(0xFFF6F8FB);
  static const Color card = Color(0xFFEEF2F7);
  static const Color text = Color(0xFF2E3A4A);
  static const Color subtle = Color(0xFF6B7A90);
  static const Color accent = Color(0xFF4BE1EC);
  static const Color record = Color(0xFFE53935);
  static const Color softIcon = Color(0xFFC4CBD7);

  static const Color badgeMuted = Color(0xFFB0B8C6);
  static const Color badgeBlue = Color(0xFF63A4FF);
  static const Color badgeGreen = Color(0xFF4CAF50);
  static const Color badgeRed = Color(0xFFE53935);
}
