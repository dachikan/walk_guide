import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FirstSetupScreen extends StatefulWidget {
  final Future<void> Function(String) speak;
  final Future<void> Function(Function(double)) micTest;
  final Future<void> Function(Function(String)) commandTest;
  final double initialVolumeThreshold;
  final int initialPauseFor;
  const FirstSetupScreen({
    required this.speak,
    required this.micTest,
    required this.commandTest,
    required this.initialVolumeThreshold,
    required this.initialPauseFor,
    super.key,
  });

  @override
  State<FirstSetupScreen> createState() => _FirstSetupScreenState();
}

class _FirstSetupScreenState extends State<FirstSetupScreen> {
  double _micLevel = 0.0;
  String _commandResult = '';
  double _volumeThreshold = 0.1;
  int _pauseFor = 3;

  @override
  void initState() {
    super.initState();
    _volumeThreshold = widget.initialVolumeThreshold;
    _pauseFor = widget.initialPauseFor;
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('volume_threshold', _volumeThreshold);
    await prefs.setInt('pause_for', _pauseFor);
    await prefs.setBool('first_setup_done', true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('初期セットアップ')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            Text('はじめに、音声認識のテストと初期設定を行います。'),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => widget.speak('使えるコマンドです。AI変更は、ジェミニ、クロード、GPT。詳細説明は、景色、説明。現在のAIは、AI。停止は、とまれ。'),
              child: Text('ヘルプコマンドの案内を聞く'),
            ),
            SizedBox(height: 16),
            Text('マイクテスト（「あー」と発声してください）'),
            ElevatedButton(
              onPressed: () => widget.micTest((level) => setState(() => _micLevel = level)),
              child: Text('マイクテスト開始'),
            ),
            LinearProgressIndicator(value: _micLevel / 2),
            SizedBox(height: 16),
            Text('コマンド認識テスト（「景色」と発声してください）'),
            ElevatedButton(
              onPressed: () => widget.commandTest((result) => setState(() => _commandResult = result)),
              child: Text('コマンドテスト開始'),
            ),
            Text('認識結果: $_commandResult'),
            SizedBox(height: 16),
            Text('音量しきい値調整'),
            Slider(
              value: _volumeThreshold,
              min: 0.01,
              max: 0.5,
              divisions: 49,
              label: _volumeThreshold.toStringAsFixed(2),
              onChanged: (v) => setState(() => _volumeThreshold = v),
            ),
            Text('無音検出時間（秒）'),
            DropdownButton<int>(
              value: _pauseFor,
              items: [1, 2, 3, 4, 5].map((v) => DropdownMenuItem(value: v, child: Text('$v秒'))).toList(),
              onChanged: (v) => setState(() => _pauseFor = v!),
            ),
            SizedBox(height: 24),
            ElevatedButton(
              onPressed: () async {
                await _saveSettings();
                if (mounted) Navigator.pop(context, true);
              },
              child: Text('設定を保存して始める'),
            ),
          ],
        ),
      ),
    );
  }
}
