import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:google_fonts/google_fonts.dart';

void main() async {
  // 1. Initialize Flutter Bindings
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Setup SQLite for Windows/Desktop if needed
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  runApp(const AccountingApp());
}

// Currency Service
class CurrencyService {
  static String currentCurrency = '৳';
  
  static String formatAmount(double amount) {
    return '$currentCurrency ${amount.toStringAsFixed(2)}';
  }
  
  static String getSymbol() {
    return currentCurrency;
  }
  
  // NEW: Format for PDF exports (uses Tk instead of Taka symbol)
  static String formatAmountForPdf(double amount) {
    return 'Tk ${amount.toStringAsFixed(2)}';
  }
}

// --- DATABASE HELPER ---
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('accounting_v10.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final directory = await getApplicationDocumentsDirectory();
    final path = p.join(directory.path, filePath);

    return await openDatabase(
      path,
      version: 5,
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  Future _createDB(Database db, int version) async {
    const idType = 'TEXT PRIMARY KEY';
    const textType = 'TEXT NOT NULL';
    const realType = 'REAL NOT NULL';
    const integerType = 'INTEGER PRIMARY KEY AUTOINCREMENT';

    // 1. Accounts Table
    await db.execute('''
      CREATE TABLE accounts (
        name $textType PRIMARY KEY, 
        type $textType
      )
    ''');

    // 2. Journal Entries Table
    await db.execute('''
      CREATE TABLE journal_entries (
        id $idType,
        date $textType,
        description $textType,
        username $textType
      )
    ''');

    // 3. Journal Lines Table
    await db.execute('''
      CREATE TABLE journal_lines (
        id $integerType,
        journal_id $textType,
        account_name $textType,
        debit $realType,
        credit $realType,
        FOREIGN KEY (journal_id) REFERENCES journal_entries (id) ON DELETE CASCADE,
        FOREIGN KEY (account_name) REFERENCES accounts (name) ON DELETE CASCADE
      )
    ''');

    // 4. Users Table
    await db.execute('''
      CREATE TABLE users (
        username $textType PRIMARY KEY,
        password $textType
      )
    ''');

    // 5. Session Table (For Persistent Login)
    await db.execute('''
      CREATE TABLE session (
        id INTEGER PRIMARY KEY CHECK (id = 1), 
        username $textType
      )
    ''');

    // 6. Settings Table (New for currency)
    await db.execute('''
      CREATE TABLE settings (
        key $textType PRIMARY KEY,
        value $textType
      )
    ''');
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE users (
          username TEXT NOT NULL PRIMARY KEY,
          password TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 3) {
      try {
        await db
            .execute('ALTER TABLE journal_entries ADD COLUMN username TEXT');
      } catch (e) {
        // Column might already exist
      }
    }
    if (oldVersion < 4) {
      // Add Session table for persistent login
      await db.execute('''
        CREATE TABLE session (
          id INTEGER PRIMARY KEY CHECK (id = 1), 
          username TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 5) {
      // Add Settings table for currency
      await db.execute('''
        CREATE TABLE settings (
          key TEXT PRIMARY KEY,
          value TEXT
        )
      ''');
    }
  }

  // --- SETTINGS OPERATIONS ---
  Future<void> setCurrency(String currency) async {
    final db = await instance.database;
    await db.insert(
      'settings',
      {'key': 'currency', 'value': currency},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> getCurrency() async {
    final db = await instance.database;
    final result = await db.query(
      'settings',
      where: 'key = ?',
      whereArgs: ['currency'],
    );
    if (result.isNotEmpty) {
      return result.first['value'] as String;
    }
    return '৳'; // Default to Taka
  }

  Future<void> deleteAccount(String accountName) async {
    final db = await instance.database;
    await db.delete('accounts', where: 'name = ?', whereArgs: [accountName]);
  }

  // --- DATA MANAGEMENT OPERATIONS ---
  Future<void> clearAllData(String username) async {
    final db = await instance.database;
    // We only need to delete from journal_entries where username matches.
    // The journal_lines will be deleted automatically because of 
    // "ON DELETE CASCADE" in your table definition.
    await db.delete(
      'journal_entries',
      where: 'username = ?',
      whereArgs: [username],
    );
  }

  Future<String> getDatabasePath() async {
    final directory = await getApplicationDocumentsDirectory();
    return p.join(directory.path, 'accounting_v10.db');
  }

  // --- SESSION OPERATIONS (Persistent Login) ---
  Future<void> setSession(String username) async {
    final db = await instance.database;
    await db.insert(
      'session',
      {'id': 1, 'username': username},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getSessionUser() async {
    final db = await instance.database;
    final result = await db.query('session', limit: 1);
    if (result.isNotEmpty) {
      return result.first['username'] as String;
    }
    return null;
  }

  Future<void> clearSession() async {
    final db = await instance.database;
    await db.delete('session');
  }

  // --- AUTH OPERATIONS ---
  Future<bool> registerUser(String username, String password) async {
    final db = await instance.database;
    try {
      await db.insert('users', {'username': username, 'password': password});
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> loginUser(String username, String password) async {
    final db = await instance.database;
    final result = await db.query(
      'users',
      where: 'username = ? AND password = ?',
      whereArgs: [username, password],
    );
    if (result.isNotEmpty) {
      await setSession(username);
      return true;
    }
    return false;
  }

  Future<List<String>> getAllUsernames() async {
    final db = await instance.database;
    final result = await db.query('users', columns: ['username']);
    return result.map((e) => e['username'] as String).toList();
  }

  Future<bool> updatePassword(String username, String newPassword) async {
    final db = await instance.database;
    final count = await db.update(
      'users',
      {'password': newPassword},
      where: 'username = ?',
      whereArgs: [username],
    );
    return count > 0;
  }

  Future<void> deleteUser(String username) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      await txn
          .delete('journal_entries', where: 'username = ?', whereArgs: [username]);
      await txn.delete('users', where: 'username = ?', whereArgs: [username]);
      await txn.delete('session', where: 'username = ?', whereArgs: [username]);
    });
  }

  // --- ACCOUNTING OPERATIONS ---
  Future<void> insertAccount(String name, String type) async {
    final db = await instance.database;
    await db.insert(
      'accounts',
      {'name': name, 'type': type},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<Map<String, dynamic>>> getAllAccounts() async {
    final db = await instance.database;
    return await db.query('accounts');
  }

  Future<void> insertJournalEntry(JournalEntry entry, String username) async {
    final db = await instance.database;

    await db.insert(
      'journal_entries',
      {
        'id': entry.id,
        'date': entry.date.toIso8601String(),
        'description': entry.description,
        'username': username,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    await db.delete('journal_lines',
        where: 'journal_id = ?', whereArgs: [entry.id]);

    for (var line in entry.lines) {
      await db.insert('journal_lines', {
        'journal_id': entry.id,
        'account_name': line.accountName,
        'debit': line.debit,
        'credit': line.credit,
      });
    }
  }

  Future<List<JournalEntry>> getAllJournalEntries(String username) async {
    final db = await instance.database;
    final result = await db.query(
      'journal_entries',
      where: 'username = ?',
      whereArgs: [username],
      orderBy: 'date DESC', // Changed to DESC for newest first
    );

    List<JournalEntry> entries = [];

    for (var row in result) {
      final id = row['id'] as String;
      final lineResult = await db.query('journal_lines',
          where: 'journal_id = ?', whereArgs: [id]);

      final lines = lineResult.map((lineRow) {
        return JournalLine(
          accountName: lineRow['account_name'] as String,
          debit: lineRow['debit'] as double,
          credit: lineRow['credit'] as double,
        );
      }).toList();

      entries.add(JournalEntry(
        id: id,
        date: DateTime.parse(row['date'] as String),
        description: row['description'] as String,
        lines: lines,
      ));
    }
    return entries;
  }

  Future<void> deleteJournalEntry(String id) async {
    final db = await instance.database;
    await db.delete('journal_entries', where: 'id = ?', whereArgs: [id]);
  }
}

// --- Data Models ---
class JournalEntry {
  final String id;
  final DateTime date;
  final String description;
  final List<JournalLine> lines;

  JournalEntry({
    required this.id,
    required this.date,
    required this.description,
    required this.lines,
  });

  bool get isBalanced {
    double totalDebit = lines.fold(0, (sum, line) => sum + line.debit);
    double totalCredit = lines.fold(0, (sum, line) => sum + line.credit);
    return (totalDebit - totalCredit).abs() < 0.01;
  }

  double get totalDebit => lines.fold(0, (sum, line) => sum + line.debit);
  double get totalCredit => lines.fold(0, (sum, line) => sum + line.credit);
}

class JournalLine {
  final String accountName;
  final double debit;
  final double credit;

  JournalLine({
    required this.accountName,
    required this.debit,
    required this.credit,
  });
}

class LedgerAccount {
  final String name;
  final String type;
  final List<LedgerTransaction> transactions;

  LedgerAccount({
    required this.name,
    required this.type,
    required this.transactions,
  });

  double get balance {
    double debitTotal = transactions.fold(0, (sum, t) => sum + t.debit);
    double creditTotal = transactions.fold(0, (sum, t) => sum + t.credit);

    if (type == 'Asset' || type == 'Expense') {
      return debitTotal - creditTotal;
    } else {
      return creditTotal - debitTotal;
    }
  }
}

class LedgerTransaction {
  final DateTime date;
  final String description;
  final double debit;
  final double credit;
  final String journalId;

  LedgerTransaction({
    required this.date,
    required this.description,
    required this.debit,
    required this.credit,
    required this.journalId,
  });
}

// --- SETTINGS PAGE ---
class SettingsPage extends StatefulWidget {
  final VoidCallback onThemeToggle;
  final bool isDarkMode;
  final String currentUser;
  final VoidCallback onDataChanged; // NEW: Callback for data changes

  const SettingsPage({
    Key? key,
    required this.onThemeToggle,
    required this.isDarkMode,
    required this.currentUser,
    required this.onDataChanged, // NEW: Added callback
  }) : super(key: key);

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _selectedCurrency = '৳';
  List<Map<String, dynamic>> _accounts = [];
  bool _isLoading = true;
  bool _localDarkMode = false; // Added for immediate theme switch response

  @override
  void initState() {
    super.initState();
    _localDarkMode = widget.isDarkMode; // Initialize with current theme
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final currency = await DatabaseHelper.instance.getCurrency();
    final accounts = await DatabaseHelper.instance.getAllAccounts();
    
    setState(() {
      _selectedCurrency = currency;
      _accounts = accounts;
      _isLoading = false;
    });
    CurrencyService.currentCurrency = currency;
  }

  Future<void> _updateCurrency(String currency) async {
    await DatabaseHelper.instance.setCurrency(currency);
    setState(() {
      _selectedCurrency = currency;
    });
    CurrencyService.currentCurrency = currency;
  }

  void _showAddAccountDialog() {
    final nameController = TextEditingController();
    String? selectedType;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add New Account'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Account Name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: selectedType,
              decoration: const InputDecoration(
                labelText: 'Account Type',
                border: OutlineInputBorder(),
              ),
              items: ['Asset', 'Liability', 'Equity', 'Revenue', 'Expense']
                  .map((type) => DropdownMenuItem(
                        value: type,
                        child: Text(type),
                      ))
                  .toList(),
              onChanged: (value) {
                selectedType = value;
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (nameController.text.isNotEmpty && selectedType != null) {
                await DatabaseHelper.instance.insertAccount(
                  nameController.text,
                  selectedType!,
                );
                if (!mounted) return;
                Navigator.pop(context);
                _loadSettings(); // Reload accounts
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Account added successfully')),
                );
              }
            },
            child: const Text('Add Account'),
          ),
        ],
      ),
    );
  }

  void _showDeleteAccountDialog(String accountName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Account'),
        content: Text('Are you sure you want to delete "$accountName"? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              await DatabaseHelper.instance.deleteAccount(accountName);
              if (!mounted) return;
              Navigator.pop(context);
              _loadSettings(); // Reload accounts
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Account deleted successfully')),
              );
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  // NEW: Clear All Data Dialog
  void _showClearAllDataDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All Data'),
        content: const Text(
          'This will permanently delete all YOUR journal entries and transactions. '
          'Other users\' data will be preserved. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              // FIX: Pass the current user's username
              await DatabaseHelper.instance.clearAllData(widget.currentUser);
              
              if (!mounted) return;
              Navigator.pop(context);
              widget.onDataChanged(); // Notify parent to reload data
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Your data cleared successfully')),
              );
            },
            child: const Text('Clear My Data'),
          ),
        ],
      ),
    );
  }

  // NEW: Backup Database
  // IMPROVED: Backup Database (Works on Windows/Desktop now)
  Future<void> _backupDatabase() async {
    try {
      final dbPath = await DatabaseHelper.instance.getDatabasePath();
      final dbFile = File(dbPath);

      if (!dbFile.existsSync()) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Database file not found')),
        );
        return;
      }

      final bytes = await dbFile.readAsBytes();
      final String fileName = 'accounting_backup_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.db';

      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        // --- DESKTOP: Open "Save As" Dialog ---
        final String? outputFile = await FilePicker.platform.saveFile(
          dialogTitle: 'Save Backup File',
          fileName: fileName,
          type: FileType.any, // Allows .db extension
        );

        if (outputFile != null) {
          final file = File(outputFile);
          await file.writeAsBytes(bytes);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Backup saved successfully to: $outputFile'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        // --- MOBILE: Share Sheet (Keep existing logic for Android/iOS) ---
        final tempDir = await getTemporaryDirectory();
        final backupFile = File('${tempDir.path}/$fileName');
        await backupFile.writeAsBytes(bytes);
        await Share.shareXFiles([XFile(backupFile.path)], text: 'Accounting Database Backup');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backup failed: $e')),
      );
    }
  }

  // NEW: Restore Database
  Future<void> _restoreDatabase() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['db'],
      );

      if (result != null && result.files.single.path != null) {
        final backupFile = File(result.files.single.path!);
        final dbPath = await DatabaseHelper.instance.getDatabasePath();
        final dbFile = File(dbPath);

        // Create backup of current database
        final backupBytes = await dbFile.readAsBytes();
        final tempDir = await getTemporaryDirectory();
        final currentBackup = File('${tempDir.path}/accounting_pre_restore_${DateTime.now().millisecondsSinceEpoch}.db');
        await currentBackup.writeAsBytes(backupBytes);

        // Replace with selected database
        final backupBytesToRestore = await backupFile.readAsBytes();
        await dbFile.writeAsBytes(backupBytesToRestore);

        if (!mounted) return;
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Database restored successfully. Please restart the app.')),
        );

        // Navigate to auth screen to force reload
        await DatabaseHelper.instance.clearSession();
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (context) => AuthScreen(
              onThemeToggle: widget.onThemeToggle,
              isDarkMode: widget.isDarkMode,
            ),
          ),
          (route) => false,
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Restore failed: $e')),
      );
    }
  }
  // NEW: Merged Backup & Restore Menu
  void _showBackupRestoreDialog() {
    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Backup & Restore'),
        children: [
          SimpleDialogOption(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.save, color: Colors.blue.shade700),
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Create Backup', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Text('Save your data to a file so you can recover it later.', 
                           style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
              ],
            ),
            onPressed: () {
              Navigator.pop(context);
              _backupDatabase();
            },
          ),
          const Divider(),
          SimpleDialogOption(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.restore_page, color: Colors.orange.shade700),
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Restore Data', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Text('Select a previously saved backup file to retrieve your data.', 
                           style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
              ],
            ),
            onPressed: () {
              Navigator.pop(context);
              _restoreDatabase();
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            // Theme Settings
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Appearance',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Dark Mode'),
                        Switch(
                          value: _localDarkMode,
                          onChanged: (value) {
                            setState(() {
                              _localDarkMode = value; // Immediate visual update
                            });
                            widget.onThemeToggle(); // Call parent callback
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Currency Settings
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Currency',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      children: [
                        _buildCurrencyChip('৳', 'Taka'),
                        _buildCurrencyChip('\$', 'Dollar'),
                        _buildCurrencyChip('£', 'Pound'),
                        _buildCurrencyChip('€', 'Euro'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // NEW: Data Management Section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Data Management',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        // MERGED BUTTON
                        FilledButton.icon(
                          icon: const Icon(Icons.settings_backup_restore),
                          label: const Text('Backup & Restore'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          ),
                          onPressed: _showBackupRestoreDialog,
                        ),

                        // CLEAR DATA BUTTON (Kept separate as requested)
                        FilledButton.icon(
                          icon: const Icon(Icons.delete_forever),
                          label: const Text('Clear My Data'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red.shade100,
                            foregroundColor: Colors.red.shade900,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          ),
                          onPressed: _showClearAllDataDialog,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Chart of Accounts
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Chart of Accounts',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add),
                          onPressed: _showAddAccountDialog,
                          tooltip: 'Add Account',
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _accounts.isEmpty
                        ? const Center(
                            child: Text('No accounts found'),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _accounts.length,
                            itemBuilder: (context, index) {
                              final account = _accounts[index];
                              return ListTile(
                                title: Text(account['name']),
                                subtitle: Text(account['type']),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.red),
                                  onPressed: () => _showDeleteAccountDialog(account['name']),
                                ),
                              );
                            },
                          ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrencyChip(String currency, String label) {
    final isSelected = _selectedCurrency == currency;
    return FilterChip(
      label: Text('$currency $label'),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          _updateCurrency(currency);
        }
      },
    );
  }
}

// --- DASHBOARD PAGE ---
class DashboardPage extends StatefulWidget {
  final String currentUser;
  final VoidCallback onThemeToggle;
  final bool isDarkMode;

  const DashboardPage({
    Key? key,
    required this.currentUser,
    required this.onThemeToggle,
    required this.isDarkMode,
  }) : super(key: key);

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  List<JournalEntry> journalEntries = [];
  Map<String, LedgerAccount> ledgerAccounts = {};
  bool _isLoading = true;
  String _timeFilter = 'This Month';
  DateTimeRange? _customDateRange;
  final TextEditingController _searchController = TextEditingController();
  String _currentCurrency = '৳';

  @override
  void initState() {
    super.initState();
    _loadData();
    _loadCurrency();
  }

  Future<void> _loadCurrency() async {
    final currency = await DatabaseHelper.instance.getCurrency();
    setState(() {
      _currentCurrency = currency;
    });
    CurrencyService.currentCurrency = currency;
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    
    // Load journal entries
    final entries = await DatabaseHelper.instance
        .getAllJournalEntries(widget.currentUser);
    
    // Load and initialize accounts
    await _refreshAccountsFromDB();
    
    setState(() {
      journalEntries = entries;
      for (var entry in entries) {
        _postToLedgerInMemory(entry);
      }
      _isLoading = false;
    });
  }

  Future<void> _refreshAccountsFromDB() async {
    final accountsData = await DatabaseHelper.instance.getAllAccounts();
    Map<String, LedgerAccount> newMap = {};

    for (var row in accountsData) {
      newMap[row['name']] = LedgerAccount(
        name: row['name'],
        type: row['type'],
        transactions: [],
      );
    }
    setState(() {
      ledgerAccounts = newMap;
    });
  }

  void _postToLedgerInMemory(JournalEntry entry) {
    for (var line in entry.lines) {
      if (ledgerAccounts.containsKey(line.accountName)) {
        ledgerAccounts[line.accountName]!.transactions.add(
          LedgerTransaction(
            date: entry.date,
            description: entry.description,
            debit: line.debit,
            credit: line.credit,
            journalId: entry.id,
          ),
        );
      }
    }
  }

  List<JournalEntry> get filteredEntries {
    DateTime now = DateTime.now();
    DateTime startDate;
    DateTime endDate;
    
    switch (_timeFilter) {
      case 'This Month':
        startDate = DateTime(now.year, now.month, 1);
        endDate = DateTime(now.year, now.month + 1, 0, 23, 59, 59, 999);
        break;
      case 'Last Month':
        startDate = DateTime(now.year, now.month - 1, 1);
        endDate = DateTime(now.year, now.month, 0, 23, 59, 59, 999); // Fixed: Include last moment of previous month
        break;
      case 'Custom Range':
        if (_customDateRange != null) {
          startDate = _customDateRange!.start;
          endDate = _customDateRange!.end.add(const Duration(days: 1)).subtract(const Duration(milliseconds: 1));
        } else {
          startDate = DateTime(2000);
          endDate = DateTime(2100, 12, 31, 23, 59, 59, 999);
        }
        break;
      default: // All Time
        startDate = DateTime(2000);
        endDate = DateTime(2100, 12, 31, 23, 59, 59, 999);
    }

    var filtered = journalEntries.where((entry) => 
      entry.date.isAfter(startDate.subtract(const Duration(milliseconds: 1))) && 
      entry.date.isBefore(endDate.add(const Duration(milliseconds: 1)))
    ).toList();

    // Apply search filter
    if (_searchController.text.isNotEmpty) {
      filtered = filtered.where((entry) =>
        entry.description.toLowerCase().contains(_searchController.text.toLowerCase()) ||
        entry.lines.any((line) => 
          line.accountName.toLowerCase().contains(_searchController.text.toLowerCase())
        )
      ).toList();
    }

    // Remove limit for "All Time" filter and custom range filter
   if (_timeFilter == 'All Time' || _timeFilter == 'Custom Range') {
      return filtered; 
    } else {
      return filtered.take(10).toList();
    }
  }

  // Analytics Data
  // --- REPLACE START (Inside _DashboardPageState) ---
  // Analytics Data
  Map<String, double> get expenseBreakdown {
    Map<String, double> expenses = {};
    for (var account in ledgerAccounts.values) {
      if (account.type == 'Expense' && account.balance > 0) {
        expenses[account.name] = account.balance;
      }
    }
    
    // Sort by value descending (Highest expense first)
    var sortedEntries = expenses.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    // FIX: Removed .take(5) so it shows ALL expenses
    return Map.fromEntries(sortedEntries);
  }

  Map<String, double> get revenueBreakdown {
    Map<String, double> revenues = {};
    for (var account in ledgerAccounts.values) {
      if (account.type == 'Revenue' && account.balance > 0) {
        revenues[account.name] = account.balance;
      }
    }
    
    // Sort by value descending
    var sortedEntries = revenues.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
      
    // FIX: Removed .take(5) so it shows ALL revenue sources
    return Map.fromEntries(sortedEntries);
  }
// --- REPLACE END ---

  double get totalRevenue {
    return ledgerAccounts.values
        .where((a) => a.type == 'Revenue')
        .fold(0.0, (sum, acc) => sum + acc.balance);
  }

  double get totalExpense {
    return ledgerAccounts.values
        .where((a) => a.type == 'Expense')
        .fold(0.0, (sum, acc) => sum + acc.balance);
  }

  void _navigateToWorkspace() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => AccountingHomePage(
          currentUser: widget.currentUser,
          onThemeToggle: widget.onThemeToggle,
          isDarkMode: widget.isDarkMode,
        ),
      ),
    );
  }

  // FIXED: Added await for navigation and reload currency
  Future<void> _navigateToSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SettingsPage(
          onThemeToggle: widget.onThemeToggle,
          isDarkMode: widget.isDarkMode,
          currentUser: widget.currentUser,
          onDataChanged: _loadData, // NEW: Pass callback
        ),
      ),
    );
    // Reload currency when returning from settings
    await _loadCurrency();
    setState(() {}); // Refresh UI
  }

  // NEW: Export Format Selection Dialog
  void _showExportFormatDialog(String reportType) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Export $reportType'),
        content: const Text('Select export format:'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _exportReport(reportType, 'PDF');
            },
            child: const Text('PDF'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _exportReport(reportType, 'Excel');
            },
            child: const Text('Excel'),
          ),
        ],
      ),
    );
  }

  void _showExportDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Export Financial Reports'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Choose report to export:'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _showExportFormatDialog('Trial Balance');
            },
            child: const Text('Export Trial Balance'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _showExportFormatDialog('Income Statement');
            },
            child: const Text('Export Income Statement'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _showExportFormatDialog('Balance Sheet');
            },
            child: const Text('Export Balance Sheet'),
          ),
        ],
      ),
    );
  }

  void _exportReport(String reportType, String format) {
    switch (reportType) {
      case 'Trial Balance':
        if (format == 'PDF') {
          _exportTrialBalance();
        } else {
          _generateExcelTrialBalance();
        }
        break;
      case 'Income Statement':
        if (format == 'PDF') {
          _exportIncomeStatement();
        } else {
          _generateExcelIncomeStatement();
        }
        break;
      case 'Balance Sheet':
        if (format == 'PDF') {
          _exportBalanceSheet();
        } else {
          _generateExcelBalanceSheet();
        }
        break;
    }
  }
  // NEW: Helper function to handle saving based on Platform
  Future<void> _saveAndShareExcel(Excel excel, String fileName) async {
    final bytes = excel.save();
    if (bytes == null) return;

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // --- DESKTOP: SHOW "SAVE AS" DIALOG ---
      final String? outputFile = await FilePicker.platform.saveFile(
        dialogTitle: 'Save $fileName',
        fileName: '${fileName}_${DateFormat('yyyyMMdd').format(DateTime.now())}.xlsx',
        allowedExtensions: ['xlsx'],
        type: FileType.custom,
      );

      if (outputFile != null) {
        final file = File(outputFile);
        await file.writeAsBytes(bytes);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to: $outputFile'),
            backgroundColor: Colors.green,
            action: SnackBarAction(
              label: 'Open',
              textColor: Colors.white,
              onPressed: () {
                // Optional: You could add logic here to open the file
                // But generally users know where they saved it now.
              },
            ),
          ),
        );
      }
    } else {
      // --- MOBILE: KEEP EXISTING SHARE LOGIC ---
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$fileName.xlsx');
      await file.writeAsBytes(bytes);
      await Share.shareXFiles([XFile(file.path)], text: '$fileName Export');
    }
  }

  // NEW: Excel Export Functions
 Future<void> _generateExcelTrialBalance() async {
    try {
      final excel = Excel.createExcel();
      // FIX: Rename the default "Sheet1" to "Trial Balance" so it's the first thing you see
      final String defaultSheet = excel.getDefaultSheet() ?? 'Sheet1';
      excel.rename(defaultSheet, 'Trial Balance');
      final sheet = excel['Trial Balance'];
      sheet.appendRow([TextCellValue(widget.currentUser)]);

      // --- Calculation Logic ---
      double totalDebit = 0;
      double totalCredit = 0;
      List<Map<String, dynamic>> accounts = [];

      for (var entry in ledgerAccounts.entries) {
        final account = entry.value;
        if (account.transactions.isNotEmpty) {
          final balance = account.balance;
          double debit = 0;
          double credit = 0;

          if (balance > 0) {
            if (account.type == 'Asset' || account.type == 'Expense') {
              debit = balance;
              totalDebit += balance;
            } else {
              credit = balance;
              totalCredit += balance;
            }
          } else if (balance < 0) {
            if (account.type == 'Asset' || account.type == 'Expense') {
              credit = balance.abs();
              totalCredit += balance.abs();
            } else {
              debit = balance.abs();
              totalDebit += balance.abs();
            }
          }

          accounts.add({
            'name': entry.key,
            'type': account.type,
            'debit': debit,
            'credit': credit,
          });
        }
      }

      // --- Writing to Excel ---
      sheet.appendRow([TextCellValue('Trial Balance')]);
      sheet.appendRow([TextCellValue('As of ${DateFormat('MMMM dd, yyyy').format(DateTime.now())}')]);
      sheet.appendRow([TextCellValue('')]); 

      sheet.appendRow([
        TextCellValue('Account'), 
        TextCellValue('Type'), 
        TextCellValue('Debit'), 
        TextCellValue('Credit')
      ]);

      for (var account in accounts) {
        sheet.appendRow([
          TextCellValue(account['name']),
          TextCellValue(account['type']),
          account['debit'] > 0 ? DoubleCellValue(account['debit']) : TextCellValue('-'),
          account['credit'] > 0 ? DoubleCellValue(account['credit']) : TextCellValue('-'),
        ]);
      }

      sheet.appendRow([TextCellValue('')]);
      sheet.appendRow([
        TextCellValue('Total'), 
        TextCellValue(''), 
        DoubleCellValue(totalDebit), 
        DoubleCellValue(totalCredit)
      ]);

      await _saveAndShareExcel(excel, 'Trial_Balance');
      
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Excel export failed: $e')),
      );
    }
  }

  Future<void> _generateExcelIncomeStatement() async {
    try {
      final excel = Excel.createExcel();
      // FIX: Rename default sheet
      final String defaultSheet = excel.getDefaultSheet() ?? 'Sheet1';
      excel.rename(defaultSheet, 'Income Statement');
      final sheet = excel['Income Statement'];
      sheet.appendRow([TextCellValue(widget.currentUser)]);

      List<LedgerAccount> revenueAccounts = ledgerAccounts.values
          .where((a) => a.type == 'Revenue' && a.balance.abs() > 0.01)
          .toList();
      List<LedgerAccount> expenseAccounts = ledgerAccounts.values
          .where((a) => a.type == 'Expense' && a.balance.abs() > 0.01)
          .toList();
      
      double totalRevenue = revenueAccounts.fold(0, (sum, acc) => sum + acc.balance);
      double totalExpense = expenseAccounts.fold(0, (sum, acc) => sum + acc.balance);
      double netIncome = totalRevenue - totalExpense;

      sheet.appendRow([TextCellValue('Income Statement')]);
      sheet.appendRow([TextCellValue('For period ending ${DateFormat('MMMM dd, yyyy').format(DateTime.now())}')]);
      sheet.appendRow([TextCellValue('')]);

      // Revenues
      sheet.appendRow([TextCellValue('REVENUES')]);
      for (var acc in revenueAccounts) {
        sheet.appendRow([TextCellValue(acc.name), DoubleCellValue(acc.balance)]);
      }
      sheet.appendRow([TextCellValue('Total Revenue'), DoubleCellValue(totalRevenue)]);
      sheet.appendRow([TextCellValue('')]);

      // Expenses
      sheet.appendRow([TextCellValue('EXPENSES')]);
      for (var acc in expenseAccounts) {
        sheet.appendRow([TextCellValue(acc.name), DoubleCellValue(acc.balance)]);
      }
      sheet.appendRow([TextCellValue('Total Expenses'), DoubleCellValue(totalExpense)]);
      sheet.appendRow([TextCellValue('')]);

      sheet.appendRow([TextCellValue('NET PROFIT'), DoubleCellValue(netIncome)]);

      await _saveAndShareExcel(excel, 'Income_Statement');

    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Excel export failed: $e')),
      );
    }
  }

  Future<void> _generateExcelBalanceSheet() async {
    try {
      final excel = Excel.createExcel();
      // FIX: Rename default sheet
      final String defaultSheet = excel.getDefaultSheet() ?? 'Sheet1';
      excel.rename(defaultSheet, 'Balance Sheet');
      final sheet = excel['Balance Sheet'];
      sheet.appendRow([TextCellValue(widget.currentUser)]);

      // Calculations
      double totalRevenue = ledgerAccounts.values
          .where((a) => a.type == 'Revenue')
          .fold(0.0, (double sum, acc) => sum + acc.balance);
      double totalExpense = ledgerAccounts.values
          .where((a) => a.type == 'Expense')
          .fold(0.0, (double sum, acc) => sum + acc.balance);
      double netIncome = totalRevenue - totalExpense;

      List<LedgerAccount> assets = ledgerAccounts.values
          .where((a) => a.type == 'Asset' && a.balance.abs() > 0.01)
          .toList();
      List<LedgerAccount> liabilities = ledgerAccounts.values
          .where((a) => a.type == 'Liability' && a.balance.abs() > 0.01)
          .toList();
      List<LedgerAccount> equity = ledgerAccounts.values
          .where((a) => a.type == 'Equity' && a.balance.abs() > 0.01)
          .toList();

      double totalAssets = assets.fold(0.0, (sum, acc) => sum + acc.balance);
      double totalLiabilities = liabilities.fold(0.0, (sum, acc) => sum + acc.balance);
      double baseEquity = equity.fold(0.0, (sum, acc) => sum + acc.balance);
      double totalEquity = baseEquity + netIncome;

      // Writing
      sheet.appendRow([TextCellValue('Balance Sheet')]);
      sheet.appendRow([TextCellValue('As of ${DateFormat('MMMM dd, yyyy').format(DateTime.now())}')]);
      sheet.appendRow([TextCellValue('')]);

      sheet.appendRow([TextCellValue('ASSETS')]);
      for (var acc in assets) {
        sheet.appendRow([TextCellValue(acc.name), DoubleCellValue(acc.balance)]);
      }
      sheet.appendRow([TextCellValue('TOTAL ASSETS'), DoubleCellValue(totalAssets)]);
      sheet.appendRow([TextCellValue('')]);

      sheet.appendRow([TextCellValue('LIABILITIES')]);
      for (var acc in liabilities) {
        sheet.appendRow([TextCellValue(acc.name), DoubleCellValue(acc.balance)]);
      }
      sheet.appendRow([TextCellValue('Total Liabilities'), DoubleCellValue(totalLiabilities)]);
      sheet.appendRow([TextCellValue('')]);

      sheet.appendRow([TextCellValue('EQUITY')]);
      for (var acc in equity) {
        sheet.appendRow([TextCellValue(acc.name), DoubleCellValue(acc.balance)]);
      }
      sheet.appendRow([TextCellValue('Net Profit (Current)'), DoubleCellValue(netIncome)]);
      sheet.appendRow([TextCellValue('TOTAL LIAB. & EQUITY'), DoubleCellValue(totalLiabilities + totalEquity)]);

      await _saveAndShareExcel(excel, 'Balance_Sheet');

    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Excel export failed: $e')),
      );
    }
  }

  // Existing PDF export functions remain the same...
  Future<void> _exportTrialBalance() async {
    final pdf = pw.Document();
    
    // Calculate trial balance data
    double totalDebit = 0;
    double totalCredit = 0;
    List<Map<String, dynamic>> accounts = [];

    for (var entry in ledgerAccounts.entries) {
      final account = entry.value;
      if (account.transactions.isNotEmpty) {
        final balance = account.balance;
        double debit = 0;
        double credit = 0;

        if (balance > 0) {
          if (account.type == 'Asset' || account.type == 'Expense') {
            debit = balance;
            totalDebit += balance;
          } else {
            credit = balance;
            totalCredit += balance;
          }
        } else if (balance < 0) {
          if (account.type == 'Asset' || account.type == 'Expense') {
            credit = balance.abs();
            totalCredit += balance.abs();
          } else {
            debit = balance.abs();
            totalDebit += balance.abs();
          }
        }

        accounts.add({
          'name': entry.key,
          'type': account.type,
          'debit': debit,
          'credit': credit,
        });
      }
    }

    pdf.addPage(
      pw.Page(
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // --- NEW SECTION: Name and Date at the top ---
              pw.Text(
                widget.currentUser,
                style: pw.TextStyle(
                  fontSize: 22,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.blue900
                )
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                'As of ${DateFormat('MMMM dd, yyyy').format(DateTime.now())}',
                style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey700)
              ),
              pw.SizedBox(height: 20),
              // ---------------------------------------------

              pw.Header(level: 0, text: 'Trial Balance'),
              pw.SizedBox(height: 20),

              // Table header
              pw.Row(
                children: [
                  pw.Expanded(flex: 3, child: pw.Text('Account', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(child: pw.Text('Debit', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(child: pw.Text('Credit', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                ],
              ),
              pw.Divider(),

              // Accounts list (Keep your existing loop here)
              for (var account in accounts)
                pw.Row(
                  children: [
                    pw.Expanded(flex: 3, child: pw.Text(account['name'])),
                    pw.Expanded(child: pw.Text(account['debit'] > 0 ? '${CurrencyService.formatAmountForPdf(account['debit'])}' : '-')),
                    pw.Expanded(child: pw.Text(account['credit'] > 0 ? '${CurrencyService.formatAmountForPdf(account['credit'])}' : '-')),
                  ],
                ),

              pw.Divider(),

              // Totals
              pw.Row(
                children: [
                  pw.Expanded(flex: 3, child: pw.Text('Total', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(child: pw.Text(CurrencyService.formatAmountForPdf(totalDebit), style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                  pw.Expanded(child: pw.Text(CurrencyService.formatAmountForPdf(totalCredit), style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                ],
              ),

              pw.SizedBox(height: 20),
              pw.Text(
                (totalDebit - totalCredit).abs() < 0.01 ? 'Trial Balance is Balanced' : 'Trial Balance is NOT Balanced',
                style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  color: (totalDebit - totalCredit).abs() < 0.01 ? PdfColors.green : PdfColors.red,
                ),
              ),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }

  Future<void> _exportIncomeStatement() async {
    final pdf = pw.Document();
    
    // Calculate income statement data
    List<LedgerAccount> revenueAccounts = ledgerAccounts.values
        .where((a) => a.type == 'Revenue' && a.balance.abs() > 0.01)
        .toList();

    List<LedgerAccount> expenseAccounts = ledgerAccounts.values
        .where((a) => a.type == 'Expense' && a.balance.abs() > 0.01)
        .toList();

    double totalRevenue = revenueAccounts.fold(0, (sum, acc) => sum + acc.balance);
    double totalExpense = expenseAccounts.fold(0, (sum, acc) => sum + acc.balance);
    double netIncome = totalRevenue - totalExpense;

    pdf.addPage(
      pw.Page(
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // --- NEW SECTION: Name and Date at the top ---
              pw.Text(
                widget.currentUser,
                style: pw.TextStyle(
                  fontSize: 22,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.blue900
                )
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                'For the period ending ${DateFormat('MMMM dd, yyyy').format(DateTime.now())}',
                style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey700)
              ),
              pw.SizedBox(height: 20),
              // ---------------------------------------------

              pw.Header(level: 0, text: 'Income Statement'),
              pw.SizedBox(height: 30),

              // Revenues
              pw.Text('REVENUES', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16)),
              pw.Divider(),
              pw.SizedBox(height: 10),

              for (var acc in revenueAccounts)
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(acc.name),
                    pw.Text(CurrencyService.formatAmountForPdf(acc.balance)),
                  ],
                ),

              pw.SizedBox(height: 10),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Total Revenue', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  pw.Text(CurrencyService.formatAmountForPdf(totalRevenue), style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                ],
              ),

              pw.SizedBox(height: 30),

              // Expenses
              pw.Text('EXPENSES', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16)),
              pw.Divider(),
              pw.SizedBox(height: 10),

              for (var acc in expenseAccounts)
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(acc.name),
                    pw.Text(CurrencyService.formatAmountForPdf(acc.balance)),
                  ],
                ),

              pw.SizedBox(height: 10),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Total Expenses', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  pw.Text(CurrencyService.formatAmountForPdf(totalExpense), style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                ],
              ),

              pw.SizedBox(height: 30),
              pw.Divider(),

              // Net Income
              pw.Container(
                padding: const pw.EdgeInsets.all(20),
                decoration: pw.BoxDecoration(
                  color: netIncome >= 0 ? PdfColors.green50 : PdfColors.red50,
                  border: pw.Border.all(color: netIncome >= 0 ? PdfColors.green : PdfColors.red),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('NET PROFIT', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 18)),
                    pw.Text(
                      CurrencyService.formatAmountForPdf(netIncome.abs()),
                      style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 18,
                        color: netIncome >= 0 ? PdfColors.green : PdfColors.red,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }

  Future<void> _exportBalanceSheet() async {
    final pdf = pw.Document();
    
    // Calculate balance sheet data
    double totalRevenue = ledgerAccounts.values
        .where((a) => a.type == 'Revenue')
        .fold(0.0, (double sum, acc) => sum + acc.balance);

    double totalExpense = ledgerAccounts.values
        .where((a) => a.type == 'Expense')
        .fold(0.0, (double sum, acc) => sum + acc.balance);

    double netIncome = totalRevenue - totalExpense;

    List<LedgerAccount> assets = ledgerAccounts.values
        .where((a) => a.type == 'Asset' && a.balance.abs() > 0.01)
        .toList();

    List<LedgerAccount> liabilities = ledgerAccounts.values
        .where((a) => a.type == 'Liability' && a.balance.abs() > 0.01)
        .toList();

    List<LedgerAccount> equity = ledgerAccounts.values
        .where((a) => a.type == 'Equity' && a.balance.abs() > 0.01)
        .toList();

    double totalAssets = assets.fold(0.0, (double sum, acc) => sum + acc.balance);
    double totalLiabilities = liabilities.fold(0.0, (double sum, acc) => sum + acc.balance);
    double baseEquity = equity.fold(0.0, (double sum, acc) => sum + acc.balance);
    double totalEquity = baseEquity + netIncome;

    pdf.addPage(
      pw.Page(
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // --- NEW SECTION: Name and Date at the top ---
              pw.Text(
                widget.currentUser,
                style: pw.TextStyle(
                  fontSize: 22,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.blue900
                )
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                'As of ${DateFormat('MMMM dd, yyyy').format(DateTime.now())}',
                style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey700)
              ),
              pw.SizedBox(height: 20),
              // ---------------------------------------------

              pw.Header(level: 0, text: 'Balance Sheet'),
              pw.SizedBox(height: 30),

              // The rest of your Balance Sheet Columns logic...
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  // Assets Column
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('ASSETS', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16)),
                        pw.Divider(),
                        pw.SizedBox(height: 10),

                        for (var acc in assets)
                          pw.Row(
                            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                            children: [
                              pw.Text(acc.name),
                              pw.Text(
                                acc.name == 'Accumulated Depreciation'
                                    ? '(${CurrencyService.formatAmountForPdf(acc.balance.abs())})'
                                    : CurrencyService.formatAmountForPdf(acc.balance.abs()),
                                style: pw.TextStyle(
                                  color: acc.balance < 0 ? PdfColors.red : PdfColors.black,
                                ),
                              ),
                            ],
                          ),

                        pw.SizedBox(height: 10),
                        pw.Divider(),
                        pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                          children: [
                            pw.Text('TOTAL ASSETS', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                            pw.Text(
                              CurrencyService.formatAmountForPdf(totalAssets.abs()),
                              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  pw.SizedBox(width: 20),

                  // Liabilities & Equity Column
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('LIABILITIES', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16)),
                        pw.Divider(),
                        pw.SizedBox(height: 10),

                        for (var acc in liabilities)
                          pw.Row(
                            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                            children: [
                              pw.Text(acc.name),
                              pw.Text(CurrencyService.formatAmountForPdf(acc.balance.abs())),
                            ],
                          ),

                        pw.SizedBox(height: 10),
                        pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                          children: [
                            pw.Text('Total Liabilities', style: pw.TextStyle(color: PdfColors.grey)),
                            pw.Text(CurrencyService.formatAmountForPdf(totalLiabilities.abs())),
                          ],
                        ),

                        pw.SizedBox(height: 20),
                        pw.Text('EQUITY', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 16)),
                        pw.Divider(),
                        pw.SizedBox(height: 10),

                        for (var acc in equity)
                          pw.Row(
                            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                            children: [
                              pw.Text(acc.name),
                              pw.Text(
                                acc.name == 'Drawings'
                                    ? '(${CurrencyService.formatAmountForPdf(acc.balance.abs())})'
                                    : CurrencyService.formatAmountForPdf(acc.balance.abs()),
                                style: pw.TextStyle(
                                  color: acc.balance < 0 ? PdfColors.red : PdfColors.black,
                                ),
                              ),
                            ],
                          ),

                        pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                          children: [
                            pw.Text('Net Profit (Current)', style: pw.TextStyle(fontStyle: pw.FontStyle.italic)),
                            pw.Text(
                              CurrencyService.formatAmountForPdf(netIncome.abs()),
                              style: pw.TextStyle(
                                fontStyle: pw.FontStyle.italic,
                                color: netIncome >= 0 ? PdfColors.green : PdfColors.red,
                              ),
                            ),
                          ],
                        ),

                        pw.SizedBox(height: 10),
                        pw.Divider(),
                        pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                          children: [
                            pw.Text('TOTAL LIAB. & EQUITY', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                            pw.Text(CurrencyService.formatAmountForPdf((totalLiabilities + totalEquity).abs()), style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              pw.SizedBox(height: 30),
              pw.Container(
                padding: const pw.EdgeInsets.all(16),
                decoration: pw.BoxDecoration(
                  color: (totalAssets - (totalLiabilities + totalEquity)).abs() < 0.01 ? PdfColors.green50 : PdfColors.red50,
                ),
                child: pw.Text(
                  (totalAssets - (totalLiabilities + totalEquity)).abs() < 0.01 ? 'Balance Sheet is Balanced' : 'Balance Sheet is Out of Balance',
                  style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold,
                    color: (totalAssets - (totalLiabilities + totalEquity)).abs() < 0.01 ? PdfColors.green : PdfColors.red,
                  ),
                  textAlign: pw.TextAlign.center,
                ),
              ),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.dashboard, size: 30),
            SizedBox(width: 12),
            Text('Accounting Dashboard',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 22)),
          ],
        ),
        actions: [
          // FIXED: Added Settings button
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _navigateToSettings,
            tooltip: 'Settings',
          ),
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: _showExportDialog,
            tooltip: 'Export Data',
          ),
          PopupMenuButton<String>(
            tooltip: 'Account',
            icon: CircleAvatar(
              radius: 18,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Text(
                widget.currentUser[0].toUpperCase(),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'workspace',
                child: const Row(
                  children: [
                    Icon(Icons.work, size: 20),
                    SizedBox(width: 12),
                    Text('Enter Workspace'),
                  ],
                ),
                onTap: _navigateToWorkspace,
              ),
              PopupMenuItem(
                value: 'logout',
                child: const Row(
                  children: [
                    Icon(Icons.logout, size: 20),
                    SizedBox(width: 12),
                    Text('Logout'),
                  ],
                ),
                onTap: _logout,
              ),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Section A: Workspace Access
            _buildWorkspaceAccess(),
            const SizedBox(height: 32),

            // Section B: Analytics
            _buildAnalyticsSection(),
            const SizedBox(height: 32),

            // Section C: Recent Entries
            _buildRecentEntriesSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkspaceAccess() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        // Beautiful modern gradient
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: widget.isDarkMode 
            ? [const Color(0xFF2C3E50), const Color(0xFF000000)]
            : [const Color(0xFF0F4C75), const Color(0xFF3282B8)],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Stack(
        children: [
          // Decorative background circle for depth
          Positioned(
            right: -50,
            top: -50,
            child: CircleAvatar(
              radius: 100,
              backgroundColor: Colors.white.withOpacity(0.1),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(40),
            child: Column(
              children: [
                const Icon(Icons.analytics_outlined, size: 64, color: Colors.white),
                const SizedBox(height: 24),
                const Text(
                  'Accounting Workspace',
                  style: TextStyle(
                    fontSize: 32, // Larger, more impressive font
                    fontWeight: FontWeight.w800, // Extra bold
                    color: Colors.white,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Manage journals, ledgers, and view real-time reports.',
                  style: TextStyle(fontSize: 16, color: Colors.white.withOpacity(0.8)),
                ),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: _navigateToWorkspace,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF0F4C75), // Deep Blue text
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 18),
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)), // Pill shape
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Enter Workspace',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(width: 8),
                      Icon(Icons.arrow_forward_rounded, size: 20),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

 // --- REPLACE START (Inside _DashboardPageState) ---
 // [Inside _DashboardPageState]

  // [Inside _DashboardPageState]

  Widget _buildAnalyticsSection() {
    final expenseData = expenseBreakdown;
    final revenueData = revenueBreakdown;
    final totalExpenseValue = totalExpense;
    final totalRevenueValue = totalRevenue;

    // Gross totals for percentages
    double grossExpenseTotal = ledgerAccounts.values
        .where((a) => a.type == 'Expense' && a.balance > 0)
        .fold(0.0, (sum, acc) => sum + acc.balance);
    if (grossExpenseTotal == 0) grossExpenseTotal = 1;

    double grossRevenueTotal = ledgerAccounts.values
        .where((a) => a.type == 'Revenue' && a.balance > 0)
        .fold(0.0, (sum, acc) => sum + acc.balance);
    if (grossRevenueTotal == 0) grossRevenueTotal = 1;

    // DISTINCT COLORS PALETTE
    final List<Color> distinctColors = [
      Colors.blue, Colors.red, Colors.green, Colors.orange, Colors.purple,
      Colors.teal, Colors.amber, Colors.indigo, Colors.brown, Colors.pink,
      Colors.cyan, Colors.deepOrange, Colors.lightGreen, Colors.deepPurple
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Financial Analytics',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),

        // Revenue vs Expense Bar Chart
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Money In vs Money Out',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),
                SizedBox(
                  height: 200,
                  child: BarChart(
                    BarChartData(
                      barTouchData: BarTouchData(
                        enabled: true,
                        touchTooltipData: BarTouchTooltipData(
                          getTooltipColor: (group) => Theme.of(context).cardColor,
                        ),
                      ),
                      titlesData: FlTitlesData(
                        show: true,
                        // FIX 1: Configure Bottom Titles (X-Axis) properly
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 30, // Necessary to prevent clipping
                            getTitlesWidget: (value, meta) {
                              return SideTitleWidget(
                                axisSide: meta.axisSide,
                                space: 4,
                                child: Text(
                                  value == 0 ? 'Revenue' : 'Expenses',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                              );
                            },
                          ),
                        ),
                        // FIX 2: Restore Left Titles (Y-Axis) logic
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 45, // Necessary for numbers like "10k"
                            getTitlesWidget: (value, meta) {
                              if (value == 0) return const SizedBox.shrink(); // Hide 0 to keep it clean
                              
                              String text;
                              if (value < 1000) {
                                text = value.toStringAsFixed(0);
                              } else if (value < 1000000) {
                                text = '${(value / 1000).toStringAsFixed(0)}k';
                              } else {
                                text = '${(value / 1000000).toStringAsFixed(1)}M';
                              }

                              return SideTitleWidget(
                                axisSide: meta.axisSide,
                                space: 4,
                                child: Text(
                                  text,
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                ),
                              );
                            },
                          ),
                        ),
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border(
                          bottom: BorderSide(color: Theme.of(context).dividerColor, width: 1),
                          left: BorderSide(color: Theme.of(context).dividerColor, width: 1),
                          top: BorderSide.none,
                          right: BorderSide.none,
                        ),
                      ),
                      gridData: const FlGridData(show: false),
                      barGroups: [
                        BarChartGroupData(x: 0, barRods: [
                          BarChartRodData(
                            toY: totalRevenueValue, 
                            color: Colors.green, 
                            width: 80, 
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                            backDrawRodData: BackgroundBarChartRodData(
                              show: true,
                              toY: (totalRevenueValue > totalExpenseValue ? totalRevenueValue : totalExpenseValue) * 1.1,
                              color: Colors.grey.withOpacity(0.05),
                            ),
                          )
                        ]),
                        BarChartGroupData(x: 1, barRods: [
                          BarChartRodData(
                            toY: totalExpenseValue, 
                            color: Colors.red, 
                            width: 80, 
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                            backDrawRodData: BackgroundBarChartRodData(
                              show: true,
                              toY: (totalRevenueValue > totalExpenseValue ? totalRevenueValue : totalExpenseValue) * 1.1,
                              color: Colors.grey.withOpacity(0.05),
                            ),
                          )
                        ]),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Pie Charts (Code kept same as previous correct version)
        Row(
          children: [
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Revenue Breakdown',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: SizedBox(
                              height: 250,
                              child: PieChart(
                                PieChartData(
                                  sections: revenueData.entries.toList().asMap().entries.map((mapEntry) {
                                    final index = mapEntry.key;
                                    final entry = mapEntry.value;
                                    final percentage = (entry.value / grossRevenueTotal * 100);
                                    final color = distinctColors[index % distinctColors.length];
                                    
                                    return PieChartSectionData(
                                      value: entry.value,
                                      title: '${percentage.toStringAsFixed(1)}%',
                                      color: color,
                                      radius: 80,
                                      titleStyle: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: _getContrastColor(color),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 1,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: revenueData.entries.toList().asMap().entries.map((mapEntry) {
                                  final index = mapEntry.key;
                                  final entry = mapEntry.value;
                                  final color = distinctColors[index % distinctColors.length];
                                  
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Row(
                                      children: [
                                        Container(width: 12, height: 12, color: color),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            entry.key,
                                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Expense Breakdown',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: SizedBox(
                              height: 250,
                              child: PieChart(
                                PieChartData(
                                  sections: expenseData.entries.toList().asMap().entries.map((mapEntry) {
                                    final index = mapEntry.key;
                                    final entry = mapEntry.value;
                                    final percentage = (entry.value / grossExpenseTotal * 100);
                                    final color = distinctColors[index % distinctColors.length];

                                    return PieChartSectionData(
                                      value: entry.value,
                                      title: '${percentage.toStringAsFixed(1)}%',
                                      color: color,
                                      radius: 80,
                                      titleStyle: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: _getContrastColor(color),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 1,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: expenseData.entries.toList().asMap().entries.map((mapEntry) {
                                  final index = mapEntry.key;
                                  final entry = mapEntry.value;
                                  final color = distinctColors[index % distinctColors.length];

                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Row(
                                      children: [
                                        Container(width: 12, height: 12, color: color),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            entry.key,
                                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
// --- REPLACE END ---

  Widget _buildRecentEntriesSection() {
    final filtered = filteredEntries;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Recent Journal Entries',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        
        // Filters and Search
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // Time Filters
                Row(
                  children: [
                    _buildFilterButton('This Month'),
                    _buildFilterButton('Last Month'),
                    _buildFilterButton('All Time'),
                    _buildFilterButton('Custom Range'),
                  ],
                ),
                const SizedBox(height: 16),
                
                // Search
                TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    labelText: 'Search entries...',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() {}),
                ),
              ],
            ),
          ),
        ),
        
        const SizedBox(height: 16),
        
        // Entries List
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: filtered.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'No entries found',
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_timeFilter == 'All Time')
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(
                            'Showing all ${filtered.length} entries',
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final entry = filtered[index];
                          return _buildEntryCard(entry);
                        },
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilterButton(String filter) {
    final isSelected = _timeFilter == filter;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(filter),
        selected: isSelected,
        onSelected: (selected) async {
          if (filter == 'Custom Range') {
            final DateTimeRange? picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
              currentDate: DateTime.now(),
              saveText: 'Apply',
            );
            if (picked != null) {
              setState(() {
                _customDateRange = picked;
                _timeFilter = filter;
              });
            }
          } else {
            setState(() {
              _timeFilter = filter;
              _customDateRange = null;
            });
          }
        },
      ),
    );
  }

  Widget _buildEntryCard(JournalEntry entry) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Icons.receipt,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(
          entry.description,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(DateFormat('MMM dd, yyyy').format(entry.date)),
            Text(
              'Debit: ${CurrencyService.formatAmount(entry.totalDebit)} | Credit: ${CurrencyService.formatAmount(entry.totalCredit)}',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        trailing: Icon(
          entry.isBalanced ? Icons.check_circle : Icons.error,
          color: entry.isBalanced ? Colors.green : Colors.orange,
        ),
      ),
    );
  }

  Color _getColorForExpense(String expenseName) {
    final colors = [
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.red,
      Colors.teal,
      Colors.pink,
    ];
    final index = expenseName.hashCode % colors.length;
    return colors[index];
  }

  // NEW: Color generator for revenue
  Color _getColorForRevenue(String revenueName) {
    final colors = [
      Colors.green,
      Colors.lightGreen,
      Colors.lime,
      Colors.teal,
      Colors.cyan,
      Colors.blue,
      Colors.indigo,
    ];
    final index = revenueName.hashCode % colors.length;
    return colors[index];
  }

  Color _getContrastColor(Color backgroundColor) {
    // Calculate the perceptive luminance (human eye favors green color)
    double luminance = (0.299 * backgroundColor.red + 0.587 * backgroundColor.green + 0.114 * backgroundColor.blue) / 255;
    
    // Return black for bright colors, white for dark colors
    return luminance > 0.5 ? Colors.black : Colors.white;
  }

  void _logout() async {
    await DatabaseHelper.instance.clearSession();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => AuthScreen(
          onThemeToggle: widget.onThemeToggle,
          isDarkMode: widget.isDarkMode,
        ),
      ),
    );
  }
}

// The rest of the code remains exactly the same (AccountingApp, AuthScreen, AccountingHomePage, and all other pages)
// ... [All remaining code from the original file remains unchanged] ...

// Note: Due to character limits, I've included only the modified sections. The rest of the code (AccountingApp, AuthScreen, AccountingHomePage, JournalPage, LedgerPage, TrialBalancePage, IncomeStatementPage, BalanceSheetPage, and all other classes) remains exactly as in your original file.

// --- APP WIDGETS ---
class AccountingApp extends StatefulWidget {
  const AccountingApp({Key? key}) : super(key: key);

  @override
  State<AccountingApp> createState() => _AccountingAppState();
}

class _AccountingAppState extends State<AccountingApp> {
  ThemeMode _themeMode = ThemeMode.light;

  void _toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 1. Define a Premium Color Palette
    const primaryLight = Color(0xFF0F4C75); // Deep Navy
    const primaryDark = Color(0xFF3282B8);  // Bright Steel Blue
    const accentColor = Color(0xFF00BFA5);  // Teal Accent

    return MaterialApp(
      title: 'Accounting System',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      
      // --- LIGHT THEME (Clean, Professional, Airy) ---
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryLight,
          primary: primaryLight,
          secondary: const Color(0xFF1B262C),
          surface: const Color(0xFFF8F9FA), // Slightly off-white background
          surfaceContainerHighest: const Color(0xFFE9ECEF),
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F6F8), // Light gray-blue bg
        
        // Typography: The biggest upgrade factor
        textTheme: GoogleFonts.interTextTheme(ThemeData.light().textTheme),
        
        // Modern Card Styling
        cardTheme: CardThemeData(
          elevation: 2,
          shadowColor: Colors.black.withOpacity(0.1),
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16), // Softer corners
            side: BorderSide.none, // Remove harsh borders
          ),
          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
        ),

        // Clean Input Fields
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: primaryLight, width: 2),
          ),
        ),
        
        // Modern Buttons
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 2,
          ),
        ),
      ),

      // --- DARK THEME (Sleek, High Contrast) ---
      // --- REPLACE START (Inside AccountingApp widget) ---
      // --- DARK THEME (Sleek, High Contrast) ---
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryDark,
          brightness: Brightness.dark,
          surface: const Color(0xFF1E2124), // Dark Gunmetal
          primary: primaryDark,
          secondary: accentColor,
        ),
        scaffoldBackgroundColor: const Color(0xFF121212),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
        
        // Card Theme
        cardTheme: CardThemeData(
          elevation: 4,
          shadowColor: Colors.black.withOpacity(0.4),
          color: const Color(0xFF1E2124),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withOpacity(0.05)),
          ),
        ),

        // FIX 1: Add Blue Border to "Add Line" buttons in Dark Mode
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: primaryDark, // Text/Icon Color
            side: const BorderSide(color: primaryDark), // Border Color
          ),
        ),

        // FIX 2: Add Focused Blue Border to Text Fields
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF2C2F33),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          
          // Default state (Subtle border so inputs are visible)
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
          ),
          
          // FOCUSED STATE: This brings back the Blue Outline when typing!
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: primaryDark, width: 2),
          ),
        ),
      ),
// --- REPLACE END ---
      home: FutureBuilder<String?>(
        future: DatabaseHelper.instance.getSessionUser(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasData && snapshot.data != null) {
            return DashboardPage(
              currentUser: snapshot.data!,
              onThemeToggle: _toggleTheme,
              isDarkMode: _themeMode == ThemeMode.dark,
            );
          }
          return AuthScreen(
            onThemeToggle: _toggleTheme,
            isDarkMode: _themeMode == ThemeMode.dark,
          );
        },
      ),
    );
  }
}

// --- AUTH SCREEN ---
class AuthScreen extends StatefulWidget {
  final VoidCallback onThemeToggle;
  final bool isDarkMode;

  const AuthScreen({
    Key? key,
    required this.onThemeToggle,
    required this.isDarkMode,
  }) : super(key: key);

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isLogin = true;
  bool _isCompany = false;
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;

  void _submit() async {
    if (_formKey.currentState!.validate()) {
      setState(() => _isLoading = true);
      final username = _usernameController.text.trim();
      final password = _passwordController.text.trim();
      bool success;

      if (_isLogin) {
        success = await DatabaseHelper.instance.loginUser(username, password);
        setState(() => _isLoading = false);

        if (!success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Invalid username or password')),
          );
        } else if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => DashboardPage(
                currentUser: username,
                onThemeToggle: widget.onThemeToggle,
                isDarkMode: widget.isDarkMode,
              ),
            ),
          );
        }
      } else {
        success = await DatabaseHelper.instance.registerUser(username, password);
        setState(() => _isLoading = false);

        if (!success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Username already exists')),
          );
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Account created successfully! Please Sign In.'),
              backgroundColor: Colors.green,
            ),
          );
          setState(() {
            _isLogin = true;
            _passwordController.clear();
          });
        }
      }
    }
  }

  void _showForgotPassword() {
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final resetFormKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Password'),
        content: SizedBox(
          width: 400,
          child: Form(
            key: resetFormKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Enter your username and set a new password.'),
                const SizedBox(height: 20),
                TextFormField(
                  controller: userCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (v) =>
                      v == null || v.isEmpty ? 'Username required' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: passCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'New Password',
                    prefixIcon: Icon(Icons.lock_reset),
                  ),
                  validator: (v) =>
                      v == null || v.isEmpty ? 'Password required' : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (resetFormKey.currentState!.validate()) {
                final username = userCtrl.text.trim();
                final newPass = passCtrl.text.trim();

                final success = await DatabaseHelper.instance
                    .updatePassword(username, newPass);

                if (!ctx.mounted) return;

                if (success) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Password reset successfully! You can now login.'),
                      backgroundColor: Colors.green,
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Username not found.'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: const Text('Reset Password'),
          ),
        ],
      ),
    );
  }

  // --- REPLACE START (Inside AuthScreen) ---
// [Inside AuthScreen class]

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.isDarkMode ? null : const Color(0xFF001F3F),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Branding
                Icon(Icons.account_balance_wallet_rounded,
                    size: 64,
                    color: widget.isDarkMode
                        ? Theme.of(context).colorScheme.primary
                        : Colors.white),
                const SizedBox(height: 16),
                Text(
                  "Assetry Vault",
                  style: GoogleFonts.inter(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 40),

                // Login Card
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Card(
                    elevation: 8,
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _isLogin ? 'Welcome Back' : 'Create Account',
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 24),

                            // NEW: Person vs Company Toggle (Only show on Sign Up)
                            if (!_isLogin) ...[
                              Text(
                                "I am signing up as a:",
                                style: TextStyle(
                                    color: Colors.grey[600],
                                    fontWeight: FontWeight.w500),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: SegmentedButton<bool>(
                                      segments: const [
                                        ButtonSegment<bool>(
                                            value: false,
                                            label: Text('Person'),
                                            icon: Icon(Icons.person)),
                                        ButtonSegment<bool>(
                                            value: true,
                                            label: Text('Company'),
                                            icon: Icon(Icons.business)),
                                      ],
                                      selected: {_isCompany}, // You need to add bool _isCompany = false; to your state variables
                                      onSelectionChanged: (Set<bool> newSelection) {
                                        setState(() {
                                          _isCompany = newSelection.first;
                                          // Clear controller when switching to avoid confusion
                                          _usernameController.clear();
                                        });
                                      },
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),
                            ],

                            TextFormField(
                              controller: _usernameController,
                              decoration: InputDecoration(
                                // NEW: Dynamic Label based on selection
                                labelText: _isLogin
                                    ? 'Username / Company ID'
                                    : (_isCompany ? 'Company Name' : 'Username'),
                                prefixIcon: Icon(_isLogin || !_isCompany
                                    ? Icons.person_outline
                                    : Icons.business_outlined),
                              ),
                              validator: (value) => value == null || value.isEmpty
                                  ? 'Please enter ${_isCompany && !_isLogin ? "Company Name" : "Username"}'
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _passwordController,
                              obscureText: true,
                              decoration: const InputDecoration(
                                labelText: 'Password',
                                prefixIcon: Icon(Icons.lock_outline),
                              ),
                              validator: (value) => value == null || value.isEmpty
                                  ? 'Please enter password'
                                  : null,
                            ),
                            if (_isLogin) ...[
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: _showForgotPassword,
                                  child: const Text('Forgot Password?'),
                                ),
                              ),
                            ] else
                              const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: FilledButton(
                                onPressed: _isLoading ? null : _submit,
                                child: _isLoading
                                    ? const CircularProgressIndicator(
                                        color: Colors.white)
                                    : Text(
                                        _isLogin ? 'Login' : 'Sign Up',
                                        style: const TextStyle(fontSize: 16),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  _isLogin = !_isLogin;
                                  _formKey.currentState?.reset();
                                  _usernameController.clear();
                                  _passwordController.clear();
                                  // Reset to Person default when switching modes
                                  if (!_isLogin) _isCompany = false;
                                });
                              },
                              child: Text(
                                _isLogin
                                    ? "Don't have an account? Sign Up"
                                    : "Already have an account? Login",
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
// --- REPLACE END ---
}

// --- Main Page (Existing AccountingHomePage) ---
class AccountingHomePage extends StatefulWidget {
  final String currentUser;
  final VoidCallback onThemeToggle;
  final bool isDarkMode;

  const AccountingHomePage({
    Key? key,
    required this.currentUser,
    required this.onThemeToggle,
    required this.isDarkMode,
  }) : super(key: key);

  @override
  State<AccountingHomePage> createState() => _AccountingHomePageState();
}

class _AccountingHomePageState extends State<AccountingHomePage> {
  int _selectedIndex = 0;
  List<JournalEntry> journalEntries = [];
  Map<String, LedgerAccount> ledgerAccounts = {};
  bool _isLoading = true;
  String _currentCurrency = '৳';

  @override
  void initState() {
    super.initState();
    _loadData();
    _loadCurrency();
  }

  Future<void> _loadCurrency() async {
    final currency = await DatabaseHelper.instance.getCurrency();
    setState(() {
      _currentCurrency = currency;
    });
    CurrencyService.currentCurrency = currency;
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    await _seedDefaultAccounts();
    await _refreshAccountsFromDB();
    final entries = await DatabaseHelper.instance
        .getAllJournalEntries(widget.currentUser);
    setState(() {
      journalEntries = entries; // Already sorted by date DESC from database
      for (var entry in entries) {
        _postToLedgerInMemory(entry);
      }
      _isLoading = false;
    });
  }

  Future<void> _seedDefaultAccounts() async {
    final defaultAccounts = {
      'Cash': 'Asset',
      'Accounts Receivable': 'Asset',
      'Inventory': 'Asset',
      'Equipment': 'Asset',
      'Prepaid Rent': 'Asset',
      'Prepaid Insurance': 'Asset',
      'Land': 'Asset',
      'Building': 'Asset',
      'Accumulated Depreciation': 'Asset',
      'Accounts Payable': 'Liability',
      'Notes Payable': 'Liability',
      'Salaries Payable': 'Liability',
      'Unearned Revenue': 'Liability',
      'Interest Payable': 'Liability',
      'Capital': 'Equity',
      'Drawings': 'Equity',
      'Retained Earnings': 'Equity',
      'Sales Revenue': 'Revenue',
      'Service Revenue': 'Revenue',
      'Interest Revenue': 'Revenue',
      'Cost of Goods Sold': 'Expense',
      'Rent Expense': 'Expense',
      'Salary Expense': 'Expense',
      'Utilities Expense': 'Expense',
      'Purchases': 'Expense',
      'Depreciation Expense': 'Expense',
      'Advertising Expense': 'Expense',
      'Interest Expense': 'Expense',
      'Insurance Expense': 'Expense',
    };

    for (var entry in defaultAccounts.entries) {
      await DatabaseHelper.instance.insertAccount(entry.key, entry.value);
    }
  }

  Future<void> _refreshAccountsFromDB() async {
    final accountsData = await DatabaseHelper.instance.getAllAccounts();
    Map<String, LedgerAccount> newMap = {};

    for (var row in accountsData) {
      newMap[row['name']] = LedgerAccount(
        name: row['name'],
        type: row['type'],
        transactions: [],
      );
    }
    setState(() {
      ledgerAccounts = newMap;
    });
  }

  void _postToLedgerInMemory(JournalEntry entry) {
    for (var line in entry.lines) {
      if (ledgerAccounts.containsKey(line.accountName)) {
        // FIXED: Sort transactions oldest-to-newest by inserting at beginning
        ledgerAccounts[line.accountName]!.transactions.insert(
          0,
          LedgerTransaction(
            date: entry.date,
            description: entry.description,
            debit: line.debit,
            credit: line.credit,
            journalId: entry.id,
          ),
        );
      }
    }
  }

  void _reverseLedgerPostingsInMemory(JournalEntry entry) {
    for (var line in entry.lines) {
      if (ledgerAccounts.containsKey(line.accountName)) {
        ledgerAccounts[line.accountName]!
            .transactions
            .removeWhere((t) => t.journalId == entry.id);
      }
    }
  }

  Future<bool> _validateAndCreateAccounts(JournalEntry entry) async {
    final newAccountNames = entry.lines
        .map((line) => line.accountName)
        .toSet()
        .where((name) => !ledgerAccounts.containsKey(name))
        .toList();

    if (newAccountNames.isEmpty) {
      return true;
    }

    final Map<String, String>? categorizedAccounts =
        await _showAccountTypeDialog(newAccountNames);

    if (categorizedAccounts == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Posting cancelled. New accounts were not categorized.'),
            backgroundColor: Colors.orange.shade700,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
      }
      return false;
    }

    for (var entry in categorizedAccounts.entries) {
      await DatabaseHelper.instance.insertAccount(entry.key, entry.value);
    }
    await _refreshAccountsFromDB();
    for (var je in journalEntries) {
      _postToLedgerInMemory(je);
    }

    return true;
  }

  Future<Map<String, String>?> _showAccountTypeDialog(List<String> newAccounts) async {
    return showDialog<Map<String, String>?>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final Map<String, String?> selections = Map.fromEntries(newAccounts.map((name) => MapEntry(name, null)));

        return StatefulBuilder(
          builder: (context, setDialogState) {
            bool allSelected = !selections.values.any((v) => v == null);

            return AlertDialog(
              title: const Text('Categorize New Accounts'),
              content: SizedBox(
                width: 450,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(newAccounts.length, (index) {
                      final accountName = newAccounts[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Text(
                                accountName,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 16),
                            DropdownButton<String>(
                              value: selections[accountName],
                              hint: const Text('Select Type...'),
                              items: ['Asset', 'Liability', 'Equity', 'Revenue', 'Expense'].map((String type) {
                                return DropdownMenuItem<String>(
                                  value: type,
                                  child: Text(type, style: const TextStyle(fontSize: 16)),
                                );
                              }).toList(),
                              onChanged: (String? newValue) {
                                setDialogState(() {
                                  selections[accountName] = newValue;
                                });
                              },
                            ),
                          ],
                        ),
                      );
                    }),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  child: const Text('Cancel', style: TextStyle(fontSize: 16)),
                  onPressed: () => Navigator.of(dialogContext).pop(null),
                ),
                FilledButton(
                  child: const Text('Create Accounts', style: TextStyle(fontSize: 16)),
                  onPressed: allSelected
                      ? () {
                          Navigator.of(dialogContext).pop(selections.cast<String, String>());
                        }
                      : null,
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _addJournalEntry(JournalEntry entry) async {
    if (!entry.isBalanced) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.error_outline, color: Colors.white),
              SizedBox(width: 8),
              Text('Entry is not balanced! Debits must equal Credits',
                  style: TextStyle(fontSize: 16)),
            ],
          ),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
      return;
    }

    final bool accountsReady = await _validateAndCreateAccounts(entry);
    if (!accountsReady) return;

    await DatabaseHelper.instance.insertJournalEntry(entry, widget.currentUser);
    setState(() {
      journalEntries.insert(0, entry); // Add to beginning for newest first
      _postToLedgerInMemory(entry);

      // FIX: Sort affected accounts Ascending (Oldest -> Newest)
      for (var line in entry.lines) {
        if (ledgerAccounts.containsKey(line.accountName)) {
          ledgerAccounts[line.accountName]!
              .transactions
              .sort((a, b) => a.date.compareTo(b.date));
        }
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle_outline, color: Colors.white),
            SizedBox(width: 8),
            Text('Journal entry posted successfully!',
                style: TextStyle(fontSize: 16)),
          ],
        ),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  void _deleteJournalEntry(String entryId) async {
    await DatabaseHelper.instance.deleteJournalEntry(entryId);

    setState(() {
      try {
        final entryToRemove = journalEntries.firstWhere((e) => e.id == entryId);
        _reverseLedgerPostingsInMemory(entryToRemove);
        journalEntries.removeWhere((e) => e.id == entryId);
      } catch (e) {
        // Ignore if not found
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Journal entry deleted.', style: TextStyle(fontSize: 16)),
        backgroundColor: Colors.blue.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

 void _updateJournalEntry(JournalEntry oldEntry, JournalEntry newEntry) async {
    if (!newEntry.isBalanced) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Updated entry is not balanced!',
              style: TextStyle(fontSize: 16)),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
      return;
    }

    final bool accountsReady = await _validateAndCreateAccounts(newEntry);
    if (!accountsReady) return;

    await DatabaseHelper.instance
        .insertJournalEntry(newEntry, widget.currentUser);
    setState(() {
      _reverseLedgerPostingsInMemory(oldEntry);
      _postToLedgerInMemory(newEntry);

      // FIX: Sort affected accounts Ascending (Oldest -> Newest)
      for (var line in newEntry.lines) {
        if (ledgerAccounts.containsKey(line.accountName)) {
          ledgerAccounts[line.accountName]!
              .transactions
              .sort((a, b) => a.date.compareTo(b.date));
        }
      }

      final index = journalEntries.indexWhere((e) => e.id == oldEntry.id);
      if (index != -1) {
        journalEntries[index] = newEntry;
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Journal entry updated successfully!',
            style: TextStyle(fontSize: 16)),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  void _navigateToDashboard() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => DashboardPage(
          currentUser: widget.currentUser,
          onThemeToggle: widget.onThemeToggle,
          isDarkMode: widget.isDarkMode,
        ),
      ),
    );
  }

  void _navigateToSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SettingsPage(
          onThemeToggle: widget.onThemeToggle,
          isDarkMode: widget.isDarkMode,
          currentUser: widget.currentUser,
          onDataChanged: _loadData, // <--- ADD THIS LINE
        ),
      ),
    );
  }

  void _logout() async {
    await DatabaseHelper.instance.clearSession();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (context) => AuthScreen(
          onThemeToggle: widget.onThemeToggle, isDarkMode: widget.isDarkMode),
    ));
  }

  void _handleManageAccounts() {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Manage Accounts'),
        children: [
          SimpleDialogOption(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
            child: const Row(
              children: [
                Icon(Icons.switch_account, color: Colors.blue),
                SizedBox(width: 12),
                Text('Switch Accounts', style: TextStyle(fontSize: 16)),
              ],
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _handleSwitchAccount();
            },
          ),
          SimpleDialogOption(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
            child: const Row(
              children: [
                Icon(Icons.delete_forever, color: Colors.red),
                SizedBox(width: 12),
                Text('Delete Account', style: TextStyle(fontSize: 16, color: Colors.red)),
              ],
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _confirmDeleteAccount();
            },
          ),
        ],
      ),
    );
  }

  void _confirmDeleteAccount() {
    final confirmCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Account Permanently?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This will delete all your journal entries and data. This action cannot be undone.'),
            const SizedBox(height: 16),
            Text('Type "${widget.currentUser}" to confirm:'),
            const SizedBox(height: 8),
            TextField(
              controller: confirmCtrl,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Username',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(ctx),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete Account'),
            onPressed: () async {
              if (confirmCtrl.text.trim() == widget.currentUser) {
                await DatabaseHelper.instance.deleteUser(widget.currentUser);
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(
                      builder: (context) => AuthScreen(
                          onThemeToggle: widget.onThemeToggle,
                          isDarkMode: widget.isDarkMode)),
                  (route) => false,
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Account deleted successfully')),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Username does not match')),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  void _handleSwitchAccount() async {
    final users = await DatabaseHelper.instance.getAllUsernames();
    final otherUsers = users.where((u) => u != widget.currentUser).toList();

    if (!mounted) return;

    if (otherUsers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No other accounts found to switch to.")),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Switch Account'),
        children: otherUsers
            .map((user) => SimpleDialogOption(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        child: Text(
                          user[0].toUpperCase(),
                          style: TextStyle(color: Theme.of(context).colorScheme.onPrimary),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Text(user, style: const TextStyle(fontSize: 16)),
                    ],
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _promptPasswordForSwitch(user);
                  },
                ))
            .toList(),
      ),
    );
  }

  void _promptPasswordForSwitch(String username) {
    final passCtrl = TextEditingController();
    showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text('Login as $username'),
              content: TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Password', border: OutlineInputBorder()),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                FilledButton(
                  onPressed: () async {
                    final success = await DatabaseHelper.instance.loginUser(username, passCtrl.text.trim());
                    if (!ctx.mounted) return;
                    Navigator.pop(ctx);

                    if (success) {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                          builder: (context) => AccountingHomePage(
                            currentUser: username,
                            onThemeToggle: widget.onThemeToggle,
                            isDarkMode: widget.isDarkMode,
                          ),
                        ),
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Invalid Password')));
                    }
                  },
                  child: const Text('Login'),
                ),
              ],
            ));
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final allAccountNames = ledgerAccounts.keys.toList();

    final List<Widget> pages = [
      JournalPage(
        entries: journalEntries,
        onAddEntry: _addJournalEntry,
        onUpdateEntry: _updateJournalEntry,
        onDeleteEntry: _deleteJournalEntry,
        allAccountNames: allAccountNames,
      ),
      LedgerPage(ledgerAccounts: ledgerAccounts),
      TrialBalancePage(ledgerAccounts: ledgerAccounts),
      IncomeStatementPage(ledgerAccounts: ledgerAccounts),
      BalanceSheetPage(ledgerAccounts: ledgerAccounts),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.account_balance_wallet, size: 30),
            SizedBox(width: 12),
            Text('Accounting System', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 22)),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _navigateToDashboard,
          tooltip: 'Back to Dashboard',
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Account',
            offset: const Offset(0, 50),
            icon: CircleAvatar(
              radius: 18,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Text(
                widget.currentUser.isNotEmpty ? widget.currentUser[0].toUpperCase() : 'U',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            itemBuilder: (context) => [
              PopupMenuItem(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Signed in as', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    Text(
                      widget.currentUser,
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'manage',
                child: Row(
                  children: [
                    Icon(Icons.manage_accounts, size: 20, color: Colors.grey),
                    SizedBox(width: 12),
                    Text('Manage Accounts'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, size: 20, color: Colors.grey),
                    SizedBox(width: 12),
                    Text('Logout'),
                  ],
                ),
              ),
            ],
            onSelected: (value) {
              if (value == 'logout') {
                _logout();
              } else if (value == 'manage') {
                _handleManageAccounts();
              }
            },
          ),
          const SizedBox(width: 16),
        ],
        elevation: 0,
        scrolledUnderElevation: 3,
      ),
      body: Row(
        children: [
          // --- REPLACE START (Inside _AccountingHomePageState build method) ---
NavigationRail(
  // 1. Structural Styling
  minWidth: 104, // Wider rail for a "Sidebar" feel
  backgroundColor: Theme.of(context).cardTheme.color, // Matches the clean white/dark card background
  elevation: 5, // Adds a subtle shadow to separate it from the content
  indicatorColor: Theme.of(context).colorScheme.primary.withOpacity(0.15), // Soft pill shape behind icon
  
  // 2. Logic (Kept Intact)
  selectedIndex: _selectedIndex,
  onDestinationSelected: (index) {
    setState(() {
      _selectedIndex = index;
    });
  },
  labelType: NavigationRailLabelType.all,

  // 3. Leading "Logo" Section (New)
  leading: Column(
    children: [
      const SizedBox(height: 30),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.4),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Icon(Icons.account_balance_wallet_rounded, color: Colors.white, size: 26),
      ),
      const SizedBox(height: 30),
    ],
  ),

  // 4. Typography & Icon Styling
  selectedLabelTextStyle: TextStyle(
    color: Theme.of(context).colorScheme.primary,
    fontWeight: FontWeight.bold,
    fontSize: 12,
    letterSpacing: 0.5,
  ),
  unselectedLabelTextStyle: TextStyle(
    color: Colors.grey.shade500,
    fontWeight: FontWeight.w500,
    fontSize: 11,
  ),
  selectedIconTheme: IconThemeData(
    color: Theme.of(context).colorScheme.primary, 
    size: 28
  ),
  unselectedIconTheme: IconThemeData(
    color: Colors.grey.shade400, 
    size: 26
  ),

  // 5. Trailing Section (Settings)
  trailing: Expanded(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        IconButton(
          onPressed: _navigateToSettings,
          icon: Icon(Icons.settings_outlined, color: Colors.grey.shade600),
          tooltip: 'Settings',
        ),
        const SizedBox(height: 24),
      ],
    ),
  ),

  // 6. Destinations (Updated Icons)
  destinations: const [
    NavigationRailDestination(
      icon: Icon(Icons.book_outlined),
      selectedIcon: Icon(Icons.book),
      label: Text('Journal'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.account_balance_outlined),
      selectedIcon: Icon(Icons.account_balance),
      label: Text('Ledger'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.balance_outlined),
      selectedIcon: Icon(Icons.balance),
      label: Text('Trial Balance.'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.trending_up),
      selectedIcon: Icon(Icons.trending_up),
      label: Text('Income Statement'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.pie_chart_outline),
      selectedIcon: Icon(Icons.pie_chart),
      label: Text('Balance Sheet'),
    ),
  ],
),
// --- REPLACE END ---
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(child: pages[_selectedIndex]),
        ],
      ),
    );
  }
}

// --- Existing Pages (JournalPage, LedgerPage, TrialBalancePage, IncomeStatementPage, BalanceSheetPage) ---

class JournalPage extends StatefulWidget {
  final Function(JournalEntry) onAddEntry;
  final Function(JournalEntry, JournalEntry) onUpdateEntry;
  final Function(String) onDeleteEntry;
  final List<JournalEntry> entries;
  final List<String> allAccountNames;

  const JournalPage({
    Key? key,
    required this.onAddEntry,
    required this.onUpdateEntry,
    required this.onDeleteEntry,
    required this.entries,
    required this.allAccountNames,
  }) : super(key: key);

  @override
  State<JournalPage> createState() => _JournalPageState();
}

class _JournalPageState extends State<JournalPage> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  
  // 1. Search Controllers
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  DateTime _selectedDate = DateTime.now();
  List<JournalLineInput> _lines = [JournalLineInput(), JournalLineInput()];

  JournalEntry? _entryBeingEdited;

  @override
  void dispose() {
    _searchController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  // 2. Filter Logic
  List<JournalEntry> get filteredEntries {
    if (_searchQuery.isEmpty) {
      return widget.entries;
    }
    final searchLower = _searchQuery.toLowerCase();
    return widget.entries.where((entry) {
      final matchesDescription = entry.description.toLowerCase().contains(searchLower);
      final matchesAccount = entry.lines.any((line) => 
        line.accountName.toLowerCase().contains(searchLower)
      );
      final matchesAmount = entry.totalDebit.toString().contains(searchLower);
      
      return matchesDescription || matchesAccount || matchesAmount;
    }).toList();
  }

  void _addLine() {
    setState(() {
      _lines.add(JournalLineInput());
    });
  }

  void _removeLine(int index) {
    if (_lines.length > 2) {
      setState(() {
        _lines.removeAt(index);
      });
    }
  }

  void _clearForm() {
    _formKey.currentState?.reset();
    _descriptionController.clear();
    setState(() {
      _lines = [JournalLineInput(), JournalLineInput()];
      _selectedDate = DateTime.now();
      _entryBeingEdited = null;
    });
  }

  void _startEditing(JournalEntry entry) {
    setState(() {
      _entryBeingEdited = entry;
      _descriptionController.text = entry.description;
      _selectedDate = entry.date;
      _lines = entry.lines.map((line) {
        final input = JournalLineInput();
        input.accountController.text = line.accountName;
        input.debitController.text =
            line.debit > 0 ? line.debit.toStringAsFixed(2) : '';
        input.creditController.text =
            line.credit > 0 ? line.credit.toStringAsFixed(2) : '';
        return input;
      }).toList();
    });
  }

  void _showDeleteDialog(String entryId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Journal Entry?', style: TextStyle(fontSize: 20)),
        content: const Text(
            'This will reverse the ledger postings and permanently delete this entry. Are you sure?',
            style: TextStyle(fontSize: 16)),
        actions: [
          TextButton(
            child: const Text('Cancel', style: TextStyle(fontSize: 16)),
            onPressed: () => Navigator.of(context).pop(),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () {
              widget.onDeleteEntry(entryId);
              Navigator.of(context).pop();
            },
            child: const Text('Delete', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }

  void _submitEntry() {
    if (_formKey.currentState!.validate()) {
      final lines = _lines
          .map((line) => JournalLine(
                accountName: line.accountController.text,
                debit: double.tryParse(line.debitController.text) ?? 0,
                credit: double.tryParse(line.creditController.text) ?? 0,
              ))
          .toList();

      final entryId = _entryBeingEdited?.id ??
          'JE-${DateTime.now().millisecondsSinceEpoch}';

      String description = _descriptionController.text.trim();
      if (description.isEmpty) {
        int nextNum = widget.entries.length + 1;
        description = 'Journal No-$nextNum';
      }

      final entry = JournalEntry(
        id: entryId,
        date: _selectedDate,
        description: description,
        lines: lines,
      );

      if (_entryBeingEdited != null) {
        widget.onUpdateEntry(_entryBeingEdited!, entry);
      } else {
        widget.onAddEntry(entry);
      }

      _clearForm();
    }
  }

  double get totalDebit => _lines.fold(
      0, (sum, line) => sum + (double.tryParse(line.debitController.text) ?? 0));
  double get totalCredit => _lines.fold(0,
      (sum, line) => sum + (double.tryParse(line.creditController.text) ?? 0));
  bool get isBalanced =>
      (totalDebit - totalCredit).abs() < 0.01 && totalDebit > 0;

  @override
  Widget build(BuildContext context) {
    final displayEntries = filteredEntries;

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- LEFT SIDE: FORM ---
          Expanded(
            flex: 3,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              Icons.add_circle_outline,
                              size: 28,
                              color: Theme.of(context).colorScheme.onPrimaryContainer,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Text(
                            _entryBeingEdited == null
                                ? 'New Journal Entry'
                                : 'Edit Journal Entry',
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 24,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              controller: _descriptionController,
                              style: const TextStyle(fontSize: 16),
                              decoration: const InputDecoration(
                                labelText: 'Transaction Description (Optional)',
                                hintText: 'Leave blank for "Journal No-X"',
                                prefixIcon: Icon(Icons.description_outlined),
                                labelStyle: TextStyle(fontSize: 16),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.calendar_today, size: 22),
                            label: Text(
                              DateFormat('MMM dd, yyyy').format(_selectedDate),
                              style: const TextStyle(fontSize: 16),
                            ),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 22),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            onPressed: () async {
                              final date = await showDatePicker(
                                context: context,
                                initialDate: _selectedDate,
                                firstDate: DateTime(2000),
                                lastDate: DateTime(2100),
                              );
                              if (date != null) {
                                setState(() => _selectedDate = date);
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: Text('Account', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                            ),
                            Expanded(
                              child: Text('Debit', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                            ),
                            Expanded(
                              child: Text('Credit', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                            ),
                            SizedBox(width: 48),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _lines.length,
                          itemBuilder: (context, index) {
                            return Padding(
                              key: _lines[index].key,
                              padding: const EdgeInsets.only(bottom: 12.0),
                              child: Row(
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: Autocomplete<String>(
                                      initialValue: TextEditingValue(text: _lines[index].accountController.text),
                                      optionsBuilder: (TextEditingValue textEditingValue) {
                                        if (textEditingValue.text == '') {
                                          return const Iterable<String>.empty();
                                        }
                                        return widget.allAccountNames.where((String option) {
                                          return option.toLowerCase().contains(textEditingValue.text.toLowerCase());
                                        });
                                      },
                                      onSelected: (String selection) {
                                        _lines[index].accountController.text = selection;
                                      },
                                      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                                        if (_lines[index].accountController.text.isNotEmpty && controller.text.isEmpty) {
                                          controller.text = _lines[index].accountController.text;
                                        }
                                        _lines[index].accountController = controller;
                                        return TextFormField(
                                          controller: controller,
                                          focusNode: focusNode,
                                          style: const TextStyle(fontSize: 16),
                                          onFieldSubmitted: (value) => onFieldSubmitted(),
                                          decoration: const InputDecoration(
                                            hintText: 'Select or type account name',
                                            isDense: true,
                                          ),
                                          validator: (value) => value?.isEmpty ?? true ? 'Required' : null,
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: TextFormField(
                                      controller: _lines[index].debitController,
                                      style: const TextStyle(fontSize: 16),
                                      decoration: InputDecoration(
                                        hintText: '0.00',
                                        isDense: true,
                                        prefixText: '${CurrencyService.getSymbol()} ',
                                      ),
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                      onChanged: (value) {
                                        if (value.isNotEmpty) {
                                          _lines[index].creditController.clear();
                                        }
                                        setState(() {});
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: TextFormField(
                                      controller: _lines[index].creditController,
                                      style: const TextStyle(fontSize: 16),
                                      decoration: InputDecoration(
                                        hintText: '0.00',
                                        isDense: true,
                                        prefixText: '${CurrencyService.getSymbol()} ',
                                      ),
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                      onChanged: (value) {
                                        if (value.isNotEmpty) {
                                          _lines[index].debitController.clear();
                                        }
                                        setState(() {});
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  IconButton(
                                    icon: Icon(
                                      Icons.remove_circle_outline,
                                      size: 28,
                                      color: _lines.length > 2 ? Colors.red.shade400 : Colors.grey.shade300,
                                    ),
                                    onPressed: _lines.length > 2 ? () => _removeLine(index) : null,
                                    tooltip: 'Remove line',
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      const Divider(height: 32),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Theme.of(context).dividerColor),
                        ),
                        child: Row(
                          children: [
                            const Expanded(
                              flex: 3,
                              child: Text('Total', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                            ),
                            Expanded(
                              child: Text(
                                CurrencyService.formatAmount(totalDebit),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                  color: totalDebit > 0 ? Colors.green.shade700 : Colors.grey,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                CurrencyService.formatAmount(totalCredit),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                  color: totalCredit > 0 ? Colors.green.shade700 : Colors.grey,
                                ),
                              ),
                            ),
                            const SizedBox(width: 48),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          OutlinedButton.icon(
                            icon: const Icon(Icons.add, size: 24),
                            label: const Text('Add Line', style: TextStyle(fontSize: 16)),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: _addLine,
                          ),
                          const Spacer(),
                          if (_entryBeingEdited != null) ...[
                            TextButton(
                              onPressed: _clearForm,
                              child: const Text('Cancel Edit', style: TextStyle(fontSize: 16)),
                            ),
                            const SizedBox(width: 16),
                          ],
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: isBalanced
                                  ? Colors.green.shade50.withOpacity(0.1)
                                  : Colors.orange.shade50.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: isBalanced ? Colors.green.shade200 : Colors.orange.shade200,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isBalanced ? Icons.check_circle : Icons.warning_amber_rounded,
                                  size: 22,
                                  color: isBalanced ? Colors.green.shade700 : Colors.orange.shade700,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  isBalanced ? 'Balanced' : 'Not Balanced',
                                  style: TextStyle(
                                    color: isBalanced ? Colors.green.shade700 : Colors.orange.shade700,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          FilledButton.icon(
                            icon: Icon(_entryBeingEdited == null ? Icons.send : Icons.save, size: 24),
                            label: Text(
                              _entryBeingEdited == null ? 'Post Entry' : 'Update Entry',
                              style: const TextStyle(fontSize: 16),
                            ),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: isBalanced ? _submitEntry : null,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 24),
          
          // --- RIGHT SIDE: LIST & SEARCH ---
          Expanded(
            flex: 2,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // HEADER ROW
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.history,
                            size: 24,
                            color: Theme.of(context).colorScheme.onSecondaryContainer,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Journal Entries',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                                fontSize: 20,
                              ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            _searchQuery.isEmpty 
                              ? '${widget.entries.length} entries'
                              : '${displayEntries.length} found',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // 3. FIX: High Visibility Search Bar
                    TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search journals, accounts, or amounts...',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        isDense: true,
                        filled: true,
                        // Using a standard color to ensure visibility
                        fillColor: Colors.grey.withOpacity(0.1), 
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (value) {
                        setState(() {
                          _searchQuery = value;
                        });
                      },
                    ),

                    const SizedBox(height: 16),

                    // LIST
                    Expanded(
                      child: displayEntries.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _searchQuery.isEmpty ? Icons.inbox_outlined : Icons.search_off_outlined,
                                    size: 72, 
                                    color: Colors.grey.shade300
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    _searchQuery.isEmpty ? 'No entries yet' : 'No matching entries found',
                                    style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 18,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              itemCount: displayEntries.length,
                              itemBuilder: (context, index) {
                                final entry = displayEntries[index];
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 16),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).cardTheme.color,
                                    borderRadius: BorderRadius.circular(16),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.05),
                                        blurRadius: 10,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: Theme(
                                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                                      child: ExpansionTile(
                                        tilePadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                                        leading: Container(
                                          padding: const EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: Icon(
                                            Icons.receipt_long_rounded,
                                            color: Theme.of(context).colorScheme.primary,
                                          ),
                                        ),
                                        title: Text(
                                          entry.description,
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                        ),
                                        subtitle: Padding(
                                          padding: const EdgeInsets.only(top: 6),
                                          child: Row(
                                            children: [
                                              Icon(Icons.calendar_today, size: 14, color: Colors.grey.shade600),
                                              const SizedBox(width: 4),
                                              Text(
                                                DateFormat('MMM dd, yyyy').format(entry.date),
                                                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                                              ),
                                              if (!entry.isBalanced) ...[
                                                const SizedBox(width: 8),
                                                Text(
                                                  '(Unbalanced)',
                                                  style: TextStyle(color: Colors.red.shade700, fontSize: 12, fontWeight: FontWeight.bold),
                                                ),
                                              ]
                                            ],
                                          ),
                                        ),
                                        children: [
                                          Container(
                                            color: Theme.of(context).colorScheme.surface.withOpacity(0.5),
                                            padding: const EdgeInsets.all(24),
                                            child: Column(
                                              children: [
                                                Table(
                                                  columnWidths: const {
                                                    0: FlexColumnWidth(3),
                                                    1: FlexColumnWidth(1),
                                                    2: FlexColumnWidth(1),
                                                  },
                                                  children: [
                                                    TableRow(
                                                      decoration: BoxDecoration(
                                                        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
                                                      ),
                                                      children: [
                                                        Padding(
                                                          padding: const EdgeInsets.only(bottom: 12),
                                                          child: Text('ACCOUNT', style: TextStyle(color: Colors.grey.shade600, fontSize: 12, fontWeight: FontWeight.bold)),
                                                        ),
                                                        Padding(
                                                          padding: const EdgeInsets.only(bottom: 12),
                                                          child: Text('DEBIT', textAlign: TextAlign.right, style: TextStyle(color: Colors.grey.shade600, fontSize: 12, fontWeight: FontWeight.bold)),
                                                        ),
                                                        Padding(
                                                          padding: const EdgeInsets.only(bottom: 12),
                                                          child: Text('CREDIT', textAlign: TextAlign.right, style: TextStyle(color: Colors.grey.shade600, fontSize: 12, fontWeight: FontWeight.bold)),
                                                        ),
                                                      ],
                                                    ),
                                                    const TableRow(children: [SizedBox(height: 12), SizedBox(height: 12), SizedBox(height: 12)]),
                                                    ...entry.lines.map((line) => TableRow(
                                                          children: [
                                                            Padding(
                                                              padding: const EdgeInsets.symmetric(vertical: 8),
                                                              child: Text(line.accountName, style: const TextStyle(fontWeight: FontWeight.w500)),
                                                            ),
                                                            Padding(
                                                              padding: const EdgeInsets.symmetric(vertical: 8),
                                                              child: Text(
                                                                line.debit > 0 ? CurrencyService.formatAmount(line.debit) : '-',
                                                                textAlign: TextAlign.right,
                                                                style: TextStyle(color: line.debit > 0 ? Colors.green.shade700 : Colors.grey),
                                                              ),
                                                            ),
                                                            Padding(
                                                              padding: const EdgeInsets.symmetric(vertical: 8),
                                                              child: Text(
                                                                line.credit > 0 ? CurrencyService.formatAmount(line.credit) : '-',
                                                                textAlign: TextAlign.right,
                                                                style: TextStyle(color: line.credit > 0 ? Colors.green.shade700 : Colors.grey),
                                                              ),
                                                            ),
                                                          ],
                                                        )),
                                                  ],
                                                ),
                                                const SizedBox(height: 16),
                                                Row(
                                                  mainAxisAlignment: MainAxisAlignment.end,
                                                  children: [
                                                    OutlinedButton.icon(
                                                      icon: const Icon(Icons.edit, size: 18),
                                                      label: const Text('Edit'),
                                                      onPressed: () => _startEditing(entry),
                                                    ),
                                                    const SizedBox(width: 12),
                                                    FilledButton.icon(
                                                      icon: const Icon(Icons.delete, size: 18),
                                                      label: const Text('Delete'),
                                                      style: FilledButton.styleFrom(backgroundColor: Colors.red.shade50, foregroundColor: Colors.red),
                                                      onPressed: () => _showDeleteDialog(entry.id),
                                                    ),
                                                  ],
                                                )
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class JournalLineInput {
  final Key key = UniqueKey();
  TextEditingController accountController = TextEditingController();
  TextEditingController debitController = TextEditingController();
  TextEditingController creditController = TextEditingController();
}

class LedgerPage extends StatefulWidget {
  final Map<String, LedgerAccount> ledgerAccounts;

  const LedgerPage({Key? key, required this.ledgerAccounts}) : super(key: key);

  @override
  State<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends State<LedgerPage> {
  String? _selectedAccount;

  @override
  Widget build(BuildContext context) {
    final accountsByType = <String, List<String>>{};
    for (var entry in widget.ledgerAccounts.entries) {
      if (entry.value.transactions.isNotEmpty) {
        accountsByType.putIfAbsent(entry.value.type, () => []).add(entry.key);
      }
    }

    accountsByType.forEach((key, value) {
      value.sort();
    });

    Color getBalanceColor(double balance) {
      if (balance >= 0) {
        return Colors.green.shade700;
      } else {
        return Colors.red.shade700;
      }
    }

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Row(
        children: [
          SizedBox(
            width: 320,
            child: Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.account_tree,
                            size: 24,
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Chart of Accounts',
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 18,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      children: [
                        for (var type in [
                          'Asset',
                          'Liability',
                          'Equity',
                          'Revenue',
                          'Expense'
                        ])
                          if (accountsByType.containsKey(type))
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(20, 16, 20, 8),
                                  child: Text(
                                    type,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey.shade600,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ),
                                ...accountsByType[type]!.map((accountName) {
                                  final account =
                                      widget.ledgerAccounts[accountName]!;
                                  final isSelected =
                                      _selectedAccount == accountName;
                                  final balColor =
                                      getBalanceColor(account.balance);

                                  return Container(
                                    margin: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primaryContainer
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: ListTile(
                                      dense: true,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 4),
                                      title: Text(
                                        accountName,
                                        style: TextStyle(
                                          fontWeight: isSelected
                                              ? FontWeight.w600
                                              : FontWeight.normal,
                                          fontSize: 15,
                                        ),
                                      ),
                                      trailing: Text(
                                        CurrencyService.formatAmount(account.balance.abs()),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                          color: balColor,
                                        ),
                                      ),
                                      selected: isSelected,
                                      onTap: () {
                                        setState(() =>
                                            _selectedAccount = accountName);
                                      },
                                    ),
                                  );
                                }),
                              ],
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Card(
              child: _selectedAccount == null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.account_balance_outlined,
                              size: 72, color: Colors.grey.shade300),
                          const SizedBox(height: 16),
                          Text(
                            'Select an account',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w500,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _selectedAccount!,
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 26,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        widget.ledgerAccounts[_selectedAccount]!
                                            .type,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Builder(builder: (context) {
                                final acc = widget
                                    .ledgerAccounts[_selectedAccount]!;
                                final balColor = getBalanceColor(acc.balance);

                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 20, vertical: 16),
                                  decoration: BoxDecoration(
                                    color: balColor.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: balColor.withOpacity(0.3),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        'Current Balance',
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        CurrencyService.formatAmount(acc.balance.abs()),
                                        style: TextStyle(
                                          fontSize: 28,
                                          fontWeight: FontWeight.bold,
                                          color: balColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                            ],
                          ),
                          const SizedBox(height: 32),
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                                  .withOpacity(0.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Row(
                              children: [
                                Expanded(
                                    flex: 1,
                                    child: Text('Date',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15))),
                                Expanded(
                                    flex: 2,
                                    child: Text('Description',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15))),
                                Expanded(
                                    flex: 1,
                                    child: Text('Debit',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15))),
                                Expanded(
                                    flex: 1,
                                    child: Text('Credit',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15))),
                                Expanded(
                                    flex: 1,
                                    child: Text('Balance',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15))),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: widget.ledgerAccounts[_selectedAccount]!
                                    .transactions.isEmpty
                                ? Center(
                                    child: Text(
                                      'No transactions',
                                      style: TextStyle(
                                        color: Colors.grey.shade600,
                                        fontSize: 16,
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    itemCount: widget
                                        .ledgerAccounts[_selectedAccount]!
                                        .transactions
                                        .length,
                                    itemBuilder: (context, index) {
                                      final transaction = widget
                                          .ledgerAccounts[_selectedAccount]!
                                          .transactions[index];
                                      final account = widget
                                          .ledgerAccounts[_selectedAccount]!;

                                      double runningBalance = 0;
                                      for (int i = 0; i <= index; i++) {
                                        final t = account.transactions[i];
                                        if (account.type == 'Asset' ||
                                            account.type == 'Expense') {
                                          runningBalance +=
                                              t.debit - t.credit;
                                        } else {
                                          runningBalance +=
                                              t.credit - t.debit;
                                        }
                                      }

                                      final runBalColor =
                                          getBalanceColor(runningBalance);

                                      return Container(
                                        margin:
                                            const EdgeInsets.only(bottom: 8),
                                        padding: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context).cardColor,
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          border: Border.all(
                                              color: Theme.of(context)
                                                  .dividerColor),
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              flex: 1,
                                              child: Text(
                                                DateFormat('MMM dd')
                                                    .format(transaction.date),
                                                style: const TextStyle(
                                                    fontSize: 15),
                                              ),
                                            ),
                                            Expanded(
                                              flex: 2,
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    transaction.description,
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w500,
                                                        fontSize: 15),
                                                  ),
                                                  Text(
                                                    transaction.journalId,
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      color: Colors
                                                          .grey.shade600,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            Expanded(
                                              flex: 1,
                                              child: Text(
                                                transaction.debit > 0
                                                    ? CurrencyService.formatAmount(transaction.debit)
                                                    : '-',
                                                style: TextStyle(
                                                  fontSize: 15,
                                                  color:
                                                      transaction.debit > 0
                                                          ? Colors
                                                              .green.shade700
                                                          : null,
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              flex: 1,
                                              child: Text(
                                                transaction.credit > 0
                                                    ? CurrencyService.formatAmount(transaction.credit)
                                                    : '-',
                                                style: TextStyle(
                                                  fontSize: 15,
                                                  color:
                                                      transaction.credit > 0
                                                          ? Colors
                                                              .green.shade700
                                                          : null,
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              flex: 1,
                                              child: Text(
                                                CurrencyService.formatAmount(runningBalance.abs()),
                                                style: TextStyle(
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.bold,
                                                  color: runBalColor,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class TrialBalancePage extends StatefulWidget {
  final Map<String, LedgerAccount> ledgerAccounts;
  const TrialBalancePage({Key? key, required this.ledgerAccounts})
      : super(key: key);

  @override
  State<TrialBalancePage> createState() => _TrialBalancePageState();
}

class _TrialBalancePageState extends State<TrialBalancePage> {
  // Added ScrollController for the Scrollbar
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    double totalDebit = 0;
    double totalCredit = 0;
    List<Map<String, dynamic>> processedAccounts = [];

    List<MapEntry<String, LedgerAccount>> accountsWithBalance = widget
        .ledgerAccounts.entries
        .where((entry) => entry.value.transactions.isNotEmpty)
        .toList();

    // Sort logic
    accountsWithBalance.sort((a, b) {
      const typeOrder = {
        'Asset': 1,
        'Liability': 2,
        'Equity': 3,
        'Revenue': 4,
        'Expense': 5
      };
      return typeOrder[a.value.type]!.compareTo(typeOrder[b.value.type]!);
    });

    for (var entry in accountsWithBalance) {
      final account = entry.value;
      final balance = account.balance;
      double debit = 0;
      double credit = 0;

      if (balance > 0) {
        if (account.type == 'Asset' || account.type == 'Expense') {
          debit = balance;
          totalDebit += balance;
        } else {
          credit = balance;
          totalCredit += balance;
        }
      } else if (balance < 0) {
        if (account.type == 'Asset' || account.type == 'Expense') {
          credit = balance.abs();
          totalCredit += balance.abs();
        } else {
          debit = balance.abs();
          totalDebit += balance.abs();
        }
      }
      processedAccounts.add({
        'key': entry.key,
        'account': account,
        'debit': debit,
        'credit': credit
      });
    }

    bool isBalanced = (totalDebit - totalCredit).abs() < 0.01;

    return Padding(
      // FIX 1: Reduced outer padding (was 24)
      padding: const EdgeInsets.all(16.0),
      child: Card(
        child: Padding(
          // FIX 2: Reduced inner padding (was 32)
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10), // Reduced from 14
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.balance,
                        size: 24, // Reduced from 30
                        color:
                            Theme.of(context).colorScheme.onPrimaryContainer),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Trial Balance',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall // Slightly smaller font
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      Text(
                          'As of ${DateFormat('MMMM dd, yyyy').format(DateTime.now())}',
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(
                                  color: Colors.grey.shade600,
                                  fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16), // Reduced from 32

              // Table Header
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withOpacity(0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Expanded(
                        flex: 3,
                        child: Text('Account',
                            style: TextStyle(fontWeight: FontWeight.bold))),
                    Expanded(
                        child: Text('Debit',
                            style: TextStyle(fontWeight: FontWeight.bold))),
                    Expanded(
                        child: Text('Credit',
                            style: TextStyle(fontWeight: FontWeight.bold))),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // List - Wrapped in Scrollbar
              Expanded(
                child: accountsWithBalance.isEmpty
                    ? Center(
                        child: Text('No transactions to display',
                            style: TextStyle(
                                fontSize: 16, color: Colors.grey.shade600)))
                    : Scrollbar(
                        // FIX 3: Added Scrollbar for Desktop/Laptop visibility
                        controller: _scrollController,
                        thumbVisibility: true,
                        child: ListView.builder(
                          controller: _scrollController,
                          itemCount: processedAccounts.length,
                          itemBuilder: (context, index) {
                            final item = processedAccounts[index];
                            final String accountName = item['key'];
                            final LedgerAccount account = item['account'];
                            final double debit = item['debit'];
                            final double credit = item['credit'];

                            return Container(
                              // FIX 4: Compact Rows (Reduced Margin & Padding)
                              margin: const EdgeInsets.only(bottom: 4),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Theme.of(context).cardColor,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                    color: Theme.of(context)
                                        .dividerColor
                                        .withOpacity(0.5)),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: Row(
                                      children: [
                                        Text(accountName,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 14)),
                                        const SizedBox(width: 8),
                                        // Account Type Tag
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.grey.withOpacity(0.1),
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            account.type,
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: Colors.grey.shade700,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      debit > 0
                                          ? CurrencyService.formatAmount(debit)
                                          : '-',
                                      style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: debit > 0
                                              ? Colors.green.shade700
                                              : Colors.grey.shade400),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      credit > 0
                                          ? CurrencyService.formatAmount(credit)
                                          : '-',
                                      style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: credit > 0
                                              ? Colors.green.shade700
                                              : Colors.grey.shade400),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
              ),

              const Divider(thickness: 1, height: 24),

              // Totals - Compacted
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withOpacity(0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Expanded(
                        flex: 3,
                        child: Text('Total',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16))),
                    Expanded(
                        child: Text(CurrencyService.formatAmount(totalDebit),
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: Colors.green.shade700))),
                    Expanded(
                        child: Text(CurrencyService.formatAmount(totalCredit),
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: Colors.green.shade700))),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Status - Compacted
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: isBalanced
                      ? Colors.green.shade50.withOpacity(0.2)
                      : Colors.red.shade50.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: isBalanced
                          ? Colors.green.shade200
                          : Colors.red.shade200),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                        isBalanced
                            ? Icons.check_circle
                            : Icons.warning_amber_rounded,
                        size: 20,
                        color: isBalanced
                            ? Colors.green.shade700
                            : Colors.red.shade700),
                    const SizedBox(width: 8),
                    Text(
                      isBalanced
                          ? 'Trial Balance is balanced'
                          : 'Trial Balance is NOT balanced',
                      style: TextStyle(
                        color: isBalanced
                            ? Colors.green.shade700
                            : Colors.red.shade700,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}

class IncomeStatementPage extends StatelessWidget {
  final Map<String, LedgerAccount> ledgerAccounts;
  const IncomeStatementPage({Key? key, required this.ledgerAccounts}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    List<LedgerAccount> revenueAccounts = ledgerAccounts.values.where((a) => a.type == 'Revenue' && a.balance.abs() > 0.01).toList();
    List<LedgerAccount> expenseAccounts = ledgerAccounts.values.where((a) => a.type == 'Expense' && a.balance.abs() > 0.01).toList();
    double totalRevenue = revenueAccounts.fold(0, (sum, acc) => sum + acc.balance);
    double totalExpense = expenseAccounts.fold(0, (sum, acc) => sum + acc.balance);
    
    // Terminology change handled here for logic, display below
    double netProfit = totalRevenue - totalExpense;

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: Colors.orange.shade100, borderRadius: BorderRadius.circular(12)),
                    child: Icon(Icons.trending_up, size: 30, color: Colors.orange.shade900),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Income Statement',
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.bold, fontSize: 26)), // BOLD
                      Text('For the period ending ${DateFormat('MMMM dd, yyyy').format(DateTime.now())}',
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: Colors.grey.shade600, fontWeight: FontWeight.bold)), // BOLD
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 32),
              
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // REVENUES
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(color: Colors.green.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                        child: Row(
                          children: [
                            Icon(Icons.arrow_upward_rounded, size: 18, color: Colors.green.shade700),
                            const SizedBox(width: 8),
                            Text('REVENUES',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.green.shade900, letterSpacing: 1.0)), // BOLD
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...revenueAccounts.asMap().entries.map((entry) {
                        int idx = entry.key;
                        var acc = entry.value;
                        return Container(
                          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                          decoration: BoxDecoration(color: idx % 2 == 0 ? Colors.transparent : Colors.grey.withOpacity(0.05), borderRadius: BorderRadius.circular(8)),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(acc.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)), // BOLD
                              Text(CurrencyService.formatAmount(acc.balance),
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: acc.balance >= 0 ? Colors.green.shade700 : Colors.red.shade700, fontFamily: 'monospace')), // BOLD
                            ],
                          ),
                        );
                      }),
                      const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Divider()),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Total Revenue', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)), // BOLD
                            Text(CurrencyService.formatAmount(totalRevenue),
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: totalRevenue >= 0 ? Colors.green.shade700 : Colors.red.shade700)), // BOLD
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),

                      // EXPENSES
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                        child: Row(
                          children: [
                            const Icon(Icons.arrow_downward_rounded, size: 18, color: Colors.orange),
                            const SizedBox(width: 8),
                            const Text('EXPENSES', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.orange, letterSpacing: 1.0)), // BOLD
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...expenseAccounts.asMap().entries.map((entry) {
                        int idx = entry.key;
                        var acc = entry.value;
                        return Container(
                          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                          decoration: BoxDecoration(color: idx % 2 == 0 ? Colors.transparent : Colors.grey.withOpacity(0.05), borderRadius: BorderRadius.circular(8)),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(acc.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)), // BOLD
                              Text(CurrencyService.formatAmount(acc.balance),
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: acc.balance >= 0 ? Colors.green.shade700 : Colors.red.shade700, fontFamily: 'monospace')), // BOLD
                            ],
                          ),
                        );
                      }),
                      const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Divider()),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Total Expenses', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)), // BOLD
                            Text(CurrencyService.formatAmount(totalExpense),
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: totalExpense >= 0 ? Colors.green.shade700 : Colors.red.shade700)), // BOLD
                          ],
                        ),
                      ),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
              
              // Net Profit
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: netProfit >= 0 ? Colors.green.shade50.withOpacity(0.2) : Colors.red.shade50.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: netProfit >= 0 ? Colors.green.shade200 : Colors.red.shade200),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // CHANGED: NET INCOME -> NET PROFIT
                    const Text('NET PROFIT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)), // BOLD
                    Text(CurrencyService.formatAmount(netProfit.abs()),
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: netProfit >= 0 ? Colors.green.shade800 : Colors.red.shade800)), // BOLD
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class BalanceSheetPage extends StatelessWidget {
  final Map<String, LedgerAccount> ledgerAccounts;
  const BalanceSheetPage({Key? key, required this.ledgerAccounts})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    // 1. Calculate Totals
    double totalRevenue = ledgerAccounts.values
        .where((a) => a.type == 'Revenue')
        .fold(0.0, (double sum, acc) => sum + acc.balance);
    double totalExpense = ledgerAccounts.values
        .where((a) => a.type == 'Expense')
        .fold(0.0, (double sum, acc) => sum + acc.balance);
    
    // CHANGED: Terminology to Net Profit
    double netProfit = totalRevenue - totalExpense;

    // 2. Filter Account Lists
    List<LedgerAccount> assets = ledgerAccounts.values
        .where((a) => a.type == 'Asset' && a.balance.abs() > 0.01)
        .toList();
    List<LedgerAccount> liabilities = ledgerAccounts.values
        .where((a) => a.type == 'Liability' && a.balance.abs() > 0.01)
        .toList();
    List<LedgerAccount> equity = ledgerAccounts.values
        .where((a) => a.type == 'Equity' && a.balance.abs() > 0.01)
        .toList();

    // 3. Calculate Section Totals
    double totalAssets =
        assets.fold(0.0, (double sum, acc) => sum + acc.balance);
    double totalLiabilities =
        liabilities.fold(0.0, (double sum, acc) => sum + acc.balance);
    double baseEquity =
        equity.fold(0.0, (double sum, acc) => sum + acc.balance);
    
    // CHANGED: Use netProfit variable
    double totalEquity = baseEquity + netProfit;

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            children: [
              // --- HEADER ---
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.pie_chart,
                        size: 30, color: Colors.blue.shade900),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Balance Sheet',
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(fontWeight: FontWeight.bold, fontSize: 26), // BOLD
                      ),
                      Text(
                        'As of ${DateFormat('MMMM dd, yyyy').format(DateTime.now())}',
                        style: Theme.of(context)
                            .textTheme
                            .bodyLarge
                            ?.copyWith(color: Colors.grey.shade600, fontWeight: FontWeight.bold), // BOLD
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 32),

              // --- MAIN CONTENT COLUMNS ---
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // -----------------------------
                    // LEFT COLUMN: ASSETS
                    // -----------------------------
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardTheme.color,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Theme.of(context).dividerColor.withOpacity(0.2)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.03),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            )
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Assets Header
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: Colors.blue.withOpacity(0.1),
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.account_balance_wallet_outlined, size: 18, color: Colors.blue.shade800),
                                  const SizedBox(width: 8),
                                  Text(
                                    'ASSETS',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold, // BOLD
                                      fontSize: 15,
                                      color: Colors.blue.shade900,
                                      letterSpacing: 1.0,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            
                            // Assets List
                            Expanded(
                              child: ListView(
                                padding: const EdgeInsets.all(8),
                                children: [
                                  ...assets.asMap().entries.map((entry) {
                                    int idx = entry.key;
                                    var acc = entry.value;
                                    return Container(
                                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                                      decoration: BoxDecoration(
                                        color: idx % 2 == 0 ? Colors.transparent : Colors.grey.withOpacity(0.05),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(acc.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)), // BOLD
                                          Text(
                                            acc.name == 'Accumulated Depreciation'
                                                ? '(${CurrencyService.formatAmount(acc.balance.abs())})'
                                                : CurrencyService.formatAmount(acc.balance.abs()),
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontFamily: 'monospace',
                                              fontWeight: FontWeight.bold, // BOLD
                                              color: acc.balance < 0 ? Colors.red.shade700 : Colors.green.shade700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }),
                                ],
                              ),
                            ),
                            
                            // Total Assets Footer
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('TOTAL ASSETS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)), // BOLD
                                  Text(
                                    CurrencyService.formatAmount(totalAssets.abs()),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold, // BOLD
                                      fontSize: 17,
                                      color: Colors.blue,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(width: 24),

                    // -----------------------------
                    // RIGHT COLUMN: LIABILITIES & EQUITY
                    // -----------------------------
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardTheme.color,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Theme.of(context).dividerColor.withOpacity(0.2)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.03),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            )
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Liab & Equity Header
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: Colors.orange.withOpacity(0.1),
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.pie_chart_outline, size: 18, color: Colors.orange.shade900),
                                  const SizedBox(width: 8),
                                  Text(
                                    'LIABILITIES & EQUITY',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold, // BOLD
                                      fontSize: 15,
                                      color: Colors.orange.shade900,
                                      letterSpacing: 1.0,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // Liab & Equity List
                            Expanded(
                              child: ListView(
                                padding: const EdgeInsets.all(8),
                                children: [
                                  // --- LIABILITIES SECTION ---
                                  Padding(
                                    padding: const EdgeInsets.only(left: 8, bottom: 8, top: 4),
                                    child: Text('LIABILITIES', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey.shade600)), // BOLD
                                  ),
                                  ...liabilities.asMap().entries.map((entry) {
                                    int idx = entry.key;
                                    var acc = entry.value;
                                    return Container(
                                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                                      decoration: BoxDecoration(
                                        color: idx % 2 == 0 ? Colors.transparent : Colors.grey.withOpacity(0.05),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(acc.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)), // BOLD
                                          Text(
                                            CurrencyService.formatAmount(acc.balance.abs()),
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontFamily: 'monospace',
                                              fontWeight: FontWeight.bold, // BOLD
                                              color: acc.balance >= 0 ? Colors.green.shade700 : Colors.red.shade700
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }),
                                  
                                  // Total Liabilities Subtotal
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        const Text('Total Liabilities', style: TextStyle(fontSize: 14, fontStyle: FontStyle.italic, color: Colors.orange, fontWeight: FontWeight.bold)), // BOLD
                                        Text(CurrencyService.formatAmount(totalLiabilities.abs()), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.orange)), // BOLD
                                      ],
                                    ),
                                  ),

                                  const Divider(),

                                  // --- EQUITY SECTION ---
                                  Padding(
                                    padding: const EdgeInsets.only(left: 8, bottom: 8, top: 4),
                                    child: Text('EQUITY', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey.shade600)), // BOLD
                                  ),
                                  ...equity.asMap().entries.map((entry) {
                                    int idx = entry.key;
                                    var acc = entry.value;
                                    return Container(
                                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                                      decoration: BoxDecoration(
                                        color: idx % 2 == 0 ? Colors.transparent : Colors.grey.withOpacity(0.05),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(acc.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)), // BOLD
                                          Text(
                                            acc.name == 'Drawings'
                                                ? '(${CurrencyService.formatAmount(acc.balance.abs())})'
                                                : CurrencyService.formatAmount(acc.balance.abs()),
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontFamily: 'monospace',
                                              fontWeight: FontWeight.bold, // BOLD
                                              color: acc.balance < 0 ? Colors.red.shade700 : Colors.green.shade700
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }),

                                  // --- NET PROFIT SECTION ---
                                  Container(
                                    margin: const EdgeInsets.only(top: 4),
                                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                                    decoration: BoxDecoration(
                                      color: netProfit >= 0 ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        // CHANGED: Net Income -> Net Profit
                                        const Text('Net Profit (Current)', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)), // BOLD
                                        Text(
                                          CurrencyService.formatAmount(netProfit.abs()),
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.bold, // BOLD
                                            fontFamily: 'monospace',
                                            color: netProfit >= 0 ? Colors.green.shade700 : Colors.red.shade700
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            
                            // Total Liabilities & Equity Footer
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('TOTAL LIAB. & EQUITY', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)), // BOLD
                                  Text(
                                    CurrencyService.formatAmount((totalLiabilities + totalEquity).abs()),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold, // BOLD
                                      fontSize: 17,
                                      color: Colors.orange,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // --- STATUS FOOTER ---
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                decoration: BoxDecoration(
                  color: (totalAssets - (totalLiabilities + totalEquity)).abs() < 0.01
                      ? Colors.green.shade50.withOpacity(0.2)
                      : Colors.red.shade50.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: (totalAssets - (totalLiabilities + totalEquity)).abs() < 0.01
                        ? Colors.green.shade200
                        : Colors.red.shade200,
                    width: 2,
                  ),
                ),
                child: Text(
                  (totalAssets - (totalLiabilities + totalEquity)).abs() < 0.01
                      ? 'Balance Sheet is Balanced'
                      : 'Balance Sheet is Out of Balance',
                  style: TextStyle(
                    color: (totalAssets - (totalLiabilities + totalEquity)).abs() < 0.01
                        ? Colors.green.shade700
                        : Colors.red.shade700,
                    fontWeight: FontWeight.bold, // BOLD
                    fontSize: 18,
                  ),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}