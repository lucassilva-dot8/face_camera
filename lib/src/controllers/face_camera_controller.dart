import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';

import '../../face_camera.dart';
import '../handlers/enum_handler.dart';
import '../handlers/face_identifier.dart';
import '../utils/logger.dart';
import 'face_camera_state.dart';

/// The controller for the [SmartFaceCamera] widget.
class FaceCameraController extends ValueNotifier<FaceCameraState> {
  /// Construct a new [FaceCameraController] instance.
  FaceCameraController({
    this.imageResolution = ImageResolution.medium,
    this.defaultCameraLens,
    this.defaultFlashMode = CameraFlashMode.auto,
    this.enableAudio = true,
    this.autoCapture = false,
    this.ignoreFacePositioning = false,
    this.orientation = CameraOrientation.portraitUp,
    this.performanceMode = FaceDetectorMode.fast,
    required this.onCapture,
    this.onFaceDetected,
  }) : super(FaceCameraState.uninitialized());

  /// The desired resolution for the camera.
  final ImageResolution imageResolution;

  /// Use this to set initial camera lens direction.
  final CameraLens? defaultCameraLens;

  /// Use this to set initial flash mode.
  final CameraFlashMode defaultFlashMode;

  /// Set false to disable capture sound.
  final bool enableAudio;

  /// Set true to capture image on face detected.
  final bool autoCapture;

  /// Set true to trigger onCapture even when the face is not well positioned
  final bool ignoreFacePositioning;

  /// Use this to lock camera orientation.
  final CameraOrientation? orientation;

  /// Use this to set your preferred performance mode.
  final FaceDetectorMode performanceMode;

  /// Callback invoked when camera captures image.
  final void Function(File? image) onCapture;

  /// Callback invoked when camera detects face.
  final void Function(Face? face)? onFaceDetected;

  // PATCH DOT8: o controller precisa saber que foi descartado.
  //
  // `initialize()` é assíncrono e era disparado sem await pelo initState do
  // SmartFaceCamera. Fechando a tela no meio da inicialização, o
  // `startImageStream()` do final de `_initCamera` subia o pipeline de detecção
  // com o widget já destruído, e a câmera ficava aberta indefinidamente.
  bool _isDisposed = false;

  /// Whether [dispose] has already been called.
  bool get isDisposed => _isDisposed;

  @override
  set value(FaceCameraState newValue) {
    if (_isDisposed) return;
    super.value = newValue;
  }

  /// Gets all available camera lens and set current len
  void _getAllAvailableCameraLens() {
    int currentCameraLens = 0;
    final List<CameraLens> availableCameraLens = [];
    for (CameraDescription d in FaceCamera.cameras) {
      final lens = EnumHandler.cameraLensDirectionToCameraLens(d.lensDirection);
      if (lens != null && !availableCameraLens.contains(lens)) {
        availableCameraLens.add(lens);
      }
    }

    if (defaultCameraLens != null) {
      try {
        currentCameraLens = availableCameraLens.indexOf(defaultCameraLens!);
      } catch (e) {
        logError(e.toString());
      }
    }

    value = value.copyWith(
        availableCameraLens: availableCameraLens,
        currentCameraLens: currentCameraLens);
  }

  Future<void> _initCamera() async {
    if (_isDisposed || value.availableCameraLens.isEmpty) return;

    final cameras = FaceCamera.cameras
        .where((c) =>
            c.lensDirection ==
            EnumHandler.cameraLensToCameraLensDirection(
                value.availableCameraLens[value.currentCameraLens]))
        .toList();

    if (cameras.isEmpty) return;

    // PATCH DOT8: libera a câmera anterior. `changeCameraLens()` chamava este
    // método sem descartar o controller antigo, abrindo uma segunda sessão.
    final previous = value.cameraController;
    if (previous != null) {
      value = value.copyWith(isInitialized: false);
      await previous.dispose();
    }

    final cameraController = CameraController(cameras.first,
        EnumHandler.imageResolutionToResolutionPreset(imageResolution),
        enableAudio: enableAudio,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888);

    try {
      await cameraController.initialize();
    } on CameraException catch (e) {
      _showCameraException(e);
      await cameraController.dispose();
      return;
    }

    // PATCH DOT8: a tela pode ter sido fechada enquanto a câmera inicializava.
    if (_isDisposed) {
      await cameraController.dispose();
      return;
    }

    value =
        value.copyWith(isInitialized: true, cameraController: cameraController);

    await changeFlashMode(value.availableFlashMode.indexOf(defaultFlashMode));

    if (_isDisposed) return;

    await cameraController.lockCaptureOrientation(
        EnumHandler.cameraOrientationToDeviceOrientation(orientation));

    await startImageStream();
  }

  Future<void> changeFlashMode([int? index]) async {
    final cameraController = value.cameraController;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    final newIndex =
        index ?? (value.currentFlashMode + 1) % value.availableFlashMode.length;
    await cameraController
        .setFlashMode(EnumHandler.cameraFlashModeToFlashMode(
            value.availableFlashMode[newIndex]))
        .then((_) {
      value = value.copyWith(currentFlashMode: newIndex);
    });
  }

  /// The supplied [zoom] value should be between 1.0 and the maximum supported
  Future<void> setZoomLevel(double zoom) async {
    final CameraController? cameraController = value.cameraController;
    if (cameraController == null) {
      return;
    }
    await cameraController.setZoomLevel(zoom);
  }

  Future<void> changeCameraLens() async {
    if (_isDisposed || value.availableCameraLens.isEmpty) return;
    value = value.copyWith(
        currentCameraLens:
            (value.currentCameraLens + 1) % value.availableCameraLens.length);
    await _initCamera();
  }

  Future<XFile?> takePicture() async {
    final CameraController? cameraController = value.cameraController;
    if (cameraController == null || !cameraController.value.isInitialized) {
      logError('Error: select a camera first.');
      return null;
    }

    if (cameraController.value.isTakingPicture) {
      logError('A capture is already pending');
      return null;
    }

    try {
      XFile file = await cameraController.takePicture();
      return file;
    } on CameraException catch (e) {
      _showCameraException(e);
      return null;
    }
  }

  void _showCameraException(CameraException e) {
    logError(e.code, e.description);
  }

  Future<void> startImageStream() async {
    // PATCH DOT8: nunca religar o stream depois do dispose.
    if (_isDisposed) return;

    final CameraController? cameraController = value.cameraController;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }
    if (!cameraController.value.isStreamingImages) {
      await cameraController.startImageStream(_processImage);
    }
  }

  Future<void> stopImageStream() async {
    final CameraController? cameraController = value.cameraController;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }
    if (cameraController.value.isStreamingImages) {
      await cameraController.stopImageStream();
    }
  }

  void _processImage(CameraImage cameraImage) async {
    // PATCH DOT8: frames que já estavam na fila não devem alimentar o detector
    // depois que a tela foi fechada.
    if (_isDisposed) return;

    final CameraController? cameraController = value.cameraController;
    if (!value.alreadyCheckingImage) {
      value = value.copyWith(alreadyCheckingImage: true);
      try {
        await FaceIdentifier.scanImage(
                cameraImage: cameraImage,
                controller: cameraController,
                performanceMode: performanceMode)
            .then((result) async {
          value = value.copyWith(detectedFace: result);

          if (result != null) {
            try {
              if (result.face != null) {
                onFaceDetected?.call(result.face);
              }
              if (autoCapture &&
                  (result.wellPositioned || ignoreFacePositioning)) {
                captureImage();
              }
            } catch (e) {
              logError(e.toString());
            }
          }
        });
        value = value.copyWith(alreadyCheckingImage: false);
      } catch (ex, stack) {
        value = value.copyWith(alreadyCheckingImage: false);
        logError('$ex, $stack');
      }
    }
  }

  @Deprecated('Use [captureImage]')
  void onTakePictureButtonPressed() async {
    captureImage();
  }

  void captureImage() async {
    final CameraController? cameraController = value.cameraController;
    if (cameraController == null || !cameraController.value.isInitialized) {
      logError('Error: select a camera first.');
      return;
    }

    try {
      if (cameraController.value.isStreamingImages) {
        await cameraController.stopImageStream();
      }
      await Future.delayed(const Duration(milliseconds: 500));

      // PATCH DOT8: a tela pode ter sido fechada durante a espera.
      if (_isDisposed) return;

      final XFile? file = await takePicture();

      /// Return image callback
      if (file != null) {
        onCapture.call(File(file.path));
      }
    } catch (e) {
      logError(e.toString());
    }
  }

/*  void onViewFinderTap(TapDownDetails details, BoxConstraints constraints) {
    if (value.cameraController == null) {
      return;
    }

    final CameraController cameraController = value.cameraController!;

    final offset = Offset(
      details.localPosition.dx / constraints.maxWidth,
      details.localPosition.dy / constraints.maxHeight,
    );
    cameraController.setExposurePoint(offset);
    cameraController.setFocusPoint(offset);
  }*/

  /// Initialize the camera and start the face detection pipeline.
  ///
  /// PATCH DOT8: agora aguarda a inicialização, para que quem chama consiga
  /// saber quando a câmera está de fato pronta (o original era fire-and-forget).
  Future<void> initialize() async {
    if (_isDisposed) return;
    _getAllAvailableCameraLens();
    await _initCamera();
  }

  /// Enables controls only when camera is initialized.
  bool get enableControls {
    final CameraController? cameraController = value.cameraController;
    return cameraController != null && cameraController.value.isInitialized;
  }

  /// Dispose the controller.
  ///
  /// Once the controller is disposed, it cannot be used anymore.
  ///
  /// PATCH DOT8: o original só descartava o [CameraController] quando ele já
  /// estava inicializado, não aguardava o descarte e deixava o detector do
  /// ML Kit aberto. Sem isso a sessão da câmera continuava listada em
  /// `dumpsys media.camera` mesmo depois de sair da tela.
  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    final CameraController? cameraController = value.cameraController;
    if (cameraController != null) {
      try {
        if (cameraController.value.isStreamingImages) {
          await cameraController.stopImageStream();
        }
      } catch (e) {
        logError(e.toString());
      }
      try {
        await cameraController.dispose();
      } catch (e) {
        logError(e.toString());
      }
    }

    try {
      await FaceIdentifier.close();
    } catch (e) {
      logError(e.toString());
    }
    super.dispose();
  }
}
