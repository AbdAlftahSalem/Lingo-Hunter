import 'dart:convert';
import 'dart:io';

import 'package:translator/translator.dart';

abstract class LingoHunter {
  /// Extracts translatable strings from a Flutter project and generates translation files
  static Future<void> extractAndCreateTranslationFiles({
    required String baseLang,
    required List<String> langs,
    String? projectDirectory,
    String? outputDirectory,
    bool translateBaseLang = true,
    List<RegExp>? additionalRegExps,
    bool overrideRegExps = false,
    List<String> fileExtensions = const ['.dart'],
  }) async {
    final String projectRoot = projectDirectory ?? await _findLibDirectory();
    final String outputDir = outputDirectory ?? projectRoot;

    print("Project root directory: $projectRoot");
    print("Output directory: $outputDir");

    final Set<String> strings = await extractStringsFromFlutterProject(
      directory: projectRoot,
      additionalRegExps: additionalRegExps,
      overrideRegExps: overrideRegExps,
      fileExtensions: fileExtensions,
    );

    await _createTranslationFiles(
      strings: strings,
      outputDirectory: outputDir,
      baseLang: baseLang,
      langs: langs,
      translateBaseLang: translateBaseLang,
    );

    print("Successfully extracted strings and generated translation files.");
  }

  static Future<String> _findLibDirectory() async {
    Directory current = Directory.current;

    while (true) {
      if (await File('${current.path}/pubspec.yaml').exists()) {
        final libPath = '${current.path}/lib';
        if (await Directory(libPath).exists()) {
          return libPath;
        } else {
          print(
              "Warning: 'lib' directory not found. Returning project root instead.");
          return current.path;
        }
      }

      if (current.path == current.parent.path) {
        break;
      }

      current = current.parent;
    }

    print(
        "Warning: `pubspec.yaml` not found. Using current directory as project root.");
    return Directory.current.path;
  }

  static Future<Set<String>> extractStringsFromFlutterProject({
    required String directory,
    List<RegExp>? additionalRegExps,
    bool overrideRegExps = false,
    List<String> fileExtensions = const ['.dart'],
  }) async {
    final List<RegExp> defaultPatterns = [
      RegExp(r'"([^"]+)"\.tr\(\)'),
      RegExp(r"'([^']+)'\.tr\(\)"),
      RegExp(r'"([^"]+)"\.tr'),
      RegExp(r"'([^']+)'\.tr"),
      RegExp(r'"([^"]+)"\.tr\(\w+\)'),
      RegExp(r"'([^']+)'\.tr\(\w+\)"),
      RegExp(r'context\.tr\("([^"]+)"\)'),
      RegExp(r"context\.tr\('([^']+)'\)"),
      RegExp(r'tr\(\w+, "([^"]+)"\)'),
      RegExp(r"tr\(\w+, '([^']+)'\)"),
      RegExp(r'tr\("([^"]+)"\)'),
      RegExp(r"tr\('([^']+)'\)"),
      RegExp(r'"([^"]+)"\.tr\(args: \[.*?\]\)'),
      RegExp(r'"([^"]+)"\.plural\(\d+\)'),
      RegExp(r'AppLocalizations\.of\(context\)!\.translate\("([^"]+)"\)'),
    ];

    List<RegExp> patterns;
    if (overrideRegExps && additionalRegExps != null) {
      patterns = additionalRegExps;
    } else {
      patterns = [...defaultPatterns];
      if (additionalRegExps != null) {
        patterns.addAll(additionalRegExps);
      }
    }

    final Set<String> strings = {};
    final Directory projectDirObj = Directory(directory);
    final List<FileSystemEntity> entities =
        await projectDirObj.list(recursive: true).toList();
    final List<File> filteredFiles = entities
        .whereType<File>()
        .where((file) => fileExtensions.any((ext) => file.path.endsWith(ext)))
        .toList();

    for (final File file in filteredFiles) {
      final String content = await file.readAsString();
      for (final RegExp pattern in patterns) {
        final Iterable<RegExpMatch> matches = pattern.allMatches(content);
        for (final RegExpMatch match in matches) {
          if (match.groupCount >= 1 && match.group(1) != null) {
            strings.add(match.group(1)!);
          }
        }
      }
    }

    return strings;
  }

  static Future<void> _createTranslationFiles({
    required Set<String> strings,
    required String outputDirectory,
    required String baseLang,
    required List<String> langs,
    bool translateBaseLang = true,
  }) async {
    final Directory outputDir = Directory(outputDirectory);
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }

    final translator = GoogleTranslator();

    final String baseFilePath = '$outputDirectory/translations_$baseLang.json';
    final Map<String, String> baseStrings = {
      for (final string in strings) string: translateBaseLang ? string : ""
    };
    await _writeTranslationFile(baseFilePath, baseStrings);

    for (final String lang in langs) {
      final String langFilePath = '$outputDirectory/translations_$lang.json';
      final Map<String, String> langStrings = {};

      // Perform batch translation for the target language
      await _batchTranslate(strings, lang, translator).then((translations) {
        for (int i = 0; i < strings.length; i++) {
          langStrings[strings.elementAt(i)] = translations[i];
        }
      }).catchError((e) {
        print("Error during batch translation to '$lang': $e");
      });

      await _writeTranslationFile(langFilePath, langStrings);
      print("Translation file created: $langFilePath");
    }
  }

  static Future<List<String>> _batchTranslate(
      Set<String> strings, String lang, GoogleTranslator translator) async {
    final List<String> batch = strings.toList();

    // Use Future.wait to translate multiple strings in parallel
    final results = await Future.wait(
      batch.map((text) async {
        try {
          final translatedText =
              await translator.translate(text, from: 'en', to: lang);
          return translatedText.text;
        } catch (e) {
          print("Error translating '$text' to '$lang': $e");
          return ''; // Fallback if translation fails
        }
      }),
    );

    return results;
  }

  static Future<void> _writeTranslationFile(
      String filePath, Map<String, String> strings) async {
    final File file = File(filePath);
    final StringBuffer content = StringBuffer();
    content.writeln('{');

    int index = 0;
    for (final MapEntry<String, String> entry in strings.entries) {
      final String comma = (index < strings.length - 1) ? ',' : '';
      final String key =
          jsonEncode(entry.key).substring(1, jsonEncode(entry.key).length - 1);
      final String value = entry.value.isEmpty
          ? ""
          : jsonEncode(entry.value)
              .substring(1, jsonEncode(entry.value).length - 1);

      content.writeln('    "$key": "$value"$comma');
      index++;
    }

    content.writeln('}');
    await file.writeAsString(content.toString());
  }
}
