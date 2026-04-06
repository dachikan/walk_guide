import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:convert';
import 'models.dart';

/// ルート設定画面
/// ルートとウェイポイントの登録・選択を行う（補助者が操作）
class RouteSettingsScreen extends StatefulWidget {
  const RouteSettingsScreen({super.key});

  @override
  State<RouteSettingsScreen> createState() => _RouteSettingsScreenState();
}

class _RouteSettingsScreenState extends State<RouteSettingsScreen> {
  List<RouteData> _routes = [];
  String? _activeRouteId;

  @override
  void initState() {
    super.initState();
    _loadRoutes();
  }

  Future<void> _loadRoutes() async {
    final prefs = await SharedPreferences.getInstance();
    final routesJson = prefs.getString('routes');
    final activeId = prefs.getString('active_route_id');
    if (routesJson != null) {
      final list = jsonDecode(routesJson) as List;
      setState(() {
        _routes = list
            .map((r) => RouteData.fromJson(r as Map<String, dynamic>))
            .toList();
        _activeRouteId = activeId;
      });
    }
  }

  Future<void> _saveRoutes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'routes',
      jsonEncode(_routes.map((r) => r.toJson()).toList()),
    );
    if (_activeRouteId != null) {
      await prefs.setString('active_route_id', _activeRouteId!);
    } else {
      await prefs.remove('active_route_id');
    }
  }

  Future<void> _setActiveRoute(String? id) async {
    setState(() {
      _activeRouteId = id;
    });
    await _saveRoutes();
  }

  Future<void> _addRoute() async {
    final nameController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新しいルートを追加'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(labelText: 'ルート名（例：公園コース）'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, nameController.text.trim()),
            child: const Text('追加'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      final newRoute = RouteData(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: result,
        waypoints: [],
      );
      setState(() {
        _routes.add(newRoute);
      });
      await _saveRoutes();
    }
  }

  Future<void> _deleteRoute(RouteData route) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ルートを削除'),
        content: Text('「${route.name}」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      setState(() {
        _routes.removeWhere((r) => r.id == route.id);
        if (_activeRouteId == route.id) _activeRouteId = null;
      });
      await _saveRoutes();
    }
  }

  void _editRoute(RouteData route) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _RouteEditScreen(
          route: route,
          onSave: (updated) async {
            final index = _routes.indexWhere((r) => r.id == updated.id);
            if (index >= 0) {
              setState(() {
                _routes[index] = updated;
              });
            }
            await _saveRoutes();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ルート設定'),
        backgroundColor: Colors.blue[700],
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _addRoute,
            tooltip: 'ルートを追加',
          ),
        ],
      ),
      body: _routes.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.route, size: 72, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  const Text(
                    'ルートが登録されていません',
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: _addRoute,
                    icon: const Icon(Icons.add),
                    label: const Text('ルートを追加'),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                if (_activeRouteId != null)
                  Container(
                    width: double.infinity,
                    color: Colors.blue[50],
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      '📍 使用中: ${_routes.firstWhere((r) => r.id == _activeRouteId, orElse: () => RouteData(id: '', name: '不明', waypoints: [])).name}',
                      style: TextStyle(
                        color: Colors.blue[700],
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _routes.length,
                    itemBuilder: (context, index) {
                      final route = _routes[index];
                      final isActive = route.id == _activeRouteId;
                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: ListTile(
                          leading: Radio<String?>(
                            value: route.id,
                            groupValue: _activeRouteId,
                            onChanged: (v) => _setActiveRoute(v),
                          ),
                          title: Text(
                            route.name,
                            style: TextStyle(
                              fontWeight: isActive
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color:
                                  isActive ? Colors.blue[700] : null,
                            ),
                          ),
                          subtitle: Text('地点数: ${route.waypoints.length}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isActive)
                                Icon(
                                  Icons.navigation,
                                  color: Colors.blue[700],
                                  size: 20,
                                ),
                              IconButton(
                                icon: const Icon(Icons.edit),
                                onPressed: () => _editRoute(route),
                                tooltip: '編集',
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete,
                                  color: Colors.red,
                                ),
                                onPressed: () => _deleteRoute(route),
                                tooltip: '削除',
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

// ─── ルート編集画面（ウェイポイント管理） ────────────────────────────────────

class _RouteEditScreen extends StatefulWidget {
  final RouteData route;
  final Future<void> Function(RouteData) onSave;

  const _RouteEditScreen({required this.route, required this.onSave});

  @override
  State<_RouteEditScreen> createState() => _RouteEditScreenState();
}

class _RouteEditScreenState extends State<_RouteEditScreen> {
  late RouteData _route;

  @override
  void initState() {
    super.initState();
    _route = widget.route.copyWith();
  }

  Future<Position?> _getCurrentPosition() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('位置情報サービスが無効です。設定で有効にしてください')),
          );
        }
        return null;
      }
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('位置情報の権限が拒否されました')),
            );
          }
          return null;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('位置情報の権限が永久に拒否されています。設定から許可してください'),
            ),
          );
        }
        return null;
      }
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('位置情報の取得に失敗しました: $e')),
        );
      }
      return null;
    }
  }

  Future<void> _addWaypoint() async {
    final nameController = TextEditingController(
      text: '地点${_route.waypoints.length + 1}',
    );
    final latController = TextEditingController();
    final lngController = TextEditingController();
    bool gettingGps = false;

    final Waypoint? result = await showDialog<Waypoint>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('ウェイポイントを追加'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: '地点名（例：公園入口）',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: latController,
                          decoration: const InputDecoration(
                            labelText: '緯度',
                            hintText: '35.6762',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: lngController,
                          decoration: const InputDecoration(
                            labelText: '経度',
                            hintText: '139.6503',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  gettingGps
                      ? const Center(child: CircularProgressIndicator())
                      : OutlinedButton.icon(
                          onPressed: () async {
                            setDialogState(() {
                              gettingGps = true;
                            });
                            final pos = await _getCurrentPosition();
                            setDialogState(() {
                              gettingGps = false;
                            });
                            if (pos != null) {
                              latController.text =
                                  pos.latitude.toStringAsFixed(6);
                              lngController.text =
                                  pos.longitude.toStringAsFixed(6);
                            }
                          },
                          icon: const Icon(Icons.my_location),
                          label: const Text('現在地を取得'),
                        ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('キャンセル'),
              ),
              ElevatedButton(
                onPressed: () {
                  final name = nameController.text.trim();
                  final lat = double.tryParse(latController.text);
                  final lng = double.tryParse(lngController.text);
                  if (name.isNotEmpty && lat != null && lng != null) {
                    Navigator.pop(
                      ctx,
                      Waypoint(name: name, latitude: lat, longitude: lng),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('地点名・緯度・経度をすべて入力してください'),
                      ),
                    );
                  }
                },
                child: const Text('追加'),
              ),
            ],
          );
        },
      ),
    );

    if (result != null) {
      setState(() {
        _route.waypoints.add(result);
      });
      await widget.onSave(_route);
    }
  }

  Future<void> _deleteWaypoint(int index) async {
    setState(() {
      _route.waypoints.removeAt(index);
    });
    await widget.onSave(_route);
  }

  Future<void> _reorderWaypoints(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex--;
    setState(() {
      final wp = _route.waypoints.removeAt(oldIndex);
      _route.waypoints.insert(newIndex, wp);
    });
    await widget.onSave(_route);
  }

  Color _waypointColor(int index) {
    if (_route.waypoints.length == 1) return Colors.blue[700]!;
    if (index == 0) return Colors.green;
    if (index == _route.waypoints.length - 1) return Colors.red;
    return Colors.blue[700]!;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_route.name),
        backgroundColor: Colors.blue[700],
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.add_location_alt),
            onPressed: _addWaypoint,
            tooltip: 'ウェイポイントを追加',
          ),
        ],
      ),
      body: _route.waypoints.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.add_location,
                    size: 72,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'ウェイポイントが登録されていません',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '出発点・経由地・目的地の順に追加してください',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _addWaypoint,
                    icon: const Icon(Icons.add),
                    label: const Text('ウェイポイントを追加'),
                  ),
                ],
              ),
            )
          : ReorderableListView(
              onReorder: _reorderWaypoints,
              header: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Text(
                  '${_route.waypoints.length}地点  ※長押しでドラッグして並び替え',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
              children: [
                for (int i = 0; i < _route.waypoints.length; i++)
                  ListTile(
                    key: ValueKey('wp_${i}_${_route.waypoints[i].name}'),
                    leading: CircleAvatar(
                      backgroundColor: _waypointColor(i),
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    title: Text(_route.waypoints[i].name),
                    subtitle: Text(
                      '緯度 ${_route.waypoints[i].latitude.toStringAsFixed(5)}'
                      '  経度 ${_route.waypoints[i].longitude.toStringAsFixed(5)}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () => _deleteWaypoint(i),
                          tooltip: '削除',
                        ),
                        const Icon(Icons.drag_handle, color: Colors.grey),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
