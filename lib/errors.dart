class AppError implements Exception {
  final String message;
  const AppError(this.message);

  @override
  String toString() => message;
}

String friendlyError(Object e) {
  if (e is AppError) return e.message;
  final s = e.toString().toLowerCase();
  if (s.contains('no space') || s.contains('enospc')) {
    return 'Not enough storage space.';
  }
  if (s.contains('password') || s.contains('encrypted')) {
    return 'This PDF is password protected.';
  }
  return 'PDF processing failed. Please try again.';
}
