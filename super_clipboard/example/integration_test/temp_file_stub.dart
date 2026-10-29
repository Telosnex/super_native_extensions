/// No files on the web: the file URI tests are skipped there.
Future<Uri> createTempFile(String name, String contents) =>
    throw UnsupportedError('no files on the web');
