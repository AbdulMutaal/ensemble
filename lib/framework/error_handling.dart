import 'package:jsparser/jsparser.dart';

class ConfigError extends Error {
  ConfigError(this.error);
  final String error;

  @override
  String toString() => 'Config Error: $error';
}


/// Language Error will be exposed on Studio
class LanguageError extends Error {
  LanguageError (this.error, {this.recovery});

  String error;
  String? recovery;

  @override
  String toString() {
    return 'Error: $error. ' + (recovery ?? '');
  }
}

class CodeError extends EnsembleError {
  late String message;
  CodeError(dynamic error) {
    if (error is ParseError) {
      message = "Code Error: ${error.message}.\n(Line ${error.line}. Position ${error.startOffset}-${error.endOffset}).";
    } else {
      message = "Code Error: ${error.toString()}";
    }
  }

  @override
  String toString() => message;

}

class RuntimeError extends EnsembleError {
  String message;
  RuntimeError(this.message);

  @override
  String toString() => "Runtime Error: $message";
}

abstract class EnsembleError extends Error {
}


/// All Exceptions will be written to a running log of some sort
class RuntimeException implements Exception {
  RuntimeException(this.message);
  String message;

  @override
  String toString() {
    return 'Exception: $message';
  }
}