import 'package:flutter/material.dart';
import 'package:olivier/src/rust/api/simple.dart';
import 'package:olivier/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const OlivierApp());
}

class OlivierApp extends StatelessWidget {
  const OlivierApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Olivier',
      home: Scaffold(
        appBar: AppBar(title: const Text('Olivier')),
        body: Center(child: Text(olivierVersion())),
      ),
    );
  }
}
