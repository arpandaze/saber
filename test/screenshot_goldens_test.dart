import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golden_screenshot/golden_screenshot.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:saber/components/canvas/invert_shader.dart';
import 'package:saber/components/canvas/pencil_shader.dart';
import 'package:saber/components/canvas/shader_image.dart';
import 'package:saber/components/home/banner_ad_widget.dart';
import 'package:saber/components/home/syncing_button.dart';
import 'package:saber/components/settings/app_info.dart';
import 'package:saber/components/settings/nextcloud_profile.dart';
import 'package:saber/components/theming/font_fallbacks.dart';
import 'package:saber/components/theming/yaru_builder.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/locales.dart';
import 'package:saber/data/prefs.dart' hide Quota;
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/home/home.dart';
import 'package:saber/pages/user/login.dart';
import 'package:yaru/yaru.dart';

import 'utils/test_mock_channel_handlers.dart';

void main() {
  group('Screenshots:', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    BackgroundIsolateBinaryMessenger.ensureInitialized(
      ServicesBinding.rootIsolateToken!,
    );

    setupMockPathProvider();
    setupMockPrinting();

    FlavorConfig.setup();
    Prefs.testingMode = true;
    Prefs.init();
    AdState.init();
    SyncingButton.forceButtonActive = true;
    AppInfo.showDebugMessage = false;

    Prefs.username.value = 'myusername';

    const quotaUsed = 17 * 1024 * 1024; // 17 MB
    const quotaTotal = 5 * 1024 * 1024 * 1024; // 5 GB
    Prefs.lastStorageQuota.value = Quota.fromJson({
      'free': quotaTotal - quotaUsed,
      'used': quotaUsed,
      'total': quotaTotal,
      'relative': quotaUsed / quotaTotal * 100,
      'quota': quotaTotal,
    });

    setUpAll(() => Future.wait([
          FileManager.init(),
          InvertShader.init(),
          PencilShader.init(),
          GoogleFonts.pendingFonts([
            GoogleFonts.inter(),
            GoogleFonts.neucha(),
            GoogleFonts.dekko(),
            GoogleFonts.firaMono(),
          ]),
        ]));

    setUpAll(() async {
      final recentFiles = <String>[];
      await Future.wait(Directory('test/demo_notes/')
          .listSync()
          .whereType<File>()
          .map((file) async {
        /// The file name starting with a slash
        final fileName = file.path.substring(file.path.lastIndexOf('/'));
        if (fileName.endsWith('.sbn2') || fileName.endsWith('.sbn')) {
          recentFiles.add(fileName);
        }
        final bytes = await file.readAsBytes();
        return FileManager.getFile(fileName).writeAsBytes(bytes);
      }));
      Prefs.recentFiles.value = recentFiles..sort();
    });

    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xffdae2ff),
      surface: const Color(0xfffefbff),
    );
    final materialTheme = ThemeData(
      colorScheme: colorScheme,
      textTheme: GoogleFonts.interTextTheme().withFallbacks(),
      scaffoldBackgroundColor: colorScheme.surface,
    );
    final yaruVariant = YaruBuilder.findClosestYaruVariant(colorScheme.primary);
    final yaruTheme = YaruThemeData(variant: yaruVariant, useMaterial3: true);

    final homeFrameColors = ScreenshotFrameColors(
      bottomBar: colorScheme.surfaceContainer,
    );

    _screenshot(
      frameColors: homeFrameColors,
      materialTheme: materialTheme,
      yaruTheme: yaruTheme,
      goldenFileName: '1_home',
      child: const HomePage(subpage: HomePage.recentSubpage, path: ''),
    );
    _screenshot(
      materialTheme: materialTheme,
      yaruTheme: yaruTheme,
      goldenFileName: '2_editor',
      child: Editor(
        path: '/Metric Spaces Week 1',
      ),
    );
    _screenshot(
      materialTheme: materialTheme,
      yaruTheme: yaruTheme,
      goldenFileName: '3_login',
      child: const NcLoginPage(
        forceAppBarLeading: true,
      ),
    );
    _screenshot(
      frameColors: homeFrameColors,
      materialTheme: materialTheme,
      yaruTheme: yaruTheme,
      goldenFileName: '4_settings',
      child: const HomePage(subpage: HomePage.settingsSubpage, path: ''),
    );
  });
}

void _screenshot({
  ScreenshotFrameColors? frameColors,
  required ThemeData materialTheme,
  required YaruThemeData yaruTheme,
  required String goldenFileName,
  required Widget child,
}) {
  group(goldenFileName, () {
    for (final localeCode in localeNames.keys) {
      for (final goldenDevice in GoldenScreenshotDevices.values) {
        testWidgets(
          'for ${goldenDevice.name} in $localeCode',
          (tester) async {
            final device = goldenDevice.device;
            LocaleSettings.setLocaleRaw(localeCode);

            debugDisableShadows = false;

            if (goldenFileName == '4_settings') {
              NextcloudProfile.forceLoginStep = LoginStep.done;
              addTearDown(() => NextcloudProfile.forceLoginStep = null);
            }

            final widget = ScreenshotApp(
              theme: switch (device.platform) {
                TargetPlatform.linux => yaruTheme.theme,
                _ => materialTheme,
              },
              device: device,
              frameColors: frameColors,
              child: TranslationProvider(
                child: child,
              ),
            );
            await tester.pumpWidget(widget);

            if (child is Editor) {
              final editorState =
                  tester.state<EditorState>(find.byType(Editor));
              while (editorState.coreInfo.isEmpty) {
                await tester.runAsync(
                    () => Future.delayed(const Duration(milliseconds: 100)));
              }
              await tester.pump();
            }

            await tester.pump();
            await tester.precacheImagesInWidgetTree();
            await tester.precacheShaderImagesInWidgetTree();
            await tester.precacheTopbarImages();
            await tester.loadFonts();
            await tester.pumpFrames(widget, const Duration(milliseconds: 100));

            await tester.expectScreenshot(
              device,
              goldenFileName,
              langCode: switch (localeCode) {
                'en' => 'en-US',
                _ => localeCode,
              },
            );

            debugDisableShadows = true;
          },
          skip: localeCode != 'en' &&
              !const bool.fromEnvironment('localize_screenshots'),
        );
      }
    }
  });
}

extension on WidgetTester {
  Future<void> precacheShaderImagesInWidgetTree({
    bool skipOffstage = true,
  }) async {
    final imageWidgets = widgetList<ShaderImage>(find.byType(
      ShaderImage,
      skipOffstage: skipOffstage,
    ));
    final imageProviders = <ImageProvider>[];
    for (final widget in imageWidgets) {
      var imageProvider = widget.image;

      if (imageProvider is FileImage) {
        final memoryImage = await runAsync(
            () => convertFileImageToMemoryImage(imageProvider as FileImage));
        ShaderImage.imageSubstitutions[imageProvider] = memoryImage!;
        imageProvider = memoryImage;
      }

      imageProviders.add(imageProvider);
    }
    return precacheImages(imageProviders);
  }

  /// Trying to precache FileImages causes the test to hang
  /// for some reason. To work around this, we convert the
  /// FileImage to a MemoryImage and precache that instead.
  static Future<MemoryImage> convertFileImageToMemoryImage(
      FileImage fileImage) async {
    final bytes = await fileImage.file.readAsBytes();
    return MemoryImage(bytes);
  }
}
