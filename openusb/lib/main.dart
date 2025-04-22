import 'dart:io';
import 'dart:async';
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

/// Checks if the application is running with admin privileges by using "net session"
Future<bool> isAdmin() async {
  try {
    ProcessResult result = await Process.run("net", ["session"]);
    return result.exitCode == 0;
  } catch (e) {
    return false;
  }
}

/// A screen to show if admin rights are missing.
class AdminRequiredApp extends StatelessWidget {
  const AdminRequiredApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Administrator Required",
      home: Scaffold(
        appBar: AppBar(
          title: const Text("Administrator Required"),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.admin_panel_settings, size: 80, color: Colors.red),
                const SizedBox(height: 20),
                const Text(
                  "This application must be run as an administrator.\n\nPlease restart it with elevated privileges.",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: () {
                    exit(0);
                  },
                  icon: const Icon(Icons.exit_to_app),
                  label: const Text("Exit"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  bool admin = await isAdmin();
  if (!admin) {
    runApp(const AdminRequiredApp());
    return;
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenUSB',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
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
  double? _progress;
  bool _isFlashing = false;
  ISOType _isoType = ISOType.Windows; // default choice

  List<DriveInfo> _driveList = [];
  DriveInfo? _selectedDrive;

  @override
  void initState() {
    super.initState();
    _fetchDrives();
  }

  /// Enumerates USB drives using WMIC (filters for InterfaceType == "USB")
  Future<void> _fetchDrives() async {
    setState(() {
      _driveList = [];
      _selectedDrive = null;
    });
    try {
      ProcessResult result = await Process.run(
          'wmic',
          ['diskdrive', 'get', 'DeviceID,Model,InterfaceType,MediaType', '/format:csv']);

      if (result.exitCode != 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error enumerating drives: ${result.stderr}")),
        );
        return;
      }

      final output = result.stdout as String;
      final lines = output
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      if (lines.length < 2) return;

      // Parse CSV header.
      final headers =
          lines.first.split(',').map((e) => e.trim().toLowerCase()).toList();
      Map<String, int> colIndex = {};
      for (int i = 0; i < headers.length; i++) {
        colIndex[headers[i]] = i;
      }

      List<DriveInfo> driveList = [];
      for (int i = 1; i < lines.length; i++) {
        final parts =
            lines[i].split(',').map((e) => e.trim()).toList();
        if (parts.length < headers.length) continue;

        final deviceID = parts[colIndex['deviceid']!];
        final model = parts[colIndex['model']!];
        final interfaceType = parts[colIndex['interfacetype']!];
        final mediaType = parts[colIndex['mediatype']!];

        if (interfaceType.toLowerCase() == 'usb') {
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Exception while fetching drives: $e")),
      );
    }
  }

  /// Allows the user to select an ISO via file picker.
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

  /// Flashes a Linux ISO (using a dd-style block copy).
  Future<void> flashLinuxISO(String isoPath, DriveInfo drive) async {
    final isoFile = File(isoPath);
    if (!await isoFile.exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Error: ISO file not found.")));
      setState(() {
        _isFlashing = false;
      });
      return;
    }
    IOSink? deviceSink;
    try {
      // On Windows, the raw device path (e.g., "\\.\PhysicalDriveX") is used for block copy.
      final targetFile = File(drive.deviceID);
      deviceSink = targetFile.openWrite(mode: FileMode.write);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error opening device: $e")));
      setState(() {
        _isFlashing = false;
      });
      return;
    }
    final int totalFileSize = await isoFile.length();
    int totalBytesWritten = 0;
    final isoStream = isoFile.openRead();

    try {
      await for (final data in isoStream) {
        deviceSink.add(data);
        totalBytesWritten += data.length;
        setState(() {
          _progress = totalBytesWritten / totalFileSize;
        });
      }
    } catch (e) {
      await deviceSink.close();
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error during Linux-ISO flashing: $e")));
      setState(() {
        _isFlashing = false;
        _progress = null;
      });
      return;
    }
    await deviceSink.flush();
    await deviceSink.close();

    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Linux ISO flashed successfully.")));
    setState(() {
      _isFlashing = false;
      _progress = null;
    });
  }

  /// Flashes a Windows ISO by:
  /// 1. Running Diskpart to clean/format the USB drive.
  /// 2. Mounting the ISO via PowerShell.
  /// 3. Copying its contents via Robocopy.
  /// 4. Running Bootsect to update the boot code.
  Future<void> flashWindowsISO(String isoPath, DriveInfo drive) async {
    // Extract disk number from deviceID (e.g., "\\.\PHYSICALDRIVE1" → "1")
    final regex = RegExp(r'PhysicalDrive(\d+)', caseSensitive: false);
    final match = regex.firstMatch(drive.deviceID);
    if (match == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Error: Unable to extract disk number.")));
      setState(() {
        _isFlashing = false;
      });
      return;
    }
    final diskNumber = match.group(1);
    if (diskNumber == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Error: Disk number not found.")));
      setState(() {
        _isFlashing = false;
      });
      return;
    }
    // Use a fixed USB drive letter (ensure it's free); here we choose Z:
    const String usbLetter = "Z";

    // Build a Diskpart script.
    String diskpartScript = '''
select disk $diskNumber
clean
create partition primary
format fs=FAT32 quick
active
assign letter=$usbLetter
exit
''';
    // Write the Diskpart script to a temporary file.
    final tempDir = Directory.systemTemp;
    final dpScriptFile = File('${tempDir.path}\\diskpart_script.txt');
    await dpScriptFile.writeAsString(diskpartScript);

    // Run Diskpart.
    ProcessResult dpResult =
        await Process.run('diskpart', ['/s', dpScriptFile.path]);
    if (dpResult.exitCode != 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Diskpart error: ${dpResult.stderr}")));
      setState(() {
        _isFlashing = false;
      });
      return;
    }

    // Mount the ISO via PowerShell:
    String mountCommand =
        "Mount-DiskImage -ImagePath '$isoPath'";
    ProcessResult mountResult =
        await Process.run('powershell', ['-Command', mountCommand]);
    // Wait a few seconds to allow the ISO to mount.
    await Future.delayed(const Duration(seconds: 3));

    // Get the drive letter of the mounted ISO.
    String getLetterCommand =
        "(Get-DiskImage -ImagePath '$isoPath' | Get-Volume).DriveLetter";
    ProcessResult getLetterResult =
        await Process.run('powershell', ['-Command', getLetterCommand]);
    String isoDriveLetter = (getLetterResult.stdout as String).trim();
    if (isoDriveLetter.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Error: Unable to mount ISO.")));
      setState(() {
        _isFlashing = false;
      });
      return;
    }
    // Construct the mounted ISO drive path (e.g., "E:\").
    isoDriveLetter = '$isoDriveLetter:\\';

    // Use Robocopy to copy all files from the mounted ISO to the USB drive.
    ProcessResult robocopyResult = await Process.run(
        'robocopy', [isoDriveLetter, "$usbLetter:\\", '/E']);
    // Robocopy returns a numeric exit code which is a bitmask;
    // codes 0-7 indicate success.
    if ((robocopyResult.exitCode as int) > 7) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Robocopy error: ${robocopyResult.stderr}")));
      setState(() {
        _isFlashing = false;
      });
      return;
    }

    // Run Bootsect to update the boot code. (Assumes bootsect.exe is in PATH.)
    ProcessResult bootsectResult =
        await Process.run('bootsect', ['/nt60', "$usbLetter:"]);
    if (bootsectResult.exitCode != 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Bootsect error: ${bootsectResult.stderr}")));
      setState(() {
        _isFlashing = false;
      });
      return;
    }

    // Dismount the ISO.
    String dismountCommand =
        "Dismount-DiskImage -ImagePath '$isoPath'";
    await Process.run('powershell', ['-Command', dismountCommand]);

    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Windows ISO flashed successfully.")));
    setState(() {
      _isFlashing = false;
      _progress = null;
    });
  }

  /// Initiates flashing based on the selected ISO type.
  void _startFlashing() async {
    if (_isoPath == null || _selectedDrive == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text("Please select an ISO file and a target drive.")),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Confirm Flash"),
        content: Text(
          "WARNING: FLASHING WILL ERASE ALL DATA ON THE SELECTED DEVICE PERMANENTLY.\n\n"
          "ISO: $_isoPath\n"
          "Selected Device: ${_selectedDrive!.toString()}\n\n"
          "ALL DATA ON THIS DEVICE WILL BE DELETED. Type YES only if you wish to proceed.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text("Yes"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _isFlashing = true;
      _progress = 0.0;
    });

    if (_isoType == ISOType.Windows) {
      await flashWindowsISO(_isoPath!, _selectedDrive!);
    } else {
      await flashLinuxISO(_isoPath!, _selectedDrive!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenUSB'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isFlashing ? null : _fetchDrives,
            tooltip: 'Refresh Drives',
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Card(
            elevation: 10,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "OpenUSB",
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _isFlashing ? null : _pickISOFile,
                    icon: const Icon(Icons.insert_drive_file),
                    label: const Text("Select ISO File"),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _isoPath ?? "No ISO file selected.",
                    style: const TextStyle(fontStyle: FontStyle.italic),
                  ),
                  const SizedBox(height: 16),
                  // Radio buttons to choose the ISO type.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text("ISO Type: "),
                      Radio<ISOType>(
                        value: ISOType.Windows,
                        groupValue: _isoType,
                        onChanged: _isFlashing
                            ? null
                            : (value) {
                                setState(() {
                                  _isoType = value!;
                                });
                              },
                      ),
                      const Text("Windows"),
                      Radio<ISOType>(
                        value: ISOType.Linux,
                        groupValue: _isoType,
                        onChanged: _isFlashing
                            ? null
                            : (value) {
                                setState(() {
                                  _isoType = value!;
                                });
                              },
                      ),
                      const Text("Linux"),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text(
                        "Target Device: ",
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _driveList.isEmpty
                            ? const Text(
                                "No USB/SD drives detected.",
                                style: TextStyle(color: Colors.red),
                              )
                            : DropdownButton<DriveInfo>(
                                isExpanded: true,
                                value: _selectedDrive,
                                items: _driveList
                                    .map((drive) => DropdownMenuItem<DriveInfo>(
                                          value: drive,
                                          child: Text(drive.toString()),
                                        ))
                                    .toList(),
                                onChanged: _isFlashing
                                    ? null
                                    : (newDrive) {
                                        setState(() {
                                          _selectedDrive = newDrive;
                                        });
                                      },
                              ),
                      )
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    "WARNING: ALL DATA ON THE SELECTED DEVICE WILL BE DELETED PERMANENTLY!",
                    style: TextStyle(
                        color: Colors.red, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  if (_isFlashing && _progress != null)
                    LinearProgressIndicator(value: _progress),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _isFlashing ? null : _startFlashing,
                    icon: const Icon(Icons.flash_on),
                    label: Text(_isFlashing
                        ? "Flashing in progress..."
                        : "Flash ISO"),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}