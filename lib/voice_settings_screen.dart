import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 音声認識調整画面
/// 設定メニューからいつでも呼び出せる（初回セットアップ以外でも利用可能）
class VoiceSettingsScreen extends StatefulWidget {
  final Future<void> Function(String) speak;
  final Future<void> Function(Function(double)) micTest;
  final Future<void> Function(Function(String)) commandTest;
  final double initialVolumeThreshold;
  final int initialPauseFor;

  const VoiceSettingsScreen({
    required this.speak,
    required this.micTest,
    required this.commandTest,
    required this.initialVolumeThreshold,
    required this.initialPauseFor,
    super.key,
  });

  @override
  State<VoiceSettingsScreen> createState() => _VoiceSettingsScreenState();
}

class _VoiceSettingsScreenState extends State<VoiceSettingsScreen> {
  double _micLevel = 0.0;
  String _commandResult = '';
  double _volumeThreshold = 0.1;
  int _pauseFor = 3;
  late TextEditingController _promptController;

  static const String _defaultPrompt = '【ルート案内優先】あなたは視覚障害者の歩行ガイドです。'
      '目的：ルートに従って次の地点へ案内すること。'
      '指示：次の地点の方位と距離、危険の有無を、[直進]、[右折]、[左折]、[30度右へ]、などの簡潔な言葉（極力漢字2文字）で伝えてください。'
      '周辺に危険がある場合のみ、[電柱危険]、[右前に溝]など、短く警告してください。'
      '地点に到達（距離3m以内など）した場合は、[地点1到達]、[目的地到達]などと報告してください。';

  @override
  void initState() {
    super.initState();
    _volumeThreshold = widget.initialVolumeThreshold;
    _pauseFor = widget.initialPauseFor;
    _promptController = TextEditingController();
    _checkInitialPrompt();
  }

  Future<void> _checkInitialPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPrompt = prefs.getString('custom_navigation_prompt');
    
    // アプリ側のデフォルトと保存されているものが違う場合、または保存されていない場合は
    // ソース側の最新デフォルトを強制適用（あるいはユーザーに確認させるべきだが、
    // ここでは「ソースと合わせる」要求に基づき、未保存時はソース優先にする）
    setState(() {
      _promptController.text = savedPrompt ?? _defaultPrompt;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('volume_threshold', _volumeThreshold);
    await prefs.setInt('pause_for', _pauseFor);
    await prefs.setString('custom_navigation_prompt', _promptController.text);
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('詳細設定'),
        backgroundColor: Colors.blue[700],
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            const Text(
              'ルート案内用プロンプト編集',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text(
              '10秒ごとの自動案内に使用されるプロンプトです。目的や指示を調整できます。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _promptController,
              maxLines: 6,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'プロンプトを入力してください',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  setState(() {
                    _promptController.text = _defaultPrompt;
                  });
                },
                icon: const Icon(Icons.refresh),
                label: const Text('初期設定に戻す'),
              ),
            ),
            const Divider(height: 32),
            ElevatedButton.icon(
              onPressed: () => widget.speak(
                '使えるコマンドです。'
                'AI変更は、ジェミニ、クロード、GPT。'
                '詳細説明は、景色、説明。'
                '現在のAIは、AI。'
                '停止は、とまれ。',
              ),
              icon: const Icon(Icons.volume_up),
              label: const Text('ヘルプコマンドの案内を聞く'),
            ),
            const SizedBox(height: 24),
            const Text(
              'マイクテスト',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Text('「あー」と発声してマイクの感度を確認します'),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () => widget.micTest(
                (level) => setState(() => _micLevel = level),
              ),
              icon: const Icon(Icons.mic),
              label: const Text('マイクテスト開始'),
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: (_micLevel / 2).clamp(0.0, 1.0)),
            const SizedBox(height: 24),
            const Text(
              'コマンド認識テスト',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Text('「景色」と発声してコマンド認識を確認します'),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () => widget.commandTest(
                (result) => setState(() => _commandResult = result),
              ),
              icon: const Icon(Icons.record_voice_over),
              label: const Text('コマンドテスト開始'),
            ),
            const SizedBox(height: 4),
            Text('認識結果: $_commandResult'),
            const SizedBox(height: 24),
            const Text(
              '音量しきい値',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Text('この値より小さい音量は無視されます（小さいほど敏感）'),
            Slider(
              value: _volumeThreshold,
              min: 0.01,
              max: 0.5,
              divisions: 49,
              label: _volumeThreshold.toStringAsFixed(2),
              onChanged: (v) => setState(() => _volumeThreshold = v),
            ),
            const SizedBox(height: 8),
            const Text(
              '無音検出時間',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Text('この時間の無音を検知するとコマンド入力を終了します'),
            const SizedBox(height: 4),
            DropdownButton<int>(
              value: _pauseFor,
              items: [1, 2, 3, 4, 5]
                  .map((v) =>
                      DropdownMenuItem(value: v, child: Text('$v秒')))
                  .toList(),
              onChanged: (v) => setState(() => _pauseFor = v!),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () async {
                await _saveSettings();
                if (mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.save),
              label: const Text('保存して戻る'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue[700],
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
