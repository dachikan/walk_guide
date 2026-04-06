// 共通データモデル・列挙型

enum AIService { gemini, claude, chatgpt }

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

  static String getDescription(AIService service) {
    switch (service) {
      case AIService.gemini:
        return '高速・無料枠が多い【デフォルト】';
      case AIService.claude:
        return '高品質・日本語が得意';
      case AIService.chatgpt:
        return '安定性高・実績豊富';
    }
  }
}

class Waypoint {
  String name;
  double latitude;
  double longitude;

  Waypoint({
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'lat': latitude,
        'lng': longitude,
      };

  factory Waypoint.fromJson(Map<String, dynamic> json) => Waypoint(
        name: json['name'] as String,
        latitude: (json['lat'] as num).toDouble(),
        longitude: (json['lng'] as num).toDouble(),
      );
}

class RouteData {
  String id;
  String name;
  List<Waypoint> waypoints;

  RouteData({
    required this.id,
    required this.name,
    required this.waypoints,
  });

  RouteData copyWith() => RouteData(
        id: id,
        name: name,
        waypoints: waypoints
            .map((w) => Waypoint(
                  name: w.name,
                  latitude: w.latitude,
                  longitude: w.longitude,
                ))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'waypoints': waypoints.map((w) => w.toJson()).toList(),
      };

  factory RouteData.fromJson(Map<String, dynamic> json) => RouteData(
        id: json['id'] as String,
        name: json['name'] as String,
        waypoints: (json['waypoints'] as List)
            .map((w) => Waypoint.fromJson(w as Map<String, dynamic>))
            .toList(),
      );
}
