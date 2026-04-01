import 'dart:math';
import 'package:geolocator/geolocator.dart';

/// 「お散歩の友」の地点データ構造
class NaviPoint {
  final int no;
  final double latitude;
  final double longitude;
  final double heading; // 方位（将来的な拡張用）
  final double triggerDistance; // 案内を開始する距離(m)
  final String message; // 読み上げるメッセージ

  NaviPoint({
    required this.no,
    required this.latitude,
    required this.longitude,
    required this.heading,
    required this.triggerDistance,
    required this.message,
  });

  /// CSV一行からNaviPointを作成
  /// フォーマット: no, 緯度, 経度, 方位, 距離, メッセージ
  factory NaviPoint.fromCsv(List<dynamic> row) {
    return NaviPoint(
      no: int.tryParse(row[0].toString()) ?? 0,
      latitude: double.tryParse(row[1].toString()) ?? 0.0,
      longitude: double.tryParse(row[2].toString()) ?? 0.0,
      heading: double.tryParse(row[3].toString()) ?? 0.0,
      triggerDistance: double.tryParse(row[4].toString()) ?? 10.0, // デフォルト10m
      message: row.length > 5 ? row[5].toString() : '地点に近づきました',
    );
  }

  /// 現在地との距離を計算(m)
  double distanceTo(Position currentPosition) {
    return Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      latitude,
      longitude,
    );
  }
}

/// 散歩ルート（地点の集合）
class WalkRoute {
  final String name;
  final List<NaviPoint> points;

  WalkRoute({required this.name, required this.points});
}
