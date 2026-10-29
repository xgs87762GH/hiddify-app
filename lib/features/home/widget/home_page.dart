import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/router/go_router/helper/active_breakpoint_notifier.dart';
import 'package:hiddify/core/theme/app_layout.dart';
import 'package:hiddify/features/home/widget/connection_button.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/widget/profile_tile.dart';
import 'package:hiddify/features/proxy/active/active_proxy_card.dart';
import 'package:hiddify/features/proxy/active/active_proxy_delay_indicator.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sliver_tools/sliver_tools.dart';

class HomePage extends HookConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    final activeProfile = ref.watch(activeProfileProvider);

    return Scaffold(
      appBar: AppBar(
        // The version sits in the actions, not inside the title: a long version
        // string used to push the app name out of an already narrow bar.
        title: Row(
          children: [
            Assets.images.logo.svg(height: 24),
            const Gap(8),
            Flexible(child: Text(t.common.appTitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          // A phone bar has no room for a version chip; about shows it there.
          if (!Breakpoint(context).isMobile()) ...[const AppVersionLabel(), const Gap(8)],
          Semantics(
            key: const ValueKey("profile_add_button"),
            label: t.pages.profiles.add,
            child: IconButton(
              icon: Icon(Icons.add_rounded, color: theme.colorScheme.primary),
              onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),
            ),
          ),
          const Gap(8),
        ],
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          // A sky behind the connect button, as at an eclipse: in dark mode a touch lighter round
          // the button, fading to the theme's own dark; in light mode brightest there, a touch
          // darker towards the edges. Both barely there, centred on where the button sits.
          gradient: theme.brightness == Brightness.dark
              ? RadialGradient(
                  center: const Alignment(0, -.15),
                  radius: .85,
                  colors: [
                    Colors.white.withValues(alpha: .045),
                    Colors.white.withValues(alpha: .015),
                    Colors.white.withValues(alpha: 0),
                  ],
                  stops: const [0, .45, 1],
                )
              : RadialGradient(
                  center: const Alignment(0, -.15),
                  radius: 1.1,
                  colors: [
                    Colors.white.withValues(alpha: .55),
                    Colors.white.withValues(alpha: 0),
                    Colors.black.withValues(alpha: .045),
                  ],
                  stops: const [0, .5, 1],
                ),
          image: DecorationImage(
            image: const AssetImage('assets/images/world_map.png'), // Replace with your image path
            fit: BoxFit.cover,
            opacity: 0.09,
            colorFilter: theme.brightness == Brightness.dark
                ? ColorFilter.mode(Colors.white.withValues(alpha: .15), BlendMode.srcIn) //
                : ColorFilter.mode(
                    Colors.grey.withValues(alpha: 1),
                    BlendMode.srcATop,
                  ), // Apply white tint in dark mode
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final profile = activeProfile.valueOrNull;
            return Stack(
              alignment: Alignment.center,
              children: [
                if (constraints.maxWidth >= AppLayout.twoColumnWidth)
                  _TwoColumnBody(profile: profile)
                else
                  _SingleColumnBody(profile: profile),
                if (ref.watch(hasAnyProfileProvider).value ?? false) const _QuickSettingsHandle(),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Until the window is wide, the page stays one scrolling column.
class _SingleColumnBody extends StatelessWidget {
  const _SingleColumnBody({required this.profile});

  final ProfileEntity? profile;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppLayout.maxColumnWidth),
        child: CustomScrollView(
          slivers: [
            MultiSliver(
              children: [
                if (profile != null)
                  ProfileTile(
                    profile: profile!,
                    isMain: true,
                    margin: const EdgeInsets.symmetric(horizontal: AppLayout.gutter, vertical: 8),
                  ),
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [const ConnectionButton(), const ActiveProxyDelayIndicator()],
                        ),
                      ),
                      const ActiveProxyFooter(),
                      const Gap(32),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A wide window puts the active profile and the proxy card beside the button
/// instead of stacking them, so the button stays the centre of attention
/// without leaving two empty margins.
class _TwoColumnBody extends StatelessWidget {
  const _TwoColumnBody({required this.profile});

  final ProfileEntity? profile;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppLayout.wideGutter, vertical: AppLayout.wideGutter),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [const ConnectionButton(), const ActiveProxyDelayIndicator()],
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          width: AppLayout.sideColumnWidth,
          child: SingleChildScrollView(
            // The bottom room keeps the last card clear of the quick settings handle.
            padding: const EdgeInsetsDirectional.only(top: AppLayout.wideGutter, end: AppLayout.wideGutter, bottom: 56),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (profile != null) ...[ProfileTile(profile: profile!, isMain: true), const Gap(12)],
                const ActiveProxyFooter(compact: true),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _QuickSettingsHandle extends ConsumerWidget {
  const _QuickSettingsHandle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    const radius = BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16));

    return Positioned(
      right: 0,
      left: 0,
      bottom: 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Material(
            color: theme.colorScheme.primaryContainer,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: () => ref.read(bottomSheetsNotifierProvider.notifier).showQuickSettings(),
              child: Container(
                height: 32,
                padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(t.pages.home.quickSettings),
                    const Gap(4),
                    const Icon(Icons.arrow_drop_up_rounded, size: 16),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AppVersionLabel extends HookConsumerWidget {
  const AppVersionLabel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    // valueOrNull: the app info is still loading on the first frame, and
    // requireValue would throw there and paint the whole bar red.
    final version = ref.watch(appInfoProvider).valueOrNull?.presentVersion;
    if (version == null || version.isBlank) return const SizedBox();

    return Semantics(
      label: t.common.version,
      button: false,
      child: Tooltip(
        message: version,
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(
            version,
            textDirection: TextDirection.ltr,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
          ),
        ),
      ),
    );
  }
}
