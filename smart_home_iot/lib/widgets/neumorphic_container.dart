import 'package:flutter/material.dart';

class NeumorphicContainer extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final bool isActive;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;

  const NeumorphicContainer({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.isActive = false,
    this.padding,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFDCE5F0),
        borderRadius: borderRadius ?? BorderRadius.circular(20),
        boxShadow: isActive
            ? [
                // Hiệu ứng lõm khi active (đảo ngược bóng)
                const BoxShadow(
                  color: Color(0xFFA6BCCF),
                  offset: Offset(-2, -2),
                  blurRadius: 6,
                ),
                const BoxShadow(
                  color: Colors.white,
                  offset: Offset(2, 2),
                  blurRadius: 6,
                ),
              ]
            : [
                // Hiệu ứng nổi bình thường
                const BoxShadow(
                  color: Colors.white,
                  offset: Offset(-5, -5),
                  blurRadius: 10,
                ),
                const BoxShadow(
                  color: Color(0xFFA6BCCF),
                  offset: Offset(5, 5),
                  blurRadius: 10,
                ),
              ],
      ),
      child: child,
    );
  }
}

class NeumorphicButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;

  const NeumorphicButton({
    super.key,
    required this.child,
    this.onPressed,
    this.width,
    this.height,
    this.borderRadius,
  });

  @override
  State<NeumorphicButton> createState() => _NeumorphicButtonState();
}

class _NeumorphicButtonState extends State<NeumorphicButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.onPressed != null
          ? (_) => setState(() => _isPressed = true)
          : null,
      onTapUp: widget.onPressed != null
          ? (_) {
              setState(() => _isPressed = false);
              widget.onPressed?.call();
            }
          : null,
      onTapCancel: () => setState(() => _isPressed = false),
      child: NeumorphicContainer(
        width: widget.width,
        height: widget.height,
        isActive: _isPressed,
        borderRadius: widget.borderRadius,
        child: widget.child,
      ),
    );
  }
}
