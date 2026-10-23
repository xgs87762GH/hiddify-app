import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/theme/app_layout.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_page.dart';

void main() {
  group('AppLayout tokens', () {
    test('the two-column layout leaves a readable button column', () {
      // Narrowest window that still shows two columns on an extended rail:
      // rail threshold plus the side column width.
      const content = AppLayout.railLabelThreshold + 20 - AppLayout.railExtendedWidth;
      const buttonColumn = content - AppLayout.sideColumnWidth;
      expect(buttonColumn, greaterThanOrEqualTo(500));
    });

    test('the rail and the side column fit the window they appear at', () {
      expect(AppLayout.railExtendedWidth + AppLayout.sideColumnWidth, lessThan(AppLayout.railLabelThreshold));
    });

    test('gutterFor widens once the page is desktop-sized', () {
      expect(AppLayout.gutterFor(600), AppLayout.gutter);
      expect(AppLayout.gutterFor(839), AppLayout.gutter);
      expect(AppLayout.gutterFor(840), AppLayout.wideGutter);
    });
  });

  group('proxyColumnCount', () {
    test('mobile stays one column below 600', () {
      expect(proxyColumnCount(100, isMobile: true), 1);
      expect(proxyColumnCount(599, isMobile: true), 1);
    });

    test('mobile scales up from 600', () {
      expect(proxyColumnCount(600, isMobile: true), 2);
      expect(proxyColumnCount(900, isMobile: true), 3);
    });

    test('desktop always scales with width, minimum one', () {
      expect(proxyColumnCount(100, isMobile: false), 1);
      expect(proxyColumnCount(268, isMobile: false), 1);
      expect(proxyColumnCount(1000, isMobile: false), 3);
    });

    test('a rail-width window keeps three columns after the gutters', () {
      // 1200 window: 240 rail, 2×16 gutters, 928 left for the grid.
      expect(proxyColumnCount(1200 - 240 - 2 * AppLayout.gutter, isMobile: false), 3);
    });
  });
}
