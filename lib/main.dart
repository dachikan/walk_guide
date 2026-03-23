import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // HapticFeedback のために追加
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    // .envファイルを読み込む
    await dotenv.load(fileName: ".walking_guide.env");
    
    // APIキーの存在確認
    if (dotenv.env['GEMINI_API_KEY'] == null) {
      throw Exception('GEMINI_API_Key is not set in .walking_guide.env file');
    }
    
    // カメラの初期化を試みる
    CameraDescription? camera;
    try {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
        camera = cameras.first;
      }
    } catch (e) {
      print('Camera initialization failed, using fallback mode: $e');
    }
    
    runApp(MaterialApp(home: WalkingGuideApp(camera: camera)));
  } catch (e) {
    print('Failed to initialize app: $e');
    runApp(MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('アプリの初期化に失敗しました: $e'),
        ),
      ),
    ));
  }
}

// AIサービスの種類
enum AIService {
  gemini,
  claude,
  chatgpt,
}

class AIServiceHelper {
  static String getDisplayName(AIService service) {
    switch (service) {
      case AIService.gemini:
        return 'Google Gemini';
      case AIService.claude:
        return 'Claude (Anthropic)';
      case AIService.chatgpt:
        return 'ChatGPT (OpenAI)';
    }
  }
}

// シンプルな状態管理
enum AppState {
  normal,           // 通常状態（解析中）
  listening,        // 音声コマンド待ち
  processing,       // コマンド処理中
}

class WalkingGuideApp extends StatefulWidget {
  final CameraDescription? camera;
  const WalkingGuideApp({super.key, this.camera});

  @override
  State<WalkingGuideApp> createState() => _WalkingGuideAppState();
}

class _WalkingGuideAppState extends State<WalkingGuideApp> {
  CameraController? _controller;
  final FlutterTts _tts = FlutterTts();
  final ImagePicker _picker = ImagePicker();
  Timer? _analysisTimer;
  bool _cameraAvailable = false;
  String _version = 'Loading...';
  AIService _selectedAI = AIService.gemini;
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechAvailable = false;
  AppState _currentState = AppState.normal;
  Uint8List? _lastImage;
  Timer? _heartbeatTimer; // 心音用タイマー
  bool _isSpeaking = false; // TTS発話中かどうかのフラグ
  bool _isExecutingCommand = false; // コマンド処理の再入防止
  /// 「どうぞ」発話完了後、STT開始までの追加待ち（ms）。機種差調整用（SharedPreferences）
  int _sttDelayAfterCueMs = 250;

  @override
  void initState() {
    super.initState();
    _initializeAll();
  }

  Future<void> _initializeAll() async {
    await _initializeCamera();
    await _loadPackageInfo();
    await _loadAIPreference();
    await _loadVoicePrefs();
    await _configureTts();
    await _initializeSpeech();
    _startAnalysisTimer();
    _startHeartbeat(); // 心音（バイブレーション）開始
    
    // 起動直後の状況説明：カメラ準備OKなら即座に1回解析を実行
    if (_cameraAvailable) {
      print('🚀 起動直後の自動解析実行');
      _analyzeScene();
    }
  }

  // 心音（常時生存確認バイブ）の開始
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(Duration(seconds: 4), (timer) {
      _playHeartbeat();
    });
    print('💓 ハートビートタイマー開始（4秒間隔バイブ）');
  }

  // ハートビート（バイブレーション）の実行
  // 通常解析中（normal）かつ案内発話中でないときだけ「強め」。コマンド系は従来どおり軽い vibrate。
  void _playHeartbeat() {
    if (!mounted) return;
    try {
      if (_currentState == AppState.normal && !_isSpeaking) {
        HapticFeedback.heavyImpact();
        Future<void>.delayed(const Duration(milliseconds: 120), () {
          if (!mounted) return;
          if (_currentState == AppState.normal && !_isSpeaking) {
            HapticFeedback.mediumImpact();
          }
        });
        print('📳 ハートビート（通常解析・強め）');
      } else if (_currentState == AppState.listening ||
          _currentState == AppState.processing) {
        HapticFeedback.vibrate();
        print('📳 ハートビート（コマンド系・従来）');
      }
    } catch (e) {
      print('バイブレーションエラー: $e');
    }
  }

  /// TTS の発話完了を await できるようにする（「どうぞ」直後のSTT開始を早める）
  Future<void> _configureTts() async {
    try {
      await _tts.awaitSpeakCompletion(true);
      print('✅ TTS awaitSpeakCompletion 有効');
    } catch (e) {
      print('TTS 設定エラー: $e');
    }
  }

  Future<void> _loadVoicePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _sttDelayAfterCueMs = (prefs.getInt('stt_delay_after_cue_ms') ?? 250).clamp(0, 2000);
    });
  }

  Future<void> _saveSttDelayAfterCueMs(int ms) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('stt_delay_after_cue_ms', ms);
    if (mounted) {
      setState(() {
        _sttDelayAfterCueMs = ms;
      });
    }
  }

  Future<void> _initializeCamera() async {
    if (widget.camera == null) {
      print('カメラなし：画像選択モード');
      setState(() {
        _cameraAvailable = false;
      });
      return;
    }

    try {
      _controller = CameraController(widget.camera!, ResolutionPreset.medium);
      await _controller!.initialize();
      
      if (mounted) {
        setState(() {
          _cameraAvailable = true;
        });
        print('✅ カメラ初期化完了');
      }
    } catch (e) {
      print('カメラ初期化失敗: $e');
      setState(() {
        _cameraAvailable = false;
      });
    }
  }

  Future<void> _loadPackageInfo() async {
    try {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      setState(() {
        _version = 'v${packageInfo.version}+${packageInfo.buildNumber}';
      });
    } catch (e) {
      setState(() {
        _version = 'v0.0.7+3'; // バージョン v0.0.7+3 に更新
      });
    }
  }

  Future<void> _loadAIPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final aiIndex = prefs.getInt('selected_ai') ?? 0;
    setState(() {
      _selectedAI = AIService.values[aiIndex];
    });
  }

  Future<void> _saveAIPreference(AIService service) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('selected_ai', service.index);
    setState(() {
      _selectedAI = service;
    });
  }

  Future<void> _initializeSpeech() async {
    print('🎤 音声認識初期化中...');
    try {
      bool available = await _speech.initialize();
      setState(() {
        _speechAvailable = available;
      });
      
      if (available) {
        print('✅ 音声認識初期化完了');
      } else {
        print('❌ 音声認識利用不可');
      }
    } catch (e) {
      print('音声認識初期化エラー: $e');
      setState(() {
        _speechAvailable = false;
      });
    }
  }

  // 解析タイマー開始
  void _startAnalysisTimer() {
    if (_cameraAvailable) {
      _analysisTimer = Timer.periodic(Duration(seconds: 10), (timer) {
        if (_currentState == AppState.normal) {
          _analyzeScene();
        }
      });
      print('⏰ 解析タイマー開始（10秒間隔）');
    }
  }

  // 解析タイマー停止
  void _stopAnalysisTimer() {
    _analysisTimer?.cancel();
    _analysisTimer = null;
    print('⏸️ 解析タイマー停止');
  }

  // 解析タイマー再開
  void _resumeAnalysisTimer() {
    if (_cameraAvailable && _analysisTimer == null) {
      _startAnalysisTimer();
    }
  }

  Future<void> _analyzeScene() async {
    if (!_cameraAvailable || _controller == null || !_controller!.value.isInitialized) {
      return;
    }
    
    print('📸 自動解析実行');
    
    try {
      final image = await _controller!.takePicture();
      final bytes = await image.readAsBytes();
      // 撮影中に音声待機へ切り替えた場合は解析を中止
      if (_currentState != AppState.normal) return;

      _lastImage = bytes;
      
      String result = await _analyzeWithGemini(bytes);
      if (_currentState != AppState.normal) return;

      // 通常状態でのみTTS実行
      if (_currentState == AppState.normal) {
        await _speak(result);
        print('🔊 解析結果: $result');
      }
      
    } catch (e) {
      print('解析エラー: $e');
    }
  }

  Future<void> _analyzePickedImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    try {
      final bytes = await File(image.path).readAsBytes();
      _lastImage = bytes;
      
      String result = await _analyzeWithGemini(bytes);
      await _speak(result);
      print('🔊 画像解析結果: $result');
      
    } catch (e) {
      print('画像解析エラー: $e');
      await _speak('画像解析でエラーが発生しました');
    }
  }

  // 音声認識開始
  Future<void> _startListening() async {
    if (!_speechAvailable) {
      await _speak('音声認識が利用できません');
      return;
    }

    // 自動解析の案内TTS中にタップした場合、従来は _isSpeaking のまま「どうぞ」がスキップされ、
    // バックグラウンドの推定待ちが終わるまでコマンド待機が始まらない。案内を即中断する。
    try {
      await _tts.stop();
    } catch (_) {}
    _isSpeaking = false;
    
    print('🎤 音声認識開始');
    
    // 即座に状態変更（ユーザーフィードバック優先）
    setState(() {
      _currentState = AppState.listening;
    });
    
    _stopAnalysisTimer();
    
    await _speak('どうぞ');
    // TTS完了後、機種差に合わせた短い余裕（設定で0〜2000ms）
    if (_sttDelayAfterCueMs > 0) {
      await Future.delayed(Duration(milliseconds: _sttDelayAfterCueMs));
    }
    
    try {
      print('🎤 音声認識開始（継続待機モード）');
      
      await _speech.listen(
        onResult: (result) {
          if (result.finalResult && result.recognizedWords.isNotEmpty) {
            if (_currentState != AppState.listening) return;
            if (_isExecutingCommand) return;
            print('🎯 音声入力: ${result.recognizedWords}');
            _executeCommand(result.recognizedWords);
          }
        },
        localeId: 'ja-JP',
        listenFor: Duration(seconds: 300), // 5分間継続（実質ユーザーが止めるまで）
        pauseFor: Duration(seconds: 3),
      );
      
      // listening状態が維持されているなら、音声認識を継続
      // （ユーザーが手動停止した場合のみ状態が変わる）
      
    } catch (e) {
      print('音声認識エラー: $e');
      _returnToNormal();
    }
  }

  // コマンド実行
  Future<void> _executeCommand(String command) async {
    if (_isExecutingCommand) return;
    _isExecutingCommand = true;

    print('⚙️ コマンド実行: $command');
    
    setState(() {
      _currentState = AppState.processing;
    });
    
    await _speech.stop();
    
    String cmd = command.toLowerCase().trim();
    
    try {
      if (cmd.contains('ヘルプ') || cmd.contains('help')) {
        await _speak('使えるコマンドです。AI変更は、ジェミニ、クロード、GPT。詳細説明は、景色、説明。現在のAIは、AI。停止は、とまれ。');
        
      } else if (cmd.contains('ai') || cmd.contains('エーアイ') || cmd.contains('現在のai') || cmd.contains('どのai')) {
        String currentAI = AIServiceHelper.getDisplayName(_selectedAI);
        await _speak('現在のAIは、$currentAI です');
        
      } else if (cmd.contains('ジェミニ') || cmd.contains('gemini')) {
        await _saveAIPreference(AIService.gemini);
        await _speak('AIをジェミニに変更しました');
        
      } else if (cmd.contains('クロード') || cmd.contains('claude')) {
        await _saveAIPreference(AIService.claude);
        await _speak('AIをクロードに変更しました');
        
      } else if (cmd.contains('gpt') || cmd.contains('チャット')) {
        await _saveAIPreference(AIService.chatgpt);
        await _speak('AIをチャットGPTに変更しました');
        
      } else if (cmd.contains('景色') || cmd.contains('説明') || cmd.contains('詳しく')) {
        // 詳細説明中は自動解析を完全停止（割り込み防止）
        _stopAnalysisTimer();
        print('🚫 詳細説明中：自動解析停止');
        
        if (_lastImage != null) {
          // 短く簡潔なプロンプトで即座開始
          await _speak('詳細に説明します');
          
          // Gemini解析を即座実行（待機時間短縮）
          print('🔍 Gemini詳細解析開始');
          String result = await _analyzeWithGemini(_lastImage!, detailedPrompt: true);
          print('🔍 解析結果取得完了');
          
          // 詳細説明を確実に最後まで発話
          await _speak(result);
          print('✅ 詳細説明完了');
          
        } else {
          await _speak('分析する画像がありません');
        }
        
      } else if (cmd.contains('停止') || cmd.contains('とまれ')) {
        await _speak('すべての機能を停止しました');
        _stopAnalysisTimer();
        
      } else {
        await _speak('コマンドが理解できませんでした。ヘルプと言うと使い方を聞けます。');
      }
      
    } catch (e) {
      print('コマンド実行エラー: $e');
      await _speak('コマンド実行でエラーが発生しました');
    } finally {
      _isExecutingCommand = false;
    }
    
    // コマンド完了後は通常モードに復帰（自動解析再開）
    await Future.delayed(Duration(seconds: 1));
    _returnToNormal();
  }

  // 通常モードに戻る
  void _returnToNormal() {
    print('🔄 通常モードに復帰');
    setState(() {
      _currentState = AppState.normal;
    });
    _resumeAnalysisTimer();
  }
  
  // 状態の役割履行チェック
  void _validateStateRole() {
    if (_currentState == AppState.listening && !_speech.isListening) {
      print('⚠️ 状態役割不一致検出: listening状態なのに音声認識停止中');
      _returnToNormal();
    }
  }

  // 音声認識停止
  void _stopListening() {
    print('⏹️ 音声認識停止');
    _speech.stop();
    _returnToNormal();
  }

  // TTS実行（完了まで確実に待機）
  Future<void> _speak(String text) async {
    if (_isSpeaking) {
      print('⚠️ TTS発話連発を回避します');
      return;
    }
    
    try {
      _isSpeaking = true;
      print('🔊 TTS開始: ${text.substring(0, text.length > 30 ? 30 : text.length)}...');
      
      // 案内用音声設定（通常の音量・ピッチ）
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      
      await _tts.speak(text);
      // awaitSpeakCompletion(true) により、上記の発話完了まで待機される想定
      print('✅ TTS完了');
      
    } catch (e) {
      print('TTS エラー: $e');
    } finally {
      _isSpeaking = false;
    }
  }

  // Gemini解析
  Future<String> _analyzeWithGemini(Uint8List bytes, {bool detailedPrompt = false}) async {
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey == null) {
      throw Exception('Gemini APIキーが設定されていません');
    }

    final model = GenerativeModel(
      model: 'gemini-2.5-flash-lite',
      apiKey: apiKey,
    );

    String promptText;
    if (detailedPrompt) {
      promptText = '【重要】あなたは視覚障害者の命を預かる歩行介助者です。' +
          '前方に見える景色、道の状況、障害物、建物、人、車両、信号機、標識など、' +
          'すべての重要な情報を具体的に日本語で説明してください。' +
          '少しでも危険の可能性があるものは必ず指摘してください。';
    } else {
      promptText = '【緊急重要】あなたは視覚障害者の歩行を支援する介助者AIです。この人の命と安全があなたの判断にかかっています。' +
          '画像を慎重に分析し、以下の基準で判断してください：' +
          '■「前方OK」は本当に完全に安全な場合のみ使用' +
          '■少しでも障害物・段差・工事・人・車両・不明物があれば「前方注意」または具体的位置「○時の方向に△△があります」' +
          '■見えにくい・判断困難な場合は「注意して進んでください」' +
          '■安全すぎる判断は良いことです。見落としは絶対に避けてください。';
    }

    final prompt = TextPart(promptText);
    final imagePart = DataPart('image/jpeg', bytes);

    final response = await model.generateContent([
      Content.multi([prompt, imagePart])
    ]);

    return response.text ?? "解析できませんでした";
  }

  String _getStateDisplayName() {
    switch (_currentState) {
      case AppState.normal:
        return '🔄 通常解析中';
      case AppState.listening:
        return '🎤 音声待機中';
      case AppState.processing:
        return '⚙️ 処理中';
    }
  }

  @override
  void dispose() {
    _analysisTimer?.cancel();
    _heartbeatTimer?.cancel(); // 心音タイマーをキャンセル
    _controller?.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text('歩道案内'),
            Spacer(),
            Text(_version, style: TextStyle(fontSize: 14)),
          ],
        ),
        backgroundColor: Colors.blue[700],
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(Icons.tune),
            tooltip: '音声コマンド待ちの調整',
            onPressed: _showVoiceTimingDialog,
          ),
          IconButton(
            icon: Icon(Icons.settings),
            onPressed: _showAISelectionDialog,
          ),
        ],
      ),
      body: _cameraAvailable && _controller != null && _controller!.value.isInitialized 
        ? GestureDetector(
            // 画面全体タッチで音声認識開始（視覚障碍者に優しい）
            onTap: () {
              print('👆 画面タッチで音声認識操作');
              if (_currentState == AppState.listening) {
                _stopListening();
              } else if (_currentState == AppState.normal) {
                _startListening();
              }
            },
            child: Stack(
              children: [
              Positioned.fill(
                child: CameraPreview(_controller!),
              ),
              // 状態表示
              Positioned(
                top: 16,
                left: 16,
                child: Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI: ${AIServiceHelper.getDisplayName(_selectedAI)}',
                        style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        _getStateDisplayName(),
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              // マイクボタン
              Positioned(
                bottom: 16,
                right: 16,
                child: FloatingActionButton(
                  backgroundColor: (_currentState == AppState.listening || _currentState == AppState.processing)
                      ? Colors.red 
                      : (_speechAvailable ? Colors.blue[700] : Colors.grey),
                  foregroundColor: Colors.white,
                  child: Icon((_currentState == AppState.listening || _currentState == AppState.processing) 
                      ? Icons.mic : Icons.mic_none),
                  onPressed: () {
                    if (_currentState == AppState.listening) {
                      _stopListening();
                    } else if (_currentState == AppState.normal) {
                      _startListening();
                    }
                  },
                ),
              ),
            ],
          ),
        )
        : Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.camera_alt, size: 100, color: Colors.grey),
                SizedBox(height: 20),
                Text(
                  'カメラが利用できません',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 10),
                Text(
                  '画像を選択して解析をテストできます',
                  style: TextStyle(fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 30),
                ElevatedButton.icon(
                  onPressed: _analyzePickedImage,
                  icon: Icon(Icons.photo_library),
                  label: Text('画像を選択して解析'),
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

  void _showVoiceTimingDialog() {
    int tempMs = _sttDelayAfterCueMs;
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            return AlertDialog(
              title: Text('音声コマンドのタイミング'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '「どうぞ」のあと、マイクが有効になるまでの追加待ち（0〜2000ミリ秒）。'
                    '早すぎて拾えない場合は増やす、遅いと感じる場合は減らしてください。',
                    style: TextStyle(fontSize: 13),
                  ),
                  SizedBox(height: 12),
                  Text('${tempMs} ms'),
                  Slider(
                    value: tempMs.toDouble(),
                    min: 0,
                    max: 2000,
                    divisions: 40,
                    label: '${tempMs} ms',
                    onChanged: (v) {
                      setLocal(() {
                        tempMs = v.round();
                      });
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('キャンセル'),
                ),
                TextButton(
                  onPressed: () async {
                    await _saveSttDelayAfterCueMs(tempMs);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showAISelectionDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('AIサービスを選択'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: AIService.values.map((service) {
              return RadioListTile<AIService>(
                title: Text(AIServiceHelper.getDisplayName(service)),
                value: service,
                groupValue: _selectedAI,
                onChanged: (AIService? value) {
                  if (value != null) {
                    _saveAIPreference(value);
                    Navigator.of(context).pop();
                  }
                },
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('キャンセル'),
            ),
          ],
        );
      },
    );
  }
}