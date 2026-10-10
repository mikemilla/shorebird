import 'package:flutter/material.dart';
import 'package:shorebird_update_ui/shorebird_update_ui.dart';

/// Changed by each patch so you can see which code is running.
const label = 'release 1.0.0+3';

void main() => runApp(const PushDemoApp());

class PushDemoApp extends StatelessWidget {
  const PushDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // The gate covers every route. Pass bannerBuilder / wallBuilder to use
      // your own widgets instead of the defaults.
      builder: (context, child) => UpdateGate(child: child!),
      home: const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Text(
            'Running: $label',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 32),
          ),
        ),
      ),
    );
  }
}
