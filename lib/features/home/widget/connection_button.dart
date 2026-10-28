import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/theme/app_layout.dart';
import 'package:hiddify/core/theme/theme_extensions.dart';
import 'package:hiddify/core/widget/animated_text.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// What the button shows, one value per look.
enum _Look { loading, disconnected, connecting, connected, noPing, hotReloading, disconnecting, failed }

/// The core reports the tunnel as up before the first ping answers, so a tunnel
/// with no ping yet still looks like connecting: the user waits once, not twice.
/// A delay of 0 is a ping not measured yet; any other invalid delay timed out.
///
/// The status reloads after every core start; until the new stream answers,
/// the last status holds. A failed start comes back as disconnected with the
/// failure attached.
///
/// A hot reload keeps the tunnel up, and the status stays connected through it.
/// It comes before the ping checks, so a reload never looks like a ping problem.
_Look _lookOf(AsyncValue<ConnectionStatus> status, int delay, bool hotReloading) => switch (status) {
  AsyncError() => _Look.failed,
  AsyncValue(valueOrNull: Disconnected(connectionFailure: _?)) => _Look.failed,
  AsyncValue(valueOrNull: Disconnected()) => _Look.disconnected,
  AsyncValue(valueOrNull: Connecting()) => _Look.connecting,
  AsyncValue(valueOrNull: Connected()) when hotReloading => _Look.hotReloading,
  AsyncValue(valueOrNull: Connected()) when delay == 0 => _Look.connecting,
  AsyncValue(valueOrNull: Connected()) when !ConnectionConst.isValidDelay(delay) => _Look.noPing,
  AsyncValue(valueOrNull: Connected()) => _Look.connected,
  AsyncValue(valueOrNull: Disconnecting()) => _Look.disconnecting,
  _ => _Look.loading,
};

class ConnectionButton extends HookConsumerWidget with PresLogger {
  const ConnectionButton({super.key, this.size = AppLayout.maxButtonSize});

  /// Diameter of the round button, handed down by the page: the home page
  /// measures the box it can spare and the rings around the button follow it.
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final status = ref.watch(connectionNotifierProvider);
    // After a disconnect Riverpod keeps the last ping as the previous value,
    // which would show the next connection as up before its own ping answers.
    final delay = ref.watch(activeProxyNotifierProvider).unwrapPrevious().valueOrNull?.urlTestDelay ?? 0;
    final hotReloading = ref.watch(hotReloadingProvider).valueOrNull ?? false;
    final look = _lookOf(status, delay, hotReloading);

    // What a tap does follows the core alone: a tunnel that is up can be
    // turned off even while it still looks like connecting. The core is busy
    // while it hot reloads, so the tap is off until that ends.
    final onTap = switch (status) {
      AsyncData(value: Connected()) when hotReloading => null,
      AsyncData(value: Disconnected()) || AsyncError() => () => _connect(ref),
      AsyncData(value: Connected()) => () => ref.read(connectionNotifierProvider.notifier).toggleConnection(),
      _ => null,
    };

    // What the button shows and whether a tap does anything, one line per
    // change: the look is picked from three providers and the tap is off for
    // half of the looks, so "nothing happens" has to be readable from here.
    final canTap = onTap != null;
    useEffect(() {
      loggy.info(
        "button: look [$look] status [$status] delay [$delay]ms hotReload [$hotReloading] tap ${canTap ? "on" : "off"}",
      );
      return null;
    }, [look, canTap]);

    const buttonTheme = ConnectionButtonTheme.light;
    final today = DateTime.now();
    return _ConnectionButton(
      look: look,
      onTap: onTap,
      label: switch (look) {
        _Look.loading => "",
        _Look.disconnected => t.connection.tapToConnect,
        _Look.connecting => t.connection.connecting,
        _Look.connected || _Look.noPing => t.connection.connected,
        _Look.hotReloading => t.connection.hotReloading,
        _Look.disconnecting => t.connection.disconnecting,
        _Look.failed => t.connection.failed,
      },
      hint: look == _Look.failed ? t.connection.tapToRetry : null,
      // Says why the tap does nothing. Most disabled looks are only visible as
      // a spinner, and hot reloading looks just like being connected.
      tooltip: switch (look) {
        _Look.loading || _Look.connecting => t.connection.connecting,
        _Look.disconnecting => t.connection.disconnecting,
        _Look.hotReloading => t.connection.hotReloading,
        _Look.failed => t.connection.tapToRetry,
        _Look.disconnected => t.connection.tapToConnect,
        _ => t.connection.connected,
      },
      buttonColor: switch (look) {
        _Look.connected => buttonTheme.connectedColor!,
        _Look.noPing || _Look.hotReloading => const Color.fromARGB(255, 185, 176, 103),
        _Look.failed => Colors.red,
        _ => buttonTheme.idleColor!,
      },
      image: switch (look) {
        _Look.connected || _Look.noPing || _Look.hotReloading => Assets.images.connectNorouz,
        _ => Assets.images.disconnectNorouz,
      },
      useImage: today.day >= 19 && today.day <= 23 && today.month == 3,
      size: size,
    );
  }

  /// Connects, or sends the user to add a profile when there is none.
  Future<void> _connect(WidgetRef ref) async {
    final dialogs = ref.read(dialogNotifierProvider.notifier);
    if (ref.read(activeProfileProvider).valueOrNull == null) {
      await dialogs.showNoActiveProfile();
      ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile();
      return;
    }
    if (await dialogs.showExperimentalFeatureNotice()) {
      await ref.read(connectionNotifierProvider.notifier).toggleConnection();
    }
  }
}

class _ConnectionButton extends HookWidget {
  const _ConnectionButton({
    required this.look,
    required this.onTap,
    required this.label,
    required this.hint,
    required this.tooltip,
    required this.buttonColor,
    required this.image,
    required this.useImage,
    required this.size,
  });

  final _Look look;
  final VoidCallback? onTap;
  final String label;
  final String? hint;
  final String tooltip;
  final Color buttonColor;
  final AssetGenImage image;
  final bool useImage;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = look == _Look.connecting || look == _Look.disconnecting;
    final disabled = onTap == null;

    // Every ring around the button is measured from its diameter, so a button
    // that had to shrink keeps the proportions it was drawn with: at 148px the
    // spinner keeps its 10px inset, the icon its 36px padding and the label
    // its 24px gap.
    final ringInset = size * (10 / 148);
    final iconPadding = size * (36 / 148);
    final labelGap = (size * (24 / 148)).clamp(12.0, 24.0);
    final strokeWidth = (size * (4 / 148)).clamp(2.5, 4.0);

    // A dimmed icon is the only difference between a button that is waiting and
    // one that can be pressed. Hot reloading used to look exactly like being
    // connected even though the tap was off.
    final iconOpacity = switch (look) {
      _Look.loading => .38,
      _ when disabled && !busy => .6,
      _ => 1.0,
    };

    // One ripple when a wait the user watched ends connected, not when the
    // app opens on a tunnel that is already up or a timed-out ping recovers.
    final ripple = useAnimationController(duration: const Duration(milliseconds: 900));
    final previousLook = usePrevious(look);
    useEffect(() {
      if (look == _Look.connected && previousLook == _Look.connecting) ripple.forward(from: 0);
      return null;
    }, [look]);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Semantics(
          button: true,
          enabled: onTap != null,
          label: label,
          hint: hint,
          child: SizedBox.square(
            key: const ValueKey("home_connection_button_size"),
            dimension: size,
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                AnimatedBuilder(
                  animation: ripple,
                  builder: (context, _) => ripple.isAnimating
                      ? Transform.scale(
                          // A smaller button ripples less, so the ring no
                          // longer reaches the label below it.
                          scale: 1 + .25 * ripple.value,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: buttonColor.withValues(alpha: .7 * (1 - ripple.value)),
                                width: strokeWidth * .75,
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                Positioned.fill(
                  left: -ringInset,
                  top: -ringInset,
                  right: -ringInset,
                  bottom: -ringInset,
                  // A single faded child: an AnimatedSwitcher here hit duplicate keys
                  // when the state flipped twice within its duration.
                  child: AnimatedOpacity(
                    opacity: busy ? 1 : 0,
                    duration: const Duration(milliseconds: 300),
                    // Stops the spinner's ticker while hidden.
                    child: TickerMode(
                      enabled: busy,
                      child: Transform.flip(
                        // Disconnecting spins the other way.
                        flipX: look == _Look.disconnecting,
                        child: CircularProgressIndicator(
                          strokeWidth: strokeWidth,
                          strokeCap: StrokeCap.round,
                          color: buttonColor,
                          backgroundColor: buttonColor.withValues(alpha: .2),
                        ),
                      ),
                    ),
                  ),
                ),
                Tooltip(
                  message: tooltip,
                  child: Material(
                    key: const ValueKey("home_connection_button"),
                    shape: const CircleBorder(),
                    color: Colors.white,
                    elevation: 3,
                    shadowColor: Colors.black,
                    surfaceTintColor: Colors.transparent,
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      focusColor: Colors.grey,
                      onTap: onTap,
                      child: Padding(
                        padding: EdgeInsets.all(iconPadding),
                        child: AnimatedOpacity(
                          opacity: iconOpacity,
                          duration: const Duration(milliseconds: 300),
                          child: TweenAnimationBuilder(
                            tween: ColorTween(end: buttonColor),
                            duration: const Duration(milliseconds: 250),
                            builder: (context, value, child) {
                              if (useImage) {
                                return image.image();
                              } else {
                                return Assets.images.logo.svg(colorFilter: ColorFilter.mode(value!, BlendMode.srcIn));
                              }
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Gap(labelGap),
        ExcludeSemantics(
          child: Column(
            children: [
              AnimatedText(label, style: theme.textTheme.titleMedium),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: hint == null
                    ? const SizedBox.shrink()
                    : Text(
                        hint!,
                        key: ValueKey(hint),
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
