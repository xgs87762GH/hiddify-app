import 'package:flutter/material.dart';

/// Layout tokens shared by the pages.
///
/// Paddings, content widths and card shapes come from here, so a page does not
/// invent its own numbers and the app keeps one rhythm from screen to screen.
abstract final class AppLayout {
  /// Gutter used by a page that is as narrow as a phone.
  static const double gutter = 16;

  /// Gutter used once the page has room to breathe.
  static const double wideGutter = 24;

  /// Width a single column of content may reach before it stops stretching.
  static const double maxColumnWidth = 720;

  /// Width the home page content needs before it shows its second column.
  ///
  /// Measured after the navigation rail took its share, so it has to leave
  /// room for a readable button column next to the side column.
  static const double twoColumnWidth = 880;

  /// Width of the home page second column.
  static const double sideColumnWidth = 360;

  /// Window width from which the navigation rail shows its labels.
  ///
  /// Below it the rail stays icon-only: an extended rail plus the stats panel
  /// would eat most of a 900px window and leave the page squeezed.
  static const double railLabelThreshold = 1100;

  /// Width of the rail once its labels are shown.
  static const double railExtendedWidth = 240;

  /// Corner radius of the cards the home page and the lists use.
  static const double cardRadius = 20;

  /// Horizontal gutter for a page whose content is [width] wide.
  static double gutterFor(double width) => width >= 840 ? wideGutter : gutter;

  /// The surface used by the home page cards.
  static BoxDecoration card(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(cardRadius),
      boxShadow: [
        BoxShadow(color: scheme.secondary.withValues(alpha: .21), blurRadius: 10, offset: const Offset(0, 4)),
      ],
    );
  }
}
