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
    // .env繝輔ぃ繧､繝ｫ繧定ｪｭ縺ｿ霎ｼ繧
    await dotenv.load(fileName: ".walking_guide.env");
    
    // API繧ｭ繝ｼ縺ｮ蟄伜惠遒ｺ隱・
    if (dotenv.env['GEMINI_API_KEY'] == null) {
      throw Exception('GEMINI_API_Key is not set in .walking_guide.env file');
    }
    
    // 繧ｫ繝｡繝ｩ縺ｮ蛻晄悄蛹悶ｒ隧ｦ縺ｿ繧・
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
          child: Text('繧｢繝励Μ縺ｮ蛻晄悄蛹悶↓螟ｱ謨励＠縺ｾ縺励◆: $e'),
        ),
      ),
    ));
  }
}

// AI繧ｵ繝ｼ繝薙せ縺ｮ遞ｮ鬘・
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

// 繧｢繝励Μ縺ｮ迥ｶ諷狗ｮ｡逅・畑enum
enum AppState {
  normalAnalysis,      // 騾壼ｸｸ縺ｮ閾ｪ蜍戊ｧ｣譫蝉ｸｭ
  waitingForCommand,   // 蜻ｽ莉､蜿嶺ｻ伜ｾ・■
  listeningCommand,    // 蜻ｽ莉､蜈･蜉帑ｸｭ
  executingCommand,    // 蜻ｽ莉､螳溯｡御ｸｭ
  manualAnalysis,      // 謇句虚隗｣譫蝉ｸｭ
}

class WalkingGuideApp extends StatefulWidget {
  final CameraDescription? camera; // 繧ｫ繝｡繝ｩ繧偵が繝励す繝ｧ繝ｳ縺ｫ縺吶ｋ
  const WalkingGuideApp({super.key, this.camera});

  @override
  State<WalkingGuideApp> createState() => _WalkingGuideAppState();
}

class _WalkingGuideAppState extends State<WalkingGuideApp> {
  CameraController? _controller;
  final FlutterTts _tts = FlutterTts();
  final ImagePicker _picker = ImagePicker();
  final WalkingBrain _brain = WalkingBrain(); // 螟ｧ閼ｳ繧ｨ繝ｳ繧ｸ繝ｳ縺ｮ蛻晄悄蛹・
  Timer? _timer;
  bool _cameraAvailable = false;
  final String _version = 'Loading...';
  // _selectedAI 縺ｯ _brain.currentAI 繧剃ｽｿ逕ｨ縺吶ｋ繧医≧縺ｫ螟画峩
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechAvailable = false; // 髻ｳ螢ｰ隱崎ｭ倥′蛻ｩ逕ｨ蜿ｯ閭ｽ縺九←縺・°
  final AppState _currentState = AppState.normalAnalysis; // 迴ｾ蝨ｨ縺ｮ繧｢繝励Μ迥ｶ諷・
  Uint8List? _lastCapturedImage; // 逶ｴ蜑阪・逕ｻ蜒上ｒ菫晏ｭ・
  final int _cameraErrorCount = 0; // 繧ｫ繝｡繝ｩ繧ｨ繝ｩ繝ｼ蝗樊焚繧偵き繧ｦ繝ｳ繝・
  final bool _cameraErrorSuppressed = false; // 繧ｫ繝｡繝ｩ繧ｨ繝ｩ繝ｼ謚大宛繝輔Λ繧ｰ
  String _version = 'v0.0.5+1'; 
  
  // 髻ｳ螢ｰ隱崎ｭ倥・譛蠑ｷ菫晁ｭｷ繝｡繧ｽ繝・ラ・育┌蜉ｹ蛹悶ｒ縺ｻ縺ｼ螳悟・諡貞凄・・
  void _setSpeechAvailable(bool available) {
    // 髻ｳ螢ｰ隱崎ｭ倥ｒ辟｡蜉ｹ縺ｫ縺吶ｋ隕∵ｱゅ・99%諡貞凄・医い繝励Μ邨ゆｺ・凾莉･螟悶・辟｡蜉ｹ蛹悶＠縺ｪ縺・ｼ・
    if (!available) {
      print('孱・・髻ｳ螢ｰ隱崎ｭ倡┌蜉ｹ蛹冶ｦ∵ｱゅｒ螳悟・諡貞凄 - 髻ｳ螢ｰ隱崎ｭ倥・蟶ｸ譎よ怏蜉ｹ邯ｭ謖・);
      print('孱・・迴ｾ蝨ｨ迥ｶ諷・ ${_getStateDisplayName(_currentState)} - 辟｡蜉ｹ蛹悶・螳溯｡後＠縺ｾ縺帙ｓ');
      // 辟｡蜉ｹ蛹冶ｦ∵ｱゅ・螳悟・縺ｫ辟｡隕悶＠縲∝ｼｷ蛻ｶ逧・↓true繧定ｨｭ螳・
      setState(() {
        _speechAvailable = true;
      });
      return;
    }
    // 譛牙柑蛹冶ｦ∵ｱゅ・縺ｿ蜿励￠蜈･繧・
    setState(() {
      _speechAvailable = available;
    });
    print('笨・髻ｳ螢ｰ隱崎ｭ俶怏蜉ｹ蛹・ $available (迴ｾ蝨ｨ迥ｶ諷・ ${_getStateDisplayName(_currentState)})');
  }
  
  // 髱樊耳螂ｨ繝輔Λ繧ｰ・亥ｾ梧婿莠呈鋤諤ｧ縺ｮ縺溘ａ菫晄戟・・
  bool get _isListening => _currentState == AppState.listeningCommand;
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
        // 謇句虚蛻ｶ蠕｡縺ｮ縺溘ａ閾ｪ蜍輔ち繧､繝槭・髢句ｧ九・辟｡蜉ｹ蛹・
        print('孱・・謇句虚蛻ｶ蠕｡縺ｮ縺溘ａ蛻晄悄繧ｿ繧､繝槭・髢句ｧ九ｒ辟｡蜉ｹ蛹・- 謇句虚縺ｧ繝懊ち繝ｳ繧呈款縺励※縺上□縺輔＞');
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
        // 繧ゅ＠蜿門ｾ励＠縺溘ヰ繝ｼ繧ｸ繝ｧ繝ｳ縺・0.0.4 莉･蜑阪・蝣ｴ蜷医・縲∝ｼｷ蛻ｶ逧・↓譛譁ｰ繧定｡ｨ遉ｺ
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

  // 莠域悄縺励↑縺・浹螢ｰ隱崎ｭ倡ｵゆｺ・・蜃ｦ逅・ｼ育┌蜉ｹ蛹・- 謇句虚蛻ｶ蠕｡縺ｮ縺ｿ・・
  void _handleUnexpectedSpeechEnd() {
    print('圷 莠域悄縺励↑縺・浹螢ｰ隱崎ｭ倡ｵゆｺ・・蜃ｦ逅・- 謇句虚蛻ｶ蠕｡縺ｮ縺溘ａ菴輔ｂ縺励∪縺帙ｓ');
    print('邃ｹ・・謇句虚縺ｧ繝懊ち繝ｳ繧呈款縺励※迥ｶ諷九ｒ螟画峩縺励※縺上□縺輔＞');
    // 謇句虚蛻ｶ蠕｡縺ｮ縺ｿ縺ｮ縺溘ａ縲∬・蜍募ｾｩ蟶ｰ縺ｯ荳蛻・｡後ｏ縺ｪ縺・
  }
  
  // 髻ｳ螢ｰ隱崎ｭ倥ち繧､繝繧｢繧ｦ繝医ち繧､繝槭・縺ｮ邂｡逅・ｼ育┌蜉ｹ蛹・- 謇句虚蛻ｶ蠕｡縺ｮ縺ｿ・・
  void _clearSpeechTimeoutTimer() {
    // 謇句虚蛻ｶ蠕｡縺ｮ縺ｿ縺ｮ縺溘ａ縲√ち繧､繝繧｢繧ｦ繝医ち繧､繝槭・縺ｯ菴ｿ逕ｨ縺励↑縺・
    print('邃ｹ・・繧ｿ繧､繝繧｢繧ｦ繝医ち繧､繝槭・縺ｯ辟｡蜉ｹ蛹悶＆繧後※縺・∪縺・- 謇句虚蛻ｶ蠕｡縺ｮ縺ｿ');
  }

  Future<void> _initializeSpeech() async {
    print('痔 髻ｳ螢ｰ隱崎ｭ伜・譛溷喧髢句ｧ・..');
    try {
      print('肌 _speech.initialize() 蜻ｼ縺ｳ蜃ｺ縺嶺ｸｭ...');
      
      bool available = await _speech.initialize(
        onStatus: (status) {
          print('投 髻ｳ螢ｰ隱崎ｭ倥せ繝・・繧ｿ繧ｹ螟画峩: $status (迴ｾ蝨ｨ迥ｶ諷・ ${_getStateDisplayName(_currentState)})');
          print('孱・・謇句虚蛻ｶ蠕｡縺ｮ縺ｿ - 閾ｪ蜍慕憾諷句､画峩縺ｯ螳悟・辟｡蜉ｹ');
          print('邃ｹ・・謇句虚縺ｧ繝懊ち繝ｳ繧呈款縺励※迥ｶ諷九ｒ蛻ｶ蠕｡縺励※縺上□縺輔＞');
          // 縺吶∋縺ｦ縺ｮ閾ｪ蜍慕憾諷句､画峩繧堤┌蜉ｹ蛹・
        },
        onError: (error) {
          print('笶・髻ｳ螢ｰ隱崎ｭ倥お繝ｩ繝ｼ: ${error.errorMsg}');
          print('孱・・謇句虚蛻ｶ蠕｡縺ｮ縺ｿ - 繧ｨ繝ｩ繝ｼ譎ゅｂ閾ｪ蜍募ｾｩ蟶ｰ縺ｯ螳悟・辟｡蜉ｹ');
          
          // 髻ｳ螢ｰ隱崎ｭ倥ｒ蠑ｷ蛻ｶ逧・↓譛牙柑縺ｫ菫昴▽
          setState(() {
            _speechAvailable = true;
          });
          
          print('邃ｹ・・謇句虚縺ｧ繝懊ち繝ｳ繧呈款縺励※迥ｶ諷九ｒ螟画峩縺励※縺上□縺輔＞');
          // 縺吶∋縺ｦ縺ｮ閾ｪ蜍募ｾｩ蟶ｰ蜃ｦ逅・ｒ辟｡蜉ｹ蛹・
        },
      );
      
      _setSpeechAvailable(available);
      
      print('痔 髻ｳ螢ｰ隱崎ｭ伜・譛溷喧邨先棡: $available');
      
      if (available) {
        print('笨・髻ｳ螢ｰ隱崎ｭ倥′蛻晄悄蛹悶＆繧後∪縺励◆');
        
        // 讓ｩ髯舌・遒ｺ隱・
        bool hasPermission = await _speech.hasPermission;
        print('柏 髻ｳ螢ｰ隱崎ｭ俶ｨｩ髯・ $hasPermission');
        
        if (!hasPermission) {
          print('笶・髻ｳ螢ｰ隱崎ｭ俶ｨｩ髯舌′縺ゅｊ縺ｾ縺帙ｓ縲り・蜍輔〒繝ｪ繧ｯ繧ｨ繧ｹ繝医＠縺ｾ縺・..');
        }
        
        // 蛻ｩ逕ｨ蜿ｯ閭ｽ縺ｪ險隱槭ｒ遒ｺ隱・
        try {
          var locales = await _speech.locales();
          var japaneseLocale = locales.where((l) => l.localeId.contains('ja')).toList();
          print('倹 譌･譛ｬ隱槭Ο繧ｱ繝ｼ繝ｫ: ${japaneseLocale.length}蛟玖ｦ九▽縺九ｊ縺ｾ縺励◆');
          for (var locale in japaneseLocale) {
            print('   - ${locale.localeId}: ${locale.name}');
          }
        } catch (e) {
          print('笞・・繝ｭ繧ｱ繝ｼ繝ｫ諠・ｱ蜿門ｾ怜､ｱ謨・ $e');
        }
      } else {
        print('笶・髻ｳ螢ｰ隱崎ｭ倥′蛻ｩ逕ｨ縺ｧ縺阪∪縺帙ｓ - 繝・ヰ繧､繧ｹ縺ｾ縺溘・讓ｩ髯舌・蝠城｡・);
      }
      
    } catch (e) {
      print('笶・髻ｳ螢ｰ隱崎ｭ伜・譛溷喧繧ｨ繝ｩ繝ｼ: $e');
      print('笶・繧ｨ繝ｩ繝ｼ隧ｳ邏ｰ: ${e.toString()}');
      // 蛻晄悄蛹悶お繝ｩ繝ｼ縺檎匱逕溘＠縺ｦ繧る浹螢ｰ隱崎ｭ倥・譛牙柑縺ｮ縺ｾ縺ｾ・域怙蠑ｷ菫晁ｭｷ・・
      print('孱・・蛻晄悄蛹悶お繝ｩ繝ｼ縺檎匱逕溘＠縺ｾ縺励◆縺碁浹螢ｰ隱崎ｭ倥・譛牙柑繧堤ｶｭ謖・);
      setState(() {
        _speechAvailable = true; // 繧ｨ繝ｩ繝ｼ縺ｧ繧ょｼｷ蛻ｶ逧・↓譛牙柑
      });
      print('笨・髻ｳ螢ｰ隱崎ｭ倡憾諷九ｒ蠑ｷ蛻ｶ逧・↓譛牙柑縺ｫ險ｭ螳・);
    }
  }

  Future<void> _startListening() async {
    print('識 髻ｳ螢ｰ隱崎ｭ倬幕蟋・ ${_getStateDisplayName(_currentState)}');
    
    // Step 1: 迥ｶ諷九メ繧ｧ繝・け
    if (_currentState != AppState.normalAnalysis) {
      print('笶・髻ｳ螢ｰ隱崎ｭ俶拠蜷ｦ: 迴ｾ蝨ｨ縺ｮ迥ｶ諷九・${_getStateDisplayName(_currentState)}');
      return;
    }
    
    if (!_speechAvailable) {
      print('笶・髻ｳ螢ｰ隱崎ｭ伜茜逕ｨ荳榊庄');
      await _safeTtsSpeak('髻ｳ螢ｰ隱崎ｭ倥′蛻ｩ逕ｨ縺ｧ縺阪∪縺帙ｓ');
      return;
    }
    
    // Step 2: 蜻ｽ莉､蜿嶺ｻ伜ｾ・■迥ｶ諷九↓遘ｻ陦鯉ｼ医ち繧､繝槭・螳悟・蛛懈ｭ｢・・
    print('桃 Step 2: 蜻ｽ莉､蜿嶺ｻ伜ｾ・■迥ｶ諷九↓遘ｻ陦・- 繧ｿ繧､繝槭・螳悟・蛛懈ｭ｢');
    _changeState(AppState.waitingForCommand);
    _pauseTimer(); // 螳悟・蛛懈ｭ｢
    await _tts.stop();
    await Future.delayed(Duration(milliseconds: 500));
    
    // Step 3: 邁｡蜊倥↑繝励Ο繝ｳ繝励ヨ逋ｺ隧ｱ
    print('桃 Step 3: 繝励Ο繝ｳ繝励ヨ逋ｺ隧ｱ');
    await _tts.speak('縺ｩ縺・◇');
    await Future.delayed(Duration(seconds: 1)); // 遏ｭ邵ｮ
    await _tts.stop();
    await Future.delayed(Duration(milliseconds: 300));
    
    // Step 4: 髻ｳ螢ｰ蜈･蜉帷憾諷九↓遘ｻ陦・
    print('桃 Step 4: 髻ｳ螢ｰ蜈･蜉帷憾諷九↓遘ｻ陦・);
    _changeState(AppState.listeningCommand);
    
    // Step 5: 髻ｳ螢ｰ隱崎ｭ倬幕蟋具ｼ医ち繧､繝繧｢繧ｦ繝医↑縺励∵焔蜍募宛蠕｡縺ｮ縺ｿ・・
    print('桃 Step 5: 髻ｳ螢ｰ隱崎ｭ倬幕蟋・- 繧ｿ繧､繝繧｢繧ｦ繝医↑縺・);
    
    // 繧ｿ繧､繝繧｢繧ｦ繝医ち繧､繝槭・縺ｯ險ｭ螳壹＠縺ｪ縺・ｼ域焔蜍募宛蠕｡縺ｮ縺ｿ・・
    print('邃ｹ・・繧ｿ繧､繝繧｢繧ｦ繝医↑縺・- 謇句虚縺ｧ繝懊ち繝ｳ繧呈款縺吶∪縺ｧ蜻ｽ莉､蠕・■迥ｶ諷九ｒ邯ｭ謖・);
    
    try {
      await _speech.listen(
        onResult: (result) {
          print('痔 髻ｳ螢ｰ邨先棡: ${result.recognizedWords} (final: ${result.finalResult})');
          if (result.finalResult && result.recognizedWords.isNotEmpty) {
            print('笨・髻ｳ螢ｰ繧ｳ繝槭Φ繝峨ｒ蜿嶺ｿ｡ - 蜃ｦ逅・幕蟋・);
            _handleSpeechResult(result.recognizedWords);
          }
        },
        localeId: 'ja-JP',
        listenFor: Duration(minutes: 60), // 髱槫ｸｸ縺ｫ髟ｷ縺・凾髢楢ｨｭ螳夲ｼ亥ｮ溯ｳｪ辟｡蛻ｶ髯撰ｼ・
        pauseFor: Duration(seconds: 5), // 辟｡髻ｳ迥ｶ諷九・險ｱ螳ｹ譎る俣繧貞ｻｶ髟ｷ
        partialResults: true,
        cancelOnError: false,
      );
      
    } catch (e) {
      print('笶・髻ｳ螢ｰ隱崎ｭ倥お繝ｩ繝ｼ: $e');
      print('邃ｹ・・髻ｳ螢ｰ隱崎ｭ倥お繝ｩ繝ｼ縺檎匱逕溘＠縺ｾ縺励◆縺後∝多莉､蠕・■迥ｶ諷九ｒ邯ｭ謖√＠縺ｾ縺・);
      print('邃ｹ・・謇句虚縺ｧ繝懊ち繝ｳ繧貞・蠎ｦ謚ｼ縺励※縺上□縺輔＞');
      // 繧ｨ繝ｩ繝ｼ譎ゅｂ蜻ｽ莉､蠕・■迥ｶ諷九ｒ邯ｭ謖・ｼ域焔蜍募宛蠕｡縺ｮ縺ｿ・・
    }
  }
  
  void _handleSpeechResult(String recognizedWords) {
    print('桃 Step 6: 髻ｳ螢ｰ邨先棡蜃ｦ逅・- "$recognizedWords"');
    
    // 髻ｳ螢ｰ隱崎ｭ伜●豁｢
    try {
      _speech.stop();
    } catch (e) {
      print('笞・・髻ｳ螢ｰ隱崎ｭ伜●豁｢繧ｨ繝ｩ繝ｼ: $e');
    }
    
    if (recognizedWords.isEmpty || recognizedWords.trim().length < 2) {
      print('売 髻ｳ螢ｰ蜈･蜉帙↑縺・- 蜻ｽ莉､蠕・■迥ｶ諷九ｒ邯ｭ謖・);
      print('邃ｹ・・蜀榊ｺｦ繧ｳ繝槭Φ繝峨ｒ隧ｱ縺吶°縲√・繧ｿ繝ｳ繧呈款縺励※縺上□縺輔＞');
      // 蜻ｽ莉､蠕・■迥ｶ諷九ｒ邯ｭ謖・ｼ域焔蜍募宛蠕｡縺ｮ縺ｿ・・
      _changeState(AppState.waitingForCommand);
      return;
    }
    
    // Step 7: 蜻ｽ莉､螳溯｡檎憾諷九↓遘ｻ陦・
    print('桃 Step 7: 蜻ｽ莉､螳溯｡檎憾諷九↓遘ｻ陦・);
    _changeState(AppState.executingCommand);
    
    // Step 8: 繧ｳ繝槭Φ繝牙・逅・ｮ溯｡・
    print('桃 Step 8: 繧ｳ繝槭Φ繝牙・逅・ｮ溯｡・);
    _executeCommand(recognizedWords);
  }

  Future<void> _executeCommand(String command) async {
    print('桃 Step 8-1: 繧ｳ繝槭Φ繝芽ｧ｣譫宣幕蟋・- "$command"');
    
    // 孱・・繧ｳ繝槭Φ繝牙ｮ溯｡御ｸｭ縺ｯ隗｣譫舌ち繧､繝槭・縺ｮ縺ｿ荳譎ょ●豁｢・亥ｮ悟・蛛懈ｭ｢縺ｧ縺ｯ縺ｪ縺・ｼ・
    print('孱・・繧ｳ繝槭Φ繝牙ｮ溯｡御ｸｭ・夊ｧ｣譫舌ち繧､繝槭・繧剃ｸ譎ょ●豁｢');
    _pauseTimer(); // 隗｣譫舌ち繧､繝槭・繧剃ｸ譎ょ●豁｢
    
    String cmd = command.toLowerCase().trim();
    
    // 繝倥Ν繝励さ繝槭Φ繝・
    if (cmd.contains('繝倥Ν繝・) || cmd.contains('逡･隱・) || cmd.contains('help')) {
      print('搭 繝倥Ν繝励さ繝槭Φ繝牙ｮ溯｡御ｸｭ');
      await _tts.speak('菴ｿ縺医ｋ繧ｳ繝槭Φ繝峨〒縺吶・I螟画峩縺ｯ縲√ず繧ｧ繝溘ル縲√け繝ｭ繝ｼ繝峨；PT縲りｩｳ邏ｰ隱ｬ譏弱・縲∵勹濶ｲ縲∬ｪｬ譏弱ょ●豁｢縺ｯ縲√→縺ｾ繧後・);
      await Future.delayed(Duration(seconds: 1));
      await _restoreNormalMode();
      return;
    }
    
    // 蛛懈ｭ｢繧ｳ繝槭Φ繝・
    if (cmd.contains('蛛懈ｭ｢') || cmd.contains('縺ｨ縺ｾ繧・) || cmd.contains('繧ｹ繝医ャ繝・)) {
      print('笵・蛛懈ｭ｢繧ｳ繝槭Φ繝牙ｮ溯｡御ｸｭ');
      await _tts.speak('縺吶∋縺ｦ縺ｮ讖溯・繧貞●豁｢縺励∪縺励◆');
      _pauseTimer();
      _changeState(AppState.normalAnalysis);
      return;
    }
    
    // AI螟画峩繧ｳ繝槭Φ繝・
    if (cmd.contains('繧ｸ繧ｧ繝溘ル') || cmd.contains('gemini')) {
      print('､・AI螟画峩繧ｳ繝槭Φ繝牙ｮ溯｡御ｸｭ・・emini・・);
      await _saveAIPreference(AIService.gemini);
      await _tts.speak('AI繧偵ず繧ｧ繝溘ル縺ｫ螟画峩縺励∪縺励◆');
      await Future.delayed(Duration(seconds: 1));
      await _restoreNormalMode();
      return;
    }
    
    if (cmd.contains('繧ｯ繝ｭ繝ｼ繝・) || cmd.contains('claude')) {
      print('､・AI螟画峩繧ｳ繝槭Φ繝牙ｮ溯｡御ｸｭ・・laude・・);
      _saveAIPreference(AIService.claude) {}
      await _tts.speak('AI繧偵け繝ｭ繝ｼ繝峨↓螟画峩縺励∪縺励◆') {}
      await Future.delayed(Duration(seconds: 1));
      await _restoreNormalMode();
      return;
    }
    
    if (cmd.contains('gpt') || cmd.contains('繧ｸ繝ｼ繝斐・繝・ぅ繝ｼ') || cmd.contains('繝√Ε繝・ヨ')) {
      print('､・AI螟画峩繧ｳ繝槭Φ繝牙ｮ溯｡御ｸｭ・・hatGPT・・);
      await _saveAIPreference(AIService.chatgpt);
      await _tts.speak('AI繧偵メ繝｣繝・ヨGPT縺ｫ螟画峩縺励∪縺励◆');
      await Future.delayed(Duration(seconds: 1));
      await _restoreNormalMode();
      return;
    }
    
    // 隧ｳ邏ｰ隱ｬ譏弱さ繝槭Φ繝・
    if (cmd.contains('譎ｯ濶ｲ') || cmd.contains('隱ｬ譏・) || cmd.contains('隧ｳ縺励￥') || cmd.contains('蜑肴婿')) {
      print('剥 隧ｳ邏ｰ隱ｬ譏弱さ繝槭Φ繝牙ｮ溯｡御ｸｭ');
      if (lastCapturedImage != null) {
        await _tts.speak('隧ｳ邏ｰ縺ｫ隱ｬ譏弱＠縺ｾ縺・);
        _changeState(AppState.manualAnalysis);
        await _analyzeCapturedImage(lastCapturedImage!, detailed: true);
      } else {
        await _tts.speak('蛻・梵縺吶ｋ逕ｻ蜒上′縺ゅｊ縺ｾ縺帙ｓ');
      }
      await Future.delayed(Duration(seconds = 1));
      await _restoreNormalMode();
      return;
    }
    
    // 譛ｪ遏･縺ｮ繧ｳ繝槭Φ繝・
    print('笶・譛ｪ遏･縺ｮ繧ｳ繝槭Φ繝牙ｮ溯｡御ｸｭ: $cmd');
    await _tts.speak('繧ｳ繝槭Φ繝峨′逅・ｧ｣縺ｧ縺阪∪縺帙ｓ縺ｧ縺励◆縲ゅ・繝ｫ繝励→險縺・→菴ｿ縺・婿繧定◇縺代∪縺吶・);
    await Future.delayed(Duration(seconds = 1));
    await _restoreNormalMode();
  }

  Future<void> _analyzeCapturedImage(Uint8List imageBytes, {bool detailed = false}) async {
    print('ｧ WalkingBrain 隗｣譫宣幕蟋・(隧ｳ邏ｰ繝｢繝ｼ繝・ $detailed)');
    try {
      final result = await _brain.analyzeScene(imageBytes, detailed: detailed);
      print('ｧ WalkingBrain 隗｣譫仙ｮ御ｺ・ ${result.message}');
      await _safeTtsSpeak(result.message);
    } catch (e) {
      print('笶・Brain analysis failed: $e');
      await _safeTtsSpeak("逕ｻ蜒剰ｧ｣譫舌〒繧ｨ繝ｩ繝ｼ縺檎匱逕溘＠縺ｾ縺励◆縲ゅう繝ｳ繧ｿ繝ｼ繝阪ャ繝域磁邯壹ｒ遒ｺ隱阪＠縺ｦ縺上□縺輔＞縲・);
    }
  }

  Future<void> _restoreNormalMode() async {
    print('桃 Step 9: 騾壼ｸｸ繝｢繝ｼ繝峨↓蠕ｩ蟶ｰ髢句ｧ・);
    
    try {
      // 髻ｳ螢ｰ隱崎ｭ伜●豁｢
      if (_speech.isListening) {
        await _speech.stop();
      }
      
      // TTS蛛懈ｭ｢
      await _tts.stop();
      await Future.delayed(Duration(milliseconds: 300));
      
      // 騾壼ｸｸ隗｣譫千憾諷九↓遘ｻ陦・
      _changeState(AppState.normalAnalysis);
      
      // 繧ｿ繧､繝槭・繧貞・髢具ｼ磯壼ｸｸ蜍穂ｽ懷ｾｩ蟶ｰ・・
      if (_cameraAvailable && _timer == null) {
        _timer = Timer.periodic(Duration(seconds: 5), (timer) => _analyzeScene());
        print('売 隗｣譫舌ち繧､繝槭・繧貞・髢九＠縺ｾ縺励◆');
      }
      
      print('笨・螳御ｺ・ 騾壼ｸｸ繝｢繝ｼ繝峨↓蠕ｩ蟶ｰ縺励∪縺励◆');
      
    } catch (e) {
      print('笶・騾壼ｸｸ繝｢繝ｼ繝牙ｾｩ蟶ｰ繧ｨ繝ｩ繝ｼ: $e');
      _changeState(AppState.normalAnalysis);
    }
  }
  
  Future<void> _stopListening() async {
    if (_currentState == AppState.listeningCommand || _currentState == AppState.waitingForCommand) {
      print('笵・髻ｳ螢ｰ隱崎ｭ倥ｒ謇句虚縺ｧ蛛懈ｭ｢荳ｭ...');
      try {
        await _speech.stop();
      } catch (e) {
        print('笞・・髻ｳ螢ｰ隱崎ｭ伜●豁｢繧ｨ繝ｩ繝ｼ: $e');
      }
      await _restoreNormalMode();
    }
  }

  // 迥ｶ諷句､画峩繝｡繧ｽ繝・ラ・磯浹螢ｰ隱崎ｭ倡憾諷倶ｿ晁ｭｷ讖溯・莉倥″・・
  void _changeState(AppState newState) {
    print('売 迥ｶ諷句､画峩: ${_getStateDisplayName(_currentState)} 竊・${_getStateDisplayName(newState)}');
    
    // 蜻ｽ莉､蜿嶺ｻ倅ｸｭ縺ｯ髻ｳ螢ｰ隱崎ｭ倥ｒ蠑ｷ蛻ｶ逧・↓譛牙柑蛹厄ｼ域怙邨ょｮ牙・陬・ｽｮ・・
    if ((newState == AppState.waitingForCommand || newState == AppState.listeningCommand) && !_speechAvailable) {
      print('孱・・譛邨ょｮ牙・陬・ｽｮ・壼多莉､蜿嶺ｻ倡憾諷九∈縺ｮ遘ｻ陦梧凾縺ｫ髻ｳ螢ｰ隱崎ｭ倥ｒ蠑ｷ蛻ｶ譛牙柑蛹・);
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
      case AppState.normalAnalysis: return '騾壼ｸｸ隗｣譫蝉ｸｭ';
      case AppState.waitingForCommand: return '蜻ｽ莉､蜿嶺ｻ伜ｾ・■';
      case AppState.listeningCommand: return '蜻ｽ莉､蜈･蜉帑ｸｭ';
      case AppState.executingCommand: return '蜻ｽ莉､螳溯｡御ｸｭ';
      case AppState.manualAnalysis: return '謇句虚隗｣譫蝉ｸｭ';
    }
  }

  // TTS螳溯｡後ｒ螳牙・縺ｫ陦後≧繝倥Ν繝代・繝｡繧ｽ繝・ラ・磯壼ｸｸ隗｣譫蝉ｸｭ縺ｯ蟶ｸ縺ｫ螳溯｡鯉ｼ・
  Future<void> _safeTtsSpeak(String text) async {
    // 騾壼ｸｸ隗｣譫蝉ｸｭ縺ｯ蟶ｸ縺ｫTTS繧貞ｮ溯｡後・浹螢ｰ隱崎ｭ倅ｸｭ縺ｯ螳溯｡後＠縺ｪ縺・
    if (_currentState == AppState.listeningCommand || 
        _currentState == AppState.waitingForCommand) {
      print('笵・TTS繝悶Ο繝・け (迥ｶ諷・ ${_getStateDisplayName(_currentState)}): $text');
      return;
    }
    try {
      print('矧 TTS螳溯｡・(迥ｶ諷・ ${_getStateDisplayName(_currentState)}): $text');
      await _tts.speak(text);
    } catch (e) {
      print('TTS繧ｨ繝ｩ繝ｼ: $e');
    }
  }

  // 邱頑･譎ゅ・TTS・亥些髯ｺ迚ｩ讀懷・譎ゅ・縺ｿ菴ｿ逕ｨ・・
  Future<void> _emergencyTtsSpeak(String text) async {
    // 邱頑･譎ゅ・髻ｳ螢ｰ隱崎ｭ倅ｸｭ縺ｧ繧ょｼｷ蛻ｶ逋ｺ隧ｱ
    try {
      await _tts.stop();
      await Future.delayed(const Duration(milliseconds: 500));
      await _tts.speak('邱頑･: $text');
    } catch (e) {
      print('邱頑･TTS繧ｨ繝ｩ繝ｼ: $e');
    }
  }

  // 繧ｿ繧､繝槭・縺ｮ蛛懈ｭ｢縺ｨ蜀埼幕
  void _pauseTimer() {
    if (_timer != null) {
      _timer!.cancel();
      _timer = null;
      print('笵・閾ｪ蜍戊ｧ｣譫舌ち繧､繝槭・繧貞ｮ悟・蛛懈ｭ｢縺励∪縺励◆');
    }
  }

  void _resumeTimer() {
    // 謇句虚蛻ｶ蠕｡縺ｮ縺ｿ縺ｮ縺溘ａ縲∬・蜍輔ち繧､繝槭・蜀埼幕縺ｯ辟｡蜉ｹ
    print('孱・・閾ｪ蜍輔ち繧､繝槭・蜀埼幕縺ｯ辟｡蜉ｹ - 謇句虚蛻ｶ蠕｡縺ｮ縺ｿ');
    print('邃ｹ・・謇句虚縺ｧ繝懊ち繝ｳ繧呈款縺励※騾壼ｸｸ繝｢繝ｼ繝峨↓蠕ｩ蟶ｰ縺励※縺上□縺輔＞');
    // 縺吶∋縺ｦ縺ｮ閾ｪ蜍輔ち繧､繝槭・繧堤┌蜉ｹ蛹・
  }

  Future<void> _analyzeScene() async {
    // 騾壼ｸｸ隗｣譫千憾諷九〒縺ｮ縺ｿ螳溯｡・
    if (_currentState != AppState.normalAnalysis) {
      print('笵・隗｣譫舌せ繧ｭ繝・・: 迴ｾ蝨ｨ縺ｮ迥ｶ諷九・${_getStateDisplayName(_currentState)}');
      return;
    }
    
    // 繧ｫ繝｡繝ｩ繧ｨ繝ｩ繝ｼ謚大宛荳ｭ縺ｯ隗｣譫舌ｒ繧ｹ繧ｭ繝・・
    if (_cameraErrorSuppressed) {
      print('笵・隗｣譫舌せ繧ｭ繝・・: 繧ｫ繝｡繝ｩ繧ｨ繝ｩ繝ｼ謚大宛荳ｭ');
      return;
    }
    
    if (!_cameraAvailable || _controller == null || !_controller!.value.isInitialized) {
      print('笵・隗｣譫舌せ繧ｭ繝・・: 繧ｫ繝｡繝ｩ譛ｪ蛻晄悄蛹・);
      return;
    }
    
    print('胴 閾ｪ蜍慕判蜒剰ｧ｣譫舌ｒ髢句ｧ・);
    
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
      
      // 繧ｫ繝｡繝ｩ隗｣譫舌′謌仙粥縺励◆蝣ｴ蜷医√お繝ｩ繝ｼ繧ｫ繧ｦ繝ｳ繝医ｒ繝ｪ繧ｻ繝・ヨ
      if (_cameraErrorCount > 0) {
        _cameraErrorCount = 0;
        print('笨・繧ｫ繝｡繝ｩ繧ｨ繝ｩ繝ｼ繧ｫ繧ｦ繝ｳ繝医Μ繧ｻ繝・ヨ - 豁｣蟶ｸ蠕ｩ譌ｧ');
      }

      await _analyzeCapturedImage(bytes);
      
    } catch (e) {
      print('Capture or analyze failed: $e');
      
      // 繧ｫ繝｡繝ｩ繧ｨ繝ｩ繝ｼ縺ｮ蝣ｴ蜷医・繧ｨ繝ｩ繝ｼ蝗樊焚繧偵き繧ｦ繝ｳ繝・
      if (e.toString().contains('CameraException') || e.toString().contains('ImageCaptureException')) {
        _cameraErrorCount++;
        print('萄 繧ｫ繝｡繝ｩ繧ｨ繝ｩ繝ｼ蝗樊焚: $_cameraErrorCount');
        
        // 3蝗樣｣邯壹〒繧ｨ繝ｩ繝ｼ縺檎匱逕溘＠縺溷ｴ蜷医・蜃ｦ逅・ｼ域焔蜍募宛蠕｡縺ｮ縺ｿ・・
        if (_cameraErrorCount >= 3 && !_cameraErrorSuppressed) {
          _cameraErrorSuppressed = true;
          print('笞・・繧ｫ繝｡繝ｩ繧ｨ繝ｩ繝ｼ縺・蝗樣｣邯夂匱逕・- 閾ｪ蜍戊ｧ｣譫舌ｒ荳譎ょ●豁｢縺励∪縺・);
          _pauseTimer();
        }
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel(); // 繧ｿ繧､繝槭・繧偵く繝｣繝ｳ繧ｻ繝ｫ
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
            Text('豁ｩ驕捺｡亥・'),
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
              // 繧ｫ繝｡繝ｩ逕ｻ髱｢繧貞・逕ｻ髱｢縺ｫ諡｡蠑ｵ
              Positioned.fill(
                child: CameraPreview(_controller!),
              ),
              // 蟾ｦ荳翫↓AI諠・ｱ繧定｡ｨ遉ｺ
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
                              return '萄 騾壼ｸｸ隗｣譫蝉ｸｭ (5s髢馴囈)';
                            case AppState.waitingForCommand:
                              return '竢ｳ 蜻ｽ莉､蜿嶺ｻ伜ｾ・■';
                            case AppState.listeningCommand:
                              return '痔 蜻ｽ莉､蜈･蜉帑ｸｭ (蜈ｨ讖溯・蛛懈ｭ｢)';
                            case AppState.executingCommand:
                              return '笞呻ｸ・蜻ｽ莉､螳溯｡御ｸｭ';
                            case AppState.manualAnalysis:
                              return '剥 謇句虚隗｣譫蝉ｸｭ';
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
              // 蜿ｳ荳九↓蜻ｽ莉､蜿嶺ｻ倥・繧ｿ繝ｳ
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
                    print('痔 髻ｳ螢ｰ繝懊ち繝ｳ縺梧款縺輔ｌ縺ｾ縺励◆');
                    print('投 迴ｾ蝨ｨ縺ｮ繧｢繝励Μ迥ｶ諷・ ${_getStateDisplayName(_currentState)}');
                    print('痔 髻ｳ螢ｰ隱崎ｭ伜茜逕ｨ蜿ｯ閭ｽ: $_speechAvailable');
                    print('閥 迴ｾ蝨ｨ髻ｳ螢ｰ隱崎ｭ倅ｸｭ: $_isListening');
                    
                    // 蜻ｽ莉､蜿嶺ｻ倅ｸｭ縺ｯ髻ｳ螢ｰ隱崎ｭ俶怏蜉ｹ縺ｨ縺励※謇ｱ縺・ｼ亥ｮ牙・陬・ｽｮ・・
                    bool effectiveSpeechAvailable = _speechAvailable || 
                        _currentState == AppState.waitingForCommand || 
                        _currentState == AppState.listeningCommand;
                    
                    if (effectiveSpeechAvailable) {
                      if (_isListening || _currentState == AppState.waitingForCommand) {
                        print('売 蜻ｽ莉､蜿嶺ｻ伜●豁｢蜃ｦ逅・幕蟋・);
                        _stopListening();
                      } else {
                        print('笆ｶ・・髻ｳ螢ｰ隱崎ｭ倬幕蟋句・逅・幕蟋・);
                        _startListening();
                      }
                    } else {
                      print('笞・・髻ｳ螢ｰ隱崎ｭ倡憾諷狗｢ｺ隱・- 蠑ｷ蛻ｶ逧・↓譛牙柑蛹悶＠縺ｦ邯咏ｶ・);
                      // 髻ｳ螢ｰ隱崎ｭ倥ｒ蠑ｷ蛻ｶ逧・↓譛牙柑蛹・
                      setState(() {
                        _speechAvailable = true;
                      });
                      print('紙 謇句虚縺ｧ騾壼ｸｸ繝｢繝ｼ繝峨↓蠕ｩ蟶ｰ縺励∪縺・);
                      _changeState(AppState.normalAnalysis);
                      // 繧ｿ繧､繝槭・縺ｮ謇句虚蜀埼幕・亥ｿｫ騾溘い繧ｯ繧ｻ繧ｹ縺ｮ縺溘ａ・・
                      if (_cameraAvailable) {
                        _timer = Timer.periodic(Duration(seconds: 5), (timer) => _analyzeScene());
                        print('笨・謇句虚縺ｧ繧ｿ繧､繝槭・繧貞・髢九＠縺ｾ縺励◆');
                      }
                    }
                  },
                ),
              ),
              // 髻ｳ螢ｰ隱崎ｭ倥・迥ｶ諷九う繝ｳ繧ｸ繧ｱ繝ｼ繧ｿ繝ｼ
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
                      '閨槭＞縺ｦ縺・∪縺・..',
                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              // 蜻ｽ莉､蜿嶺ｻ伜ｾ・■迥ｶ諷九・繧､繝ｳ繧ｸ繧ｱ繝ｼ繧ｿ繝ｼ
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
                      '蜻ｽ莉､蠕・■荳ｭ...',
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
                  '繧ｫ繝｡繝ｩ縺悟茜逕ｨ縺ｧ縺阪∪縺帙ｓ',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 10),
                Text(
                  '逕ｻ蜒上ｒ驕ｸ謚槭＠縺ｦ隗｣譫舌ｒ繝・せ繝医〒縺阪∪縺・,
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
                  label: Text('逕ｻ蜒上ｒ驕ｸ謚槭＠縺ｦ隗｣譫・),
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
          title: Text('AI繧ｵ繝ｼ繝薙せ繧帝∈謚・),
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
              child: Text('繧ｭ繝｣繝ｳ繧ｻ繝ｫ'),
            ),
          ],
        );
      },
    );
  }

  String _getAIDescription(AIService service) {
    switch (service) {
      case AIService.gemini:
        return '讓呎ｺ悶・鬮倬溘・辟｡譁呎椢謨ｰ縺悟､壹＞';
      case AIService.claude:
        return '鬮伜刀雉ｪ繝ｻ譌･譛ｬ隱槭′蠕玲э';
      case AIService.chatgpt:
        return '螳牙ｮ壽ｧ鬮倥・螳溽ｸｾ雎雁ｯ・;
    }
  }
}
    _timer?.cancel(); // 繧ｿ繧､繝槭・繧偵く繝｣繝ｳ繧ｻ繝ｫ
    // _speechTimeoutTimer 縺ｯ謇句虚蛻ｶ蠕｡縺ｮ縺溘ａ菴ｿ逕ｨ縺励↑縺・
    _controller?.dispose();
    _tts.stop(); // TTS繧貞●豁｢
    super.dispose();
  }

  @override
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text('豁ｩ驕捺｡亥・'),
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
              // 繧ｫ繝｡繝ｩ逕ｻ髱｢繧貞・逕ｻ髱｢縺ｫ諡｡蠑ｵ
              Positioned.fill(
                child: CameraPreview(_controller!),
              ),
              // 蟾ｦ荳翫↓AI諠・ｱ繧定｡ｨ遉ｺ
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
                              return '萄 騾壼ｸｸ隗｣譫蝉ｸｭ (5s髢馴囈)';
                            case AppState.waitingForCommand:
                              return '竢ｳ 蜻ｽ莉､蜿嶺ｻ伜ｾ・■';
                            case AppState.listeningCommand:
                              return '痔 蜻ｽ莉､蜈･蜉帑ｸｭ (蜈ｨ讖溯・蛛懈ｭ｢)';
                            case AppState.executingCommand:
                              return '笞呻ｸ・蜻ｽ莉､螳溯｡御ｸｭ';
                            case AppState.manualAnalysis:
                              return '剥 謇句虚隗｣譫蝉ｸｭ';
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
              // 蜿ｳ荳九↓蜻ｽ莉､蜿嶺ｻ倥・繧ｿ繝ｳ
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
                    print('痔 髻ｳ螢ｰ繝懊ち繝ｳ縺梧款縺輔ｌ縺ｾ縺励◆');
                    print('投 迴ｾ蝨ｨ縺ｮ繧｢繝励Μ迥ｶ諷・ ${_getStateDisplayName(_currentState)}');
                    print('痔 髻ｳ螢ｰ隱崎ｭ伜茜逕ｨ蜿ｯ閭ｽ: $_speechAvailable');
                    print('閥 迴ｾ蝨ｨ髻ｳ螢ｰ隱崎ｭ倅ｸｭ: $_isListening');
                    
                    // 蜻ｽ莉､蜿嶺ｻ倅ｸｭ縺ｯ髻ｳ螢ｰ隱崎ｭ俶怏蜉ｹ縺ｨ縺励※謇ｱ縺・ｼ亥ｮ牙・陬・ｽｮ・・
                    bool effectiveSpeechAvailable = _speechAvailable || 
                        _currentState == AppState.waitingForCommand || 
                        _currentState == AppState.listeningCommand;
                    
                    if (effectiveSpeechAvailable) {
                      if (_isListening || _currentState == AppState.waitingForCommand) {
                        print('売 蜻ｽ莉､蜿嶺ｻ伜●豁｢蜃ｦ逅・幕蟋・);
                        _stopListening();
                      } else {
                        print('笆ｶ・・髻ｳ螢ｰ隱崎ｭ倬幕蟋句・逅・幕蟋・);
                        _startListening();
                      }
                    } else {
                      print('笞・・髻ｳ螢ｰ隱崎ｭ倡憾諷狗｢ｺ隱・- 蠑ｷ蛻ｶ逧・↓譛牙柑蛹悶＠縺ｦ邯咏ｶ・);
                      // 髻ｳ螢ｰ隱崎ｭ倥ｒ蠑ｷ蛻ｶ逧・↓譛牙柑蛹・
                      setState(() {
                        _speechAvailable = true;
                      });
                      print('紙 謇句虚縺ｧ騾壼ｸｸ繝｢繝ｼ繝峨↓蠕ｩ蟶ｰ縺励∪縺・);
                      _changeState(AppState.normalAnalysis);
                      // 繧ｿ繧､繝槭・縺ｮ謇句虚蜀埼幕・亥ｿｫ騾溘い繧ｯ繧ｻ繧ｹ縺ｮ縺溘ａ・・
                      if (_cameraAvailable) {
                        _timer = Timer.periodic(Duration(seconds: 5), (timer) => _analyzeScene());
                        print('笨・謇句虚縺ｧ繧ｿ繧､繝槭・繧貞・髢九＠縺ｾ縺励◆');
                      }
                    }
                  },
                ),
              ),
              // 髻ｳ螢ｰ隱崎ｭ倥・迥ｶ諷九う繝ｳ繧ｸ繧ｱ繝ｼ繧ｿ繝ｼ
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
                      '閨槭＞縺ｦ縺・∪縺・..',
                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              // 蜻ｽ莉､蜿嶺ｻ伜ｾ・■迥ｶ諷九・繧､繝ｳ繧ｸ繧ｱ繝ｼ繧ｿ繝ｼ
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
                      '蜻ｽ莉､蠕・■荳ｭ...',
                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              // 縲碁浹螢ｰ隱崎ｭ倡┌蜉ｹ縲崎｡ｨ遉ｺ繧貞ｮ悟・縺ｫ蜑企勁・域怏螳ｳ縺ｪ陦ｨ遉ｺ縺ｮ縺溘ａ豌ｸ荵・↓蜑企勁・・
              // 縺薙・陦ｨ遉ｺ縺ｯ蜑企勁縺輔ｌ縺ｾ縺励◆ - 髻ｳ螢ｰ隱崎ｭ倥・蟶ｸ譎よ怏蜉ｹ縺ｨ縺励※謇ｱ縺・∪縺・
            ],
          )
        : Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.camera_alt, size: 100, color: Colors.grey),
                SizedBox(height: 20),
                Text(
                  '繧ｫ繝｡繝ｩ縺悟茜逕ｨ縺ｧ縺阪∪縺帙ｓ',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 10),
                Text(
                  '逕ｻ蜒上ｒ驕ｸ謚槭＠縺ｦ隗｣譫舌ｒ繝・せ繝医〒縺阪∪縺・,
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
                  label: Text('逕ｻ蜒上ｒ驕ｸ謚槭＠縺ｦ隗｣譫・),
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
          title: Text('AI繧ｵ繝ｼ繝薙せ繧帝∈謚・),
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
              child: Text('繧ｭ繝｣繝ｳ繧ｻ繝ｫ'),
            ),
          ],
        );
      },
    );
  }

  String _getAIDescription(AIService service) {
    switch (service) {
      case AIService.gemini:
        return '讓呎ｺ悶・鬮倬溘・辟｡譁呎椢謨ｰ縺悟､壹＞';
      case AIService.claude:
        return '鬮伜刀雉ｪ繝ｻ譌･譛ｬ隱槭′蠕玲э';
      case AIService.chatgpt:
        return '螳牙ｮ壽ｧ鬮倥・螳溽ｸｾ雎雁ｯ・;
    }
  }
}
