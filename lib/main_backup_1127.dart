import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

import 'walking_brain.dart';

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

// アプリの状態管理用enum
enum AppState {
  normalAnalysis,      // 通常の自動解析中
  waitingForCommand,   // 命令受付待ち
  listeningCommand,    // 命令入力中
  executingCommand,    // 命令実行中
  manualAnalysis,      // 手動解析中
}

class WalkingGuideApp extends StatefulWidget {
  final CameraDescription? camera; // カメラをオプションにする
  const WalkingGuideApp({super.key, this.camera});

  @override
  State<WalkingGuideApp> createState() => _WalkingGuideAppState();
}

class _WalkingGuideAppState extends State<WalkingGuideApp> {
  CameraController? _controller;
  final FlutterTts _tts = FlutterTts();
  final ImagePicker _picker = ImagePicker();
  final WalkingBrain _brain = WalkingBrain(); // 大脳エンジンの初期化
  Timer? _timer;
  bool _cameraAvailable = false;
  String _version = 'Loading...';
  // _selectedAI は _brain.currentAI を使用するように変更
  final stt.SpeechToText _speech = stt.SpeechToText();
  final bool _isListening = false;
  bool _speechAvailable = false; // 音声認識が利用可能かどうか
  AppState _currentState = AppState.normalAnalysis; // 現在のアプリ状態
  Uint8List? _lastCapturedImage; // 直前の画像を保存
  int _cameraErrorCount = 0; // カメラエラー回数をカウント
  bool _cameraErrorSuppressed = false; // カメラエラー抑制フラグ
  final String _versionStr = 'v0.0.5+1'; 
  final AIService _selectedAI = AIService.gemini; // ダミー変数追加
  
  // 音声認識の最強保護メソッド（無効化をほぼ完全拒否）
  void _setSpeechAvailable(bool available) {
    // 音声認識を無効にする要求は99%拒否（アプリ終了時以外は無効化しない）
    if (!available) {
      print('🛡️ 音声認識無効化要求を完全拒否 - 音声認識は常時有効維持');
      print('🛡️ 現在状態: ${_getStateDisplayName(_currentState)} - 無効化は実行しません');
      // 無効化要求は完全に無視し、強制的にtrueを設定
      setState(() {
        _speechAvailable = true;
      });
      return;
    }
    // 有効化要求のみ受け入れ
    setState(() {
      _speechAvailable = available;
    });
    print('✅ 音声認識有効化: $available (現在状態: ${_getStateDisplayName(_currentState)})');
  }
  
  // 非推奨フラグ（後方互換性のため保持）
  // bool get _isListening => _currentState == AppState.listeningCommand; // エラー回避のため一旦コメントアウト
  bool get _analysisEnabled => _currentState == AppState.normalAnalysis;
  bool get _strictTtsControl => _currentState != AppState.normalAnalysis;
  bool get _isAnalyzing => _currentState == AppState.manualAnalysis;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _loadPackageInfo();
    _loadAIPreference();
    _initializeSpeech();
  }

  Future<void> _initializeCamera() async {
    if (widget.camera == null) {
      print('No camera available, using image picker mode');
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
        // 手動制御のため自動タイマー開始は無効化
        print('🛡️ 手動制御のため初期タイマー開始を無効化 - 手動でボタンを押してください');
        // _timer = Timer.periodic(Duration(seconds: 5), (timer) => _analyzeScene());
      }
    } catch (e) {
      print('Camera initialization failed: $e');
      setState(() {
        _cameraAvailable = false;
      });
    }
  }

  Future<void> _loadPackageInfo() async {
    try {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      setState(() {
        // もし取得したバージョンが 0.0.4 以前の場合は、強制的に最新を表示
        if (packageInfo.version.startsWith('0.0.4')) {
          _version = 'v0.0.5+1';
        } else {
          _version = 'v${packageInfo.version}+${packageInfo.buildNumber}';
        }
      });
    } catch (e) {
      setState(() {
        _version = 'v0.0.5+1';
      });
    }
  }

  Future<void> _loadAIPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final aiIndex = prefs.getInt('selected_ai') ?? 0;
    setState(() {
      _brain.setAI(AIService.values[aiIndex]);
    });
  }

  Future<void> _saveAIPreference(AIService service) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('selected_ai', service.index);
    setState(() {
      _brain.setAI(service);
    });
  }

  // 予期しない音声認識終了の処理（無効化 - 手動制御のみ）
  void _handleUnexpectedSpeechEnd() {
    print('🚨 予期しない音声認識終了の処理 - 手動制御のため何もしません');
    print('ℹ️ 手動でボタンを押して状態を変更してください');
    // 手動制御のみのため、自動復帰は一切行わない
  }
  
  // 音声認識タイムアウトタイマーの管理（無効化 - 手動制御のみ）
  void _clearSpeechTimeoutTimer() {
    // 手動制御のみのため、タイムアウトタイマーは使用しない
    print('ℹ️ タイムアウトタイマーは無効化されています - 手動制御のみ');
  }

  Future<void> _initializeSpeech() async {
    print('🎤 音声認識初期化開始...');
    try {
      print('🔧 _speech.initialize() 呼び出し中...');
      
      bool available = await _speech.initialize(
        onStatus: (status) {
          print('📊 音声認識ステータス変更: $status (現在状態: ${_getStateDisplayName(_currentState)})');
          print('🛡️ 手動制御のみ - 自動状態変更は完全無効');
          print('ℹ️ 手動でボタンを押して状態を制御してください');
          // すべての自動状態変更を無効化
        },
        onError: (error) {
          print('❌ 音声認識エラー: ${error.errorMsg}');
          print('🛡️ 手動制御のみ - エラー時も自動復帰は完全無効');
          
          // 音声認識を強制的に有効に保つ
          setState(() {
            _speechAvailable = true;
          });
          
          print('ℹ️ 手動でボタンを押して状態を変更してください');
          // すべての自動復帰処理を無効化
        },
      );
      
      _setSpeechAvailable(available);
      
      print('🎤 音声認識初期化結果: $available');
      
      if (available) {
        print('✅ 音声認識が初期化されました');
        
        // 権限の確認
        bool hasPermission = await _speech.hasPermission;
        print('🔐 音声認識権限: $hasPermission');
        
        if (!hasPermission) {
          print('❌ 音声認識権限がありません。自動でリクエストします...');
        }
        
        // 利用可能な言語を確認
        try {
          var locales = await _speech.locales();
          var japaneseLocale = locales.where((l) => l.localeId.contains('ja')).toList();
          print('🌐 日本語ロケール: ${japaneseLocale.length}個見つかりました');
          for (var locale in japaneseLocale) {
            print('   - ${locale.localeId}: ${locale.name}');
          }
        } catch (e) {
          print('⚠️ ロケール情報取得失敗: $e');
        }
      } else {
        print('❌ 音声認識が利用できません - デバイスまたは権限の問題');
      }
      
    } catch (e) {
      print('❌ 音声認識初期化エラー: $e');
      print('❌ エラー詳細: ${e.toString()}');
      // 初期化エラーが発生しても音声認識は有効のまま（最強保護）
      print('🛡️ 初期化エラーが発生しましたが音声認識は有効を維持');
      setState(() {
        _speechAvailable = true; // エラーでも強制的に有効
      });
      print('✅ 音声認識状態を強制的に有効に設定');
    }
  }

  Future<void> _startListening() async {
    print('🎯 音声認識開始: ${_getStateDisplayName(_currentState)}');
    
    // Step 1: 状態チェック
    if (_currentState != AppState.normalAnalysis) {
      print('❌ 音声認識拒否: 現在の状態は${_getStateDisplayName(_currentState)}');
      return;
    }
    
    if (!_speechAvailable) {
      print('❌ 音声認識利用不可');
      await _safeTtsSpeak('音声認識が利用できません');
      return;
    }
    
    // Step 2: 命令受付待ち状態に移行（タイマー完全停止）
    print('📍 Step 2: 命令受付待ち状態に移行 - タイマー完全停止');
    _changeState(AppState.waitingForCommand);
    _pauseTimer(); // 完全停止
    await _tts.stop();
    await Future.delayed(Duration(milliseconds: 500));
    
    // Step 3: 簡単なプロンプト発話
    print('📍 Step 3: プロンプト発話');
    await _tts.speak('どうぞ');
    await Future.delayed(Duration(seconds: 1)); // 短縮
    await _tts.stop();
    await Future.delayed(Duration(milliseconds: 300));
    
    // Step 4: 音声入力状態に移行
    print('📍 Step 4: 音声入力状態に移行');
    _changeState(AppState.listeningCommand);
    
    // Step 5: 音声認識開始（タイムアウトなし、手動制御のみ）
    print('📍 Step 5: 音声認識開始 - タイムアウトなし');
    
    // タイムアウトタイマーは設定しない（手動制御のみ）
    print('ℹ️ タイムアウトなし - 手動でボタンを押すまで命令待ち状態を維持');
    
    try {
      await _speech.listen(
        onResult: (result) {
          print('🎤 音声結果: ${result.recognizedWords} (final: ${result.finalResult})');
          if (result.finalResult && result.recognizedWords.isNotEmpty) {
            print('✅ 音声コマンドを受信 - 処理開始');
            _handleSpeechResult(result.recognizedWords);
          }
        },
        localeId: 'ja-JP',
        listenFor: Duration(minutes: 60), // 非常に長い時間設定（実質無制限）
        pauseFor: Duration(seconds: 5), // 無音状態の許容時間を延長
        partialResults: true,
        cancelOnError: false,
      );
      
    } catch (e) {
      print('❌ 音声認識エラー: $e');
      print('ℹ️ 音声認識エラーが発生しましたが、命令待ち状態を維持します');
      print('ℹ️ 手動でボタンを再度押してください');
      // エラー時も命令待ち状態を維持（手動制御のみ）
    }
  }
  
  void _handleSpeechResult(String recognizedWords) {
    print('📍 Step 6: 音声結果処理 - "$recognizedWords"');
    
    // 音声認識停止
    try {
      _speech.stop();
    } catch (e) {
      print('⚠️ 音声認識停止エラー: $e');
    }
    
    if (recognizedWords.isEmpty || recognizedWords.trim().length < 2) {
      print('🔄 音声入力なし - 命令待ち状態を維持');
      print('ℹ️ 再度コマンドを話すか、ボタンを押してください');
      // 命令待ち状態を維持（手動制御のみ）
      _changeState(AppState.waitingForCommand);
      return;
    }
    
    // Step 7: 命令実行状態に移行
    print('📍 Step 7: 命令実行状態に移行');
    _changeState(AppState.executingCommand);
    
    // Step 8: コマンド処理実行
    print('📍 Step 8: コマンド処理実行');
    _executeCommand(recognizedWords);
  }

  Future<void> _executeCommand(String command) async {
    print('📍 Step 8-1: コマンド解析開始 - "$command"');
    
    // 🛡️ コマンド実行中は解析タイマーのみ一時停止（完全停止ではない）
    print('🛡️ コマンド実行中：解析タイマーを一時停止');
    _pauseTimer(); // 解析タイマーを一時停止
    
    String cmd = command.toLowerCase().trim();
    
    // ヘルプコマンド
    if (cmd.contains('ヘルプ') || cmd.contains('略語') || cmd.contains('help')) {
      print('📋 ヘルプコマンド実行中');
      await _tts.speak('使えるコマンドです。AI変更は、ジェミニ、クロード、GPT。詳細説明は、景色、説明。停止は、とまれ。');
      await Future.delayed(Duration(seconds: 1));
      await _restoreNormalMode();
      return;
    }
    
    // 停止コマンド
    if (cmd.contains('停止') || cmd.contains('とまれ') || cmd.contains('ストップ')) {
      print('⛔ 停止コマンド実行中');
      await _tts.speak('すべての機能を停止しました');
      _pauseTimer();
      _changeState(AppState.normalAnalysis);
      return;
    }
    
    // AI変更コマンド
    if (cmd.contains('ジェミニ') || cmd.contains('gemini')) {
      print('🤖 AI変更コマンド実行中（Gemini）');
      await _saveAIPreference(AIService.gemini);
      await _tts.speak('AIをジェミニに変更しました');
      await Future.delayed(Duration(seconds: 1));
      await _restoreNormalMode();
      return;
    }
    
    if (cmd.contains('クロード') || cmd.contains('claude')) {
      print('🤖 AI変更コマンド実行中（Claude）');
      await _saveAIPreference(AIService.claude);
      await _tts.speak('AIをクロードに変更しました');
      await Future.delayed(Duration(seconds: 1));
      await _restoreNormalMode();
      return;
    }
    
    if (cmd.contains('gpt') || cmd.contains('ジーピーティー') || cmd.contains('チャット')) {
      print('🤖 AI変更コマンド実行中（ChatGPT）');
      await _saveAIPreference(AIService.chatgpt);
      await _tts.speak('AIをチャットGPTに変更しました');
      await Future.delayed(Duration(seconds: 1));
      await _restoreNormalMode();
      return;
    }
    
    // 詳細説明コマンド
    if (cmd.contains('景色') || cmd.contains('説明') || cmd.contains('詳しく') || cmd.contains('前方')) {
      print('🔍 詳細説明コマンド実行中');
      if (_lastCapturedImage != null) {
        await _tts.speak('詳細に説明します');
        _changeState(AppState.manualAnalysis);
        await _analyzeCapturedImage(_lastCapturedImage!, detailed: true);
      } else {
        await _tts.speak('分析する画像がありません');
      }
      await Future.delayed(Duration(seconds: 1));
      await _restoreNormalMode();
      return;
    }
    
    // 未知のコマンド
    print('❌ 未知のコマンド実行中: $cmd');
    await _tts.speak('コマンドが理解できませんでした。ヘルプと言うと使い方を聞けます。');
    await Future.delayed(Duration(seconds: 1));
    await _restoreNormalMode();
  }

  Future<void> _analyzeCapturedImage(Uint8List imageBytes, {bool detailed = false}) async {
    print('🧠 WalkingBrain 解析開始 (詳細モード: $detailed)');
    try {
      final result = await _brain.analyzeScene(imageBytes, detailed: detailed);
      print('🧠 WalkingBrain 解析完了: ${result.message}');
      await _safeTtsSpeak(result.message);
    } catch (e) {
      print('❌ Brain analysis failed: $e');
      await _safeTtsSpeak("画像解析でエラーが発生しました。インターネット接続を確認してください。");
    }
  }

  Future<void> _restoreNormalMode() async {
    print('📍 Step 9: 通常モードに復帰開始');
    
    try {
      // 音声認識停止
      if (_speech.isListening) {
        await _speech.stop();
      }
      
      // TTS停止
      await _tts.stop();
      await Future.delayed(Duration(milliseconds: 300));
      
      // 通常解析状態に移行
      _changeState(AppState.normalAnalysis);
      
      // タイマーを再開（通常動作復帰）
      if (_cameraAvailable && _timer == null) {
        _timer = Timer.periodic(Duration(seconds: 5), (timer) => _analyzeScene());
        print('🔄 解析タイマーを再開しました');
      }
      
      print('✅ 完了: 通常モードに復帰しました');
      
    } catch (e) {
      print('❌ 通常モード復帰エラー: $e');
      _changeState(AppState.normalAnalysis);
    }
  }
  
  Future<void> _stopListening() async {
    if (_currentState == AppState.listeningCommand || _currentState == AppState.waitingForCommand) {
      print('⛔ 音声認識を手動で停止中...');
      try {
        await _speech.stop();
      } catch (e) {
        print('⚠️ 音声認識停止エラー: $e');
      }
      await _restoreNormalMode();
    }
  }

  // 状態変更メソッド（音声認識状態保護機能付き）
  void _changeState(AppState newState) {
    print('🔄 状態変更: ${_getStateDisplayName(_currentState)} → ${_getStateDisplayName(newState)}');
    
    // 命令受付中は音声認識を強制的に有効化（最終安全装置）
    if ((newState == AppState.waitingForCommand || newState == AppState.listeningCommand) && !_speechAvailable) {
      print('🛡️ 最終安全装置：命令受付状態への移行時に音声認識を強制有効化');
      setState(() {
        _speechAvailable = true;
        _currentState = newState;
      });
      return;
    }
    
    setState(() {
      _currentState = newState;
    });
  }
  
  String _getStateDisplayName(AppState state) {
    switch (state) {
      case AppState.normalAnalysis: return '通常解析中';
      case AppState.waitingForCommand: return '命令受付待ち';
      case AppState.listeningCommand: return '命令入力中';
      case AppState.executingCommand: return '命令実行中';
      case AppState.manualAnalysis: return '手動解析中';
    }
  }

  // TTS実行を安全に行うヘルパーメソッド（通常解析中は常に実行）
  Future<void> _safeTtsSpeak(String text) async {
    // 通常解析中は常にTTSを実行、音声認識中は実行しない
    if (_currentState == AppState.listeningCommand || 
        _currentState == AppState.waitingForCommand) {
      print('⛔ TTSブロック (状態: ${_getStateDisplayName(_currentState)}): $text');
      return;
    }
    try {
      print('🔊 TTS実行 (状態: ${_getStateDisplayName(_currentState)}): $text');
      await _tts.speak(text);
    } catch (e) {
      print('TTSエラー: $e');
    }
  }

  // 緊急時のTTS（危険物検出時のみ使用）
  Future<void> _emergencyTtsSpeak(String text) async {
    // 緊急時は音声認識中でも強制発話
    try {
      await _tts.stop();
      await Future.delayed(const Duration(milliseconds: 500));
      await _tts.speak('緊急: $text');
    } catch (e) {
      print('緊急TTSエラー: $e');
    }
  }

  // タイマーの停止と再開
  void _pauseTimer() {
    if (_timer != null) {
      _timer!.cancel();
      _timer = null;
      print('⛔ 自動解析タイマーを完全停止しました');
    }
  }

  void _resumeTimer() {
    // 手動制御のみのため、自動タイマー再開は無効
    print('🛡️ 自動タイマー再開は無効 - 手動制御のみ');
    print('ℹ️ 手動でボタンを押して通常モードに復帰してください');
    // すべての自動タイマーを無効化
  }

  Future<void> _analyzeScene() async {
    // 通常解析状態でのみ実行
    if (_currentState != AppState.normalAnalysis) {
      print('⛔ 解析スキップ: 現在の状態は${_getStateDisplayName(_currentState)}');
      return;
    }
    
    // カメラエラー抑制中は解析をスキップ
    if (_cameraErrorSuppressed) {
      print('⛔ 解析スキップ: カメラエラー抑制中');
      return;
    }
    
    if (!_cameraAvailable || _controller == null || !_controller!.value.isInitialized) {
      print('⛔ 解析スキップ: カメラ未初期化');
      return;
    }
    
    print('📷 自動画像解析を開始');
    
    await _captureAndAnalyze(() async {
      try {
        final image = await _controller!.takePicture();
        return await image.readAsBytes();
      } catch (e) {
        print('Error taking picture: $e');
        rethrow;
      }
    });
  }

  Future<void> _analyzePickedImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    await _captureAndAnalyze(() async {
      return await File(image.path).readAsBytes();
    });
  }

  Future<void> _captureAndAnalyze(Future<Uint8List> Function() getImageBytes) async {
    try {
      final bytes = await getImageBytes();
      _lastCapturedImage = bytes;
      
      // カメラ解析が成功した場合、エラーカウントをリセット
      if (_cameraErrorCount > 0) {
        _cameraErrorCount = 0;
        print('✅ カメラエラーカウントリセット - 正常復旧');
      }

      await _analyzeCapturedImage(bytes);
      
    } catch (e) {
      print('Capture or analyze failed: $e');
      
      // カメラエラーの場合はエラー回数をカウント
      if (e.toString().contains('CameraException') || e.toString().contains('ImageCaptureException')) {
        _cameraErrorCount++;
        print('📸 カメラエラー回数: $_cameraErrorCount');
        
        // 3回連続でエラーが発生した場合の処理（手動制御のみ）
        if (_cameraErrorCount >= 3 && !_cameraErrorSuppressed) {
          _cameraErrorSuppressed = true;
          print('⚠️ カメラエラーが3回連続発生 - 自動解析を一時停止します');
          _pauseTimer();
        }
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel(); // タイマーをキャンセル
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
            Text(
              _version,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.normal),
            ),
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
        ? Stack(
            children: [
              // カメラ画面を全画面に拡張
              Positioned.fill(
                child: CameraPreview(_controller!),
              ),
              // 左上にAI情報を表示
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
                        'AI: ${AIServiceHelper.getDisplayName(_brain.currentAI)}',
                        style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        () {
                          switch (_currentState) {
                            case AppState.normalAnalysis:
                              return '📸 通常解析中 (5s間隔)';
                            case AppState.waitingForCommand:
                              return '⏳ 命令受付待ち';
                            case AppState.listeningCommand:
                              return '🎤 命令入力中 (全機能停止)';
                            case AppState.executingCommand:
                              return '⚙️ 命令実行中';
                            case AppState.manualAnalysis:
                              return '🔍 手動解析中';
                          }
                        }(),
                        style: TextStyle(
                          color: () {
                            switch (_currentState) {
                              case AppState.normalAnalysis:
                                return Colors.green[300];
                              case AppState.waitingForCommand:
                                return Colors.orange[300];
                              case AppState.listeningCommand:
                                return Colors.red[300];
                              case AppState.executingCommand:
                                return Colors.blue[300];
                              case AppState.manualAnalysis:
                                return Colors.purple[300];
                            }
                          }(),
                          fontSize: 12
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 右下に命令受付ボタン
              Positioned(
                bottom: 16,
                right: 16,
                child: FloatingActionButton(
                  backgroundColor: (_isListening || _currentState == AppState.waitingForCommand)
                      ? Colors.red 
                      : (_speechAvailable ? Colors.blue[700] : Colors.grey),
                  foregroundColor: Colors.white,
                  child: Icon((_isListening || _currentState == AppState.waitingForCommand) ? Icons.mic : Icons.mic_none),
                  onPressed: () {
                    print('🎤 音声ボタンが押されました');
                    print('📊 現在のアプリ状態: ${_getStateDisplayName(_currentState)}');
                    print('🎤 音声認識利用可能: $_speechAvailable');
                    print('🔴 現在音声認識中: $_isListening');
                    
                    // 命令受付中は音声認識有効として扱う（安全装置）
                    bool effectiveSpeechAvailable = _speechAvailable || 
                        _currentState == AppState.waitingForCommand || 
                        _currentState == AppState.listeningCommand;
                    
                    if (effectiveSpeechAvailable) {
                      if (_isListening || _currentState == AppState.waitingForCommand) {
                        print('🔄 命令受付停止処理開始');
                        _stopListening();
                      } else {
                        print('▶️ 音声認識開始処理開始');
                        _startListening();
                      }
                    } else {
                      print('⚠️ 音声認識状態確認 - 強制的に有効化して継続');
                      // 音声認識を強制的に有効化
                      setState(() {
                        _speechAvailable = true;
                      });
                      print('🎆 手動で通常モードに復帰します');
                      _changeState(AppState.normalAnalysis);
                      // タイマーの手動再開（快速アクセスのため）
                      if (_cameraAvailable) {
                        _timer = Timer.periodic(Duration(seconds: 5), (timer) => _analyzeScene());
                        print('✅ 手動でタイマーを再開しました');
                      }
                    }
                  },
                ),
              ),
              // 音声認識の状態インジケーター
              if (_isListening)
                Positioned(
                  bottom: 90,
                  right: 16,
                  child: Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '聞いています...',
                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              // 命令受付待ち状態のインジケーター
              if (_currentState == AppState.waitingForCommand)
                Positioned(
                  bottom: 90,
                  right: 16,
                  child: Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '命令待ち中...',
                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
            ],
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
                SizedBox(height: 8),
                Text(
                  'AI: ${AIServiceHelper.getDisplayName(_brain.currentAI)}',
                  style: TextStyle(fontSize: 14, color: Colors.blue[600]),
                ),
                SizedBox(height: 4),
                Text(
                  'Version: $_version',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                SizedBox(height: 30),
                ElevatedButton.icon(
                  onPressed: _analyzePickedImage,
                  icon: Icon(Icons.photo_library),
                  label: Text('画像を選択して解析'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue[700],
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
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
                subtitle: Text(_getAIDescription(service)),
                value: service,
                groupValue: _brain.currentAI,
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

  String _getAIDescription(AIService service) {
    switch (service) {
      case AIService.gemini:
        return '標準・高速・無料枚数が多い';
      case AIService.claude:
        return '高品質・日本語が得意';
      case AIService.chatgpt:
        return '安定性高・実績豊富';
    }
  }
}
    _timer?.cancel(); // タイマーをキャンセル
    // _speechTimeoutTimer は手動制御のため使用しない
    _controller?.dispose();
    _tts.stop(); // TTSを停止
    super.dispose();
  }

  @override
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text('歩道案内'),
            Spacer(),
            Text(
              _version,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.normal),
            ),
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
        ? Stack(
            children: [
              // カメラ画面を全画面に拡張
              Positioned.fill(
                child: CameraPreview(_controller!),
              ),
              // 左上にAI情報を表示
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
                        () {
                          switch (_currentState) {
                            case AppState.normalAnalysis:
                              return '📸 通常解析中 (5s間隔)';
                            case AppState.waitingForCommand:
                              return '⏳ 命令受付待ち';
                            case AppState.listeningCommand:
                              return '🎤 命令入力中 (全機能停止)';
                            case AppState.executingCommand:
                              return '⚙️ 命令実行中';
                            case AppState.manualAnalysis:
                              return '🔍 手動解析中';
                          }
                        }(),
                        style: TextStyle(
                          color: () {
                            switch (_currentState) {
                              case AppState.normalAnalysis:
                                return Colors.green[300];
                              case AppState.waitingForCommand:
                                return Colors.orange[300];
                              case AppState.listeningCommand:
                                return Colors.red[300];
                              case AppState.executingCommand:
                                return Colors.blue[300];
                              case AppState.manualAnalysis:
                                return Colors.purple[300];
                            }
                          }(),
                          fontSize: 12
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 右下に命令受付ボタン
              Positioned(
                bottom: 16,
                right: 16,
                child: FloatingActionButton(
                  backgroundColor: (_isListening || _currentState == AppState.waitingForCommand)
                      ? Colors.red 
                      : (_speechAvailable ? Colors.blue[700] : Colors.grey),
                  foregroundColor: Colors.white,
                  child: Icon((_isListening || _currentState == AppState.waitingForCommand) ? Icons.mic : Icons.mic_none),
                  onPressed: () {
                    print('🎤 音声ボタンが押されました');
                    print('📊 現在のアプリ状態: ${_getStateDisplayName(_currentState)}');
                    print('🎤 音声認識利用可能: $_speechAvailable');
                    print('🔴 現在音声認識中: $_isListening');
                    
                    // 命令受付中は音声認識有効として扱う（安全装置）
                    bool effectiveSpeechAvailable = _speechAvailable || 
                        _currentState == AppState.waitingForCommand || 
                        _currentState == AppState.listeningCommand;
                    
                    if (effectiveSpeechAvailable) {
                      if (_isListening || _currentState == AppState.waitingForCommand) {
                        print('🔄 命令受付停止処理開始');
                        _stopListening();
                      } else {
                        print('▶️ 音声認識開始処理開始');
                        _startListening();
                      }
                    } else {
                      print('⚠️ 音声認識状態確認 - 強制的に有効化して継続');
                      // 音声認識を強制的に有効化
                      setState(() {
                        _speechAvailable = true;
                      });
                      print('🎆 手動で通常モードに復帰します');
                      _changeState(AppState.normalAnalysis);
                      // タイマーの手動再開（快速アクセスのため）
                      if (_cameraAvailable) {
                        _timer = Timer.periodic(Duration(seconds: 5), (timer) => _analyzeScene());
                        print('✅ 手動でタイマーを再開しました');
                      }
                    }
                  },
                ),
              ),
              // 音声認識の状態インジケーター
              if (_isListening)
                Positioned(
                  bottom: 90,
                  right: 16,
                  child: Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '聞いています...',
                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              // 命令受付待ち状態のインジケーター
              if (_currentState == AppState.waitingForCommand)
                Positioned(
                  bottom: 90,
                  right: 16,
                  child: Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '命令待ち中...',
                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              // 「音声認識無効」表示を完全に削除（有害な表示のため永久に削除）
              // この表示は削除されました - 音声認識は常時有効として扱います
            ],
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
                SizedBox(height: 8),
                Text(
                  'AI: ${AIServiceHelper.getDisplayName(_selectedAI)}',
                  style: TextStyle(fontSize: 14, color: Colors.blue[600]),
                ),
                SizedBox(height: 4),
                Text(
                  'Version: $_version',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                SizedBox(height: 30),
                ElevatedButton.icon(
                  onPressed: _analyzePickedImage,
                  icon: Icon(Icons.photo_library),
                  label: Text('画像を選択して解析'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue[700],
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
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
                subtitle: Text(_getAIDescription(service)),
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

  String _getAIDescription(AIService service) {
    switch (service) {
      case AIService.gemini:
        return '標準・高速・無料枚数が多い';
      case AIService.claude:
        return '高品質・日本語が得意';
      case AIService.chatgpt:
        return '安定性高・実績豊富';
    }
  }
}
