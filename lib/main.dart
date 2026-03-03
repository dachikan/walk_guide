import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';

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

  @override
  void initState() {
    super.initState();
    _initializeAll();
  }

  Future<void> _initializeAll() async {
    await _initializeCamera();
    await _loadPackageInfo();
    await _loadAIPreference();
    await _initializeSpeech();
    _startAnalysisTimer();
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
        _version = 'v0.0.3+2'; // バージョンを明示的にハードコードして確実にする
      });
    } catch (e) {
      setState(() {
        _version = 'v0.0.3+2';
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
      _analysisTimer = Timer.periodic(Duration(seconds: 5), (timer) {
        if (_currentState == AppState.normal) {
          _analyzeScene();
        }
      });
      print('⏰ 解析タイマー開始（5秒間隔）');
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
      _lastImage = bytes;
      
      String result = await _analyzeWithGemini(bytes);
      
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

  // 音声認識開始 (Pixel 8 / Jelly / Huawei 対応強化版)
  Future<void> _startListening() async {
    if (!_speechAvailable) {
      await _speak('音声認識が利用できません');
      return;
    }

    print('🎤 音声認識セッション準備開始');
    
    // 1. 割り込み防止：TTS（読み上げ）を即座に停止
    await _tts.stop();
    
    // 2. 状態変更
    setState(() {
      _currentState = AppState.listening;
    });
    _stopAnalysisTimer();

    // 継続的なバイブレーション（受付中であることを示し続ける）
    Timer? vibrationTimer;
    void startContinuousVibration() {
      vibrationTimer = Timer.periodic(Duration(milliseconds: 1500), (timer) {
        if (_currentState == AppState.listening) {
          HapticFeedback.lightImpact();
        } else {
          timer.cancel();
        }
      });
    }

    // 3. オーディオセッションの競合回避のための微小待機
    await Future.delayed(Duration(milliseconds: 200));

    try {
      print('🎤 SpeechToText.listen 実行 (onDevice: true)');
      
      // 受付開始の合図（強めのバイブ）
      await HapticFeedback.vibrate(); 
      startContinuousVibration(); // 受付中の継続バイブ開始
      print('📳 バイブレーション開始：受付中');
      
      bool started = await _speech.listen(
        onResult: (result) {
          if (result.finalResult && result.recognizedWords.isNotEmpty) {
            print('🎯 認識成功: ${result.recognizedWords}');
            vibrationTimer?.cancel(); // 認識成功したらバイブ停止
            _executeCommand(result.recognizedWords);
          }
        },
        localeId: 'ja-JP',
        onDevice: true, 
        listenMode: stt.ListenMode.confirmation, 
        listenFor: Duration(seconds: 15), // 最大15秒待機
        pauseFor: Duration(seconds: 3),  // 3秒無音で自動終了
        cancelOnError: true,
      );

      if (!started) {
        print('❌ 音声認識の開始に失敗しました');
        vibrationTimer?.cancel();
        _returnToNormal();
      }

    } catch (e) {
      print('音声認識エラー: $e');
      vibrationTimer?.cancel();
      _returnToNormal();
    }
  }

  // コマンド実行
  Future<void> _executeCommand(String command) async {
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
    try {
      print('🔊 TTS開始: ${text.substring(0, text.length > 30 ? 30 : text.length)}...');
      
      await _tts.speak(text);
      
      // 文字数に基づく推定時間（日本語：1文字約0.12秒）
      int estimatedDuration = (text.length * 0.12).ceil();
      int waitTime = (estimatedDuration + 1).clamp(1, 20); // 1秒〜20秒の範囲
      
      print('🕰️ TTS完了待機: ${waitTime}秒');
      await Future.delayed(Duration(seconds: waitTime));
      print('✅ TTS完了');
      
    } catch (e) {
      print('TTS エラー: $e');
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
          '■「前方OK」は本当に完全に絶対的な安全が確認できた場合のみ使用してください。' +
          '■少しでも障害物、段差、工事、人、車両、不明な物体がある場合は、迷わず「前方注意」または具体的に位置を「○時の方向に△△があります」と伝えてください。' +
          '■逆光やボケなどで判断が困難な場合は、憶測で安全と言わず「状況が不明です。注意して進んでください」と警告してください。' +
          '■過剰に安全側の判断をすることは、この状況では正しい行動です。見落としは許されません。';
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
        return '🔵 通常解析中';
      case AppState.listening:
        return '🟣 音声受付中';
      case AppState.processing:
        return '🔴 処理中';
    }
  }

  @override
  void dispose() {
    _analysisTimer?.cancel();
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
                        style: TextStyle(
                          color: _currentState == AppState.listening ? Colors.purpleAccent : Colors.white, 
                          fontSize: 16, 
                          fontWeight: FontWeight.bold
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 音声入力待機中の視覚的強調（画面中央に大きな紫の円）
              if (_currentState == AppState.listening)
                Center(
                  child: Container(
                    width: 200,
                    height: 200,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.purple.withOpacity(0.3),
                      border: Border.all(color: Colors.purple, width: 4),
                    ),
                    child: Icon(Icons.mic, color: Colors.purple, size: 80),
                  ),
                ),
              // マイクボタン
              Positioned(
                bottom: 16,
                right: 16,
                child: FloatingActionButton(
                  backgroundColor: _currentState == AppState.listening
                      ? Colors.purple
                      : (_currentState == AppState.processing ? Colors.red : (_speechAvailable ? Colors.blue[700] : Colors.grey)),
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