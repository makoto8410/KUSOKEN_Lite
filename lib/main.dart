import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const KusokenLiteApp());
}

class KusokenLiteApp extends StatelessWidget {
  const KusokenLiteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KUSOKEN Lite',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const KusokenLiteHomePage(),
    );
  }
}

class KusokenLiteHomePage extends StatefulWidget {
  const KusokenLiteHomePage({super.key});

  @override
  State<KusokenLiteHomePage> createState() => _KusokenLiteHomePageState();
}

class _KusokenLiteHomePageState extends State<KusokenLiteHomePage> {
  static const Color kusokenColor = Colors.cyanAccent;

  // 個人DRIVERシート受付用GAS
  static const String gasUrl =
      'https://script.google.com/macros/s/AKfycbyQ2BIQf-w3YSVAEuFB54UPttnUv_B7ssfAYsxv5lOm52H-pPjaKBhbb_c4_IOhUfV-4g/exec';

  // サマリー専用GASをウェブアプリ公開し、そのURLへ差し替える
  static const String summaryGasUrl = 'https://script.google.com/macros/s/AKfycbx-Rps17ek8jPQaFzCF5dybQYnhY_y78iqlFTsL7AbqO5-SC5WHvAlSWkT7ncMJ7lLozw/exec';

  static const String pickupLatKey = 'lastPickupLat';
  static const String pickupLngKey = 'lastPickupLng';
  static const String pickupTimeKey = 'lastPickupTime';

  String driverId = '';
  String currentStatus = '準備';
  String sendingStatus = '待機中';

  String summaryText = '空車ボタンでサマリーを取得します';
  bool isSending = false;
  bool isSummaryLoading = false;

  double? lastPickupLat;
  double? lastPickupLng;
  DateTime? lastPickupTime;

  final List<String> logs = [];

  DateTime statusStartedAt = DateTime.now();
  Duration statusElapsed = Duration.zero;
  Timer? statusTimer;

  @override
  void initState() {
    super.initState();

    statusTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;

        setState(() {
          statusElapsed = DateTime.now().difference(statusStartedAt);
        });
      },
    );

    loadSavedData();
  }

  @override
  void dispose() {
    statusTimer?.cancel();
    super.dispose();
  }

  Future<void> loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    final savedDriverId = prefs.getString('driverId');
    final savedPickupLat = prefs.getDouble(pickupLatKey);
    final savedPickupLng = prefs.getDouble(pickupLngKey);
    final savedPickupTimeText = prefs.getString(pickupTimeKey);

    DateTime? savedPickupTime;
    if (savedPickupTimeText != null) {
      savedPickupTime = DateTime.tryParse(savedPickupTimeText);
    }

    if (!mounted) return;

    setState(() {
      driverId = savedDriverId?.trim() ?? '';
      lastPickupLat = savedPickupLat;
      lastPickupLng = savedPickupLng;
      lastPickupTime = savedPickupTime;
    });

    if (driverId.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showDriverIdDialog();
      });
    }
  }

  Future<void> saveLastPickup({
    required Position position,
    required DateTime pickupTime,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    await Future.wait([
      prefs.setDouble(pickupLatKey, position.latitude),
      prefs.setDouble(pickupLngKey, position.longitude),
      prefs.setString(pickupTimeKey, pickupTime.toIso8601String()),
    ]);

    if (!mounted) return;

    setState(() {
      lastPickupLat = position.latitude;
      lastPickupLng = position.longitude;
      lastPickupTime = pickupTime;
    });
  }

  Future<void> showDriverIdDialog() async {
    final controller = TextEditingController(text: driverId);

    await showDialog<void>(
      context: context,
      barrierDismissible: driverId.isNotEmpty,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('ドライバーID設定'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              hintText: '例：D001',
              labelText: 'ドライバーID',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final newDriverId = controller.text.trim();

                if (newDriverId.isEmpty) {
                  return;
                }

                FocusScope.of(dialogContext).unfocus();

                if (!mounted) return;

                setState(() {
                  driverId = newDriverId;
                  pushLog('ドライバーID設定：$newDriverId');
                });

                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }

                try {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('driverId', newDriverId);
                } catch (error) {
                  if (!mounted) return;

                  setState(() {
                    pushLog('ID保存エラー：$error');
                  });
                }
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
  }

  void resetStatusTimer() {
    statusStartedAt = DateTime.now();
    statusElapsed = Duration.zero;
  }

  String formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes =
        (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds =
        (duration.inSeconds % 60).toString().padLeft(2, '0');

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }

    return '$minutes:$seconds';
  }

  String formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final second = dateTime.second.toString().padLeft(2, '0');

    return '$hour:$minute:$second';
  }

  void pushLog(String text) {
    logs.insert(0, text);

    if (logs.length > 30) {
      logs.removeRange(30, logs.length);
    }
  }

  Future<Position> getCurrentPosition() async {
    final serviceEnabled =
        await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      throw Exception('位置情報サービスがOFFです');
    }

    LocationPermission permission =
        await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw Exception('位置情報が許可されていません');
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception('位置情報が永久に拒否されています');
    }

    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
  }

  Future<void> sendEvent({
    required String label,
    required String event,
  }) async {
    if (isSending) {
      return;
    }

    if (driverId.isEmpty) {
      await showDriverIdDialog();

      if (driverId.isEmpty) {
        return;
      }
    }

    final pressedAt = DateTime.now();

    setState(() {
      isSending = true;
      currentStatus = label;
      sendingStatus = '位置情報取得中';
      resetStatusTimer();
      pushLog('${formatTime(pressedAt)}  $label');
    });

    try {
      final position = await getCurrentPosition();

      if (!mounted) return;

      setState(() {
        sendingStatus = '送信中';
      });

      final requestId =
          '${driverId}_${pressedAt.microsecondsSinceEpoch}';

      final payload = <String, dynamic>{
        'driverId': driverId,
        'token': '',
        'event': event,
        'status': event,
        'lat': position.latitude,
        'lng': position.longitude,
        'accuracy': position.accuracy,
        'fare': '',
        'memo': '',
        'requestId': requestId,
        'source': 'KUSOKEN_LITE',
      };

      final response = await http
          .post(
            Uri.parse(gasUrl),
            headers: const {
              'Content-Type': 'text/plain; charset=utf-8',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 20));

      if (!mounted) return;

      final eventSucceeded =
          response.statusCode == 200 ||
          response.statusCode == 302;

      if (!eventSucceeded) {
        setState(() {
          sendingStatus = '送信失敗';
          pushLog(
            '${formatTime(DateTime.now())}  HTTP ${response.statusCode}',
          );
        });
        return;
      }

      setState(() {
        sendingStatus = '送信完了';
        pushLog(
          '${formatTime(DateTime.now())}  送信成功 ${response.statusCode}',
        );
      });

      if (event == 'pickup') {
        await saveLastPickup(
          position: position,
          pickupTime: pressedAt,
        );

        if (!mounted) return;

        setState(() {
          summaryText = '実車地点を保存しました\n空車時にサマリーを取得します';
          pushLog(
            '${formatTime(DateTime.now())}  pickup地点保存',
          );
        });
      }

      if (event == 'dropoff') {
        await fetchSummary(
          dropoffPosition: position,
          eventTime: pressedAt,
        );
      }
    } on TimeoutException {
      if (!mounted) return;

      setState(() {
        sendingStatus = 'タイムアウト';
        pushLog(
          '${formatTime(DateTime.now())}  送信タイムアウト',
        );
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        sendingStatus = 'エラー';
        pushLog(
          '${formatTime(DateTime.now())}  $error',
        );
      });
    } finally {
      if (!mounted) return;

      setState(() {
        isSending = false;
      });
    }
  }

  Future<void> fetchSummary({
    required Position dropoffPosition,
    required DateTime eventTime,
  }) async {
    if (lastPickupLat == null || lastPickupLng == null) {
      if (!mounted) return;

      setState(() {
        summaryText = '直前のpickup地点がありません\n先に実車ボタンを押してください';
        pushLog(
          '${formatTime(DateTime.now())}  pickup地点なし',
        );
      });
      return;
    }

    if (summaryGasUrl == 'PASTE_SUMMARY_GAS_URL_HERE') {
      if (!mounted) return;

      setState(() {
        summaryText = 'サマリーGAS URLが未設定です';
        pushLog('サマリーGAS URL未設定');
      });
      return;
    }

    setState(() {
      isSummaryLoading = true;
      sendingStatus = 'サマリー取得中';
      summaryText = 'サマリー取得中…';
    });

    final payload = <String, dynamic>{
      'driver_id': driverId,
      'event_time': eventTime.toIso8601String(),
      'pickup_lat': lastPickupLat,
      'pickup_lng': lastPickupLng,
      'pickup_address': '',
      'pickup_prefecture': '',
      'pickup_city': '',
      'pickup_town': '',
      'pickup_chome': '',
      'dropoff_lat': dropoffPosition.latitude,
      'dropoff_lng': dropoffPosition.longitude,
      'dropoff_address': '',
    };

    final client = http.Client();

    try {
      final request = http.Request(
        'POST',
        Uri.parse(summaryGasUrl),
      )
        ..followRedirects = false
        ..headers['Content-Type'] =
            'text/plain; charset=utf-8'
        ..body = jsonEncode(payload);

      final streamedResponse = await client
          .send(request)
          .timeout(const Duration(seconds: 20));

      http.Response response =
          await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 301 ||
          response.statusCode == 302 ||
          response.statusCode == 303 ||
          response.statusCode == 307 ||
          response.statusCode == 308) {
        final redirectUrl = response.headers['location'];

        if (redirectUrl == null || redirectUrl.isEmpty) {
          throw Exception('サマリー転送先URLがありません');
        }

        response = await http
            .get(Uri.parse(redirectUrl))
            .timeout(const Duration(seconds: 20));
      }

      if (!mounted) return;

      if (response.statusCode != 200) {
        throw Exception(
          'サマリーHTTP ${response.statusCode}',
        );
      }

      final dynamic decoded = jsonDecode(response.body);

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'サマリー応答がJSONオブジェクトではありません',
        );
      }

      final ok = decoded['ok'] == true;
      final returnedSummary =
          decoded['summary']?.toString().trim() ?? '';
      final returnedError =
          decoded['error']?.toString().trim() ?? '';

      if (!ok) {
        throw Exception(
          returnedError.isEmpty
              ? 'サマリー作成に失敗しました'
              : returnedError,
        );
      }

      if (returnedSummary.isEmpty) {
        throw const FormatException('summaryが空欄です');
      }

      setState(() {
        summaryText = returnedSummary;
        sendingStatus = 'サマリー取得完了';
        pushLog(
          '${formatTime(DateTime.now())}  サマリー取得',
        );
      });
    } on TimeoutException {
      if (!mounted) return;

      setState(() {
        summaryText = 'サマリー取得がタイムアウトしました';
        sendingStatus = 'サマリータイムアウト';
        pushLog(
          '${formatTime(DateTime.now())}  サマリータイムアウト',
        );
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        summaryText = 'サマリー取得エラー\n$error';
        sendingStatus = 'サマリーエラー';
        pushLog(
          '${formatTime(DateTime.now())}  サマリーエラー',
        );
      });
    } finally {
      client.close();

      if (!mounted) return;

      setState(() {
        isSummaryLoading = false;
      });
    }
  }

  Color getStatusColor() {
    switch (currentStatus) {
      case '実車':
        return Colors.redAccent;
      case '空車':
        return Colors.blueAccent;
      default:
        return kusokenColor;
    }
  }

  Widget buildPanel({
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(
          color: kusokenColor,
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: child,
    );
  }

  Widget buildSummaryPanel() {
  return buildPanel(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isSummaryLoading)
            const Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: kusokenColor,
                ),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              child: SelectableText(
                summaryText,
                style: const TextStyle(
                  color: kusokenColor,
                  fontSize: 22,
                  height: 1.55,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          if (lastPickupLat != null && lastPickupLng != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                lastPickupTime == null
                    ? '直前pickup保存済み'
                    : '直前pickup：${formatTime(lastPickupTime!)}',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

  Widget buildEventButton({
    required String label,
    required String event,
    required Color color,
  }) {
    return SizedBox(
      height: double.infinity,
      child: ElevatedButton(
        onPressed: isSending
            ? null
            : () {
                sendEvent(
                  label: label,
                  event: event,
                );
              },
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.black,
          foregroundColor: color,
          disabledBackgroundColor: Colors.black54,
          disabledForegroundColor: Colors.grey,
          side: BorderSide(
            color: isSending ? Colors.grey : color,
            width: 2.5,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget buildControlPanel() {
    final statusColor = getStatusColor();
    final displayedLogs = logs.take(3).toList();

    return buildPanel(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    currentStatus,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'ドライバーID設定',
                  onPressed: isSending
                      ? null
                      : showDriverIdDialog,
                  icon: const Icon(
                    Icons.settings,
                    color: kusokenColor,
                  ),
                ),
              ],
            ),
            Text(
              formatDuration(statusElapsed),
              style: TextStyle(
                color: statusColor,
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'ID：${driverId.isEmpty ? '未設定' : driverId}',
              style: const TextStyle(
                color: kusokenColor,
                fontSize: 15,
              ),
            ),
            Text(
              '通信：$sendingStatus',
              style: TextStyle(
                color: isSending || isSummaryLoading
                    ? Colors.yellowAccent
                    : kusokenColor,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  Expanded(
                    child: buildEventButton(
                      label: '実車',
                      event: 'pickup',
                      color: Colors.redAccent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: buildEventButton(
                      label: '空車',
                      event: 'dropoff',
                      color: Colors.blueAccent,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              flex: 2,
              child: displayedLogs.isEmpty
                  ? const Text(
                      'ログなし',
                      style: TextStyle(
                        color: kusokenColor,
                        fontSize: 14,
                      ),
                    )
                  : ListView.builder(
                      physics:
                          const NeverScrollableScrollPhysics(),
                      itemCount: displayedLogs.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding:
                              const EdgeInsets.only(bottom: 4),
                          child: Text(
                            displayedLogs[index],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kusokenColor,
                              fontSize: 14,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isLandscape =
                constraints.maxWidth > constraints.maxHeight;

            if (isLandscape) {
              return Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      flex: 6,
                      child: buildSummaryPanel(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 4,
                      child: buildControlPanel(),
                    ),
                  ],
                ),
              );
            }

            return Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Expanded(
                    flex: 5,
                    child: buildSummaryPanel(),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    flex: 5,
                    child: buildControlPanel(),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
