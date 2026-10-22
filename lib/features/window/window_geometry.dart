import 'dart:math';
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';

/// `screen_retriever` reports displays in logical pixels, each using its own
/// scale factor. A window position is also logical, but it is interpreted with
/// the DPI of the monitor the window currently sits on. Restoring a window on
/// another monitor therefore has to go through physical pixels.
double displayScale(Display display) => (display.scaleFactor ?? 1).toDouble();

Rect logicalWorkArea(Display display) {
  final position = display.visiblePosition ?? Offset.zero;
  final size = display.visibleSize ?? display.size;
  return position & size;
}

Rect physicalWorkArea(Display display) {
  final scale = displayScale(display);
  final area = logicalWorkArea(display);
  return Rect.fromLTWH(
    area.left * scale,
    area.top * scale,
    area.width * scale,
    area.height * scale,
  );
}

/// The display a saved window belonged to, judged by the largest overlap.
Display? displayForSavedWindow(List<Display> displays, Rect logicalWindow) {
  Display? best;
  var bestOverlap = 0.0;
  for (final display in displays) {
    final overlap = logicalWorkArea(display).intersect(logicalWindow);
    if (overlap.isEmpty) continue;
    final area = overlap.width * overlap.height;
    if (area > bestOverlap) {
      bestOverlap = area;
      best = display;
    }
  }
  return best;
}

Size _fitSize(Size size, Rect workArea, Size minimumSize, double maxFraction) {
  final maxWidth = workArea.width * maxFraction;
  final maxHeight = workArea.height * maxFraction;
  return Size(
    size.width.clamp(min(minimumSize.width, maxWidth), maxWidth).toDouble(),
    size.height.clamp(min(minimumSize.height, maxHeight), maxHeight).toDouble(),
  );
}

/// Keeps a saved window on screen: oversized windows shrink to [maxFraction]
/// of the work area, and one that would sit (partly) off-screen is centered.
Rect fitWindowToWorkArea(
  Rect window,
  Rect workArea, {
  required Size minimumSize,
  double maxFraction = 0.9,
}) {
  final size = _fitSize(window.size, workArea, minimumSize, maxFraction);
  final fits = size == window.size &&
      window.left >= workArea.left &&
      window.top >= workArea.top &&
      window.right <= workArea.right &&
      window.bottom <= workArea.bottom;
  if (fits) return window;
  return Rect.fromLTWH(
    workArea.left + (workArea.width - size.width) / 2,
    workArea.top + (workArea.height - size.height) / 2,
    size.width,
    size.height,
  );
}

Rect centeredWindow(
  Rect workArea,
  Size preferredSize, {
  required Size minimumSize,
  double maxFraction = 0.9,
}) {
  final size = _fitSize(preferredSize, workArea, minimumSize, maxFraction);
  return Rect.fromLTWH(
    workArea.left + (workArea.width - size.width) / 2,
    workArea.top + (workArea.height - size.height) / 2,
    size.width,
    size.height,
  );
}
