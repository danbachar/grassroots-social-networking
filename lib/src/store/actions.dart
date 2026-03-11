/// Base class for all actions
abstract class AppAction {}

// ===== Connection Status Actions =====

/// Set connection status to initializing
class SetInitializingAction extends AppAction {}

/// Set connection status to online (active but not scanning)
class SetOnlineAction extends AppAction {}

/// Set connection status to error with message
class SetErrorAction extends AppAction {
  final String message;
  SetErrorAction(this.message);
}

// ===== Scanning Actions =====

/// Scanning started
class ScanStartedAction extends AppAction {}

/// Scanning completed
class ScanCompletedAction extends AppAction {}
