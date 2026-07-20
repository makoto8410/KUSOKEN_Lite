import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FontFeature;

import 'package:characters/characters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  runApp(const KusokenApp());
}

class KusokenApp extends StatelessWidget {
  const KusokenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KUSOKEN β',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const KusokenHomePage(),
    );
  }
}

class KusokenHomePage extends StatefulWidget {
  const KusokenHomePage({super.key});

  @override
  State<KusokenHomePage> createState() => _KusokenHomePageState();
}

class _KusokenHomePageState extends State<KusokenHomePage> {
  static const Color kusokenColor = Colors.cyanAccent;

  /// 個人RAW／ARCHIVEへイベントを書き込むGAS。
  final String gasUrl =
      'https://script.google.com/macros/s/AKfycbyQ2BIQf-w3YSVAEuFB54UPttnUv_B7ssfAYsxv5lOm52H-pPjaKBhbb_c4_IOhUfV-4g/exec';

  /// サマリー専用GASのデプロイURLへ置き換えてください。
  /// 例: https://script.google.com/macros/s/XXXXXXXXXXXX/exec
  final String summaryGasUrl =
      'https://script.google.com/macros/s/AKfycbx-Rps17ek8jPQaFzCF5dybQYnhY_y78iqlFTsL7AbqO5-SC5WHvAlSWkT7ncMJ7lLozw/exec';

  String currentStatus = '準備';
  String communicationStatus = '';
  String voiceText = '';
  String fare = '';
  String driverId = '';
  String bleStatus = 'BLE未接続';
  String summaryText = '実車後、空車にするとサマリーを表示します。';
  String currentAddressText = '';
  bool isShowingCurrentAddress = false;

  double? savedPickupLat;
  double? savedPickupLng;
  String savedPickupAddress = '';

  final List<String> logs = [];

  BluetoothDevice? espDevice;
  BluetoothCharacteristic? espCharacteristic;
  StreamSubscription<List<ScanResult>>? scanSubscription;
  StreamSubscription<List<int>>? espValueSubscription;

  late stt.SpeechToText speech;
  bool isListening = false;
  bool isEmptyProcessing = false;

  DateTime statusStartedAt = DateTime.now();
  Duration statusElapsed = Duration.zero;
  Timer? statusTimer;
  Timer? clockTimer;
  DateTime currentDateTime = DateTime.now();

  bool get isSummaryUrlConfigured =>
      summaryGasUrl.startsWith('https://script.google.com/macros/s/') &&
      summaryGasUrl.endsWith('/exec');

  @override
  void initState() {
    super.initState();

    WakelockPlus.enable();

    speech = stt.SpeechToText();

    statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        statusElapsed = DateTime.now().difference(statusStartedAt);
      });
    });

    clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        currentDateTime = DateTime.now();
      });
    });

    startApp();
  }

  Future<void> startApp() async {
    await loadSavedData();

    if (!mounted) return;

    await scanBle();
  }

  @override
  void dispose() {
    statusTimer?.cancel();
    clockTimer?.cancel();
    scanSubscription?.cancel();
    espValueSubscription?.cancel();
    speech.stop();
    super.dispose();
  }

  void resetStatusTimer() {
    statusStartedAt = DateTime.now();
    statusElapsed = Duration.zero;
  }

  void setCommunicationStatus(String value) {
    if (!mounted) return;
    setState(() {
      communicationStatus = value;
    });
  }

  String formatDuration(Duration duration) {
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  String timeText(DateTime dateTime) {
    return '${dateTime.hour.toString().padLeft(2, '0')}:'
        '${dateTime.minute.toString().padLeft(2, '0')}:'
        '${dateTime.second.toString().padLeft(2, '0')}';
  }

  String dateText(DateTime dateTime) {
    const weekdays = ['月', '火', '水', '木', '金', '土', '日'];

    return '${dateTime.month.toString().padLeft(2, '0')}/'
        '${dateTime.day.toString().padLeft(2, '0')}'
        '(${weekdays[dateTime.weekday - 1]}) '
        '${dateTime.hour.toString().padLeft(2, '0')}:'
        '${dateTime.minute.toString().padLeft(2, '0')}:'
        '${dateTime.second.toString().padLeft(2, '0')}';
  }

  void pushLog(String text) {
    logs.insert(0, text);
    if (logs.length > 50) {
      logs.removeRange(50, logs.length);
    }
  }

  Future<bool> requestBlePermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final scanGranted =
        statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connectGranted =
        statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    final locationGranted =
        statuses[Permission.locationWhenInUse]?.isGranted ?? false;

    if (mounted) {
      setState(() {
        pushLog(
          'BLE権限：'
          'scan=$scanGranted '
          'connect=$connectGranted '
          'location=$locationGranted',
        );
      });
    }

    return scanGranted && connectGranted && locationGranted;
  }

  Future<void> scanBle() async {
    if (!mounted) return;

    final permissionGranted = await requestBlePermissions();

    if (!permissionGranted) {
      if (!mounted) return;

      setState(() {
        bleStatus = 'BLE権限なし';
        pushLog('BLE権限が許可されていません');
      });
      return;
    }

    setState(() {
      bleStatus = 'BLEスキャン中';
      pushLog('BLEスキャン開始');
    });

    try {
      await scanSubscription?.cancel();

      scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
        for (final result in results) {
          final name = result.device.platformName.isNotEmpty
              ? result.device.platformName
              : result.advertisementData.advName;

          if (name.isNotEmpty && mounted) {
            setState(() {
              pushLog('BLE検出：$name');
            });
          }

          if (name != 'KUSOKEN-ESP') continue;

          await FlutterBluePlus.stopScan();
          espDevice = result.device;

          if (mounted) {
            setState(() {
              bleStatus = 'ESP検出';
              pushLog('KUSOKEN-ESP検出');
            });
          }

          await connectEsp();
          return;
        }
      });

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 8),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        bleStatus = 'BLEスキャン失敗';
        pushLog('BLEスキャンエラー：$e');
      });
    }
  }

  Future<void> connectEsp() async {
    final device = espDevice;
    if (device == null) return;

    try {
      await device.connect(
        timeout: const Duration(seconds: 10),
        license: License.free,
      );

      if (!mounted) return;
      setState(() {
        bleStatus = 'ESP接続済み';
        pushLog('ESP接続成功');
      });

      await discoverEspServices();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        bleStatus = 'ESP接続失敗';
        pushLog('ESP接続エラー：$e');
      });
    }
  }

  Future<void> discoverEspServices() async {
    final device = espDevice;
    if (device == null) return;

    try {
      final services = await device.discoverServices();

      for (final service in services) {
        if (service.uuid.toString() !=
            '8f8a0001-6c7a-4a5b-9a6f-000000000001') {
          continue;
        }

        for (final characteristic in service.characteristics) {
          if (characteristic.uuid.toString() !=
              '8f8a0002-6c7a-4a5b-9a6f-000000000001') {
            continue;
          }

          espCharacteristic = characteristic;
          await characteristic.setNotifyValue(true);

          await espValueSubscription?.cancel();
          espValueSubscription =
              characteristic.lastValueStream.listen((value) async {
            final jsonText = utf8.decode(value, allowMalformed: true);

            if (mounted) {
              setState(() {
                pushLog('BLE受信：$jsonText');
              });
            }

            await handleBleJson(jsonText);
          });

          if (!mounted) return;
          setState(() {
            bleStatus = 'ESP接続済み';
            pushLog('ESP通知受信準備OK');
          });
          return;
        }
      }

      if (!mounted) return;
      setState(() {
        bleStatus = 'ESPサービスなし';
        pushLog('ESPサービスが見つかりません');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        bleStatus = 'ESP設定失敗';
        pushLog('ESPサービス設定エラー：$e');
      });
    }
  }

  Future<void> handleBleJson(String jsonText) async {
    final text = jsonText.trim();

    if (text.isEmpty || !text.startsWith('{')) return;

    try {
      final dynamic decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['type'] != 'button') return;

      final dynamic buttonValue = decoded['btn'];
      final int? buttonNumber = buttonValue is int
          ? buttonValue
          : int.tryParse(buttonValue.toString());

      switch (buttonNumber) {
        case 1:
          await sendLog('実車', 'pickup');
          break;
        case 2:
          await startFareVoiceInput();
          break;
        case 3:
          await sendLog('Deploy', 'deploy');
          break;
        case 4:
          await sendLog('迎車', 'pickup_request');
          break;
        case 5:
          await sendLog('出庫', 'startwork');
          break;
        case 6:
          await sendLog('帰庫', 'endwork');
          break;
        default:
          if (!mounted) return;
          setState(() {
            pushLog('未定義ボタン：$buttonValue');
          });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        pushLog('JSON解析エラー：$e / raw=$text');
      });
    }
  }

  Future<void> loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString('driverId');

    final pickupLat = prefs.getDouble('savedPickupLat');
    final pickupLng = prefs.getDouble('savedPickupLng');
    final pickupAddress = prefs.getString('savedPickupAddress') ?? '';

    if (!mounted) return;

    setState(() {
      driverId = savedId ?? '';
      savedPickupLat = pickupLat;
      savedPickupLng = pickupLng;
      savedPickupAddress = pickupAddress;
    });

    if (savedId == null || savedId.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 300));

      if (!mounted) return;

      await showDriverIdDialog();
    }
  }

  Future<void> savePickupPoint(
    Position position, {
    String address = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setDouble('savedPickupLat', position.latitude);
    await prefs.setDouble('savedPickupLng', position.longitude);
    await prefs.setString('savedPickupAddress', address);

    if (!mounted) return;
    setState(() {
      savedPickupLat = position.latitude;
      savedPickupLng = position.longitude;
      savedPickupAddress = address;
      pushLog('pickup地点を保存');
    });
  }

  Future<void> showDriverIdDialog() async {
    if (!mounted) return;

    final controller = TextEditingController(text: driverId);

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('ドライバーID設定'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '例：D001',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final id = controller.text.trim();
                if (id.isEmpty) return;

                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('driverId', id);

                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop();

                if (!mounted) return;
                setState(() {
                  driverId = id;
                  pushLog('ドライバーID：$id');
                });
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    // ローカルControllerはダイアログ終了アニメーション中に参照されることがあるため、
    // ここでは即時disposeしない。
  }

  Future<Position> getCurrentPosition() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('位置情報サービスがOFFです');
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw Exception('位置情報の許可がありません');
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception('位置情報が永久に拒否されています');
    }

    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
  }

  String parseFareText(String text) {
    final normalized = text
        .replaceAll('，', '')
        .replaceAll(',', '')
        .replaceAll('円', '')
        .replaceAll(' ', '')
        .replaceAll('　', '')
        .trim();

    if (RegExp(r'^[0-9]+$').hasMatch(normalized)) {
      return normalized;
    }

    final directNumber = normalized.replaceAll(RegExp(r'[^0-9]'), '');

    int kanjiNumberToInt(String source) {
      const numbers = {
        '零': 0,
        '〇': 0,
        '一': 1,
        '二': 2,
        '三': 3,
        '四': 4,
        '五': 5,
        '六': 6,
        '七': 7,
        '八': 8,
        '九': 9,
      };

      const units = {
        '十': 10,
        '百': 100,
        '千': 1000,
      };

      var total = 0;
      var current = 0;

      for (final character in source.characters) {
        if (numbers.containsKey(character)) {
          current = numbers[character]!;
        } else if (units.containsKey(character)) {
          final unit = units[character]!;
          total += (current == 0 ? 1 : current) * unit;
          current = 0;
        }
      }

      return total + current;
    }

    var result = 0;

    if (normalized.contains('万')) {
      final parts = normalized.split('万');
      final manPart = parts.first;
      final restPart = parts.length > 1 ? parts[1] : '';

      final manValue = RegExp(r'[0-9]').hasMatch(manPart)
          ? int.parse(manPart.replaceAll(RegExp(r'[^0-9]'), ''))
          : kanjiNumberToInt(manPart);

      result += manValue * 10000;

      if (restPart.isNotEmpty) {
        final restValue = RegExp(r'[0-9]').hasMatch(restPart)
            ? int.parse(restPart.replaceAll(RegExp(r'[^0-9]'), ''))
            : kanjiNumberToInt(restPart);

        result += restValue;
      }

      return result.toString();
    }

    if (directNumber.isNotEmpty) {
      return directNumber;
    }

    final kanjiValue = kanjiNumberToInt(normalized);
    return kanjiValue > 0 ? kanjiValue.toString() : '';
  }

  Future<http.Response> postToAppsScript_({
    required String url,
    required Map<String, dynamic> payload,
    required Duration timeout,
    required String logPrefix,
  }) async {
    final request = http.Request(
      'POST',
      Uri.parse(url),
    )
      ..followRedirects = false
      ..headers['Content-Type'] = 'text/plain; charset=UTF-8'
      ..body = jsonEncode(payload);

    if (mounted) {
      setState(() {
        pushLog('$logPrefix URL：$url');
      });
    }

    final streamedResponse = await request.send().timeout(timeout);
    var response = await http.Response.fromStream(streamedResponse);

    if (mounted) {
      setState(() {
        pushLog(
          '$logPrefix HTTP：${response.statusCode} '
          '${response.headers['content-type'] ?? '(Content-Typeなし)'}',
        );
      });
    }

    final isRedirect = response.statusCode == 301 ||
        response.statusCode == 302 ||
        response.statusCode == 303 ||
        response.statusCode == 307 ||
        response.statusCode == 308;

    if (isRedirect) {
      final location = response.headers['location'];

      if (location == null || location.trim().isEmpty) {
        throw Exception(
          '$logPrefix リダイレクト先URLがありません',
        );
      }

      final redirectUri = Uri.parse(location);

      if (mounted) {
        setState(() {
          pushLog('$logPrefix 転送先：$redirectUri');
        });
      }

      response = await http.get(redirectUri).timeout(timeout);

      if (mounted) {
        setState(() {
          pushLog(
            '$logPrefix 転送後HTTP：${response.statusCode} '
            '${response.headers['content-type'] ?? '(Content-Typeなし)'}',
          );
          pushLog(
            '$logPrefix 最終URL：${response.request?.url ?? redirectUri}',
          );
        });
      }
    } else if (mounted) {
      setState(() {
        pushLog(
          '$logPrefix 最終URL：${response.request?.url ?? Uri.parse(url)}',
        );
      });
    }

    return response;
  }

  Future<String> fetchAddress(double lat, double lng) async {
    if (!isSummaryUrlConfigured) return '';

    try {
      final payload = {
        'action': 'location',
        'lat': lat,
        'lng': lng,
      };

      final response = await postToAppsScript_(
        url: summaryGasUrl,
        payload: payload,
        timeout: const Duration(seconds: 15),
        logPrefix: '住所',
      );

      if (response.statusCode != 200) {
        return '';
      }

      final responseText = utf8.decode(response.bodyBytes).trim();

      if (mounted) {
        setState(() {
          pushLog(
            '住所GAS応答：'
            '${responseText.isEmpty ? '(空)' : responseText}',
          );
        });
      }

      if (responseText.isEmpty) {
        return '';
      }

      final decoded = jsonDecode(responseText);
      if (decoded is! Map<String, dynamic> || decoded['ok'] != true) {
        return '';
      }

      return decoded['address']?.toString().trim() ?? '';
    } catch (e) {
      if (mounted) {
        setState(() {
          pushLog('住所取得エラー：$e');
        });
      }
      return '';
    }
  }

  Future<Position?> sendLog(
    String label,
    String event, {
    String value = '',
  }) async {
    if (driverId.isEmpty) {
      await showDriverIdDialog();
      if (driverId.isEmpty) return null;
    }

    final now = DateTime.now();

    if (mounted) {
      setState(() {
        currentStatus = label;
        resetStatusTimer();
        communicationStatus = '現在地取得中';
        pushLog('${timeText(now)}  $label');
      });
    }

    try {
      final position = await getCurrentPosition();

      setCommunicationStatus('送信中');

      final response = await http
          .post(
            Uri.parse(gasUrl),
            headers: const {
              'Content-Type': 'text/plain; charset=UTF-8',
            },
            body: jsonEncode({
              'driverId': driverId,
              'event': event,
              'status': event,
              'source': 'ESP_BLE',
              'note': 'esp button',
              'value': value,
              'lat': position.latitude,
              'lng': position.longitude,
              'accuracy': position.accuracy,
            }),
          )
          .timeout(const Duration(seconds: 20));

      final responseText = utf8.decode(response.bodyBytes).trim();

      if (mounted) {
        setState(() {
          pushLog(
            '${timeText(DateTime.now())}  GAS応答：'
            '${responseText.isEmpty ? '(空)' : responseText}',
          );
        });
      }

      if (response.statusCode != 200 && response.statusCode != 302) {
        throw Exception(
          'GAS HTTPエラー：${response.statusCode} / '
          '${responseText.isEmpty ? '(応答なし)' : responseText}',
        );
      }

      // 通常GASはHTTP成功なら、レスポンス形式に関係なく処理を続行する。
      // 明示的に ok:false または success:false が返った場合だけ失敗扱い。
      if (responseText.isNotEmpty) {
        try {
          final dynamic decodedResponse = jsonDecode(responseText);

          if (decodedResponse is Map<String, dynamic>) {
            final explicitFailure =
                decodedResponse['ok'] == false ||
                decodedResponse['success'] == false;

            if (explicitFailure) {
              throw Exception(
                decodedResponse['error']?.toString() ??
                    'GAS処理失敗：$responseText',
              );
            }
          }
        } on FormatException {
          if (mounted) {
            setState(() {
              pushLog('GAS応答は非JSON：$responseText');
            });
          }
        }
      }

      if (mounted) {
        setState(() {
          pushLog(
            '${timeText(DateTime.now())}  GAS送信完了',
          );
        });
      }

      if (event == 'pickup') {
        setCommunicationStatus('pickup保存中');
        final address = await fetchAddress(
          position.latitude,
          position.longitude,
        );
        await savePickupPoint(position, address: address);
      }

      return position;
    } catch (e) {
      if (!mounted) return null;
      setState(() {
        pushLog('${timeText(DateTime.now())}  送信エラー：$e');
      });
      return null;
    } finally {
      setCommunicationStatus('');
    }
  }

  Future<bool> fetchSalesSummary({
    required Position dropoffPosition,
  }) async {
    if (!isSummaryUrlConfigured) {
      if (!mounted) return false;
      setState(() {
        summaryText = 'サマリーGASのURLが未設定です。';
        communicationStatus = 'URL未設定';
        pushLog('summaryGasUrlを設定してください');
      });
      return false;
    }

    if (savedPickupLat == null || savedPickupLng == null) {
      if (!mounted) return false;
      setState(() {
        summaryText = '直前の実車地点がありません。';
        communicationStatus = 'pickup地点なし';
        pushLog('サマリー取得中止：pickup地点なし');
      });
      return false;
    }

    setCommunicationStatus('サマリー取得中');

    try {
      final dropoffAddress = await fetchAddress(
        dropoffPosition.latitude,
        dropoffPosition.longitude,
      );

      final payload = <String, dynamic>{
              // 新しいサマリーGAS用
              'action': 'summary',
              'driverId': driverId,
              'weekday': DateTime.now().weekday % 7,
              'hour': DateTime.now().hour,
              'pickupPoint': {
                'lat': savedPickupLat,
                'lng': savedPickupLng,
                'address': savedPickupAddress,
              },
              'dropoffPoint': {
                'lat': dropoffPosition.latitude,
                'lng': dropoffPosition.longitude,
                'address': dropoffAddress,
              },

              // 旧サマリーGASとの互換用
              'driver_id': driverId,
              'event_time': DateTime.now().toIso8601String(),
              'pickup_lat': savedPickupLat,
              'pickup_lng': savedPickupLng,
              'pickup_address': savedPickupAddress,
              'pickup_prefecture': '',
              'pickup_city': '',
              'pickup_town': '',
              'pickup_chome': '',
              'dropoff_lat': dropoffPosition.latitude,
              'dropoff_lng': dropoffPosition.longitude,
              'dropoff_address': dropoffAddress,
      };

      final response = await postToAppsScript_(
        url: summaryGasUrl,
        payload: payload,
        timeout: const Duration(seconds: 25),
        logPrefix: 'サマリー',
      );

      final responseText = utf8.decode(response.bodyBytes).trim();

      if (mounted) {
        setState(() {
          pushLog(
            'サマリーGAS応答：'
            '${responseText.isEmpty ? '(空)' : responseText}',
          );
        });
      }

      if (response.statusCode != 200 && response.statusCode != 302) {
        throw Exception(
          'HTTP ${response.statusCode} / '
          '${responseText.isEmpty ? '(応答なし)' : responseText}',
        );
      }

      if (responseText.isEmpty) {
        throw Exception('サマリーGAS応答が空です');
      }

      final dynamic decoded = jsonDecode(responseText);

      if (decoded is! Map<String, dynamic>) {
        throw Exception('サマリーレスポンス形式が不正です');
      }

      if (decoded['ok'] != true) {
        throw Exception(
          decoded['error']?.toString() ?? 'サマリー取得に失敗しました',
        );
      }

      final receivedSummary = decoded['summary']?.toString().trim() ?? '';

      if (!mounted) return true;
      setState(() {
        summaryText = receivedSummary.isEmpty ? '該当実績なし' : receivedSummary;
        currentAddressText = '';
        isShowingCurrentAddress = false;
        communicationStatus = 'サマリー受信';
        pushLog('サマリー受信成功');
      });

      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted && communicationStatus == 'サマリー受信') {
        setCommunicationStatus('');
      }

      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        summaryText = 'サマリーを取得できませんでした。';
        communicationStatus = 'サマリー取得エラー';
        pushLog('サマリー取得エラー：$e');
      });
      return false;
    }
  }

  Future<void> startFareVoiceInput() async {
    if (isListening || isEmptyProcessing) return;

    setCommunicationStatus('音声入力準備中');

    final available = await speech.initialize(
      onStatus: (status) {
        if (!mounted) return;

        if (status == 'notListening' || status == 'done') {
          setState(() {
            isListening = false;
            if (communicationStatus == '音声入力中') {
              communicationStatus = '';
            }
          });
        }
      },
      onError: (error) {
        if (!mounted) return;
        setState(() {
          isListening = false;
          isEmptyProcessing = false;
          communicationStatus = '';
          pushLog('音声認識エラー：${error.errorMsg}');
        });
      },
    );

    if (!available) {
      if (!mounted) return;
      setState(() {
        communicationStatus = '';
        pushLog('音声認識が利用できません');
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      isListening = true;
      voiceText = '';
      fare = '';
      communicationStatus = '音声入力中';
      pushLog('単価を話してください');
    });

    await speech.listen(
      localeId: 'ja_JP',
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 3),
      onResult: (result) async {
        if (!mounted) return;

        setState(() {
          voiceText = result.recognizedWords;
        });

        if (!result.finalResult || isEmptyProcessing) return;

        isEmptyProcessing = true;
        await speech.stop();

        final recognizedFare = parseFareText(result.recognizedWords);
        final fareNumber = int.tryParse(recognizedFare);

        if (recognizedFare.isEmpty || fareNumber == null || fareNumber <= 0) {
          if (!mounted) return;
          setState(() {
            isListening = false;
            isEmptyProcessing = false;
            communicationStatus = '単価を認識できません';
            pushLog('単価認識失敗：${result.recognizedWords}');
          });
          return;
        }

        if (!mounted) return;
        setState(() {
          isListening = false;
          fare = recognizedFare;
          communicationStatus = '空車送信中';
          pushLog('単価：$fare');
        });

        final dropoffPosition = await sendLog(
          '空車',
          'dropoff',
          value: fare,
        );

        if (dropoffPosition != null) {
          await fetchSalesSummary(
            dropoffPosition: dropoffPosition,
          );
        }

        if (mounted) {
          setState(() {
            isEmptyProcessing = false;
          });
        }
      },
    );
  }

  Future<void> handleCurrentLocationButton() async {
    setCommunicationStatus('現在地取得中');

    try {
      final position = await getCurrentPosition();
      final address = await fetchAddress(
        position.latitude,
        position.longitude,
      );

      final displayText = address.isNotEmpty
          ? address
          : '${position.latitude.toStringAsFixed(5)}, '
              '${position.longitude.toStringAsFixed(5)}';

      if (!mounted) return;
      setState(() {
        currentAddressText = displayText;
        isShowingCurrentAddress = true;
        communicationStatus = '現在地表示';
        pushLog('現在地：$displayText');
      });

      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted && communicationStatus == '現在地表示') {
        setCommunicationStatus('');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        currentAddressText = '現在地を取得できませんでした。';
        isShowingCurrentAddress = true;
        communicationStatus = '現在地取得エラー';
        pushLog('現在地取得エラー：$e');
      });
    }
  }

  Future<void> handleWorkButton(
    String label,
    String event,
  ) async {
    await sendLog(label, event);
  }

  Color getStatusColor(String status) {
    switch (status) {
      case '実車':
        return Colors.blueAccent;
      case '空車':
        return Colors.redAccent;
      case 'Deploy':
      case '待機':
        return Colors.yellowAccent;
      case '迎車':
        return Colors.pinkAccent;
      default:
        return kusokenColor;
    }
  }

  bool get isEspConnected => bleStatus.contains('接続済み');

  Color getEspColor() {
    return isEspConnected ? Colors.greenAccent : Colors.redAccent;
  }

  Widget buildPanel({
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(
          color: kusokenColor,
          width: 1.4,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  Widget buildPanelTitle(String title) {
    return Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: kusokenColor,
        fontSize: 24,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  Widget buildInformationPanel({
    required bool compact,
  }) {
    final dateFontSize = compact ? 17.0 : 20.0;
    final timeFontSize = compact ? 34.0 : 42.0;
    final logFontSize = compact ? 12.0 : 14.0;
    final visibleLogs = logs.take(5).toList();

    return buildPanel(
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Column(
                children: [
                  Text(
                    dateText(currentDateTime),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: kusokenColor,
                      fontSize: dateFontSize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: compact ? 6 : 10),
            Divider(
              color: kusokenColor.withOpacity(0.45),
              height: 1,
            ),
            SizedBox(height: compact ? 6 : 10),
            Text(
              '通信ログ',
              style: TextStyle(
                color: kusokenColor,
                fontSize: compact ? 13 : 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: compact ? 4 : 6),
            Expanded(
              child: visibleLogs.isEmpty
                  ? Text(
                      'ログはまだありません。',
                      style: TextStyle(
                        color: kusokenColor.withOpacity(0.6),
                        fontSize: logFontSize,
                      ),
                    )
                  : ListView.separated(
                      padding: EdgeInsets.zero,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: visibleLogs.length,
                      separatorBuilder: (_, __) =>
                          SizedBox(height: compact ? 3 : 5),
                      itemBuilder: (context, index) {
                        return Text(
                          visibleLogs[index],
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: kusokenColor,
                            fontSize: logFontSize,
                            height: 1.25,
                            fontWeight: index == 0
                                ? FontWeight.bold
                                : FontWeight.normal,
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

  InlineSpan buildHighlightedSummarySpan({
    required bool compact,
  }) {
    final baseStyle = TextStyle(
      color: kusokenColor,
      fontSize: compact ? 16 : 20,
      height: 1.55,
      fontWeight: FontWeight.w600,
    );

    final areaStyle = baseStyle.copyWith(
      color: Colors.yellowAccent,
      fontWeight: FontWeight.bold,
    );

    final spans = <InlineSpan>[];
    final lines = summaryText.split('\n');

    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final match = RegExp(
        r'^(リターン：|3km以内：|帰路途中：)([^、]+)(.*)$',
      ).firstMatch(line);

      if (match != null && !line.contains('該当実績なし')) {
        spans.add(TextSpan(
          text: match.group(1),
          style: baseStyle,
        ));
        spans.add(TextSpan(
          text: match.group(2),
          style: areaStyle,
        ));
        spans.add(TextSpan(
          text: match.group(3),
          style: baseStyle,
        ));
      } else {
        spans.add(TextSpan(
          text: line,
          style: baseStyle,
        ));
      }

      if (index < lines.length - 1) {
        spans.add(const TextSpan(text: '\n'));
      }
    }

    return TextSpan(children: spans);
  }

  Widget buildSummaryPanel({
  required bool compact,
}) {
  return buildPanel(
    child: Padding(
      padding: EdgeInsets.all(compact ? 14 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: isShowingCurrentAddress
                  ? Text(
                      currentAddressText,
                      style: TextStyle(
                        color: Colors.redAccent,
                        fontSize: compact ? 24 : 30,
                        height: 1.5,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : Text.rich(
                      buildHighlightedSummarySpan(
                        compact: compact,
                      ),
                    ),
            ),
          ),
        ],
      ),
    ),
  );
}

  Widget buildStatusItem({
    required Widget child,
    double? width,
  }) {
    final content = Container(
      height: 42,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(
          color: kusokenColor.withOpacity(0.55),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );

    if (width == null) {
      return content;
    }

    return SizedBox(
      width: width,
      child: content,
    );
  }

  Widget buildBottomActionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return SizedBox(
      width: 48,
      height: 42,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: Colors.black,
          foregroundColor: color ?? kusokenColor,
          side: BorderSide(
            color: color ?? kusokenColor,
            width: 1.1,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: Icon(
          icon,
          size: 23,
        ),
      ),
    );
  }

  Widget buildBottomBar({
    required double availableWidth,
  }) {
    final statusColor = getStatusColor(currentStatus);
    final communicationText =
        communicationStatus.isEmpty ? 'KUSOKEN' : communicationStatus;
    final fareText = fare.isEmpty ? '¥－' : '¥$fare';

    return SizedBox(
      height: 54,
      child: Row(
        children: [
          buildStatusItem(
            width: 78,
            child: Text(
              currentStatus,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: statusColor,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 6),
          buildStatusItem(
            width: 104,
            child: Text(
              formatDuration(statusElapsed),
              style: TextStyle(
                color: statusColor,
                fontSize: 17,
                fontWeight: FontWeight.bold,
                fontFeatures: const [
                  FontFeature.tabularFigures(),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          buildStatusItem(
            width: 44,
            child: Text(
              'ESP',
              textAlign: TextAlign.center,
              maxLines: 1,
              style: TextStyle(
                color: getEspColor(),
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: buildStatusItem(
              child: Text(
                isListening && voiceText.isNotEmpty
                    ? voiceText
                    : communicationText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isListening
                      ? Colors.orangeAccent
                      : communicationStatus.isEmpty
                          ? kusokenColor.withOpacity(0.72)
                          : kusokenColor,
                  fontSize: 14,
                  fontWeight: communicationStatus.isEmpty
                      ? FontWeight.normal
                      : FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          buildStatusItem(
            width: 82,
            child: Text(
              fareText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kusokenColor,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 6),
          buildBottomActionButton(
            icon: Icons.play_arrow_rounded,
            tooltip: '出庫',
            onPressed: () {
              handleWorkButton('出庫', 'startwork');
            },
          ),
          const SizedBox(width: 6),
          buildBottomActionButton(
            icon: Icons.stop_rounded,
            tooltip: '帰庫',
            onPressed: () {
              handleWorkButton('帰庫', 'endwork');
            },
          ),
          const SizedBox(width: 6),
          buildBottomActionButton(
            icon: Icons.settings_rounded,
            tooltip: '設定',
            onPressed: showDriverIdDialog,
          ),
          const SizedBox(width: 6),
          buildBottomActionButton(
            icon: Icons.my_location_rounded,
            tooltip: '現在地',
            onPressed: handleCurrentLocationButton,
          ),
        ],
      ),
    );
  }

  Widget buildLandscapeLayout(
    BoxConstraints constraints,
  ) {
    final compact = constraints.maxHeight < 430;

    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: buildInformationPanel(
                    compact: compact,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: buildSummaryPanel(
                    compact: compact,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          buildBottomBar(
            availableWidth: constraints.maxWidth,
          ),
        ],
      ),
    );
  }

  Widget buildPortraitLayout(
    BoxConstraints constraints,
  ) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        children: [
          Expanded(
            child: buildInformationPanel(
              compact: true,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: buildSummaryPanel(
              compact: true,
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: 760,
              child: buildBottomBar(
                availableWidth: 760,
              ),
            ),
          ),
        ],
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
              return buildLandscapeLayout(constraints);
            }

            return buildPortraitLayout(constraints);
          },
        ),
      ),
    );
  }
}
