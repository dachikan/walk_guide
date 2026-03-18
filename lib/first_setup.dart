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
      appBar: AppBar(title: Text('蛻晄悄繧ｻ繝・ヨ繧｢繝・・')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            Text('縺ｯ縺倥ａ縺ｫ縲・浹螢ｰ隱崎ｭ倥・繝・せ繝医→蛻晄悄險ｭ螳壹ｒ陦後＞縺ｾ縺吶・),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => widget.speak('菴ｿ縺医ｋ繧ｳ繝槭Φ繝峨〒縺吶・I螟画峩縺ｯ縲√ず繧ｧ繝溘ル縲√け繝ｭ繝ｼ繝峨；PT縲りｩｳ邏ｰ隱ｬ譏弱・縲∵勹濶ｲ縲∬ｪｬ譏弱ら樟蝨ｨ縺ｮAI縺ｯ縲、I縲ょ●豁｢縺ｯ縲√→縺ｾ繧後・),
              child: Text('繝倥Ν繝励さ繝槭Φ繝峨・譯亥・繧定◇縺・),
            ),
            SizedBox(height: 16),
            Text('繝槭う繧ｯ繝・せ繝茨ｼ医後≠繝ｼ縲阪→逋ｺ螢ｰ縺励※縺上□縺輔＞・・),
            ElevatedButton(
              onPressed: () => widget.micTest((level) => setState(() => _micLevel = level)),
              child: Text('繝槭う繧ｯ繝・せ繝磯幕蟋・),
            ),
            LinearProgressIndicator(value: _micLevel / 2),
            SizedBox(height: 16),
            Text('繧ｳ繝槭Φ繝芽ｪ崎ｭ倥ユ繧ｹ繝茨ｼ医梧勹濶ｲ縲阪→逋ｺ螢ｰ縺励※縺上□縺輔＞・・),
            ElevatedButton(
              onPressed: () => widget.commandTest((result) => setState(() => _commandResult = result)),
              child: Text('繧ｳ繝槭Φ繝峨ユ繧ｹ繝磯幕蟋・),
            ),
            Text('隱崎ｭ倡ｵ先棡: $_commandResult'),
            SizedBox(height: 16),
            Text('髻ｳ驥上＠縺阪＞蛟､隱ｿ謨ｴ'),
            Slider(
              value: _volumeThreshold,
              min: 0.01,
              max: 0.5,
              divisions: 49,
              label: _volumeThreshold.toStringAsFixed(2),
              onChanged: (v) => setState(() => _volumeThreshold = v),
            ),
            Text('辟｡髻ｳ讀懷・譎る俣・育ｧ抵ｼ・),
            DropdownButton<int>(
              value: _pauseFor,
              items: [1, 2, 3, 4, 5].map((v) => DropdownMenuItem(value: v, child: Text('$v遘・))).toList(),
              onChanged: (v) => setState(() => _pauseFor = v!),
            ),
            SizedBox(height: 24),
            ElevatedButton(
              onPressed: () async {
                await _saveSettings();
                if (mounted) Navigator.pop(context, true);
              },
              child: Text('險ｭ螳壹ｒ菫晏ｭ倥＠縺ｦ蟋九ａ繧・),
            ),
          ],
        ),
      ),
    );
  }
}
