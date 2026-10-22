import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/window/window_geometry.dart';
import 'package:screen_retriever/screen_retriever.dart';

void main() {
  const primary = Display(
    id: 'primary',
    size: Size(1440, 900),
    visiblePosition: Offset.zero,
    visibleSize: Size(1440, 900),
    scaleFactor: 2,
  );
  const secondary = Display(
    id: 'secondary',
    size: Size(1920, 1080),
    visiblePosition: Offset(-1920, 108),
    visibleSize: Size(1920, 1032),
    scaleFactor: 1,
  );

  test('display geometry is converted to physical pixels', () {
    expect(physicalWorkArea(primary), const Rect.fromLTWH(0, 0, 2880, 1800));
    expect(physicalWorkArea(secondary), const Rect.fromLTWH(-1920, 108, 1920, 1032));
  });

  test('a window saved on the secondary display is recognized as such', () {
    final display = displayForSavedWindow(
      const [primary, secondary],
      const Rect.fromLTWH(-1635, 234, 1250, 850),
    );

    expect(display, secondary);
    expect(displayScale(display!), 1);
  });

  test('a window below every display is not matched to one', () {
    expect(
      displayForSavedWindow(
        const [primary, secondary],
        const Rect.fromLTWH(2000, 2000, 500, 500),
      ),
      isNull,
    );
  });

  test('a window saved on the 100% display keeps its physical size', () {
    const saved = Rect.fromLTWH(-1635, 234, 1250, 850);
    final restored = fitWindowToWorkArea(
      saved,
      physicalWorkArea(secondary),
      minimumSize: const Size(368, 568),
    );

    expect(restored, saved);
  });

  test('a window inflated by the startup DPI is clamped to the work area', () {
    final restored = fitWindowToWorkArea(
      const Rect.fromLTWH(200, 200, 2500, 1700),
      physicalWorkArea(primary),
      minimumSize: const Size(736, 1136),
    );

    expect(restored.size, const Size(2500, 1620));
    expect(restored.center, physicalWorkArea(primary).center);
  });

  test('a window partly off-screen is centered', () {
    final restored = fitWindowToWorkArea(
      const Rect.fromLTWH(2700, 100, 800, 500),
      physicalWorkArea(primary),
      minimumSize: const Size(736, 1136),
    );

    expect(restored.size, const Size(800, 1136));
    expect(restored.center, physicalWorkArea(primary).center);
  });

  test('a window without saved geometry is centered at its default size', () {
    final restored = centeredWindow(
      physicalWorkArea(secondary),
      const Size(868, 668),
      minimumSize: const Size(368, 568),
    );

    expect(restored.size, const Size(868, 668));
    expect(restored.center, physicalWorkArea(secondary).center);
  });

  test('a saved window smaller than the minimum grows to the minimum', () {
    final restored = fitWindowToWorkArea(
      const Rect.fromLTWH(300, 300, 100, 100),
      physicalWorkArea(primary),
      minimumSize: const Size(736, 1136),
    );

    expect(restored.size, const Size(736, 1136));
    expect(restored.center, physicalWorkArea(primary).center);
  });
}
