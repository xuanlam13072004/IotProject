import 'package:flutter/material.dart';
import 'package:another_flushbar/flushbar.dart';

class NotificationService {
  static void show(BuildContext context, String message, bool isError) {
    Flushbar(
      message: message,
      duration: const Duration(seconds: 3),
      backgroundColor: isError ? Colors.red : Colors.green,
      icon: Icon(
        isError ? Icons.error_outline : Icons.check_circle_outline,
        color: Colors.white,
        size: 28,
      ),
      leftBarIndicatorColor: Colors.white,
      flushbarPosition: FlushbarPosition.TOP,
      margin: const EdgeInsets.all(8),
      borderRadius: BorderRadius.circular(12),
      boxShadows: const [
        BoxShadow(
          color: Colors.black26,
          offset: Offset(0, 2),
          blurRadius: 6,
        ),
      ],
    ).show(context);
  }
}
