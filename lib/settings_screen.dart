import 'package:flutter/material.dart';
import 'models.dart';
import 'voice_settings_screen.dart';
import 'route_settings_screen.dart';

/// 設定メニュー画面
/// AppBarの⚙️ボタンから遷移する。補助者が目で見て操作することを前提とする。
/// 設定中は音声コマンドが無効化される（呼び出し元で制御）。
class SettingsScreen extends StatefulWidget {
  final AIService currentAI;
  final Future<void> Function(AIService) onAIChanged;
  final Future<void> Function(String) speak;
  final Future<void> Function(Function(double)) micTest;
  final Future<void> Function(Function(String)) commandTest;
  final double initialVolumeThreshold;
  final int initialPauseFor;

  const SettingsScreen({
    required this.currentAI,
    required this.onAIChanged,
    required this.speak,
    required this.micTest,
    required this.commandTest,
    required this.initialVolumeThreshold,
    required this.initialPauseFor,
    super.key,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AIService _currentAI;

  @override
  void initState() {
    super.initState();
    _currentAI = widget.currentAI;
  }

  void _showAIDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AIサービスを選択'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: AIService.values.map((service) {
            return RadioListTile<AIService>(
              title: Text(AIServiceHelper.getDisplayName(service)),
              subtitle: Text(AIServiceHelper.getDescription(service)),
              value: service,
              groupValue: _currentAI,
              onChanged: (value) async {
                if (value != null) {
                  await widget.onAIChanged(value);
                  setState(() {
                    _currentAI = value;
                  });
                  if (ctx.mounted) Navigator.of(ctx).pop();
                }
              },
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('キャンセル'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
        backgroundColor: Colors.blue[700],
        foregroundColor: Colors.white,
      ),
      body: ListView(
        children: [
          // ── AIサービス選択 ─────────────────────────────────
          ListTile(
            leading: Icon(Icons.smart_toy, color: Colors.blue[700]),
            title: const Text('🤖 AIサービス選択'),
            subtitle: Text('現在: ${AIServiceHelper.getDisplayName(_currentAI)}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showAIDialog,
          ),
          const Divider(height: 1),

          // ── 音声認識調整 ─────────────────────────────────
          ListTile(
            leading: Icon(Icons.mic, color: Colors.blue[700]),
            title: const Text('🎤 音声認識調整'),
            subtitle: const Text('音量レベル・無音検出時間の設定'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => VoiceSettingsScreen(
                    speak: widget.speak,
                    micTest: widget.micTest,
                    commandTest: widget.commandTest,
                    initialVolumeThreshold: widget.initialVolumeThreshold,
                    initialPauseFor: widget.initialPauseFor,
                  ),
                ),
              );
            },
          ),
          const Divider(height: 1),

          // ── ルート設定 ─────────────────────────────────
          ListTile(
            leading: Icon(Icons.route, color: Colors.blue[700]),
            title: const Text('📍 ルート設定'),
            subtitle: const Text('ウェイポイントの登録・ルート選択'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const RouteSettingsScreen(),
                ),
              );
            },
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}
