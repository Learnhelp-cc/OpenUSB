import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

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

/// Checks if the current process has administrator privileges.
/// Uses the 'net session' command; exit code 0 indicates admin rights.
Future<bool> isAdmin() async {
  try {
    ProcessResult result = await Process.run("net", ["session"]);
    return result.exitCode == 0;
  } catch (e) {
    return false;
  }
}

/// Screen to display if admin privileges are missing.
class AdminRequiredApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Administrator Required",
      home: Scaffold(
        appBar: AppBar(
          title: Text("Administrator Required"),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.admin_panel_settings, size: 80, color: Colors.red),
                SizedBox(height: 20),
                Text(
                  "This application must be run as an administrator.\n\nPlease restart it with elevated privileges.",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18),
                ),
                SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: () {
                    exit(0);
                  },
                  icon: Icon(Icons.exit_to_app),
                  label: Text("Exit"),
                )
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

  // Check for administrator privileges.
  bool admin = await isAdmin();
  if (!admin) {
    runApp(AdminRequiredApp());
    return;
  }

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenUSB V1',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: FlashHomePage(),
    );
  }
}

class FlashHomePage extends StatefulWidget {
  @override
  _FlashHomePageState createState() => _FlashHomePageState();
}

class _FlashHomePageState extends State<FlashHomePage> {
  String? _isoPath;
  double? _progress;
  bool _isFlashing = false;

  List<DriveInfo> _driveList = [];
  DriveInfo? _selectedDrive;

  @override
  void initState() {
    super.initState();
    _fetchDrives();
  }

  /// Enumerates USB drives using WMIC and filters for devices with InterfaceType "USB".
  Future<void> _fetchDrives() async {
    setState(() {
      _driveList = [];
      _selectedDrive = null;
    });

    try {
      ProcessResult result = await Process.run(
        'wmic',
        ['diskdrive', 'get', 'DeviceID,Model,InterfaceType,MediaType', '/format:csv'],
      );

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

      final headers = lines.first.split(',').map((e) => e.trim().toLowerCase()).toList();
      Map<String, int> colIndex = {};
      for (int i = 0; i < headers.length; i++) {
        colIndex[headers[i]] = i;
      }

      List<DriveInfo> driveList = [];
      for (var i = 1; i < lines.length; i++) {
        final parts = lines[i].split(',').map((e) => e.trim()).toList();
        if (parts.length < headers.length) continue;

        final deviceID = parts[colIndex['deviceid']!];
        final model = parts[colIndex['model']!];
        final interfaceType = parts[colIndex['interfacetype']!];
        final mediaType = parts[colIndex['mediatype']!];

        // Filter for USB devices only.
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

  /// Uses the FilePicker package to allow the user to select an ISO file.
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

  /// Writes the ISO file to the selected device.
  Future<void> flashISO(String isoPath, DriveInfo drive) async {
    final isoFile = File(isoPath);
    if (!await isoFile.exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Error: ISO file not found.")),
      );
      setState(() {
        _isFlashing = false;
      });
      return;
    }

    IOSink? deviceSink;
    try {
      // The deviceID should be in the Windows format, e.g., "\\.\PhysicalDriveX".
      final targetFile = File(drive.deviceID);
      deviceSink = targetFile.openWrite(mode: FileMode.write);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error opening device: $e")),
      );
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
        SnackBar(content: Text("Error during flashing: $e")),
      );
      setState(() {
        _isFlashing = false;
        _progress = null;
      });
      return;
    }

    await deviceSink.flush();
    await deviceSink.close();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Flashing completed successfully.")),
    );
    setState(() {
      _isFlashing = false;
      _progress = null;
    });
  }

  /// Initiates the flashing process after confirming with the user.
  void _startFlashing() async {
    if (_isoPath == null || _selectedDrive == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please select an ISO file and a target drive.")),
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

    await flashISO(_isoPath!, _selectedDrive!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenUSB V1'),
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
          child: Padding(
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
                    Text(
                      "OpenUSB V1",
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _isFlashing ? null : _pickISOFile,
                      icon: Icon(Icons.insert_drive_file),
                      label: Text("Select ISO File"),
                    ),
                    SizedBox(height: 8),
                    Text(
                      _isoPath ?? "No ISO file selected.",
                      style: TextStyle(fontStyle: FontStyle.italic),
                    ),
                    SizedBox(height: 16),
                    Row(
                      children: [
                        Text(
                          "Target Device: ",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: _driveList.isEmpty
                              ? Text(
                                  "No USB/SD drives detected.",
                                  style: TextStyle(color: Colors.red),
                                )
                              : DropdownButton<DriveInfo>(
                                  isExpanded: true,
                                  value: _selectedDrive,
                                  items: _driveList.map((drive) {
                                    return DropdownMenuItem<DriveInfo>(
                                      value: drive,
                                      child: Text(drive.toString()),
                                    );
                                  }).toList(),
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
                    SizedBox(height: 16),
                    Text(
                      "WARNING: ALL DATA ON THE SELECTED DEVICE WILL BE DELETED PERMANENTLY!",
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: 16),
                    if (_isFlashing && _progress != null)
                      LinearProgressIndicator(value: _progress),
                    SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _isFlashing ? null : _startFlashing,
                      icon: Icon(Icons.flash_on),
                      label: Text(
                          _isFlashing ? "Flashing in progress..." : "Flash ISO"),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}