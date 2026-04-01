import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

// AIサービスの種類: lib/main.dartから移動
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

// 解析結果の構造体
class AnalysisResult {
  final String message;
  final bool isSafe;
  final String? error; // エラー詳細を保持
  final List<String>? localDetections; // 小脳（ローカル解析）での検知結果

  AnalysisResult({
    required this.message,
    required this.isSafe,
    this.error,
    this.localDetections,
  });
}

class WalkingBrain {
  AIService _currentAI = AIService.gemini;
  
  // 小脳（ローカル記憶）: 直近のローカル解析結果を保持
  List<String> _lastLocalDetections = [];
  
  AIService get currentAI => _currentAI;

  void setAI(AIService service) {
    _currentAI = service;
  }

  /// 小脳（ローカル解析）からの入力を記録する
  void updateLocalDetections(List<String> detections) {
    _lastLocalDetections = detections;
  }

  Future<AnalysisResult> analyzeScene(Uint8List imageBytes, {bool detailedPrompt = false}) async {
    String prompt;
    if (detailedPrompt) {
      prompt = '【重要】あなたは視覚障害者の命を預かる歩行介助者です。' '前方に見える景色、道の状況、障害物、建物、人、車両、信号機、標識など、' 'すべての重要な情報を具体的に日本語で説明してください。' +
          '少しでも危険の可能性があるものは必ず指摘してください。';
    } else {
      prompt = '【緊急重要】あなたは視覚障害者の歩行を支援する介助者AIです。この人の命と安全があなたの判断にかかっています。' '画像を慎重に分析し、以下の基準で判断してください：' '■「前方OK」は本当に完全に安全な場合のみ使用' +
          '■少しでも障害物・段差・工事・人・車両・不明物があれば「前方注意」または具体的位置「○時の方向に△△があります」' +
          '■見えにくい・判断困難な場合は「注意して進んでください」' +
          '■安全すぎる判断は良いことです。見落としは絶対に避けてください。';
    }

    try {
      switch (_currentAI) {
        case AIService.gemini:
          return await _analyzeWithGemini(imageBytes, prompt);
        case AIService.claude:
        case AIService.chatgpt:
          // ステップ段階ではGeminiで代用
          return await _analyzeWithGemini(imageBytes, prompt);
      }
    } catch (e) {
      print('❌ AI Analysis Error: $e');
      // ここでは敢えて例外を投げず、エラー文言を返すことでアプリを止めない
      return AnalysisResult(
        message: '通信エラーが発生しました。インターネット接続を確認してください。',
        isSafe: false,
        error: e.toString(), // エラー内容を渡す
      );
    }
  }

  Future<AnalysisResult> _analyzeWithGemini(Uint8List imageBytes, String prompt) async {
    final apiKey = dotenv.env['GEMINI_API_KEY'];
    if (apiKey == null) throw Exception('GEMINI_API_KEY not found');

    // 3/2安定版(01fe628)にて確実に動作していた「gemini-2.5-flash-lite」に戻します
    final model = GenerativeModel(model: 'gemini-2.5-flash-lite', apiKey: apiKey);
    final content = [
      Content.multi([
        TextPart(prompt),
        DataPart('image/jpeg', imageBytes),
      ])
    ];

    try {
      final response = await model.generateContent(content).timeout(Duration(seconds: 15));
      final text = response.text ?? '解析不可';
      
      // 解析結果に小脳（ローカル）の情報があれば、それを AnalysisResult に持たせてUIに返します
      return AnalysisResult(
        message: text,
        isSafe: !text.contains('危険') && !text.contains('止まって'),
        localDetections: _lastLocalDetections.isNotEmpty ? List.from(_lastLocalDetections) : null,
      );
    } catch (e) {
      rethrow; // analyzeScene側のcatchで一括処理
    }
  }
}
