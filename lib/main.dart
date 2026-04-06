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
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:geolocator/geolocator.dart'; // 位置情報
import 'package:csv/csv.dart'; // CSV
import 'walking_route.dart'; // 地点データ
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

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
  AIService _selectedAI = AIService.chatgpt;
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechAvailable = false;
  AppState _currentState = AppState.normal;
  Uint8List? _lastImage;
  Uint8List? _previousImage; // 10秒前（前回）の画像：短期記憶（海馬）用
  String? _lastAnalysisResult; // 前回の解析結果：差分分析用
  Timer? _heartbeatTimer; // 心音用タイマー
  bool _isSpeaking = false; // TTS発話中かどうかのフラグ
  bool _isExecutingCommand = false; // コマンド処理の再入防止
  
  // 小脳（ローカル解析）関連
  ObjectDetector? _objectDetector;
  bool _isLocalAnalyzing = false;
  List<String> _currentDetections = [];

  // お散歩の友（GPSナビゲーション）関連
  WalkRoute? _selectedRoute;
  StreamSubscription<Position>? _positionStream;
  NaviPoint? _lastAnnouncedPoint;
  double? _currentHeading; // 現在の方位

  /// 「どうぞ」発話完了後、STT開始までの追加待ち（ms）。機種差調整用（SharedPreferences）
  int _sttDelayAfterCueMs = 250;

  @override
  void initState() {
    super.initState();
    _initializeAll();
  }

  Future<void> _initializeAll() async {
    await _initializeCamera();
    await _initializeLocalAI(); // 小脳の初期化
    await _loadPackageInfo();
    await _loadAIPreference();
    await _loadVoicePrefs();
    await _configureTts();
    await _initializeSpeech();
    await _initializeLocation(); // GPSナビの初期化
    await _ensureRouteDirectory(); // ルートディレクトリの準備
    _startAnalysisTimer();
    _startHeartbeat(); // 心音（バイブレーション）開始
    
    // 起動直後の状況説明：カメラ準備OKなら即座に1回解析を実行
    if (_cameraAvailable) {
      print('🚀 起動直後の自動解析実行');
      _analyzeScene();
    }
  }

  /// 外部ストレージのrouteフォルダを準備する
  Future<void> _ensureRouteDirectory() async {
    try {
      Directory? baseDir;
      if (Platform.isAndroid) {
        baseDir = await getExternalStorageDirectory(); // Android: /Storage/emulated/0/Android/data/com.example.app/files
      } else {
        baseDir = await getApplicationDocumentsDirectory();
      }

      if (baseDir != null) {
        final routeDirPath = p.join(baseDir.path, 'route');
        final routeDir = Directory(routeDirPath);
        if (!(await routeDir.exists())) {
          await routeDir.create(recursive: true);
          print('📁 ルート用ディレクトリを作成しました: $routeDirPath');
          
          // 初回作成時にサンプルファイルを置いておくと親切
          final sampleFile = File(p.join(routeDirPath, 'readme.txt'));
          await sampleFile.writeAsString('このフォルダに .csv ファイルを置くと「ルート」コマンドで読み込めます。');
        } else {
          print('📂 ルート用ディレクトリは既に存在します: $routeDirPath');
        }
      }
    } catch (e) {
      print('❌ ルートディレクトリ準備エラー: $e');
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
      _controller = CameraController(widget.camera!, ResolutionPreset.medium, enableAudio: false);
      await _controller!.initialize();
      
      if (mounted) {
        setState(() {
          _cameraAvailable = true;
        });
        print('✅ カメラ初期化完了');
        
        // 小脳（ローカル解析）ストリーム開始
        _startLocalStream();
      }
    } catch (e) {
      print('カメラ初期化失敗: $e');
      setState(() {
        _cameraAvailable = false;
      });
    }
  }

  // 小脳（ローカル解析）の初期化
  Future<void> _initializeLocalAI() async {
    final options = ObjectDetectorOptions(
      mode: DetectionMode.stream,
      classifyObjects: true,
      multipleObjects: true,
    );
    _objectDetector = ObjectDetector(options: options);
    print('🧠 小脳（ObjectDetector）初期化完了');
  }

  // カメラストリームによるリアルタイム解析の開始
  void _startLocalStream() {
    if (_controller == null || !_controller!.value.isInitialized) return;

    _controller!.startImageStream((CameraImage image) {
      if (_currentState != AppState.normal || _isLocalAnalyzing) return;
      _processLocalImage(image);
    });
    print('👁️ 小脳ストリーム開始');
  }

  Future<void> _processLocalImage(CameraImage image) async {
    if (_objectDetector == null) return;
    _isLocalAnalyzing = true;

    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final Size imageSize = Size(image.width.toDouble(), image.height.toDouble());
      final InputImageRotation imageRotation = InputImageRotation.rotation0deg;
      final InputImageFormat inputImageFormat = InputImageFormatValue.fromRawValue(image.format.raw) ?? InputImageFormat.nv21;

      final inputImageData = InputImageMetadata(
        size: imageSize,
        rotation: imageRotation,
        format: inputImageFormat,
        bytesPerRow: image.planes[0].bytesPerRow,
      );

      final inputImage = InputImage.fromBytes(bytes: bytes, metadata: inputImageData);
      final objects = await _objectDetector!.processImage(inputImage);

      List<String> labels = [];
      bool urgentDanger = false;

      for (var obj in objects) {
        for (var label in obj.labels) {
          labels.add(label.text);
          // 緊急回避判定（例：車が中央に大きく映った場合など、ここでは簡易的に特定のラベルで判定）
          if (label.text.toLowerCase().contains('car') || label.text.toLowerCase().contains('person')) {
             // 面積が一定以上なら緊急
             if ((obj.boundingBox.width * obj.boundingBox.height) > (image.width * image.height * 0.3)) {
               urgentDanger = true;
             }
          }
        }
      }

      if (urgentDanger && !_isSpeaking) {
        // 短い振動で警告（大脳を介さない反射）
        HapticFeedback.vibrate();
        print('⚡ 反射：緊急回避バイブ');
      }

      _currentDetections = labels;
      
    } catch (e) {
      print('小脳解析エラー: $e');
    } finally {
      // 負荷軽減のため少し待ってから次へ
      await Future.delayed(Duration(milliseconds: 500));
      _isLocalAnalyzing = false;
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
        _version = 'v0.0.11+10'; // バージョン v0.0.11+10 に更新
      });
    }
  }

  Future<void> _loadAIPreference() async {
    final prefs = await SharedPreferences.getInstance();
    // デフォルトを AIService.chatgpt (インデックス 2) に変更
    final aiIndex = prefs.getInt('selected_ai') ?? 2;
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

  /// 位置情報とナビゲーションの初期化
  Future<void> _initializeLocation() async {
    print('📍 位置情報初期化中...');
    
    // パーミッション確認
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    
    if (permission == LocationPermission.deniedForever) {
      print('❌ 位置情報パーミッションが永続的に拒否されています');
      return;
    }

    // 位置情報の監視開始
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2, // 2メートル移動ごとに更新
      ),
    ).listen((Position position) {
      _checkRoutePoint(position);
    });

    // 標準ルート（自宅ルート）の自動読み込み
    _loadDefaultRoute();

    print('✅ 位置情報監視開始');
  }

  /// 起動時にデフォルトのルートを読み込む
  Future<void> _loadDefaultRoute() async {
    try {
      final String csvContent = await rootBundle.loadString('assets/routes/home_route.csv');
      await _loadRouteFromCsv(csvContent, "自宅ルート");
    } catch (e) {
      print('ℹ️ デフォルトルートの読み込みをスキップ: $e');
    }
  }

  /// 現在地とルート上の地点を照合し、案内が必要なら発話する
  void _checkRoutePoint(Position position) {
    if (_selectedRoute == null || _isSpeaking) return;

    for (var point in _selectedRoute!.points) {
      double distance = point.distanceTo(position);
      
      // 設定された距離以内に入ったか
      if (distance <= point.triggerDistance) {
        // 同じ地点を連続で案内しないように管理
        if (_lastAnnouncedPoint?.no != point.no) {
          print('🔔 地点案内実行: ${point.message} (距離: ${distance.toStringAsFixed(1)}m)');
          _speak(point.message);
          _lastAnnouncedPoint = point;
          break;
        }
      }
    }
  }

  /// ルートCSVの読み込み
  Future<void> _loadRouteFromCsv(String csvContent, String routeName) async {
    try {
      List<List<dynamic>> rows = const CsvToListConverter().convert(csvContent);
      List<NaviPoint> points = [];
      
      for (var row in rows) {
        if (row.length >= 5) {
          points.add(NaviPoint.fromCsv(row));
        }
      }

      setState(() {
        _selectedRoute = WalkRoute(name: routeName, points: points);
        _lastAnnouncedPoint = null;
      });
      print('✅ ルート読み込み完了: $routeName (${points.length}地点)');
      await _speak('${routeName}のガイドを開始します');
      
      // ルート読み込み直後に即座に方向と距離を案内
      await _analyzeForNavigation();
    } catch (e) {
      print('❌ ルート読み込みエラー: $e');
    }
  }

  /// 現在地から次の目標地点への方向と距離を案内（GPSナビゲーション）
  Future<void> _analyzeForNavigation() async {
    if (_selectedRoute == null || _selectedRoute!.points.isEmpty) return;
    if (_isSpeaking) return;

    try {
      // 現在地を取得
      Position currentPos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // 次の目標地点を特定（まだ到達していない最初の地点）
      NaviPoint? targetPoint;
      for (var point in _selectedRoute!.points) {
        double distance = point.distanceTo(currentPos);
        
        // まだ到達していない地点（5m以上離れている）を次の目標とする
        if (distance > 5.0) {
          targetPoint = point;
          break;
        }
      }

      // すべての地点に到達済みの場合、最後の地点を目標とする
      if (targetPoint == null && _selectedRoute!.points.isNotEmpty) {
        targetPoint = _selectedRoute!.points.last;
      }

      if (targetPoint == null) return;

      // 距離を計算
      double currentDistance = targetPoint.distanceTo(currentPos);
      
      // 方位を計算（北を0度として時計回りに360度）
      double bearing = Geolocator.bearingBetween(
        currentPos.latitude,
        currentPos.longitude,
        targetPoint.latitude,
        targetPoint.longitude,
      );
      
      // 方位を時計の向きに変換（0度=北=12時）
      int clockDirection = ((bearing + 360) % 360 / 30).round();
      if (clockDirection == 0) clockDirection = 12;

      // 案内メッセージを作成
      String targetLabel = targetPoint.message.isNotEmpty ? targetPoint.message : '地点${targetPoint.no}';
      String promptModifier = '';

      // 3m以内なら到達報告
      if (currentDistance <= 3.0) {
        promptModifier = '$targetLabel に到達しました。';
      } else {
        promptModifier = '$targetLabel は、${clockDirection}時方向、${currentDistance.toStringAsFixed(0)}メートルです。';
      }

      print('🧭 ナビゲーション案内: $promptModifier');
      await _speak(promptModifier);

    } catch (e) {
      print('❌ ナビゲーション案内エラー: $e');
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
    // 補助者が設定や地図を操作中の時は、自動解析（クラウドAI）を停止する
    // これにより誤入力を防ぎ、通信エラーの連呼を防止する
    if (ModalRoute.of(context)?.isCurrent == false) {
      print('⏳ 補助者操作中のため解析スキップ');
      return;
    }

    if (!_cameraAvailable || _controller == null || !_controller!.value.isInitialized) {
      return;
    }
    
    print('📸 自動解析実行');
    
    try {
      final image = await _controller!.takePicture();
      final bytes = await image.readAsBytes();
      // 撮影中に音声待機へ切り替えた場合は解析を中止
      if (_currentState != AppState.normal) return;

      // 短期記憶（海馬）処理：前回の画像をスライド
      _previousImage = _lastImage;
      _lastImage = bytes;
      
      String result;
      if (_previousImage != null && _lastAnalysisResult != null) {
        // 短期記憶を活用した差分解析
        result = await _analyzeWithMemory(bytes, _previousImage!, _lastAnalysisResult!);
      } else {
        // 初回または画像がない場合は通常解析
        result = await _analyzeCurrentAI(bytes);
      }
      
      if (_currentState != AppState.normal) return;

      // 通常状態でのみTTS実行
      if (_currentState == AppState.normal) {
        _lastAnalysisResult = result; // 解析結果を記録（次回の海馬用）
        await _speak(result);
        print('🔊 解析結果: $result');
      }
      
    } catch (e) {
      print('解析エラー: $e');
      if (_currentState == AppState.normal) {
        await _speak('通信エラー');
        // ステップ4：詳細エラーを「後出し」で説明
        String errorDetail = e.toString();
        if (errorDetail.contains('GenerativeAIException')) {
          await _speak('AIサービスが一時的に利用できません。時間をおいて試してください。');
        } else if (errorDetail.contains('SocketException')) {
          await _speak('インターネット接続を確認してください。');
        } else {
          await _speak('詳細な状況： $errorDetail');
        }
      }
    }
  }

  Future<void> _analyzePickedImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    try {
      final bytes = await File(image.path).readAsBytes();
      _lastImage = bytes;
      
      String result = await _analyzeCurrentAI(bytes);
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
          
          try {
            // 解析を即座実行（待機時間短縮）
            print('🔍 AI詳細解析開始');
            String result = await _analyzeCurrentAI(_lastImage!, detailedPrompt: true);
            print('🔍 解析結果取得完了');
            
            // 詳細説明を確実に最後まで発話
            await _speak(result);
            print('✅ 詳細説明完了');
          } catch (e) {
            print('詳細説明エラー: $e');
            await _speak('通信エラー');
            // ステップ4：詳細エラーを「後出し」
            await _speak('詳細なエラー内容は次のとおりです。${e.toString()}');
          }
          
        } else {
          await _speak('分析する画像がありません');
        }
        
      } else if (cmd.contains('停止') || cmd.contains('とまれ')) {
        await _speak('すべての機能を停止しました');
        _stopAnalysisTimer();
        
      } else if (cmd.contains('じたく')) {
        final String csvContent = await rootBundle.loadString('assets/routes/home_route.csv');
        await _loadRouteFromCsv(csvContent, "自宅ルート");

      } else if (cmd.contains('ゆうじん')) {
        final String csvContent = await rootBundle.loadString('assets/routes/friend_home.csv');
        await _loadRouteFromCsv(csvContent, "友人自宅ルート");

      } else if (cmd.contains('ルート') || cmd.contains('ナビ')) {
        // スマホ内の route フォルダにある CSV ファイルを読み込む
        await _promptRouteSelection();

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

  /// スマホ内部の route フォルダをスキャンし、CSVの読み込みを促す
  Future<void> _promptRouteSelection() async {
    try {
      Directory? baseDir;
      if (Platform.isAndroid) {
        baseDir = await getExternalStorageDirectory();
      } else {
        baseDir = await getApplicationDocumentsDirectory();
      }

      if (baseDir != null) {
        final routeDirPath = p.join(baseDir.path, 'route');
        final routeDir = Directory(routeDirPath);
        
        if (await routeDir.exists()) {
          final files = routeDir.listSync().whereType<File>().where((f) => f.path.endsWith('.csv')).toList();
          
          if (files.isEmpty) {
            await _speak('route フォルダに CSV ファイルが見つかりませんでした。');
            return;
          }

          // 全ファイルを読み込んで、現在地に最も近い地点を含むルートを探す
          File? bestFile;
          double minDistance = double.infinity;
          String bestFileName = "";
          
          Position currentPos = await Geolocator.getCurrentPosition();

          for (var file in files) {
            final content = await file.readAsString();
            List<List<dynamic>> rows = const CsvToListConverter().convert(content);
            for (var row in rows) {
              if (row.length >= 3) {
                double targetLat = double.tryParse(row[1].toString()) ?? 0;
                double targetLng = double.tryParse(row[2].toString()) ?? 0;
                double dist = Geolocator.distanceBetween(currentPos.latitude, currentPos.longitude, targetLat, targetLng);
                if (dist < minDistance) {
                  minDistance = dist;
                  bestFile = file;
                  bestFileName = p.basename(file.path);
                }
              }
            }
          }

          if (bestFile != null) {
            await _speak('現在地に近いルート、 $bestFileName を読み込みます');
            final content = await bestFile.readAsString();
            await _loadRouteFromCsv(content, bestFileName);
          } else {
            // 見つからない場合は従来通り最新のファイル
            files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
            final targetFile = files.first;
            final fileName = p.basename(targetFile.path);
            await _speak('$fileName を読み込みます');
            final content = await targetFile.readAsString();
            await _loadRouteFromCsv(content, fileName);
          }
        } else {
          await _speak('route フォルダが見つかりません。');
          await _ensureRouteDirectory();
        }
      }
    } catch (e) {
      print('❌ ルート選択エラー: $e');
      await _speak('ファイル読み込み中にエラーが発生しました');
    }
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

  // ステップ６：短期記憶（海馬）を活用した解析
  Future<String> _analyzeWithMemory(Uint8List currentImage, Uint8List previousImage, String previousResult) async {
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey == null) {
      // Gemini が使えない場合は、現在のAIで通常解析（フォールバック）
      return await _analyzeCurrentAI(currentImage);
    }

    final model = GenerativeModel(
      model: 'gemini-2.5-flash-lite',
      apiKey: apiKey,
    );

    final promptText = '【重要：短期記憶（海馬）解析】あなたは視覚障害者の歩行介助AIです。'
        '1枚目の画像は「約10秒前の景色」で、その解析結果は「$previousResult」でした。'
        '2枚目の画像は「現在の景色」です。'
        '10秒前との変化（近づいたもの、新しく現れたもの、去ったもの、信号の変化など）を重点的に分析し、'
        '安全のために知っておくべき「現在の状況」を簡潔に。'
        '※「前回との差」を説明するのではなく、あくまで「今の状況」として伝えてください。';

    final prompt = TextPart(promptText);
    final previousPart = DataPart('image/jpeg', previousImage);
    final currentPart = DataPart('image/jpeg', currentImage);

    try {
      final response = await model.generateContent([
        Content.multi([prompt, previousPart, currentPart])
      ]);
      return response.text ?? "解析できませんでした";
    } catch (e) {
      print('海馬解析エラー: $e');
      // エラー時は現在のAIで通常解析にフォールバック
      return await _analyzeCurrentAI(currentImage);
    }
  }

  // AI 選択に応じた解析の振り分け
  Future<String> _analyzeCurrentAI(Uint8List bytes, {bool detailedPrompt = false}) async {
    switch (_selectedAI) {
      case AIService.gemini:
        return await _analyzeWithGemini(bytes, detailedPrompt: detailedPrompt);
      case AIService.claude:
        return await _analyzeWithClaude(bytes, detailedPrompt: detailedPrompt);
      case AIService.chatgpt:
        return await _analyzeWithChatGPT(bytes, detailedPrompt: detailedPrompt);
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

    String promptText = _getPromptText(detailedPrompt);

    final prompt = TextPart(promptText);
    final imagePart = DataPart('image/jpeg', bytes);

    final response = await model.generateContent([
      Content.multi([prompt, imagePart])
    ]);

    return response.text ?? "解析できませんでした";
  }

  // Claude解析 (Anthropic API)
  Future<String> _analyzeWithClaude(Uint8List bytes, {bool detailedPrompt = false}) async {
    final apiKey = dotenv.env['CLAUDE_API_KEY'];
    if (apiKey == null) throw Exception('Claude APIキーが設定されていません');

    final String base64Image = base64Encode(bytes);
    final String promptText = _getPromptText(detailedPrompt);

    final response = await http.post(
      Uri.parse('https://api.anthropic.com/v1/messages'),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode({
        'model': 'claude-3-5-sonnet-20240620',
        'max_tokens': 1024,
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/jpeg',
                  'data': base64Image,
                },
              },
              {
                'type': 'text',
                'text': promptText,
              }
            ],
          }
        ],
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      return data['content'][0]['text'] ?? "解析できませんでした";
    } else {
      throw Exception('Claude API Error: ${response.statusCode} ${response.body}');
    }
  }

  // ChatGPT解析 (OpenAI API)
  Future<String> _analyzeWithChatGPT(Uint8List bytes, {bool detailedPrompt = false}) async {
    final apiKey = dotenv.env['OPENAI_API_KEY'];
    if (apiKey == null) throw Exception('OpenAI APIキーが設定されていません');

    final String base64Image = base64Encode(bytes);
    final String promptText = _getPromptText(detailedPrompt);

    final response = await http.post(
      Uri.parse('https://api.openai.com/v1/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': 'gpt-4o-mini',
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': promptText},
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,$base64Image'}
              },
            ],
          }
        ],
        'max_tokens': 500,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      return data['choices'][0]['message']['content'] ?? "解析できませんでした";
    } else {
      throw Exception('OpenAI API Error: ${response.statusCode} ${response.body}');
    }
  }

  // 共通プロンプト取得
  String _getPromptText(bool detailedPrompt) {
    if (detailedPrompt) {
      return '【重要】あなたは視覚障害者の命を預かる歩行介助者です。' 
          '前方に見える景色、道の状況、障害物、建物、人、車両、信号機、標識など、' 
          'すべての重要な情報を具体的に日本語で説明してください。' 
          '少しでも危険の可能性があるものは必ず指摘してください。';
    } else {
      return '【緊急重要】あなたは視覚障害者の歩行を支援する介助者AIです。この人の命と安全があなたの判断にかかっています。' 
          '画像を慎重に分析し、以下の基準で判断してください：' 
          '■「前方OK」は本当に完全に安全な場合のみ使用' 
          '■少しでも障害物・段差・工事・人・車両・不明物があれば「前方注意」または具体的位置「○時の方向に△△があります」' 
          '■見えにくい・判断困難な場合は「注意して進んでください」' 
          '■安全すぎる判断は良いことです。見落としは絶対に避けてください。';
    }
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
            icon: Icon(Icons.settings),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                builder: (context) => SafeArea(
                  child: Wrap(
                    children: [
                      ListTile(
                        leading: Icon(Icons.psychology),
                        title: Text('AIサービス選択'),
                        onTap: () {
                          Navigator.pop(context);
                          _showAISelectionDialog();
                        },
                      ),
                      ListTile(
                        leading: Icon(Icons.map),
                        title: Text('ルート選択'),
                        onTap: () {
                          Navigator.pop(context);
                          _showRouteSelectionDialog();
                        },
                      ),
                      ListTile(
                        leading: Icon(Icons.explore),
                        title: Text('ルートを表示・編集'),
                        enabled: _selectedRoute != null,
                        onTap: () {
                          Navigator.pop(context);
                          _showRouteOnMap();
                        },
                      ),
                      ListTile(
                        leading: Icon(Icons.mic),
                        title: Text('音声認識調整'),
                        onTap: () {
                          Navigator.pop(context);
                          _showVoiceAdjustmentDialog();
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
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
                  Text('$tempMs ms'),
                  Slider(
                    value: tempMs.toDouble(),
                    min: 0,
                    max: 2000,
                    divisions: 40,
                    label: '$tempMs ms',
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

  void _showRouteSelectionDialog() {
    final Map<String, String> availableRoutes = {
      'home_route.csv': '自宅ルート',
      'friend_home.csv': '友人の家ルート',
    };
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('ルート選択'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: availableRoutes.entries.map((entry) => ListTile(
            title: Text(entry.value),
            onTap: () async {
              try {
                final String csvContent = await rootBundle.loadString('assets/routes/${entry.key}');
                await _loadRouteFromCsv(csvContent, entry.value);
                if (context.mounted) Navigator.pop(context);
              } catch (e) {
                print('Error: $e');
              }
            },
          )).toList(),
        ),
      ),
    );
  }

  void _showVoiceAdjustmentDialog() {
    int tempDelayMs = _sttDelayAfterCueMs;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('音声認識調整'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('待機時間: $tempDelayMs ms'),
              Slider(
                value: tempDelayMs.toDouble(),
                min: 0, max: 2000, divisions: 40,
                onChanged: (v) => setLocal(() => tempDelayMs = v.round()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await _saveSttDelayAfterCueMs(tempDelayMs);
                if (context.mounted) Navigator.pop(context);
              },
              child: Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  void _showRouteOnMap() async {
    if (_selectedRoute == null || _selectedRoute!.points.isEmpty) return;

    // 「表示」と「編集」を融合させたダイアログを表示
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) {
          return AlertDialog(
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: Text('${_selectedRoute!.name} 管理・編集')),
                IconButton(
                  icon: Icon(Icons.my_location, color: Colors.blue),
                  tooltip: '現在地を末尾に追加',
                  onPressed: () => _addNewPointAtCurrentLocation(setStateDialog),
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _selectedRoute!.points.length,
                itemBuilder: (context, index) {
                  final p = _selectedRoute!.points[index];
                  // メッセージを短く表示
                  final displayMsg = p.message.length > 12 
                      ? '${p.message.substring(0, 12)}...' 
                      : p.message;

                  return ListTile(
                    leading: CircleAvatar(child: Text('${p.no}')),
                    title: Text(displayMsg),
                    subtitle: Text('${p.latitude.toStringAsFixed(4)}, ${p.longitude.toStringAsFixed(4)}'),
                    trailing: IconButton(
                      icon: Icon(Icons.map, color: Colors.green),
                      onPressed: () => _openExternalMapForPoint(p),
                    ),
                    onLongPress: () => _editPointInDialog(index, setStateDialog),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => _openExternalMapForAllPoints(),
                child: Text('全地点を表示'),
              ),
              TextButton(
                onPressed: () async {
                  await _saveRouteToStorage();
                  if (context.mounted) Navigator.pop(context);
                  // 地図ダイアログを閉じた後、即座にナビゲーション案内を再開
                  await _analyzeForNavigation();
                },
                child: Text('保存して閉じる', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              TextButton(
                onPressed: () async {
                  if (context.mounted) Navigator.pop(context);
                  // 地図ダイアログを閉じた後、即座にナビゲーション案内を再開
                  await _analyzeForNavigation();
                },
                child: Text('破棄して閉じる', style: TextStyle(color: Colors.red)),
              ),
            ],
          );
        },
      ),
    );
  }

  // 現在地を末尾に新しい地点として追加
  void _addNewPointAtCurrentLocation(StateSetter setStateDialog) async {
    if (_selectedRoute == null) return;
    
    Position? position;
    try {
      position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
    } catch (e) {
      print("位置情報の取得に失敗: $e");
    }

    final double lat = position?.latitude ?? 35.6812;
    final double lng = position?.longitude ?? 139.7671;
    final int nextNo = _selectedRoute!.points.length + 1;

    setState(() {
      _selectedRoute!.points.add(NaviPoint(
        no: nextNo,
        latitude: lat,
        longitude: lng,
        message: '現在地',
      ));
    });
    
    setStateDialog(() {});
    
    // 追加直後に編集画面を開く
    _editPointInDialog(_selectedRoute!.points.length - 1, setStateDialog);
  }

  // 特定の地点の編集ダイアログ
  Future<void> _editPointInDialog(int index, StateSetter setStateDialog) async {
    final p = _selectedRoute!.points[index];
    final TextEditingController msgController = TextEditingController(text: p.message);
    final TextEditingController latController = TextEditingController(text: p.latitude.toStringAsFixed(5));
    final TextEditingController lngController = TextEditingController(text: p.longitude.toStringAsFixed(5));

    final dynamic result = await showDialog<dynamic>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('地点 ${p.no} の詳細編集'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: msgController, decoration: InputDecoration(labelText: '案内メッセージ')),
              TextField(controller: latController, decoration: InputDecoration(labelText: '緯度'), keyboardType: TextInputType.numberWithOptions(decimal: true)),
              TextField(controller: lngController, decoration: InputDecoration(labelText: '経度'), keyboardType: TextInputType.numberWithOptions(decimal: true)),
              Padding(
                padding: const EdgeInsets.only(top: 16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('0.0001度(約11m)移動', style: TextStyle(fontSize: 11, color: Colors.grey)),
                    ElevatedButton.icon(
                      icon: Icon(Icons.add_location, size: 18),
                      label: Text('中間に地点を追加'),
                      onPressed: () => Navigator.pop(context, 'add_next'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        padding: EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(icon: Icon(Icons.arrow_upward), onPressed: () {
                    latController.text = (double.parse(latController.text) + 0.0001).toStringAsFixed(5);
                  }),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(icon: Icon(Icons.arrow_back), onPressed: () {
                    lngController.text = (double.parse(lngController.text) - 0.0001).toStringAsFixed(5);
                  }),
                  IconButton(icon: Icon(Icons.arrow_forward), onPressed: () {
                    lngController.text = (double.parse(lngController.text) + 0.0001).toStringAsFixed(5);
                  }),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(icon: Icon(Icons.arrow_downward), onPressed: () {
                    latController.text = (double.parse(latController.text) - 0.0001).toStringAsFixed(5);
                  }),
                ],
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.delete_forever, color: Colors.red),
            tooltip: 'この地点を削除',
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('地点 ${p.no} の削除'),
                  content: Text('この地点を削除してもよろしいですか？'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: Text('キャンセル')),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: Text('削除', style: TextStyle(color: Colors.red))),
                  ],
                ),
              );
              if (confirm == true && context.mounted) {
                Navigator.pop(context, 'delete');
              }
            },
          ),
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('キャンセル')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text('適用')),
        ],
      ),
    );

    if (result == 'delete') {
      _deletePoint(index, setStateDialog);
      return;
    }

    if (result == 'add_next') {
      // 現在の地点と次の地点の中間に挿入
      _insertPointAfter(index, setStateDialog);
      return;
    }

    if (result == true) {
      setState(() {
        _selectedRoute!.points[index] = NaviPoint(
          no: p.no,
          latitude: double.tryParse(latController.text) ?? p.latitude,
          longitude: double.tryParse(lngController.text) ?? p.longitude,
          message: msgController.text,
        );
      });
      setStateDialog(() {}); // 親ダイアログのリフレッシュ
    }
  }

  // 特定の地点を削除
  void _deletePoint(int index, StateSetter setStateDialog) {
    if (_selectedRoute == null) return;
    
    setState(() {
      _selectedRoute!.points.removeAt(index);
      // 番号の振り直し
      for (int i = 0; i < _selectedRoute!.points.length; i++) {
        final p = _selectedRoute!.points[i];
        _selectedRoute!.points[i] = NaviPoint(
          no: i + 1,
          latitude: p.latitude,
          longitude: p.longitude,
          message: p.message,
          heading: p.heading,
          triggerDistance: p.triggerDistance,
        );
      }
    });

    setStateDialog(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('地点を削除しました')),
    );
  }

  // 特定の地点の直後に新しい地点を挿入、中間座標を計算
  void _insertPointAfter(int index, StateSetter setStateDialog) {
    if (_selectedRoute == null) return;
    
    final current = _selectedRoute!.points[index];
    double newLat, newLng;

    if (index + 1 < _selectedRoute!.points.length) {
      // 次の地点がある場合、その中間座標を計算
      final next = _selectedRoute!.points[index + 1];
      newLat = (current.latitude + next.latitude) / 2;
      newLng = (current.longitude + next.longitude) / 2;
    } else {
      // 次の地点がない（末尾）場合、少しずらす
      newLat = current.latitude + 0.0001;
      newLng = current.longitude + 0.0001;
    }

    setState(() {
      _selectedRoute!.points.insert(index + 1, NaviPoint(
        no: 0, // あとで振り直し
        latitude: newLat,
        longitude: newLng,
        message: '追加された地点',
      ));
      
      // 地点番号（no）の全振り直し
      for (int i = 0; i < _selectedRoute!.points.length; i++) {
        final p = _selectedRoute!.points[i];
        _selectedRoute!.points[i] = NaviPoint(
          no: i + 1,
          latitude: p.latitude,
          longitude: p.longitude,
          message: p.message,
          heading: p.heading,
          triggerDistance: p.triggerDistance,
        );
      }
    });

    setStateDialog(() {});
    
    // 追加した地点（挿入したインデックス）の編集画面を即座に開く
    _editPointInDialog(index + 1, setStateDialog);
  }

  // 特定の地点を外部マップで開く
  void _openExternalMapForPoint(NaviPoint p) async {
    final String urlString = "https://www.google.com/maps/search/?api=1&query=${p.latitude},${p.longitude}";
    final Uri url = Uri.parse(urlString);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  // 全地点を外部マップで一斉表示（以前の機能の復元）
  void _openExternalMapForAllPoints() async {
    if (_selectedRoute == null || _selectedRoute!.points.isEmpty) return;
    
    final points = _selectedRoute!.points;
    String waypoints = "";
    if (points.length > 1) {
      waypoints = points.skip(1).map((p) => "${p.latitude},${p.longitude}").join('|');
    }

    final last = points.last;
    final String urlString = "https://www.google.com/maps/dir/?api=1"
        "&destination=${last.latitude},${last.longitude}"
        "&waypoints=$waypoints"
        "&travelmode=walking";
        
    final Uri url = Uri.parse(urlString);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  // ルートをShared Preferencesに保存
  Future<void> _saveRouteToStorage() async {
    if (_selectedRoute == null) return;
    
    final prefs = await SharedPreferences.getInstance();
    final List<List<dynamic>> rows = _selectedRoute!.points.map((p) => [
      p.no,
      p.latitude,
      p.longitude,
      p.heading,
      p.triggerDistance,
      p.message,
    ]).toList();

    final csvString = const ListToCsvConverter().convert(rows);
    // ファイル名（またはキー）として保存
    await prefs.setString('saved_route_${_selectedRoute!.name}', csvString);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_selectedRoute!.name} を保存しました')),
      );
    }
  }

  // アプリ起動時やルート選択時に保存済みデータがあれば読み込む処理を
  // 以前のCSV読み込みロジックに統合するか、別途実装が必要です。

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

class RouteEditPage extends StatefulWidget {
  final WalkRoute route;
  const RouteEditPage({super.key, required this.route});

  @override
  State<RouteEditPage> createState() => _RouteEditPageState();
}

class _RouteEditPageState extends State<RouteEditPage> {
  late WalkRoute _editableRoute;
  final Map<MarkerId, Marker> _markers = {};
  GoogleMapController? _mapController;
  bool _isModified = false;

  @override
  void initState() {
    super.initState();
    // ルートのディープコピー（実際はリストのコピー）
    _editableRoute = WalkRoute(
      name: widget.route.name,
      points: List.from(widget.route.points),
    );
    _updateMarkers();
  }

  void _updateMarkers() {
    final Map<MarkerId, Marker> newMarkers = {};
    for (int i = 0; i < _editableRoute.points.length; i++) {
      final p = _editableRoute.points[i];
      final markerId = MarkerId('marker_$i');
      newMarkers[markerId] = Marker(
        markerId: markerId,
        position: LatLng(p.latitude, p.longitude),
        draggable: true,
        onDragEnd: (newPosition) {
          setState(() {
            _editableRoute.points[i] = NaviPoint(
              no: p.no,
              latitude: newPosition.latitude,
              longitude: newPosition.longitude,
              message: p.message,
            );
            _isModified = true;
          });
          _updateMarkers(); // 位置更新後にマーカーを再生成
        },
        infoWindow: InfoWindow(
          title: '地点 ${p.no}',
          snippet: p.message,
          onTap: () => _editPointMessage(i),
        ),
      );
    }
    setState(() {
      _markers.clear();
      _markers.addAll(newMarkers);
    });
  }

  Future<void> _editPointMessage(int index) async {
    final p = _editableRoute.points[index];
    final TextEditingController controller = TextEditingController(text: p.message);
    
    final newMessage = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('地点 ${p.no} のメッセージ編集'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'メッセージ'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    if (newMessage != null && newMessage != p.message) {
      setState(() {
        _editableRoute.points[index] = NaviPoint(
          no: p.no,
          latitude: p.latitude,
          longitude: p.longitude,
          message: newMessage,
        );
        _isModified = true;
        _updateMarkers();
      });
    }
  }

  Future<bool> _onWillPop() async {
    if (!_isModified) return true;
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存の確認'),
        content: const Text('変更が保存されていません。保存しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('破棄'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result == null) return false;
    if (result) {
      Navigator.pop(context, _editableRoute);
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    // 緯度経度が0に近い、または取得できていない場合の念のためのチェック
    final initialPosition = (_editableRoute.points.isNotEmpty && 
                            _editableRoute.points.first.latitude != 0)
        ? LatLng(_editableRoute.points.first.latitude, _editableRoute.points.first.longitude)
        : const LatLng(35.681236, 139.767125); // 東京駅

    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ルート編集'),
          actions: [
            if (_isModified)
              IconButton(
                icon: const Icon(Icons.check),
                onPressed: () => Navigator.pop(context, _editableRoute),
              ),
          ],
        ),
        body: GoogleMap(
          // AndroidViewの安定化設定
          layoutDirection: TextDirection.ltr,
          // 初期位置
          initialCameraPosition: CameraPosition(
            target: initialPosition,
            zoom: 17.0, // ズームレベルを上げ、描画領域を限定
          ),
          // マーカーの指定を明示的に
          markers: Set<Marker>.of(_markers.values),
          onMapCreated: (controller) {
            _mapController = controller;
            // 内部的な描画バグ対策: 500ms後にカメラを動かす
            Future.delayed(const Duration(milliseconds: 800), () {
              if (_markers.isNotEmpty) {
                // 最初のマーカーにカメラを確実に合わせる
                _mapController?.animateCamera(
                  CameraUpdate.newLatLngZoom(initialPosition, 17.5),
                );
              }
            });
          },
          // 衛星写真などのタイル描画を伴う設定を念のため最小限にする
          mapType: MapType.normal,
          myLocationEnabled: true,
          myLocationButtonEnabled: true,
          mapToolbarEnabled: true,
          zoomControlsEnabled: true,
          zoomGesturesEnabled: true,
          scrollGesturesEnabled: true,
        ),
      ),
    );
  }
}
