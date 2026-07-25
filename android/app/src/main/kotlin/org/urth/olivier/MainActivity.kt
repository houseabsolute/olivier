package org.urth.olivier

import com.ryanheise.audioservice.AudioServiceActivity

// Must extend AudioServiceActivity, not FlutterActivity: audio_service looks up
// the running FlutterEngine through it, and without that `AudioService.init()`
// never completes — main() blocks before runApp() and the app sits on the
// launch splash forever, rendering zero frames with no error surfaced to Dart.
class MainActivity : AudioServiceActivity()
