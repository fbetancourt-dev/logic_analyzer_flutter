import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import '../models/capture_data.dart';

class SrExporter {
  /// Export capture as a standard Sigrok .sr file (zip container)
  static Future<File> exportToSigrokFile(CaptureData capture, {String? fileName}) async {
    final archive = Archive();

    // 1. Version file
    final versionContent = utf8.encode('2\n');
    archive.addFile(ArchiveFile('version', versionContent.length, versionContent));

    // 2. Metadata file
    final metadataString = StringBuffer();
    metadataString.writeln('[global]');
    metadataString.writeln('sigrok version=0.5.2');
    metadataString.writeln();
    metadataString.writeln('[device 1]');
    metadataString.writeln('capturefile=logic-1');
    metadataString.writeln('total probes=${capture.numChannels}');
    metadataString.writeln('samplerate=${capture.sampleRate} Hz');
    metadataString.writeln('total analog=0');
    for (int i = 0; i < capture.numChannels; i++) {
      metadataString.writeln('probe${i + 1}=D$i');
    }
    metadataString.writeln('unitsize=1');

    final metadataContent = utf8.encode(metadataString.toString());
    archive.addFile(ArchiveFile('metadata', metadataContent.length, metadataContent));

    // 3. Logic data chunks (each chunk typically up to 4MB)
    const chunkSize = 4 * 1024 * 1024;
    final totalBytes = capture.rawSamples.length;
    int chunkIndex = 1;
    int offset = 0;

    if (totalBytes == 0) {
      archive.addFile(ArchiveFile('logic-1-1', 0, Uint8List(0)));
    } else {
      while (offset < totalBytes) {
        final end = (offset + chunkSize < totalBytes) ? offset + chunkSize : totalBytes;
        final chunk = capture.rawSamples.sublist(offset, end);
        archive.addFile(ArchiveFile('logic-1-$chunkIndex', chunk.length, chunk));
        offset = end;
        chunkIndex++;
      }
    }

    // Encode zip
    final zipData = ZipEncoder().encode(archive);
    if (zipData == null) {
      throw Exception('Failed to generate zip archive for .sr file');
    }

    final tempDir = await getTemporaryDirectory();
    final name = fileName ?? 'capture_${DateTime.now().millisecondsSinceEpoch}.sr';
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(zipData);
    return file;
  }

  /// Export as plain CSV
  static Future<File> exportToCsv(CaptureData capture, {int maxRows = 100000}) async {
    final buffer = StringBuffer();
    buffer.write('Time (s)');
    for (int c = 0; c < capture.numChannels; c++) {
      buffer.write(',D$c');
    }
    buffer.writeln();

    final limit = capture.totalSamples < maxRows ? capture.totalSamples : maxRows;
    final dt = 1.0 / capture.sampleRate;

    for (int i = 0; i < limit; i++) {
      buffer.write((i * dt).toStringAsFixed(8));
      final byte = capture.rawSamples[i];
      for (int c = 0; c < capture.numChannels; c++) {
        buffer.write(',${(byte >> c) & 1}');
      }
      buffer.writeln();
    }

    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/capture_${DateTime.now().millisecondsSinceEpoch}.csv');
    await file.writeAsString(buffer.toString());
    return file;
  }
}
