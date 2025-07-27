import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'dart:ui' as ui;
import 'package:permission_handler/permission_handler.dart';
import 'package:image/image.dart' as img;

// === 열거형 정의 ===
enum AppPageState { main, guide, camera, result }

class MainPage extends StatefulWidget {
  final List<CameraDescription> cameras;

  const MainPage({super.key, required this.cameras});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with WidgetsBindingObserver {
  // 화면 상태 관리
  AppPageState _currentState = AppPageState.main;

  // 카메라 관련
  late CameraController _controller;
  bool _isCameraReady = false;
  bool _hasPermission = false;

  // 처리 상태
  bool _isProcessing = false;
  double _processingProgress = 0.0;
  Timer? _progressTimer;
  String? _processingStatus;

  // 결과 이미지들
  ui.Image? _overlayImage;
  ui.Image? _predictImage;
  bool _showOverlay = true;

  // 촬영된 이미지 (호환성용)
  XFile? _capturedImage;
  ui.Image? _capturedDisplayImage;

  // 드래그 관련 (호환성용)
  Offset? _dragStart;
  Offset? _dragEnd;
  bool _isDragging = false;

  // 가이드 단계
  int _guideStep = 0;

  // 촬영 상태
  bool _isCapturing = false;

  // 플래시 효과
  bool _showFlash = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _progressTimer?.cancel();
    if (_isCameraReady) {
      _controller.dispose();
    }
    super.dispose();
  }

  // === 권한 및 카메라 초기화 ===
  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (status.isGranted) {
      setState(() {
        _hasPermission = true;
      });
      await _initializeCamera();
    } else {
      _showPermissionDialog();
    }
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('카메라 권한 필요'),
        content: const Text('재활용품 분석을 위해 카메라 접근 권한이 필요합니다.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              setState(() {
                _currentState = AppPageState.guide;
              });
            },
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              openAppSettings();
            },
            child: const Text('설정으로 이동'),
          ),
        ],
      ),
    );
  }

  Future<void> _initializeCamera() async {
    try {
      _controller = CameraController(
        widget.cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await _controller.initialize();
      if (mounted) {
        setState(() {
          _isCameraReady = true;
          _currentState = AppPageState.camera;
        });
      }
    } catch (e) {
      print('카메라 초기화 오류: $e');
      _showSnackBar('카메라 초기화에 실패했습니다');
    }
  }

  // === 스마트 이미지 전처리 (형태 보존 우선) ===
  Future<Uint8List> _preprocessImage(Uint8List imageBytes) async {
    print('🎯 스마트 이미지 전처리 시작...');

    try {
      img.Image? image = img.decodeImage(imageBytes);
      if (image == null) throw Exception('이미지 디코딩 실패');

      print('원본 크기: ${image.width}x${image.height}');

      // 1. 크기 조정만 (형태 보존을 위해 크롭 최소화)
      const maxImageSize = 1024.0;
      if (image.width > maxImageSize || image.height > maxImageSize) {
        double scale = maxImageSize / math.max(image.width, image.height);
        int newWidth = (image.width * scale).round();
        int newHeight = (image.height * scale).round();
        image = img.copyResize(image, width: newWidth, height: newHeight);
        print('리사이즈 완료: ${image.width}x${image.height}');
      }

      // 2. 가벼운 크롭만 (0.95로 거의 자르지 않음)
      image = _centerCrop(image, 0.95);
      print('중심 크롭 완료: ${image.width}x${image.height}');

      // 3. 조명 정규화 (약하게)
      image = img.adjustColor(image,
        brightness: 0.05,  // 더 약하게
        contrast: 1.1,     // 더 약하게
      );
      print('조명 정규화 완료');

      // 4. 배경 간소화 제거 (형태 보존을 위해)
      // _simplifyBackground 함수 호출 제거

      final processedBytes = Uint8List.fromList(
          img.encodeJpg(image, quality: 90)  // 품질 향상
      );

      print('✅ 전처리 완료: ${processedBytes.length} bytes');
      return processedBytes;

    } catch (e) {
      print('❌ 이미지 전처리 실패: $e');
      rethrow;
    }
  }

  img.Image _centerCrop(img.Image image, double ratio) {
    int newWidth = (image.width * ratio).round();
    int newHeight = (image.height * ratio).round();
    int startX = (image.width - newWidth) ~/ 2;
    int startY = (image.height - newHeight) ~/ 2;

    return img.copyCrop(image,
        x: startX,
        y: startY,
        width: newWidth,
        height: newHeight
    );
  }

  img.Image _normalizeImage(img.Image image) {
    image = img.adjustColor(image,
      brightness: 0.1,
      contrast: 1.2,
    );
    return image;
  }

  img.Image _applyEdgeFade(img.Image image, int fadeWidth) {
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        int distanceFromEdge = math.min(
            math.min(x, image.width - x),
            math.min(y, image.height - y)
        );

        if (distanceFromEdge < fadeWidth) {
          double fadeRatio = distanceFromEdge / fadeWidth;
          var pixel = image.getPixel(x, y);

          int originalR = pixel.r.toInt();
          int originalG = pixel.g.toInt();
          int originalB = pixel.b.toInt();

          int r = (originalR * fadeRatio + 255 * (1 - fadeRatio)).round();
          int g = (originalG * fadeRatio + 255 * (1 - fadeRatio)).round();
          int b = (originalB * fadeRatio + 255 * (1 - fadeRatio)).round();

          image.setPixel(x, y, img.ColorRgb8(r, g, b));
        }
      }
    }
    return image;
  }

  img.Image _simplifyBackground(img.Image image) {
    int centerX = image.width ~/ 2;
    int centerY = image.height ~/ 2;
    int radius = math.min(image.width, image.height) ~/ 3;

    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        double distance = math.sqrt(
            math.pow(x - centerX, 2) + math.pow(y - centerY, 2)
        );

        if (distance > radius) {
          var pixel = image.getPixel(x, y);

          int originalR = pixel.r.toInt();
          int originalG = pixel.g.toInt();
          int originalB = pixel.b.toInt();

          int gray = ((originalR + originalG + originalB) / 3).round();

          int r = (originalR * 0.3 + gray * 0.7).round();
          int g = (originalG * 0.3 + gray * 0.7).round();
          int b = (originalB * 0.3 + gray * 0.7).round();

          image.setPixel(x, y, img.ColorRgb8(r, g, b));
        }
      }
    }
    return image;
  }

  // === 6가지 분리수거 분류 로직 (수정됨) ===
  Map<String, dynamic> _classifyRecyclable(Map<String, dynamic> serverResponse) {
    final detectedClass = serverResponse['class'] ?? 'unknown';
    final confidence = serverResponse['confidence'] ?? 0.0;

    Map<String, String> recyclingGuide = {
      'can': '🥤 캔류',
      'glass': '🍺 유리류',
      'paper': '📄 종이류',
      'plastic': '🧴 플라스틱류',
      'styrofoam': '📦 스티로폼',
      'vinyl': '🛍️ 비닐류',
    };

    Map<String, String> disposalMethod = {
      'can': '캔류 재활용함에 분리배출\n※ 내용물 완전히 비운 후',
      'glass': '유리병 전용 수거함에 분리배출\n※ 뚜껑, 라벨 제거 후',
      'paper': '종이 재활용함에 분리배출\n※ 라벨, 테이프 제거 후',
      'plastic': '플라스틱 재활용함에 분리배출\n※ 라벨 제거, 깨끗이 세척 후',
      'styrofoam': '스티로폼 전용 수거함에 분리배출\n※ 이물질 제거 후',
      'vinyl': '비닐류 전용 수거함에 분리배출\n※ 깨끗이 세척 후',
    };

    Map<String, Color> categoryColors = {
      'can': const Color(0xFFFF9800),
      'glass': const Color(0xFF4CAF50),
      'paper': const Color(0xFF2196F3),
      'plastic': const Color(0xFF9C27B0),
      'styrofoam': const Color(0xFFE91E63),
      'vinyl': const Color(0xFF607D8B),
    };

    return {
      'originalClass': detectedClass,
      'recyclingCategory': recyclingGuide[detectedClass] ?? '❓ 기타',
      'disposalMethod': disposalMethod[detectedClass] ?? '일반쓰레기로 배출',
      'categoryColor': categoryColors[detectedClass] ?? Colors.grey,
      'confidence': confidence,
      'isRecyclable': recyclingGuide.containsKey(detectedClass),
      'additionalTips': _getAdditionalTips(detectedClass),
    };
  }

  List<String> _getAdditionalTips(String classType) {
    switch (classType) {
      case 'can':
        return [
          '🥤 음료캔: 내용물 완전히 비우기',
          '🍅 통조림: 라벨 제거, 깨끗이 세척',
          '🍺 맥주캔: 뚜껑도 함께 재활용 가능',
        ];
      case 'glass':
        return [
          '🍺 맥주병: 뚜껑(금속)과 라벨(종이) 분리',
          '🍷 와인병: 코르크마개와 라벨 제거',
          '🥛 유리병: 깨끗이 세척 후 배출',
        ];
      case 'paper':
        return [
          '📄 일반 종이: 스테이플러 침 제거',
          '📋 코팅지: 일반쓰레기로 배출',
          '📦 택배상자: 테이프, 라벨 모두 제거',
        ];
      case 'plastic':
        return [
          '🧴 플라스틱병: PET 마크 확인',
          '🥤 일회용컵: 플라스틱 재질만 재활용',
          '🛍️ 포장재: 깨끗이 세척 후 배출',
        ];
      case 'styrofoam':
        return [
          '📦 포장재: 테이프, 라벨 제거',
          '🥡 음식 용기: 깨끗이 세척 필수',
          '⚠️ 오염된 것은 일반쓰레기',
        ];
      case 'vinyl':
        return [
          '🛍️ 비닐봉지: 깨끗한 것만 재활용',
          '📦 포장 비닐: 테이프 제거 후',
          '⚠️ 오염된 것은 일반쓰레기',
        ];
      default:
        return ['분류가 어려운 경우 관할 구청에 문의하세요'];
    }
  }

  // === 스마트 촬영 및 처리 ===
  Future<void> _captureAndProcessSmart() async {
    if (!_controller.value.isInitialized || _isCapturing) return;

    setState(() {
      _isCapturing = true;
      _processingStatus = '📸 사진 촬영 중...';
      _processingProgress = 0.1;
    });

    try {
      setState(() {
        _showFlash = true;
      });

      SystemSound.play(SystemSoundType.click);
      HapticFeedback.mediumImpact();

      final XFile image = await _controller.takePicture();
      final imageBytes = await image.readAsBytes();

      await Future.delayed(const Duration(milliseconds: 100));
      setState(() {
        _showFlash = false;
        _processingStatus = '🎯 스마트 전처리 중...';
        _processingProgress = 0.2;
      });

      final processedBytes = await _preprocessImage(imageBytes);

      setState(() {
        _processingStatus = '🤖 AI 분석 중...';
        _processingProgress = 0.5;
      });

      await _sendToServerSmart(processedBytes);

    } catch (e) {
      print('스마트 처리 오류: $e');
      _showDetailedError('스마트 처리', e);
      setState(() {
        _isCapturing = false;
        _isProcessing = false;
        _showFlash = false;
      });
    }
  }

  // === 수정된 서버 통신 함수 ===
  Future<void> _sendToServerSmart(Uint8List imageBytes) async {
    setState(() {
      _isProcessing = true;
      _processingProgress = 0.6;
    });

    _startProgressAnimation();

    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        print("🔄 === 시도 $attempt/3 시작 ===");
        print("📡 서버 URL: https://ml-dl-portfolio.onrender.com/predict");
        print("📤 이미지 크기: ${imageBytes.length} bytes");

        print("🌐 네트워크 연결 테스트 중...");

        final request = http.MultipartRequest(
          'POST',
          Uri.parse("https://ml-dl-portfolio.onrender.com/predict"),
        );

        request.headers.addAll({
          'Accept': 'application/json',
          'User-Agent': 'SmartRecycling-Flutter/1.0',
        });

        request.files.add(
          http.MultipartFile.fromBytes(
            "file",
            imageBytes,
            filename: "image.jpg",
            contentType: MediaType('image', 'jpeg'),
          ),
        );

        setState(() {
          _processingStatus = '☁️ 서버 전송 중... ($attempt/3)';
          _processingProgress = 0.7;
        });

        print("📡 HTTP 요청 전송 시작...");
        print("🎯 Content-Type: image/jpeg 설정!");
        print("🕐 타임아웃: 60초");

        final response = await request.send().timeout(
          const Duration(seconds: 60),
          onTimeout: () {
            print("⏰ 타임아웃 발생!");
            throw TimeoutException("서버 응답 시간 초과", const Duration(seconds: 60));
          },
        );

        print("📨 응답 수신! 상태코드: ${response.statusCode}");
        print("📋 응답 헤더: ${response.headers}");

        final responseBody = await response.stream.bytesToString();
        print("📄 응답 길이: ${responseBody.length} characters");
        print("📄 응답 내용 (첫 500자): ${responseBody.length > 500 ? responseBody.substring(0, 500) + '...' : responseBody}");

        if (response.statusCode != 200) {
          print("❌ HTTP 에러: ${response.statusCode}");
          print("❌ 에러 내용: $responseBody");
          throw Exception('HTTP ${response.statusCode}: $responseBody');
        }

        print("🔍 JSON 파싱 시도...");
        final decoded = json.decode(responseBody);
        print("✅ JSON 파싱 성공!");
        print("📊 서버 응답 구조: ${decoded.keys}");

        if (decoded["status"] == "success") {
          print("🎉 성공 응답 확인!");
          print("🔍 감지된 클래스: ${decoded['class']}");
          print("🔍 신뢰도: ${decoded['confidence']}");

          final classificationResult = _classifyRecyclable({
            'class': decoded['class'] ?? 'unknown',
            'confidence': decoded['confidence'] ?? 0.0,
          });

          setState(() {
            _processingStatus = '🎨 결과 생성 중...';
            _processingProgress = 0.9;
          });

          print("🖼️ Base64 이미지 디코딩 시작...");
          final overlayBytes = base64Decode(decoded["overlay"]);
          final predictBytes = base64Decode(decoded["prediction"]);
          print("🖼️ 디코딩 완료 - Overlay: ${overlayBytes.length}bytes, Predict: ${predictBytes.length}bytes");

          await _loadResultImages(overlayBytes, predictBytes);

          setState(() {
            _processingStatus = '✅ 완료!';
            _processingProgress = 1.0;
            _currentState = AppPageState.result;
          });

          print("🎉 === 전체 처리 완료! ===");
          return;
        } else {
          print("❌ 서버 응답 상태가 success가 아님: ${decoded['status']}");
          throw Exception('서버 응답 오류: ${decoded["status"] ?? "알 수 없는 오류"}');
        }

      } catch (e) {
        print('❌ === 시도 $attempt 실패 ===');
        print('❌ 에러 타입: ${e.runtimeType}');
        print('❌ 에러 메시지: $e');

        if (e.toString().contains('SocketException')) {
          print('🔌 네트워크 연결 문제 - 인터넷 연결을 확인하세요');
        } else if (e.toString().contains('TimeoutException')) {
          print('⏰ 연결 시간 초과 - 서버가 응답하지 않습니다');
        } else if (e.toString().contains('HandshakeException')) {
          print('🔒 SSL/TLS 핸드셰이크 문제');
        } else if (e.toString().contains('FormatException')) {
          print('📄 JSON 파싱 오류 - 서버 응답이 올바르지 않습니다');
        }

        if (attempt == 3) {
          print('💥 === 최종 실패: 모든 재시도 완료 ===');
          _showDetailedNetworkError(e);
          break;
        } else {
          print('⏳ 2초 대기 후 재시도...');
          await Future.delayed(const Duration(seconds: 2));
          setState(() {
            _processingStatus = '🔄 재시도 중... (${attempt + 1}/3)';
          });
        }
      }
    }

    _progressTimer?.cancel();
    setState(() {
      _isProcessing = false;
      _isCapturing = false;
      _processingProgress = 0.0;
      _processingStatus = null;
    });
  }

  void _showDetailedNetworkError(dynamic error) {
    String title = "네트워크 오류";
    String message = "서버 연결에 실패했습니다.";
    String suggestion = "";

    if (error.toString().contains('SocketException')) {
      title = "인터넷 연결 오류";
      message = "인터넷 연결을 확인해주세요.";
      suggestion = "• WiFi 또는 모바일 데이터 확인\n• 네트워크 권한 확인\n• 방화벽 설정 확인";
    } else if (error.toString().contains('TimeoutException')) {
      title = "서버 응답 지연";
      message = "서버가 응답하지 않습니다.";
      suggestion = "• 잠시 후 재시도\n• 서버 상태 확인\n• 네트워크 속도 확인";
    } else if (error.toString().contains('HandshakeException')) {
      title = "보안 연결 오류";
      message = "HTTPS 연결에 실패했습니다.";
      suggestion = "• 앱 재시작\n• 기기 시간 설정 확인\n• 인증서 문제일 수 있음";
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Row(
          children: [
            const Icon(Icons.wifi_off, color: Colors.red),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(color: Colors.white, fontFamily: 'Pretendard')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: const TextStyle(color: Colors.white70, fontSize: 16, fontFamily: 'Pretendard'),
            ),
            if (suggestion.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                "해결 방법:",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'Pretendard'),
              ),
              const SizedBox(height: 8),
              Text(
                suggestion,
                style: const TextStyle(color: Colors.white70, fontSize: 14, fontFamily: 'Pretendard'),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _currentState = AppPageState.camera;
              });
            },
            child: const Text('다시 촬영', style: TextStyle(color: Colors.grey, fontFamily: 'Pretendard')),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _captureAndProcessSmart();
            },
            child: const Text('재시도', style: TextStyle(color: Color(0xFF4CAF50), fontFamily: 'Pretendard')),
          ),
        ],
      ),
    );
  }

  void _startProgressAnimation() {
    _progressTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!_isProcessing) {
        timer.cancel();
        return;
      }

      setState(() {
        _processingProgress += 0.05;
        if (_processingProgress >= 0.95) {
          _processingProgress = 0.95;
        }
      });
    });
  }

  Future<void> _loadResultImages(Uint8List overlayBytes, Uint8List predictBytes) async {
    final overlayCodec = await ui.instantiateImageCodec(overlayBytes);
    final predictCodec = await ui.instantiateImageCodec(predictBytes);

    final overlayFrame = await overlayCodec.getNextFrame();
    final predictFrame = await predictCodec.getNextFrame();

    setState(() {
      _overlayImage = overlayFrame.image;
      _predictImage = predictFrame.image;
      _showOverlay = true;
      _processingProgress = 1.0;
    });
  }

  // === 기존 호환성 함수들 ===
  void _onPanStart(DragStartDetails details) {}
  void _onPanUpdate(DragUpdateDetails details) {}
  void _onPanEnd(DragEndDetails details) {}
  Future<void> _capturePhoto() async => await _captureAndProcessSmart();
  Future<void> _processSelectedArea() async {}
  Rect _calculateCropRect() => const Rect.fromLTWH(0, 0, 100, 100);
  Future<Uint8List> _cropImage(Uint8List bytes, Rect cropRect) async => bytes;
  Future<void> _sendToServer(Uint8List imageBytes) async => await _sendToServerSmart(imageBytes);

  // === UI 헬퍼 메서드 ===
  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontFamily: 'Pretendard')),
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.black.withOpacity(0.8),
      ),
    );
  }

  void _showDetailedError(String context, dynamic error) {
    final errorMessage = error.toString();
    print("[$context] 오류: $errorMessage");

    String userMessage = "오류가 발생했습니다";

    if (errorMessage.contains("network") || errorMessage.contains("connection")) {
      userMessage = "네트워크 연결을 확인해주세요";
    } else if (errorMessage.contains("permission")) {
      userMessage = "권한을 확인해주세요";
    } else if (errorMessage.contains("image") || errorMessage.contains("crop")) {
      userMessage = "이미지 처리 중 오류가 발생했습니다";
    } else if (errorMessage.contains("server") || errorMessage.contains("500")) {
      userMessage = "서버 오류가 발생했습니다. 잠시 후 다시 시도해주세요";
    }

    _showSnackBar(userMessage);
  }

  void _showRetryDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Row(
          children: [
            Icon(Icons.cloud_off, color: Colors.orange),
            SizedBox(width: 8),
            Text('서버 연결 실패', style: TextStyle(color: Colors.white, fontFamily: 'Pretendard')),
          ],
        ),
        content: const Text(
          '서버가 일시적으로 응답하지 않습니다.\n잠시 후 다시 시도해주세요.',
          style: TextStyle(color: Colors.white70, fontFamily: 'Pretendard'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _currentState = AppPageState.camera;
              });
            },
            child: const Text('다시 촬영', style: TextStyle(color: Colors.grey, fontFamily: 'Pretendard')),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _captureAndProcessSmart();
            },
            child: const Text('재시도', style: TextStyle(color: Color(0xFF4CAF50), fontFamily: 'Pretendard')),
          ),
        ],
      ),
    );
  }

  // === UI 빌드 메서드들 ===
  @override
  Widget build(BuildContext context) {
    switch (_currentState) {
      case AppPageState.main:
        return _buildMainPage();
      case AppPageState.guide:
        return _buildGuidePage();
      case AppPageState.camera:
        return _buildCameraPage();
      case AppPageState.result:
        return _buildResultPage();
    }
  }

  // 1. 메인페이지 중앙 정렬 수정
  Widget _buildMainPage() {
    return Scaffold(
      backgroundColor: const Color(0xFF4CAF50),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(60),
                ),
                child: const Icon(
                  Icons.recycling,
                  size: 80,
                  color: Color(0xFF4CAF50),
                ),
              ),
              const SizedBox(height: 60),
              SizedBox(
                width: MediaQuery.of(context).size.width - 60,
                height: 60,
                child: ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _currentState = AppPageState.guide;
                      _guideStep = 0;
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF4CAF50),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  child: const Text(
                    'START',
                    style: TextStyle(
                      fontFamily: 'Pretendard',
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 1. 가이드 페이지 - 상자 위로 올리고 화살표 추가
  Widget _buildGuidePage() {
    final guides = [
      '재활용품을 촬영해주세요',
      '라벨이나 뚜껑은 분리 후\n각각 재활용하세요',
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF4CAF50),
      body: SafeArea(
        child: Column(
          children: [
            // 뒤로가기 버튼
            Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: IconButton(
                  onPressed: () {
                    setState(() {
                      _currentState = AppPageState.main;
                    });
                  },
                  icon: const Icon(
                    Icons.arrow_back_ios,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
            ),

            // 상자들을 위로 올리기 - 뒤로가기 버튼과 가까이
            const SizedBox(height: 20), // 뒤로가기 버튼과의 간격 줄임

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                children: [
                  // 가이드 항목들과 화살표
                  for (int i = 0; i < guides.length; i++) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(25),
                      ),
                      child: Text(
                        guides[i],
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: 'Pretendard',
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF4CAF50),
                        ),
                      ),
                    ),
                    // 화살표 추가 (항상 추가)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 20),
                      child: Icon(
                        Icons.keyboard_arrow_down,
                        color: Colors.white,
                        size: 30,
                      ),
                    ),
                  ],

                  const SizedBox(height: 20), // 버튼과의 간격 줄임

                  // Take A Photo 버튼
                  SizedBox(
                    width: MediaQuery.of(context).size.width - 40,
                    height: 70,
                    child: ElevatedButton(
                      onPressed: () {
                        _requestCameraPermission();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xFF4CAF50),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(35),
                        ),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.camera_alt, size: 24, color: Color(0xFF4CAF50)),
                          SizedBox(width: 12),
                          Text(
                            'Take A Photo',
                            style: TextStyle(
                              fontFamily: 'Pretendard',
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                              color: Color(0xFF4CAF50),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraPage() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: !_hasPermission
          ? const Center(child: CircularProgressIndicator())
          : !_isCameraReady
          ? const Center(child: CircularProgressIndicator())
          : _buildCameraView(),
    );
  }

  Widget _buildCameraView() {
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: MediaQuery.of(context).size.height * 0.8,
          child: ClipRect(
            child: CameraPreview(_controller),
          ),
        ),

        // 플래시 효과 오버레이
        if (_showFlash)
          Positioned.fill(
            child: Container(
              color: Colors.white.withOpacity(0.8),
            ),
          ),

        // 2. 처리 중 오버레이 - 자막 없애고 게이지바만
        if (_isProcessing || _isCapturing)
          Positioned.fill(
            child: Container(
              color: Colors.black.withOpacity(0.8),
              child: Center(
                child: Container(
                  margin: const EdgeInsets.all(40),
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 200,
                        child: LinearProgressIndicator(
                          value: _processingProgress,
                          backgroundColor: Colors.grey[700],
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${(_processingProgress * 100).round()}%',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          fontFamily: 'Pretendard',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

        // 하단 촬영 영역
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: MediaQuery.of(context).size.height * 0.2,
          child: Container(
            color: Colors.black,
            child: Center(
              child: GestureDetector(
                onTapDown: (_) => HapticFeedback.lightImpact(),
                onTap: _isProcessing || _isCapturing ? null : _captureAndProcessSmart,
                child: AnimatedContainer(
                  duration: Duration(milliseconds: _isCapturing ? 200 : 100),
                  width: _isCapturing ? 60 : 70,
                  height: _isCapturing ? 60 : 70,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isCapturing ? Colors.grey[300] : Colors.white,
                    border: Border.all(
                      color: Colors.grey[400]!,
                      width: _isCapturing ? 2 : 3,
                    ),
                    boxShadow: _isCapturing ? [] : [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: _isCapturing
                      ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.grey),
                    ),
                  )
                      : const Icon(
                    Icons.camera_alt,
                    color: Colors.grey,
                    size: 30,
                  ),
                ),
              ),
            ),
          ),
        ),

        // 뒤로가기 버튼
        Positioned(
          top: 50,
          left: 20,
          child: IconButton(
            onPressed: () {
              setState(() {
                _currentState = AppPageState.guide;
              });
            },
            icon: const Icon(
              Icons.arrow_back_ios,
              color: Colors.white,
              size: 24,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResultPage() {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    return Scaffold(
      backgroundColor: Colors.black,
      body: isLandscape ? _buildLandscapeResult() : _buildPortraitResult(),
    );
  }

  // 3. 가로모드에서 반반 화면 분할 (경계선 없음)
  Widget _buildLandscapeResult() {
    return Row(
      children: [
        // Overlay 이미지 (왼쪽 절반)
        Expanded(
          child: Container(
            color: Colors.black,
            child: Stack(
              children: [
                Center(
                  child: _overlayImage != null
                      ? RawImage(
                    image: _overlayImage!,
                    fit: BoxFit.contain,
                  )
                      : const Text(
                    'Overlay',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontFamily: 'Pretendard',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                // 뒤로가기 버튼 (왼쪽 상단)
                Positioned(
                  top: 50,
                  left: 20,
                  child: IconButton(
                    onPressed: () async {
                      // 모든 처리 상태 초기화
                      setState(() {
                        _isProcessing = false;
                        _isCapturing = false;
                        _processingProgress = 0.0;
                        _processingStatus = null;
                        _showFlash = false;
                      });

                      // 타이머 정리
                      _progressTimer?.cancel();

                      // 카메라를 다시 초기화하고 카메라 화면으로 이동
                      if (_isCameraReady) {
                        await _controller.dispose();
                      }
                      _controller = CameraController(
                        widget.cameras.first,
                        ResolutionPreset.high,
                        enableAudio: false,
                      );
                      await _controller.initialize();
                      if (mounted) {
                        setState(() {
                          _isCameraReady = true;
                          _currentState = AppPageState.camera;
                        });
                      }
                    },
                    icon: const Icon(
                      Icons.arrow_back_ios,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Predict 이미지 (오른쪽 절반) - 경계선 제거됨
        Expanded(
          child: Container(
            color: Colors.black,
            child: Center(
              child: _predictImage != null
                  ? RawImage(
                image: _predictImage!,
                fit: BoxFit.contain,
              )
                  : const Text(
                'Predict',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontFamily: 'Pretendard',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPortraitResult() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 60,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 20),
              child: IconButton(
                onPressed: () async {
                  // 모든 처리 상태 초기화
                  setState(() {
                    _isProcessing = false;
                    _isCapturing = false;
                    _processingProgress = 0.0;
                    _processingStatus = null;
                    _showFlash = false;
                  });

                  // 타이머 정리
                  _progressTimer?.cancel();

                  // 카메라를 다시 초기화하고 카메라 화면으로 이동
                  if (_isCameraReady) {
                    await _controller.dispose();
                  }
                  _controller = CameraController(
                    widget.cameras.first,
                    ResolutionPreset.high,
                    enableAudio: false,
                  );
                  await _controller.initialize();
                  if (mounted) {
                    setState(() {
                      _isCameraReady = true;
                      _currentState = AppPageState.camera;
                    });
                  }
                },
                icon: const Icon(
                  Icons.arrow_back_ios,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
            Expanded(
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 10),
                child: _showOverlay && _overlayImage != null
                    ? RawImage(
                  image: _overlayImage!,
                  fit: BoxFit.contain,
                  width: double.infinity,
                )
                    : _predictImage != null
                    ? RawImage(
                  image: _predictImage!,
                  fit: BoxFit.contain,
                  width: double.infinity,
                )
                    : Container(),
              ),
            ),
            Container(
              height: 100,
              width: double.infinity,
              color: Colors.black,
              child: Center(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(25),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () => setState(() => _showOverlay = true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          decoration: BoxDecoration(
                            color: _showOverlay ? Colors.white : Colors.transparent,
                            borderRadius: BorderRadius.circular(25),
                          ),
                          child: Text(
                            'Overlay',
                            style: TextStyle(
                              color: _showOverlay ? const Color(0xFF4CAF50) : Colors.white,
                              fontSize: 16,
                              fontFamily: 'Pretendard',
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => setState(() => _showOverlay = false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          decoration: BoxDecoration(
                            color: !_showOverlay ? Colors.white : Colors.transparent,
                            borderRadius: BorderRadius.circular(25),
                          ),
                          child: Text(
                            'Predict',
                            style: TextStyle(
                              color: !_showOverlay ? const Color(0xFF4CAF50) : Colors.white,
                              fontSize: 16,
                              fontFamily: 'Pretendard',
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}