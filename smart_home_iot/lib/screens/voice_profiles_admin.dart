import 'package:flutter/material.dart';

import '../services/connectivity_service.dart';
import '../services/voice_api_service.dart';

class VoiceProfilesAdminScreen extends StatefulWidget {
  const VoiceProfilesAdminScreen({super.key});

  @override
  State<VoiceProfilesAdminScreen> createState() =>
      _VoiceProfilesAdminScreenState();
}

class _VoiceProfilesAdminScreenState extends State<VoiceProfilesAdminScreen> {
  late final VoiceApiService _voiceApi;
  bool _loading = true;
  String? _error;
  List<_VoiceProfile> _profiles = const [];

  @override
  void initState() {
    super.initState();
    _voiceApi =
        VoiceApiService(baseUrl: () => connectivityService.voiceBaseUrl);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final raw = await _voiceApi.listProfiles();
      final parsed = raw
          .map((e) => _VoiceProfile(
                ownerId: e['owner_id']?.toString() ?? 'unknown',
                sampleCount:
                    int.tryParse(e['sample_count']?.toString() ?? '') ?? 0,
                calibrated: e['calibrated'] == true,
                lastUpdated: e['updated_at']?.toString(),
              ))
          .toList();

      setState(() {
        _profiles = parsed;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _fmtDate(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return '${dt.day.toString().padLeft(2, '0')}/'
          '${dt.month.toString().padLeft(2, '0')}/'
          '${dt.year} '
          '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }

  // ── View sample details ──────────────────────────────────────────
  Future<void> _showSampleDetails(String ownerId) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final result = await _voiceApi.listOwnerSamples(ownerId: ownerId);
      if (!mounted) return;
      Navigator.pop(context);

      final samples = (result['samples'] as List?) ?? [];
      final metadata = result['metadata'] as Map<String, dynamic>?;
      final calibrated = result['calibrated'] == true;

      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('$ownerId — ${samples.length} mẫu',
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(
                    calibrated ? Icons.check_circle : Icons.cancel,
                    size: 16,
                    color: calibrated ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    calibrated ? 'Calibrated.' : 'Not calibrated',
                    style: TextStyle(
                      fontSize: 13,
                      color: calibrated ? Colors.green : Colors.grey,
                    ),
                  ),
                ]),
                if (metadata != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Embedding dim: ${metadata['embedding_dim'] ?? '?'} · Max samples: ${metadata['max_samples'] ?? '?'}',
                    style:
                        const TextStyle(fontSize: 11, color: _Palette.subtle),
                  ),
                ],
                const Divider(height: 16),
                if (samples.isEmpty)
                  const Text('No samples available.',
                      style: TextStyle(color: _Palette.subtle))
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: samples.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final s = samples[i] as Map<String, dynamic>;
                        final filename = s['filename']?.toString() ?? '';
                        final createdAt = s['created_at']?.toString() ?? '';
                        final sizeKb = ((s['size_bytes'] as int?) ?? 0) / 1024;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            radius: 14,
                            backgroundColor: _Palette.accent.withOpacity(0.15),
                            child: Text('${i + 1}',
                                style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: _Palette.text)),
                          ),
                          title: Text(filename,
                              style: const TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            '${_fmtDate(createdAt)} · ${sizeKb.toStringAsFixed(1)} KB',
                            style: const TextStyle(
                                fontSize: 10, color: _Palette.subtle),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete,
                                size: 18, color: _Palette.badgeRed),
                            tooltip: 'Delete Sample',
                            onPressed: () {
                              Navigator.pop(ctx);
                              _confirmDeleteSample(ownerId, filename);
                            },
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        _showSnack('Error loading details: $e');
      }
    }
  }

  // ── Delete single sample ─────────────────────────────────────────
  Future<void> _confirmDeleteSample(String ownerId, String filename) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Voice Sample'),
        content: Text(
            'Delete "$filename" of $ownerId?\nThis action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _voiceApi.deleteSample(ownerId: ownerId, filename: filename);
      _showSnack('Deleted $filename');
      await _load();
    } catch (e) {
      _showSnack('Error deleting sample: $e');
    }
  }

  // ── Delete entire profile ────────────────────────────────────────
  Future<void> _confirmDeleteProfile(String ownerId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Entire Profile'),
        content: Text(
            'Delete all voice samples, calibration, and anti-spoof data for "$ownerId"?\n\n'
            '⚠ This action cannot be undone!'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Delete All', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _voiceApi.deleteProfile(ownerId: ownerId);
      _showSnack('Deleted profile $ownerId');
      await _load();
    } catch (e) {
      _showSnack('Error deleting profile: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalSamples =
        _profiles.fold<int>(0, (sum, p) => sum + p.sampleCount);

    return Scaffold(
      backgroundColor: _Palette.page,
      appBar: AppBar(
        backgroundColor: _Palette.page,
        elevation: 0,
        foregroundColor: _Palette.text,
        titleSpacing: 16,
        title: const Text(
          'Voice Library',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          color: _Palette.accent,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _SummaryCard(
                  totalProfiles: _profiles.length, totalSamples: totalSamples),
              const SizedBox(height: 16),
              if (_loading) ...[
                const _SkeletonCard(),
                const SizedBox(height: 12),
                const _SkeletonCard(),
              ] else if (_profiles.isEmpty) ...[
                _EmptyState(error: _error),
              ] else ...[
                ..._profiles.map((p) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _ProfileCard(
                        profile: p,
                        onTap: () => _showSampleDetails(p.ownerId),
                        onDelete: () => _confirmDeleteProfile(p.ownerId),
                      ),
                    )),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.totalProfiles, required this.totalSamples});

  final int totalProfiles;
  final int totalSamples;

  @override
  Widget build(BuildContext context) {
    return _SoftCard(
      child: Row(
        children: [
          _Badge(icon: Icons.library_music, color: _Palette.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Stored Voices',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: _Palette.text,
                      fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  '$totalProfiles profiles · $totalSamples samples',
                  style: const TextStyle(color: _Palette.subtle, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.onTap,
    required this.onDelete,
  });

  final _VoiceProfile profile;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: _SoftCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _Badge(icon: Icons.person, color: _Palette.badgeBlue),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.ownerId,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: _Palette.text,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${profile.sampleCount} sample(s)',
                    style:
                        const TextStyle(color: _Palette.subtle, fontSize: 13),
                  ),
                  if (profile.lastUpdated != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Updated: ${profile.lastUpdated}',
                      style:
                          const TextStyle(color: _Palette.subtle, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            _StatusBadge(
              label: profile.calibrated ? 'Calibrated' : 'Pending',
              color: profile.calibrated
                  ? _Palette.badgeGreen
                  : _Palette.badgeMuted,
              icon: profile.calibrated ? Icons.check : Icons.timelapse,
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.delete_forever,
                  size: 22, color: _Palette.badgeRed),
              tooltip: 'Xóa hồ sơ',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    return _SoftCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          const Icon(Icons.library_music_outlined,
              size: 44, color: _Palette.subtle),
          const SizedBox(height: 10),
          const Text(
            'No voice data available.',
            style: TextStyle(fontWeight: FontWeight.w700, color: _Palette.text),
          ),
          const SizedBox(height: 6),
          Text(
            error ??
                'No voice data available. When the backend is ready, tap Refresh to load.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _Palette.subtle, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) {
    return _SoftCard(
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(height: 12, width: 140, decoration: _shimmerBox),
                const SizedBox(height: 6),
                Container(height: 10, width: 90, decoration: _shimmerBox),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(color: Colors.white, offset: Offset(-4, -4), blurRadius: 8),
          BoxShadow(
              color: Color(0x1A1B2B45), offset: Offset(4, 6), blurRadius: 12),
        ],
      ),
      child: Icon(icon, color: color, size: 24),
    );
  }
}

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
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
              color: Colors.white, offset: Offset(-8, -8), blurRadius: 18),
          BoxShadow(
              color: Color(0x1A1B2B45), offset: Offset(8, 12), blurRadius: 24),
        ],
      ),
      child: child,
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge(
      {required this.label, required this.color, required this.icon});

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
          Text(label,
              style: TextStyle(color: color, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _VoiceProfile {
  const _VoiceProfile({
    required this.ownerId,
    required this.sampleCount,
    required this.calibrated,
    this.lastUpdated,
  });

  final String ownerId;
  final int sampleCount;
  final bool calibrated;
  final String? lastUpdated;
}

class _Palette {
  static const Color page = Color(0xFFF6F8FB);
  static const Color card = Color(0xFFEEF2F7);
  static const Color text = Color(0xFF2E3A4A);
  static const Color subtle = Color(0xFF6B7A90);
  static const Color accent = Color(0xFF4BE1EC);
  static const Color badgeBlue = Color(0xFF63A4FF);
  static const Color badgeGreen = Color(0xFF4CAF50);
  static const Color badgeMuted = Color(0xFFB0B8C6);
  static const Color badgeRed = Color(0xFFE53935);
}

const _shimmerBox = BoxDecoration(
  color: Color(0xFFE2E6EC),
  borderRadius: BorderRadius.all(Radius.circular(12)),
);
