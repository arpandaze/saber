import 'package:flutter/material.dart';
import 'package:saber/components/canvas/inner_canvas.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/prefs.dart';

typedef _CacheItem = (EditorCoreInfo coreInfo, double pageHeight);

class CanvasPreview extends StatelessWidget {
  const CanvasPreview({
    super.key,
    this.pageIndex = 0,
    required this.height,
    required this.coreInfo,
  });

  final int pageIndex;
  final double? height;
  final EditorCoreInfo coreInfo;

  static final _previewCache = <String, Future<_CacheItem>>{};
  static Widget fromFile({
    Key? key,
    required String filePath,
  }) {
    final future = _previewCache.putIfAbsent(
      filePath,
      () async {
        final coreInfo = await EditorCoreInfo.loadFromFilePath(filePath);
        final pageHeight = coreInfo.pages.isNotEmpty
            ? coreInfo.pages[0].previewHeight(lineHeight: coreInfo.lineHeight)
            : EditorPage.defaultHeight * 0.1;
        return (coreInfo, pageHeight);
      },
    );

    return FutureBuilder(
      key: key,
      future: future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) return const Icon(Icons.note, size: 48);

        return CanvasPreview(
          key: key,
          coreInfo: data.$1,
          height: data.$2,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final pageSize = coreInfo.pages.isNotEmpty
        ? coreInfo.pages[pageIndex].size
        : EditorPage.defaultSize;
    final widgetSize = Size(pageSize.width, height ?? pageSize.height);

    return InnerCanvas(
      pageIndex: pageIndex,
      width: widgetSize.width,
      height: widgetSize.height,
      isPreview: true,
      coreInfo: coreInfo,
      currentStroke: null,
      currentStrokeDetectedShape: null,
      currentSelection: null,
      hideBackground: Prefs.hideHomeBackgrounds.value,
      currentToolIsSelect: false,
    );
  }
}
