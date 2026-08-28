/// Shell only. The measurement lives in integration_test/fanout_test.dart,
/// which is what `flutter test` actually runs on the handset.
library;

import 'package:flutter/material.dart';

void main() => runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('udx fan-out probe'))),
    ));
