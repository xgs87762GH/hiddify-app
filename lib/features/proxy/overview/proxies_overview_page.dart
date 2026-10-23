import 'dart:math';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/core/theme/app_layout.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/features/proxy/widget/proxy_tile.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Column count for the proxy grid at [width] logical pixels.
///
/// The grid is guttered on both sides, so callers pass the width already
/// reduced by the gutters; mobile stays one column below 600.
int proxyColumnCount(double width, {required bool isMobile}) =>
    isMobile && width < 600 ? 1 : max(1, (width / 268).floor());

class ProxiesOverviewPage extends HookConsumerWidget with PresLogger {
  const ProxiesOverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;

    final proxies = ref.watch(proxiesOverviewNotifierProvider);
    final sortBy = ref.watch(proxiesSortNotifierProvider);

    // final selectActiveProxyMutation = useMutation(
    //   initialOnFailure: (error) => CustomToast.error(t.presentShortError(error)).show(context),
    // );

    return Scaffold(
      appBar: AppBar(
        title: Text(t.pages.proxies.title),
        actions: [
          PopupMenuButton<ProxiesSort>(
            initialValue: sortBy,
            onSelected: ref.read(proxiesSortNotifierProvider.notifier).update,
            icon: const Icon(FluentIcons.arrow_sort_24_regular),
            tooltip: t.pages.proxies.sort,
            itemBuilder: (context) {
              return [...ProxiesSort.values.map((e) => PopupMenuItem(value: e, child: Text(e.present(t))))];
            },
          ),
          const Gap(8),
        ],
      ),
      // Nothing to test until the core reports a group. It used to look ready
      // and do nothing when tapped.
      floatingActionButton: Builder(
        builder: (context) {
          final tag = proxies.valueOrNull?.tag;
          final canTest = tag != null && tag.isNotEmpty;
          return FloatingActionButton(
            // The group the page is showing, not a hard-coded tag: the core
            // names it, and a test of a tag that does not exist does nothing.
            onPressed: !canTest
                ? null
                : () async => await ref.read(proxiesOverviewNotifierProvider.notifier).urlTest(tag),
            tooltip: t.pages.proxies.testDelay,
            child: const Icon(FluentIcons.flash_24_filled),
          );
        },
      ),
      body: proxies.when(
        data: (group) => group != null
            ? LayoutBuilder(
                builder: (context, constraints) {
                  // The grid is padded on both sides, so the column count has to
                  // ignore the gutters or the last column overflows.
                  final width = constraints.maxWidth - AppLayout.gutter * 2;
                  final crossAxisCount = proxyColumnCount(width, isMobile: PlatformUtils.isMobile);
                  return GridView.builder(
                    padding: const EdgeInsets.fromLTRB(AppLayout.gutter, 8, AppLayout.gutter, 86),
                    itemCount: group.items.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      mainAxisExtent: 72,
                    ),
                    itemBuilder: (context, index) {
                      final proxy = group.items[index];
                      return ProxyTile(
                        proxy,
                        selected: group.selected == proxy.tag,
                        onTap: () async {
                          await ref.read(proxiesOverviewNotifierProvider.notifier).changeProxy(group.tag, proxy.tag);
                          // if (selectActiveProxyMutation.state.isInProgress) return;
                          // selectActiveProxyMutation.setFuture(
                          // );
                        },
                      );
                    },
                  );
                },
              )
            : Center(child: Text(t.pages.proxies.empty)),
        // The core connection dropped or the query failed: let the user ask
        // again instead of leaving an error text with no way forward.
        error: (error, stackTrace) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, color: Theme.of(context).colorScheme.error),
              const Gap(12),
              Text(t.presentShortError(error), textAlign: TextAlign.center),
              const Gap(12),
              OutlinedButton.icon(
                onPressed: () => ref.invalidate(proxiesOverviewNotifierProvider),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(t.common.retry),
              ),
            ],
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}
