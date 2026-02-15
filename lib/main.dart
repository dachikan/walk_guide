import 'package:flutter/material.dart';
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
  Timer? _timer;
  bool _cameraAvailable = false;
  String _version = 'Loading...';
  AIService _selectedAI = AIService.gemini; // デフォルトはGemini
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  bool _speechAvailable = false; // 音声認識が利用可能かどうか
  Uint8List? _lastCapturedImage; // 直前の画像を保存

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
        // カメラが初期化されたら5秒ごとに解析を実行するタイマーを開始
        _timer = Timer.periodic(Duration(seconds: 5), (timer) => _analyzeScene());
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
        _version = 'v${packageInfo.version}+${packageInfo.buildNumber}';
      });
    } catch (e) {
      setState(() {
        _version = 'v1.2.6+14';
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
    try {
      print('音声認識の初期化を開始します...');
      
      bool available = await _speech.initialize(
        onStatus: (status) {
          print('Speech Status: $status');
          if (status == 'listening') {
            print('音声認識中...');
          } else if (status == 'done') {
            print('音声認識終了');
            setState(() => _isListening = false);
          }
        },
        onError: (error) {
          print('Speech Error: $error');
          setState(() => _isListening = false);
        },
      );
      
      setState(() {
        _speechAvailable = available;
      });
      
      if (available) {
        print('音声認識が初期化されました');
        
        // 権限の確認
        bool hasPermission = await _speech.hasPermission;
        print('音声認識権限: $hasPermission');
        
        if (!hasPermission) {
          print('音声認識権限がありません。自動でリクエストします...');
        }
        
        // 利用可能な言語を確認
        var locales = await _speech.locales();
        var japaneseLocale = locales.where((l) => l.localeId.contains('ja')).toList();
        print('日本語ロケール: $japaneseLocale');
      } else {
        print('音声認識が利用できません');
      }
    } catch (e) {
      print('音声認識の初期化エラー: $e');
      setState(() => _speechAvailable = false);
    }
  }

  Future<void> _startListening() async {
    if (_isListening) {
      print('既に音声認識中です');
      return;
    }
    
    if (!_speechAvailable) {
      await _tts.speak('音声認識が利用できません');
      print('音声認識が利用できません');
      return;
    }
    
    try {
      // 権限を再確認
      bool hasPermission = await _speech.hasPermission;
      print('音声認識権限確認: $hasPermission');
      
      if (!hasPermission) {
        await _tts.speak('マイクの権限が必要です。設定で許可してください');
        print('マイクの権限がありません');
        return;
      }
      
      await _tts.speak('命令は何ですか');
      await Future.delayed(const Duration(seconds: 2)); // TTSが完了するまで待機
      
      setState(() => _isListening = true);
      
      print('音声認識を開始します...');
      
      await _speech.listen(
        onResult: (result) {
          print('音声認識結果: ${result.recognizedWords} (final: ${result.finalResult})');
          if (result.finalResult && result.recognizedWords.isNotEmpty) {
            _processVoiceCommand(result.recognizedWords);
          }
        },
        localeId: 'ja-JP',
        listenFor: const Duration(seconds: 10),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        onSoundLevelChange: (level) {
          // 音量レベルをログ出力（デバッグ用）
          if (level > 0.1) {
            print('音量レベル: $level');
          }
        },
      );
    } catch (e) {
      print('音声認識開始エラー: $e');
      await _tts.speak('音声認識でエラーが発生しました');
      setState(() => _isListening = false);
    }
  }

  Future<void> _stopListening() async {
    try {
      print('音声認識を停止します...');
      await _speech.stop();
      setState(() => _isListening = false);
    } catch (e) {
      print('音声認識停止エラー: $e');
      setState(() => _isListening = false);
    }
  }

  Future<void> _processVoiceCommand(String command) async {
    print('認識された音声コマンド: $command');
    
    // 基本的なクリーニング
    String cleanCommand = command.toLowerCase().trim();
    
    // 明らかに無効なパターンのみフィルタリング
    if (cleanCommand.isEmpty || 
        cleanCommand == 'アスタリスク' || cleanCommand == 'asterisk' || cleanCommand == '*') {
      print('無効なコマンドとして無視: $cleanCommand');
      setState(() => _isListening = false);
      return;
    }
    
    // ヘルプコマンド - 略語の読み上げ
    if (command.contains('略語') || command.contains('りゃくご') || command.contains('ヘルプ') || command.contains('help')) {
      await _tts.speak('使える略語です。AI変更は、ジェミニ、クロード、GPT、ジーピーティー。詳細説明は、景色、説明、前方、見える、どんな、詳しく、です。');
      setState(() => _isListening = false);
      return;
    }
    
    // AIサービス変更コマンド（よりカジュアルなパターンを追加）
    if (command.contains('CLAUDE') || command.contains('クロード') || command.contains('claude') 
        || command.contains('クロードに') || command.contains('クロードを')) {
      await _saveAIPreference(AIService.claude);
      await _tts.speak('AIをクロードに変更しました');
    } else if (command.contains('ChatGPT') || command.contains('チャットGPT') || command.contains('chatgpt')
               || command.contains('GPT') || command.contains('ジーピーティー') || command.contains('チャットを')) {
      await _saveAIPreference(AIService.chatgpt);
      await _tts.speak('AIをチャットGPTに変更しました');
    } else if (command.contains('Gemini') || command.contains('ジェミニ') || command.contains('gemini')
              || command.contains('ジェミニに') || command.contains('ジェミニを')) {
      await _saveAIPreference(AIService.gemini);
      await _tts.speak('AIをジェミニに変更しました');
    } 
    // 景色説明コマンド（より多様なパターンに対応）
    else if (command.contains('景色') || command.contains('説明') || command.contains('前方') 
             || command.contains('見える') || command.contains('どんな') || command.contains('詳しく')) {
      if (_lastCapturedImage != null) {
        await _tts.speak('画像を詳しく説明します');
        await _analyzeImage(_lastCapturedImage!);
      } else {
        await _tts.speak('分析できる画像がありません');
      }
    } else {
      print('有効なコマンドが見つかりませんでした: $cleanCommand');
      await _tts.speak('コマンドが理解できませんでした。略語と言うとヘルプを聞けます。');
    }
    
    setState(() => _isListening = false);
  }

  // 詳細説明用の解析メソッド
  Future<void> _analyzeImage(Uint8List imageBytes) async {
    try {
      String resultText;
      String detailedPrompt = '目の不自由な方のための詳細な風景説明をお願いします。'
          '前方に見える景色、道の状況、障害物、建物、人、車両、信号機、標識など、'
          'すべての重要な情報を具体的に日本語で説明してください。';

      switch (_selectedAI) {
        case AIService.gemini:
          resultText = await _analyzeWithGemini(imageBytes, customPrompt: detailedPrompt);
          break;
        case AIService.claude:
          resultText = await _analyzeWithClaude(imageBytes, customPrompt: detailedPrompt);
          break;
        case AIService.chatgpt:
          resultText = await _analyzeWithChatGPT(imageBytes, customPrompt: detailedPrompt);
          break;
      }

      await _tts.speak(resultText);
      print('Detailed analysis result (${AIServiceHelper.getDisplayName(_selectedAI)}): $resultText');
      
    } catch (e) {
      print('Detailed analysis failed: $e');
      await _tts.speak("詳細な画像解析でエラーが発生しました");
    }
  }

  Future<void> _analyzeScene() async {
    // 音声認識中は画像解析を完全にスキップ（音声入力の妨害を防ぐ）
    if (_isListening) {
      print('音声認識中のため自動画像解析をスキップしました');
      return;
    }
    
    if (!_cameraAvailable || _controller == null || !_controller!.value.isInitialized) {
      return;
    }

    await _captureAndAnalyze(() async {
      final image = await _controller!.takePicture();
      return await image.readAsBytes();
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
      // 1. 画像を取得
      final bytes = await getImageBytes();
      _lastCapturedImage = bytes; // 最新の画像を保存

      // 2. 選択されたAIサービスで解析
      String resultText;
      switch (_selectedAI) {
        case AIService.gemini:
          resultText = await _analyzeWithGemini(bytes);
          break;
        case AIService.claude:
          resultText = await _analyzeWithClaude(bytes);
          break;
        case AIService.chatgpt:
          resultText = await _analyzeWithChatGPT(bytes);
          break;
      }

      // 3. 音声認識中でなければ音声で伝える（重要: 音声認識と音声出力の競合を防ぐ）
      if (!_isListening) {
        await _tts.speak(resultText);
        print('Analysis result (${AIServiceHelper.getDisplayName(_selectedAI)}): $resultText');
      } else {
        print('音声認識中のため音声出力をスキップ: $resultText');
      }
      
    } catch (e) {
      print('Scene analysis failed: $e');
      await _tts.speak("画像解析でエラーが発生しました");
    }
  }

  // Gemini APIでの解析
  Future<String> _analyzeWithGemini(Uint8List bytes, {String? customPrompt}) async {
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey == null) {
      throw Exception('Gemini APIキーが設定されていません');
    }

    final model = GenerativeModel(
      model: 'gemini-2.5-flash-lite',
      apiKey: apiKey,
    );

    final defaultPrompt = "あなたは視覚障害者の歩行支援AIです。画像を見て、前方の状況を『前方OK』『前方危険』、または障害物の位置を『〇時の方向』で短く答えてください。";
    final prompt = TextPart(customPrompt ?? defaultPrompt);
    final imagePart = DataPart('image/jpeg', bytes);

    final response = await model.generateContent([
      Content.multi([prompt, imagePart])
    ]);

    return response.text ?? "解析できませんでした";
  }

  // Claude APIでの解析
  Future<String> _analyzeWithClaude(Uint8List bytes, {String? customPrompt}) async {
    final apiKey = dotenv.env['CLAUDE_API_KEY'];
    if (apiKey == null || apiKey == 'your_claude_api_key_here') {
      throw Exception('Claude APIキーが設定されていません');
    }

    final base64Image = base64Encode(bytes);
    final defaultPrompt = 'あなたは視覚障害者の歩行支援AIです。画像を見て、前方の状況を「前方OK」「前方危険」、または障害物の位置を「○時の方向」で短く答えてください。';
    
    final response = await http.post(
      Uri.parse('https://api.anthropic.com/v1/messages'),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode({
        'model': 'claude-sonnet-4-5-20250929',
        'max_tokens': 300,
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'text',
                'text': customPrompt ?? defaultPrompt
              },
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/jpeg',
                  'data': base64Image,
                }
              }
            ]
          }
        ]
      }),
    );

    print('Claude API response status: ${response.statusCode}');
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['content'] != null && data['content'].isNotEmpty) {
        return data['content'][0]['text'];
      } else {
        throw Exception('Claude API: Empty response content');
      }
    } else {
      print('Claude API error body: ${response.body}');
      throw Exception('Claude API error: ${response.statusCode} - ${response.body}');
    }
  }

  // ChatGPT APIでの解析
  Future<String> _analyzeWithChatGPT(Uint8List bytes, {String? customPrompt}) async {
    final apiKey = dotenv.env['OPENAI_API_KEY'];
    if (apiKey == null || apiKey == 'your_openai_api_key_here') {
      throw Exception('OpenAI APIキーが設定されていません');
    }

    // HTTP経由で直接呼び出し（dart_openaiパッケージの問題回避）
    final base64Image = base64Encode(bytes);
    final defaultPrompt = 'あなたは視覚障害者の歩行支援AIです。画像を見て、前方の状況を「前方OK」「前方危険」、または障害物の位置を「○時の方向」で短く答えてください。';
    
    final response = await http.post(
      Uri.parse('https://api.openai.com/v1/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': 'gpt-4o',  // 最新のモデルを使用
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'text',
                'text': customPrompt ?? defaultPrompt
              },
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:image/jpeg;base64,$base64Image'
                }
              }
            ]
          }
        ],
        'max_tokens': 300
      }),
    );
    
    print('ChatGPT API response status: ${response.statusCode}');
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['choices'] != null && data['choices'].isNotEmpty) {
        final content = data['choices'][0]['message']['content'];
        return content ?? '解析できませんでした';
      } else {
        throw Exception('ChatGPT API: Empty response choices');
      }
    } else {
      print('ChatGPT API error body: ${response.body}');
      throw Exception('ChatGPT API error: ${response.statusCode} - ${response.body}');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
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
                        '自動解析中 (5s間隔)',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
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
                  backgroundColor: _isListening 
                      ? Colors.red 
                      : (_speechAvailable ? Colors.blue[700] : Colors.grey),
                  foregroundColor: Colors.white,
                  child: Icon(_isListening ? Icons.mic : Icons.mic_none),
                  onPressed: () {
                    print('音声ボタンが押されました');
                    print('音声認識利用可能: $_speechAvailable');
                    print('現在聞いています: $_isListening');
                    
                    if (_speechAvailable) {
                      _isListening ? _stopListening() : _startListening();
                    } else {
                      _tts.speak('音声認識が利用できません。初期化をやり直します。');
                      _initializeSpeech();
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
              // 音声認識利用不可の場合の表示
              if (!_speechAvailable)
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
                      '音声認識無効',
                      style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
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