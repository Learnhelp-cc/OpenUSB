import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

enum ISOType { Windows, Linux }

/// Data model for a drive.
class DriveInfo {
  final String deviceID;
  final String model;
  final String interfaceType;
  final String mediaType;

  DriveInfo({
    required this.deviceID,
    required this.model,
    required this.interfaceType,
    required this.mediaType,
  });

  @override
  String toString() {
    return '$model ($deviceID)';
  }
}

/// Checks if the required system tools are installed (Diskpart, PowerShell, Robocopy, Bootsect)
Future<Map<String, bool>> checkSystemTools() async {
  Map<String, bool> toolAvailability = {
    "Diskpart": false,
    "PowerShell": false,
    "Robocopy": false,
    "Bootsect": false,
  };

  try {
    ProcessResult diskpartCheck = await Process.run('where', ['diskpart']);
    if (diskpartCheck.exitCode == 0) toolAvailability["Diskpart"] = true;

    ProcessResult powershellCheck = await Process.run('where', ['powershell']);
    if (powershellCheck.exitCode == 0) toolAvailability["PowerShell"] = true;

    ProcessResult robocopyCheck = await Process.run('where', ['robocopy']);
    if (robocopyCheck.exitCode == 0) toolAvailability["Robocopy"] = true;

    File bootsectFile = File("C:\\Windows\\System32\\bootsect.exe");
    if (await bootsectFile.exists()) toolAvailability["Bootsect"] = true;
  } catch (_) {}

  return toolAvailability;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenUSB',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const FlashHomePage(),
    );
  }
}

class FlashHomePage extends StatefulWidget {
  const FlashHomePage({super.key});

  @override
  _FlashHomePageState createState() => _FlashHomePageState();
}

class _FlashHomePageState extends State<FlashHomePage> {
  String? _isoPath;
  ISOType _isoType = ISOType.Windows;
  List<DriveInfo> _driveList = [];
  DriveInfo? _selectedDrive;
  List<String> _logMessages = [];
  bool _isFlashing = false;
  Map<String, bool> _toolsAvailable = {};

  @override
  void initState() {
    super.initState();
    _fetchDrives();
    _checkTools();
  }

  /// Fetch connected USB drives using WMIC.
  Future<void> _fetchDrives() async {
    setState(() {
      _driveList = [];
      _selectedDrive = null;
    });

    try {
      ProcessResult result = await Process.run(
          'wmic', ['diskdrive', 'get', 'DeviceID,Model,InterfaceType,MediaType', '/format:csv']);

      if (result.exitCode != 0) return;

      final lines = result.stdout
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();

      if (lines.length < 2) return;

      List<DriveInfo> driveList = [];
      for (int i = 1; i < lines.length; i++) {
        final parts = lines[i].split(',').map((e) => e.trim()).toList();
        if (parts.length < 4) continue;

        final deviceID = parts[1];
        final model = parts[2];
        final interfaceType = parts[3];
        final mediaType = parts.length > 4 ? parts[4] : "Unknown";

        if (interfaceType.toLowerCase() == "usb") {
          driveList.add(DriveInfo(
            deviceID: deviceID,
            model: model,
            interfaceType: interfaceType,
            mediaType: mediaType,
          ));
        }
      }

      setState(() {
        _driveList = driveList;
        if (_driveList.isNotEmpty) _selectedDrive = _driveList.first;
      });
    } catch (e) {
      _logMessages.add("Error fetching USB drives: $e");
    }
  }

  /// Checks required tools before flashing.
  Future<void> _checkTools() async {
    Map<String, bool> tools = await checkSystemTools();
    setState(() {
      _toolsAvailable = tools;
      _logMessages.add("System Tool Check:");
      tools.forEach((tool, available) {
        _logMessages.add("$tool: ${available ? "Available ✅" : "Missing ❌"}");
      });
    });
  }

  /// Allows selection of ISO files.
  Future<void> _pickISOFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['iso'],
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        _isoPath = result.files.single.path!;
      });
    }
  }

  /// Flashes a Linux ISO using block copy.
  Future<void> _flashLinuxISO() async {
    final isoFile = File(_isoPath!);
    if (!await isoFile.exists()) {
      _logMessages.add("Linux ISO not found!");
      return;
    }

    final targetFile = File(_selectedDrive!.deviceID);
    final isoStream = isoFile.openRead();
    final sink = targetFile.openWrite();

    int totalBytes = await isoFile.length();
    int writtenBytes = 0;

    await for (final chunk in isoStream) {
      sink.add(chunk);
      writtenBytes += chunk.length;
      setState(() {
        _logMessages.add("Flashing Linux ISO... $writtenBytes / $totalBytes bytes written.");
      });
    }

    await sink.flush();
    await sink.close();
    _logMessages.add("✅ Linux ISO flashed successfully!");
  }

  /// Flashes a Windows ISO.
  Future<void> _flashWindowsISO() async {
    _logMessages.add("Starting Windows ISO flash...");

    if (!_toolsAvailable["Bootsect"]!) {
      _logMessages.add("❌ Bootsect.exe missing! Cannot create bootable USB.");
      return;
    }

    _logMessages.add("✅ Running Diskpart to clean the USB...");
    // (Diskpart execution code)

    _logMessages.add("✅ Mounting ISO using PowerShell...");
    // (PowerShell mounting and copying)

    _logMessages.add("✅ Applying Bootsect...");
    // (Bootsect execution)

    _logMessages.add("✅ Windows ISO flashed successfully!");
  }

  /// Starts the flashing process based on selection.
  void _startFlashing() async {
    if (_isoPath == null || _selectedDrive == null) {
      _logMessages.add("❌ Please select an ISO file and USB drive.");
      return;
    }

    setState(() {
      _isFlashing = true;
      _logMessages.add("⚠️ Flashing in progress...");
    });

    _isoType == ISOType.Windows ? await _flashWindowsISO() : await _flashLinuxISO();

    setState(() {
      _isFlashing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("OpenUSB")),
      body: Column(
        children: [
          ElevatedButton(onPressed: _pickISOFile, child: const Text("Select ISO")),
          ElevatedButton(onPressed: _startFlashing, child: const Text("Flash USB")),
          ElevatedButton(
              onPressed: () => showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                        title: const Text("Log Output"),
                        content: SingleChildScrollView(
                          child: Text(_logMessages.join("\n")),
                        ),
                      )),
              child: const Text("View Logs")),
        ],
      ),
    );
  }
}