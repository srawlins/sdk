import 'dart:async';

import 'package:front_end/kernel_generator.dart';
import 'package:front_end/compiler_options.dart';
import 'package:kernel/binary/ast_to_binary.dart';
import 'package:kernel/kernel.dart' show Program;

Future dumpToSink(Program program, StreamSink<List<int>> sink) {
  new BinaryPrinter(sink).writeProgramFile(program);
  return sink.close();
}

Future kernelToSink(Uri entry, StreamSink<List<int>> sink) async {
  var program = await kernelForProgram(entry,
      new CompilerOptions()
        ..sdkPath = 'sdk'
        ..packagesFilePath = '.packages'
        ..onError = (e) => print(e.message));

  await dumpToSink(program, sink);
}

main(args) async {
  kernelToSink(Uri.base.resolve(args[0]),
      // TODO(sigmund,hausner): define memory type where to dump binary data.
      new StreamController<List<int>>.broadcast().sink);
}
