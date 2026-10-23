import 'package:flutter/material.dart';
import 'package:hiddify/core/model/constants.dart';

class AnimatedText extends Text {
  const AnimatedText(
    super.data, {
    super.key,
    super.style,
    this.duration = kAnimationDuration,
    this.size = true,
    this.slide = true,
  });

  final Duration duration;
  final bool size;
  final bool slide;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      transitionBuilder: (child, animation) {
        Widget wrapped = FadeTransition(opacity: animation, child: child);
        if (size) {
          wrapped = SizeTransition(
            axis: Axis.horizontal,
            fixedCrossAxisSizeFactor: 1,
            sizeFactor: Tween<double>(begin: 0.88, end: 1).animate(animation),
            child: wrapped,
          );
        }
        if (slide) {
          wrapped = SlideTransition(
            position: Tween<Offset>(begin: const Offset(0.0, -0.2), end: Offset.zero).animate(animation),
            child: wrapped,
          );
        }
        return wrapped;
      },
      child: Text(data!, key: ValueKey<String>(data!), style: style),
    );
  }
}
