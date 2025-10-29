import 'dart:convert';
import 'dart:io' show File;

import 'package:crypto/crypto.dart' as crypto;
import 'package:encrypt/encrypt.dart' as enc;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CloneSettingsApp());
}

class CloneSettingsApp extends StatelessWidget {
  const CloneSettingsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CloneSettings Crypto',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const CryptoHomePage(),
    );
  }
}

enum KeyMethod { auto, dynamicKey, fixedKey }

class CryptoHomePage extends StatefulWidget {
  const CryptoHomePage({super.key});

  @override
  State<CryptoHomePage> createState() => _CryptoHomePageState();
}

class _CryptoHomePageState extends State<CryptoHomePage> {
  // Constants copied from Python script
  static const String keySuffix = "/I am the one who knocks!";
  static const String fileNamePrefix = "I'll be back.";
  static const String fixedKeyString = "UYGy723!Po-efjve"; // 16 chars

  final TextEditingController _packageController =
      TextEditingController(text: "com.crypto.tool");
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _outputController = TextEditingController();

  KeyMethod _method = KeyMethod.auto;
  bool _busy = false;
  List<PlatformFile> _selectedFiles = [];
  String? _filesInfo;

  enc.Key _deriveDynamicKey(String packageName) {
    final str = packageName + keySuffix;
    final digest = crypto.md5.convert(utf8.encode(str));
    return enc.Key(Uint8List.fromList(digest.bytes));
  }

  enc.Key _fixedKey() {
    // In Python: return FIXED_KEY.encode('utf-8') (16 bytes)
    return enc.Key.fromUtf8(fixedKeyString);
  }

  enc.Encrypter _buildEncrypter(enc.Key key) {
    return enc.Encrypter(
      enc.AES(key, mode: enc.AESMode.ecb, padding: 'PKCS7'),
    );
  }

  String _sanitizeBase64(String s) => s.replaceAll(RegExp(r"\s+"), "");

  Future<void> _decryptFromInput() async {
    final pkg = _packageController.text.trim();
    final raw = _sanitizeBase64(_inputController.text.trim());
    if (pkg.isEmpty || raw.isEmpty) {
      _snack('Enter package name and Base64 input');
      return;
    }
    setState(() => _busy = true);
    try {
      String? result;
      String used = '';

      Future<String> tryDynamic() async {
        final key = _deriveDynamicKey(pkg);
        final dec = _buildEncrypter(key)
            .decrypt(enc.Encrypted.fromBase64(raw));
        return dec;
      }

      Future<String> tryFixed() async {
        final key = _fixedKey();
        final dec = _buildEncrypter(key)
            .decrypt(enc.Encrypted.fromBase64(raw));
        return dec;
      }

      switch (_method) {
        case KeyMethod.dynamicKey:
          result = await tryDynamic();
          used = 'DYNAMIC';
          break;
        case KeyMethod.fixedKey:
          result = await tryFixed();
          used = 'FIXED';
          break;
        case KeyMethod.auto:
          try {
            result = await tryDynamic();
            used = 'DYNAMIC';
          } catch (_) {
            result = await tryFixed();
            used = 'FIXED';
          }
          break;
      }

      // Pretty print JSON when possible
      try {
        final jsonObj = json.decode(result) as Object;
        final pretty = const JsonEncoder.withIndent('  ').convert(jsonObj);
        _outputController.text = pretty;
        // Auto-save the decrypted settings
        if (!kIsWeb && _selectedFiles.isNotEmpty) {
          final firstFile = _selectedFiles.first;
          if (firstFile.path != null) {
            final dir = File(firstFile.path!).parent;
            final saveFile = File('${dir.path}/cloneSettings.json');
            await saveFile.writeAsString(pretty);
            _snack('Decrypted and saved to ${saveFile.path}');
          } else {
            _snack('Decrypted successfully using $used');
          }
        } else {
          _snack('Decrypted successfully using $used');
        }
      } catch (_) {
        _outputController.text = result;
        _snack('Decrypted successfully using $used');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Decrypt error: $e');
      }
      _snack('Decryption failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _encryptFromInput() async {
    final pkg = _packageController.text.trim();
    final plain = _outputController.text;
    if (pkg.isEmpty || plain.isEmpty) {
      _snack('Enter package name and plaintext to encrypt');
      return;
    }
    if (_method == KeyMethod.auto) {
      _snack('Choose Dynamic or Fixed for encryption');
      return;
    }
    setState(() => _busy = true);
    try {
      final key = _method == KeyMethod.dynamicKey
          ? _deriveDynamicKey(pkg)
          : _fixedKey();
      final encBase64 = _buildEncrypter(key)
          .encrypt(plain)
          .base64;
      _inputController.text = encBase64;
      _snack('Encrypted successfully');
    } catch (e) {
      _snack('Encryption failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  // Generate expected MD5 UPPERCASE names from Python logic
  String _expectedName(String packageName, int index) {
    final s = '$packageName$fileNamePrefix$index';
    final dig = crypto.md5.convert(utf8.encode(s)).bytes;
    final hex = dig.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return hex.toUpperCase();
  }

  Future<void> _pickFilesAndAssemble() async {
    final pkg = _packageController.text.trim();
    if (pkg.isEmpty) {
      _snack('Enter package name first');
      return;
    }
    try {
      setState(() => _busy = true);
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: !kIsWeb, // web provides bytes in memory
      );
      if (result == null) {
        setState(() => _busy = false);
        return;
      }
      _selectedFiles = result.files;

      // Sort files by name to ensure consistent order
      _selectedFiles.sort((a, b) => a.name.compareTo(b.name));

      final buffer = StringBuffer();
      for (final f in _selectedFiles) {
        String content;
        if (kIsWeb) {
          // On web, PlatformFile.bytes is used
          content = utf8.decode(f.bytes ?? Uint8List(0));
        } else {
          if (f.path != null) {
            content = await File(f.path!).readAsString();
          } else {
            content = utf8.decode(f.bytes ?? Uint8List(0));
          }
        }
        buffer.write(_sanitizeBase64(content));
      }

      final assembled = buffer.toString();
      _filesInfo = 'Assembled ${_selectedFiles.length} file(s), total length: ${assembled.length}';
      if (assembled.isEmpty) {
        _snack('No matching resource files found in selection');
        setState(() {});
        return;
      }
      _inputController.text = assembled;
      _snack('Assembly complete');
      setState(() {});
    } catch (e) {
      _snack('File pick/assembly failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  void _copyOutput() async {
    final text = _outputController.text;
    if (text.isEmpty) {
      _snack('Nothing to copy');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _snack('Copied to clipboard');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isBusy = _busy;
    return Scaffold(
      appBar: AppBar(
        title: const Text('CloneSettings Crypto (AES/ECB/PKCS7)'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _packageController,
                decoration: const InputDecoration(
                  labelText: 'Package Name',
                  hintText: 'e.g. com.crypto.tool',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Key Method:'),
                  ChoiceChip(
                    label: const Text('Auto (decrypt only)'),
                    selected: _method == KeyMethod.auto,
                    onSelected: isBusy
                        ? null
                        : (v) {
                            if (v) setState(() => _method = KeyMethod.auto);
                          },
                  ),
                  ChoiceChip(
                    label: const Text('Dynamic'),
                    selected: _method == KeyMethod.dynamicKey,
                    onSelected: isBusy
                        ? null
                        : (v) {
                            if (v) setState(() => _method = KeyMethod.dynamicKey);
                          },
                  ),
                  ChoiceChip(
                    label: const Text('Fixed'),
                    selected: _method == KeyMethod.fixedKey,
                    onSelected: isBusy
                        ? null
                        : (v) {
                            if (v) setState(() => _method = KeyMethod.fixedKey);
                          },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: isBusy ? null : _pickFilesAndAssemble,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Pick resource files and assemble'),
                    ),
                  ),
                ],
              ),
              if (_filesInfo != null) ...[
                const SizedBox(height: 8),
                Text(_filesInfo!),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _inputController,
                minLines: 4,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: 'Encrypted Base64 (assembled)',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: isBusy ? null : _decryptFromInput,
                      icon: const Icon(Icons.lock_open),
                      label: const Text('Decrypt'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: isBusy ? null : _encryptFromInput,
                      icon: const Icon(Icons.lock),
                      label: const Text('Encrypt (uses selected method)'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _outputController,
                minLines: 6,
                maxLines: 16,
                decoration: const InputDecoration(
                  labelText: 'Decrypted plaintext (JSON or raw) / Plaintext to encrypt',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: isBusy ? null : _copyOutput,
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy output'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              const Text(
                'Notes',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              const Text(
                '• Dynamic key = MD5(packageName + \'/I am the one who knocks!\') (16 bytes)\n'
                '• Fixed key = UYGy723!Po-efjve (16 bytes)\n'
                '• AES/ECB/PKCS7 with Base64 encoding, matching the Python script.\n'
                '• File assembly expects names derived from MD5(package + "I\'ll be back." + index) in UPPERCASE.\n'
                '• On decrypt Auto mode tries Dynamic first then Fixed.',
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
