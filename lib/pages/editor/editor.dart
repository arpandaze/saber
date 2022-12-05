
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:keybinder/keybinder.dart';
import 'package:saber/components/canvas/_editor_image.dart';
import 'package:saber/components/canvas/canvas_gesture_detector.dart';
import 'package:saber/components/canvas/canvas_image.dart';
import 'package:saber/components/canvas/tools/_tool.dart';
import 'package:saber/components/canvas/tools/eraser.dart';
import 'package:saber/components/canvas/tools/highlighter.dart';
import 'package:saber/components/canvas/tools/pen.dart';
import 'package:saber/components/canvas/tools/stroke_properties.dart';
import 'package:saber/components/toolbar/editor_bottom_sheet.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_exporter.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/prefs.dart';

import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/toolbar/toolbar.dart';
import 'package:saber/components/canvas/canvas.dart';

class Editor extends StatefulWidget {
  Editor({
    super.key,
    String? path,
    this.embedded = false,
  }) : initialPath = path != null ? Future.value(path) : FileManager.newFilePath("/"),
        needsNaming = path == null;

  final Future<String> initialPath;
  final bool needsNaming;

  final bool embedded;

  static const String extension = '.sbn';
  /// Hidden files used by other functions of the app
  static List<String> reservedFileNames = ["/_whiteboard"];

  @override
  State<Editor> createState() => _EditorState();
}

class _EditorState extends State<Editor> {
  final List<EditorPage> pages = [];

  EditorCoreInfo coreInfo = EditorCoreInfo();

  EditorHistory history = EditorHistory();

  String path = "";
  late bool needsNaming = widget.needsNaming;

  late Tool currentTool = (){
    int? lastPenColor, lastHighlighterColor;
    if (Prefs.lastPenColor.value >= 0) {
      lastPenColor = Prefs.lastPenColor.value;
    }
    if (Prefs.lastHighlighterColor.value >= 0) {
      lastHighlighterColor = Prefs.lastHighlighterColor.value;
    }

    Pen.currentPen = Pen.fountainPen()
      ..strokeProperties.color = Color(lastPenColor ?? StrokeProperties.defaultColor.value);

    Highlighter.currentHighlighter = Highlighter()
      ..strokeProperties.color = Color(lastHighlighterColor ?? Highlighter.defaultColor.value);

    return Pen.currentPen;
  }();

  bool _hasEdited = false;
  Timer? _delayedSaveTimer;

  // used to prevent accidentally drawing when pinch zooming
  int lastSeenPointerCount = 0;
  Timer? _lastSeenPointerCountTimer;

  @override
  void initState() {
    _initAsync();
    _assignKeybindings();

    super.initState();
  }
  void _initAsync() async {
    path = await widget.initialPath;
    filenameTextEditingController.text = _filename;
    setState(() {});

    if (needsNaming) {
      filenameTextEditingController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: filenameTextEditingController.text.length,
      );
    }

    await _initStrokes();
  }
  Future _initStrokes() async {
    coreInfo = await EditorCoreInfo.loadFromFilePath(path);

    if (coreInfo.strokes.isEmpty && coreInfo.images.isEmpty) {
      pages.add(EditorPage());
    } else {
      for (Stroke stroke in coreInfo.strokes) {
        createPageOfStroke(stroke.pageIndex);
      }
      for (EditorImage image in coreInfo.images) {
        createPageOfStroke(image.pageIndex);
        image.onMoveImage = onMoveImage;
        image.onDeleteImage = onDeleteImage;
        image.onMiscChange = autosaveAfterDelay;
      }
    }

    setState(() {});
  }

  Keybinding? _ctrlZ;
  Keybinding? _ctrlY;
  Keybinding? _ctrlShiftZ;
  _assignKeybindings() {
    _ctrlZ = Keybinding([KeyCode.ctrl, KeyCode.from(LogicalKeyboardKey.keyZ)], inclusive: true);
    _ctrlY = Keybinding([KeyCode.ctrl, KeyCode.from(LogicalKeyboardKey.keyY)], inclusive: true);
    _ctrlShiftZ = Keybinding([KeyCode.ctrl, KeyCode.shift, KeyCode.from(LogicalKeyboardKey.keyZ)], inclusive: true);

    Keybinder.bind(_ctrlZ!, undo);
    Keybinder.bind(_ctrlY!, redo);
    Keybinder.bind(_ctrlShiftZ!, redo);
  }
  _removeKeybindings() {
    if (_ctrlZ != null) Keybinder.remove(_ctrlZ!);
    if (_ctrlY != null) Keybinder.remove(_ctrlY!);
    if (_ctrlShiftZ != null) Keybinder.remove(_ctrlShiftZ!);
  }

  void createPageOfStroke([int? pageIndex]) {
    int maxPageIndex;
    if (pageIndex != null) {
      maxPageIndex = pageIndex;
    } else {
      if (coreInfo.strokes.isEmpty) {
        maxPageIndex = 0;
      } else {
        maxPageIndex = coreInfo.strokes.map((e) => e.pageIndex).reduce(max);
      }
    }

    while (maxPageIndex >= pages.length - 1) {
      pages.add(EditorPage());
      coreInfo.pageSizes.add(EditorCoreInfo.defaultPageSize);
    }
  }
  void removeExcessPagesAfterStroke(Stroke? stroke) {
    int minPageIndex = stroke?.pageIndex ?? 0;

    // remove excess pages if all pages >= this one are empty
    for (int i = pages.length - 1; i >= minPageIndex + 1; --i) {
      /// true if this page and the page before it are empty
      final pageEmpty = !coreInfo.strokes.any((stroke) => stroke.pageIndex == i || stroke.pageIndex == i - 1)
          && !coreInfo.images.any((image) => image.pageIndex == i || image.pageIndex == i - 1);
      if (pageEmpty) {
        pages.removeAt(i);
        coreInfo.pageSizes.removeAt(i);
      }
    }
  }

  undo() {
    if (!history.canUndo) return;

    // if we disabled redo, re-enable it
    if (!history.canRedo) {
      // no redo is possible, so clear the redo stack
      history.clearRedo();
      // don't disable redoing anymore
      history.canRedo = true;
    }

    setState(() {
      EditorHistoryItem item = history.undo();
      if (item.type == EditorHistoryItemType.draw) { // undo draw
        for (Stroke stroke in item.strokes) {
          coreInfo.strokes.remove(stroke);
        }
        for (EditorImage image in item.images) {
          coreInfo.images.remove(image);
        }
        removeExcessPagesAfterStroke(null);
      } else if (item.type == EditorHistoryItemType.erase) { // undo erase
        for (Stroke stroke in item.strokes) {
          coreInfo.strokes.add(stroke);
        }
        for (EditorImage image in item.images) {
          coreInfo.images.add(image);
          image.newImage = true;
        }
        createPageOfStroke(null);
      } else if (item.type == EditorHistoryItemType.move) { // undo move
        for (EditorImage image in item.images) {
          image.dstRect = Rect.fromLTRB(
            image.dstRect.left - item.offset!.left,
            image.dstRect.top - item.offset!.top,
            image.dstRect.right - item.offset!.right,
            image.dstRect.bottom - item.offset!.bottom,
          );
        }
      }
    });

    autosaveAfterDelay();
  }

  redo() {
    if (!history.canRedo) return;

    setState(() {
      EditorHistoryItem item = history.redo();
      if (item.type == EditorHistoryItemType.draw) { // redo draw
        for (Stroke stroke in item.strokes) {
          coreInfo.strokes.add(stroke);
        }
        for (EditorImage image in item.images) {
          coreInfo.images.add(image);
          image.newImage = true;
        }
        createPageOfStroke(null);
      } else if (item.type == EditorHistoryItemType.erase) { // redo erase
        for (Stroke stroke in item.strokes) {
          coreInfo.strokes.remove(stroke);
        }
        for (EditorImage image in item.images) {
          coreInfo.images.remove(image);
        }
        removeExcessPagesAfterStroke(null);
      } else if (item.type == EditorHistoryItemType.move) { // redo move
        for (EditorImage image in item.images) {
          image.dstRect = Rect.fromLTRB(
            image.dstRect.left + item.offset!.left,
            image.dstRect.top + item.offset!.top,
            image.dstRect.right + item.offset!.right,
            image.dstRect.bottom + item.offset!.bottom,
          );
        }
      }
    });

    autosaveAfterDelay();
  }

  int? onWhichPageIsFocalPoint(Offset focalPoint) {
    for (int i = 0; i < pages.length; ++i) {
      if (pages[i].renderBox == null) continue;
      Rect pageBounds = Offset.zero & coreInfo.pageSizes[i];
      if (pageBounds.contains(pages[i].renderBox!.globalToLocal(focalPoint))) return i;
    }
    return null;
  }

  int? dragPageIndex;
  double? currentPressure;
  /// if [pressureWasNegative], switch back to pen when pressure becomes positive again
  bool pressureWasNegative = false;
  bool isDrawGesture(ScaleStartDetails details) {
    // ignore: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member
    CanvasImage.activeListener.notifyListeners();

    _lastSeenPointerCountTimer?.cancel();
    if (lastSeenPointerCount >= 2) { // was a zoom gesture, ignore
      lastSeenPointerCount = lastSeenPointerCount;
      return false;
    } else if (details.pointerCount >= 2) { // is a zoom gesture, remove accidental stroke
      if (lastSeenPointerCount == 1 && Prefs.editorFingerDrawing.value) {
        setState(() {
          EditorHistoryItem? item = history.removeAccidentalStroke();
          if (item != null) {
            for (Stroke stroke in item.strokes) {
              coreInfo.strokes.remove(stroke);
            }
            // item.images is always empty
            removeExcessPagesAfterStroke(null);
          }
        });
      }
      lastSeenPointerCount = details.pointerCount;
      return false;
    } else { // is a stroke
      lastSeenPointerCount = details.pointerCount;
    }

    dragPageIndex = onWhichPageIsFocalPoint(details.focalPoint);
    if (dragPageIndex == null) return false;

    if (Prefs.editorFingerDrawing.value || currentPressure != null) {
      return true;
    } else {
      if (kDebugMode) print("Non-stylus found, rejected stroke");
      return false;
    }
  }
  onDrawStart(ScaleStartDetails details) {
    Offset position = pages[dragPageIndex!].renderBox!.globalToLocal(details.focalPoint);
    if (currentTool is Pen) {
      (currentTool as Pen).onDragStart(coreInfo.pageSizes[dragPageIndex!], position, dragPageIndex!, currentPressure);
    } else if (currentTool is Eraser) {
      for (int i in (currentTool as Eraser).checkForOverlappingStrokes(dragPageIndex!, position, coreInfo.strokes).reversed) {
        Stroke removed = coreInfo.strokes.removeAt(i);
        removeExcessPagesAfterStroke(removed);
      }
    }

    history.canRedo = false;
  }
  onDrawUpdate(ScaleUpdateDetails details) {
    Offset position = pages[dragPageIndex!].renderBox!.globalToLocal(details.focalPoint);
    setState(() {
      if (currentTool is Pen) {
        (currentTool as Pen).onDragUpdate(coreInfo.pageSizes[dragPageIndex!], position, currentPressure, () => setState(() {}));
      } else if (currentTool is Eraser) {
        for (int i in (currentTool as Eraser).checkForOverlappingStrokes(dragPageIndex!, position, coreInfo.strokes).reversed) {
          Stroke removed = coreInfo.strokes.removeAt(i);
          removeExcessPagesAfterStroke(removed);
        }
      }
    });
  }
  onDrawEnd(ScaleEndDetails details) {
    setState(() {
      if (currentTool is Pen) {
        Stroke newStroke = (currentTool as Pen).onDragEnd();
        coreInfo.strokes.add(newStroke);
        createPageOfStroke(newStroke.pageIndex);
        history.recordChange(EditorHistoryItem(
          type: EditorHistoryItemType.draw,
          strokes: [newStroke],
          images: [],
        ));
      } else if (currentTool is Eraser) {
        history.recordChange(EditorHistoryItem(
          type: EditorHistoryItemType.erase,
          strokes: (currentTool as Eraser).onDragEnd(),
          images: [],
        ));
      }
    });
    autosaveAfterDelay();

    if (pressureWasNegative) {
      pressureWasNegative = false;
      currentTool = Pen.currentPen;
    }
  }
  onInteractionEnd(ScaleEndDetails details) {
    // reset after 1ms to keep track of the same gesture only
    _lastSeenPointerCountTimer?.cancel();
    _lastSeenPointerCountTimer = Timer(const Duration(milliseconds: 10), () {
      lastSeenPointerCount = 0;
    });
  }
  onPressureChanged(double? pressure) {
    currentPressure = pressure == 0.0 ? null : pressure;
    if (currentPressure == null) return;

    if (currentPressure! < 0) {
      pressureWasNegative = true;
      currentTool = Eraser();
    }
  }

  onMoveImage(EditorImage image, Rect offset) {
    history.recordChange(EditorHistoryItem(
      type: EditorHistoryItemType.move,
      strokes: [],
      images: [image],
      offset: offset,
    ));
    // setState to update undo button
    setState(() {});
    autosaveAfterDelay();
  }
  onDeleteImage(EditorImage image) {
    history.recordChange(EditorHistoryItem(
      type: EditorHistoryItemType.erase,
      strokes: [],
      images: [image],
    ));
    setState(() {
      coreInfo.images.remove(image);
    });
    autosaveAfterDelay();
  }

  autosaveAfterDelay() {
    _hasEdited = true;
    _delayedSaveTimer?.cancel();
    _delayedSaveTimer = Timer(const Duration(milliseconds: 1000), () {
      saveToFile();
    });
  }


  String get _filename => path.substring(path.lastIndexOf('/') + 1);
  String _saveToString() {
    return json.encode(coreInfo);
  }
  void saveToFile() async {
    String toSave = _saveToString();
    await FileManager.writeFile(path + Editor.extension, toSave);
  }


  late final filenameTextEditingController = TextEditingController();
  Timer? _renameTimer;
  void renameFile(String newName) {
    _renameTimer?.cancel();

    if (newName.contains("/") || newName.isEmpty) { // if invalid name, don't rename
      _renameTimer = Timer(const Duration(milliseconds: 5000), () {
        filenameTextEditingController.text = _filename;
        filenameTextEditingController.selection = TextSelection.fromPosition(TextPosition(offset: _filename.length));
      });
    } else { // rename after a delay
      _renameTimer = Timer(const Duration(milliseconds: 500), () {
        _renameFileNow(newName);
      });
    }
  }
  Future _renameFileNow(String newName) async {
    path = await FileManager.moveFile(path + Editor.extension, newName + Editor.extension);
    path = path.substring(0, path.lastIndexOf(Editor.extension));
    needsNaming = false;
  }

  void updateColorBar(Color color) {
    final String newColorString = color.value.toString();

    // migrate from old pref format
    if (Prefs.recentColorsChronological.value.length != Prefs.recentColorsPositioned.value.length) {
      if (kDebugMode) print("MIGRATING recentColors: ${Prefs.recentColorsChronological.value.length} vs ${Prefs.recentColorsPositioned.value.length}");
      Prefs.recentColorsChronological.value = List.of(Prefs.recentColorsPositioned.value);
    }

    if (Prefs.recentColorsPositioned.value.contains(newColorString)) {
      // if the color is already in the list, move it to the top
      Prefs.recentColorsChronological.value.remove(newColorString);
      Prefs.recentColorsChronological.value.add(newColorString);
      Prefs.recentColorsChronological.notifyListeners();
    } else {
      if (Prefs.recentColorsPositioned.value.length >= 5) {
        // if full, replace the oldest color with the new one
        final String removedColorString = Prefs.recentColorsChronological.value.removeAt(0);
        Prefs.recentColorsChronological.value.add(newColorString);
        final int removedColorPosition = Prefs.recentColorsPositioned.value.indexOf(removedColorString);
        Prefs.recentColorsPositioned.value[removedColorPosition] = newColorString;
      } else {
        // if not full, add the new color to the end
        Prefs.recentColorsChronological.value.add(newColorString);
        Prefs.recentColorsPositioned.value.add(newColorString);
      }
      Prefs.recentColorsChronological.notifyListeners();
      Prefs.recentColorsPositioned.notifyListeners();
    }
  }

  Future pickPhoto() async {
    final int? currentPageIndex = this.currentPageIndex;
    if (currentPageIndex == null) return;

    Uint8List? bytes;
    if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
      bytes = await pickPhotoMobile();
    } else {
      bytes = await pickPhotoDesktop();
    }
    if (bytes == null) return;

    int pageIndex = currentPageIndex;
    EditorImage image = EditorImage(
      bytes: bytes,
      pageIndex: pageIndex,
      pageSize: coreInfo.pageSizes[pageIndex],
      onMoveImage: onMoveImage,
      onDeleteImage: onDeleteImage,
      onMiscChange: autosaveAfterDelay,
      onLoad: () => setState(() {}),
    );
    history.recordChange(EditorHistoryItem(
      type: EditorHistoryItemType.draw,
      strokes: [],
      images: [image],
    ));
    coreInfo.images.add(image);
    autosaveAfterDelay();
  }

  Future<Uint8List?> pickPhotoMobile() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1000,
      maxHeight: 1000,
      imageQuality: 90,
      requestFullMetadata: false,
    );
    if (image == null) return null;
    return await image.readAsBytes();
  }
  Future<Uint8List?> pickPhotoDesktop() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null) return null;
    return result.files.single.bytes;
  }

  Future exportAsPdf() async {
    final pdf = EditorExporter.generatePdf(pages, coreInfo);
    await FileManager.exportFile("$_filename.pdf", await pdf.save());
  }
  Future exportAsSbn() async {
    final content = _saveToString();
    final encoded = utf8.encode(content);
    await FileManager.exportFile("$_filename.sbn", encoded);
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = Column(
      verticalDirection: Prefs.editorToolbarOnBottom.value ? VerticalDirection.down : VerticalDirection.up,
      children: [
        Expanded(
          child: CanvasGestureDetector(
            isDrawGesture: isDrawGesture,
            onInteractionEnd: onInteractionEnd,
            onDrawStart: onDrawStart,
            onDrawUpdate: onDrawUpdate,
            onDrawEnd: onDrawEnd,
            onPressureChanged: onPressureChanged,

            undo: undo,
            redo: redo,

            child: Column(
              children: [
                for (int pageIndex = 0; pageIndex < pages.length; pageIndex++) ...[
                  Canvas(
                    path: path,
                    pageIndex: pageIndex,
                    innerCanvasKey: pages[pageIndex].innerCanvasKey,
                    coreInfo: coreInfo.copyWith(
                      strokes: coreInfo.strokes.where((stroke) => stroke.pageIndex == pageIndex).toList(),
                      images: coreInfo.images.where((image) => image.pageIndex == pageIndex).toList(),
                    ),
                    currentStroke: () {
                      Stroke? currentStroke = Pen.currentPen.currentStroke ?? Highlighter.currentHighlighter.currentStroke;
                      return (currentStroke?.pageIndex == pageIndex) ? currentStroke : null;
                    }(),
                  ),
                  const SizedBox(height: 16),
                ]
              ],
            ),
          ),
        ),

        SafeArea(
          child: Toolbar(
            setTool: (tool) {
              setState(() {
                currentTool = tool;

                if (currentTool is Highlighter) {
                  Highlighter.currentHighlighter = currentTool as Highlighter;
                } else if (currentTool is Pen) {
                  Pen.currentPen = currentTool as Pen;
                }
              });
            },
            currentTool: currentTool,
            setColor: (color) {
              setState(() {
                updateColorBar(color);

                if (currentTool is Highlighter) {
                  (currentTool as Highlighter).strokeProperties.color = color.withAlpha(Highlighter.alpha);
                } else if (currentTool is Pen) {
                  (currentTool as Pen).strokeProperties.color = color;
                }
              });
            },
            undo: undo,
            isUndoPossible: history.canUndo,
            redo: redo,
            isRedoPossible: history.canRedo,
            toggleFingerDrawing: () {
              setState(() {
                Prefs.editorFingerDrawing.value = !Prefs.editorFingerDrawing.value;
                lastSeenPointerCount = 0;
              });
            },

            pickPhoto: pickPhoto,

            exportAsSbn: exportAsSbn,
            exportAsPdf: exportAsPdf,
            exportAsPng: null,
          ),
        ),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: kToolbarHeight,
        title: TextField(
          decoration: const InputDecoration(
            border: InputBorder.none,
          ),
          controller: filenameTextEditingController,
          onChanged: renameFile,
          autofocus: needsNaming,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                builder: (context) => bottomSheet(context),
              );
            },
          )
        ],
      ),
      body: body,
    );
  }

  Widget bottomSheet(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
    final bool invert = Prefs.editorAutoInvert.value && brightness == Brightness.dark;

    return EditorBottomSheet(
      invert: invert,
      coreInfo: coreInfo,
      setBackgroundPattern: (pattern) => setState(() {
          coreInfo.backgroundPattern = pattern;
          Prefs.lastBackgroundPattern.value = pattern;
          autosaveAfterDelay();
        }),
      setLineHeight: (lineHeight) => setState(() {
          coreInfo.lineHeight = lineHeight;
          Prefs.lastLineHeight.value = lineHeight;
          autosaveAfterDelay();
        }),
      clearPage: () {
        final int? currentPageIndex = this.currentPageIndex;
        if (currentPageIndex == null) return;

        setState(() {
          List<Stroke> removedStrokes = coreInfo.strokes.where((stroke) => stroke.pageIndex == currentPageIndex).toList();
          for (Stroke stroke in removedStrokes) {
            coreInfo.strokes.remove(stroke);
          }
          List<EditorImage> removedImages = coreInfo.images.where((image) => image.pageIndex == currentPageIndex).toList();
          for (EditorImage image in removedImages) {
            coreInfo.images.remove(image);
          }
          removeExcessPagesAfterStroke(null);
          history.recordChange(EditorHistoryItem(
            type: EditorHistoryItemType.erase,
            strokes: removedStrokes,
            images: removedImages,
          ));
        });
      },

      clearAllPages: () {
        setState(() {
          List<Stroke> removedStrokes = coreInfo.strokes.toList();
          List<EditorImage> removedImages = coreInfo.images.toList();
          coreInfo.strokes.clear();
          coreInfo.images.clear();
          removeExcessPagesAfterStroke(null);
          history.recordChange(EditorHistoryItem(
            type: EditorHistoryItemType.erase,
            strokes: removedStrokes,
            images: removedImages,
          ));
        });
      },
    );
  }

  /// The index of the page that is currently centered on screen.
  int? get currentPageIndex {
    final Size windowSize = MediaQuery.of(context).size;
    late Offset centre = Offset(windowSize.width / 2, windowSize.height / 2);

    for (int pageIndex = 0; pageIndex < pages.length; ++pageIndex) {
      final page = pages[pageIndex];
      if (page.renderBox == null) continue;
      final localCenter = page.renderBox!.globalToLocal(centre);

      if (page.renderBox!.hitTest(BoxHitTestResult(), position: localCenter)) {
        return pageIndex;
      }
    }

    return null;
  }

  @override
  void dispose() {
    _delayedSaveTimer?.cancel();
    _lastSeenPointerCountTimer?.cancel();

    _removeKeybindings();

    if (_hasEdited) {
      saveToFile();
    }

    // dispose of images' cache
    for (EditorImage image in coreInfo.images) {
      image.invertedBytesCache = null;
    }

    super.dispose();
  }
}
