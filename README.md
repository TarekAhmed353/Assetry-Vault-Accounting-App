# Assetry Vault

Assetry Vault is a double-entry accounting app built with Flutter. You record journal entries, the app posts them to ledger accounts, and it builds a trial balance, an income statement and a balance sheet from them. Reports export to PDF and Excel, and the whole database can be backed up to a single file and restored later.

This README explains how the app is put together and how to test it, both with automated checks and by hand.

## How the app is built

| Part | Details |
| --- | --- |
| Framework | Flutter, Dart SDK 3.5 or newer |
| Code layout | Everything is in one file, `lib/main.dart` (about 6,200 lines) |
| Storage | SQLite through `sqflite`; desktop builds use `sqflite_common_ffi` |
| Database file | `accounting_v10.db` in the app's documents folder (schema version 5) |
| Reports | `pdf` and `printing` for PDF, `excel` for .xlsx, `fl_chart` for dashboard charts |
| Backup | `file_picker` on desktop, the share sheet (`share_plus`) on Android and iOS |

The database has six tables: `users`, `session`, `accounts`, `journal_entries`, `journal_lines` and `settings`. Journal entries and their lines belong to a user. The chart of accounts does not; every user on the device shares it.

When a user opens the workspace, the app adds 29 default accounts (Cash, Accounts Receivable, Capital, Service Revenue, Rent Expense and so on) if they are missing. Typing a new account name in a journal entry opens a dialog asking you to classify it as Asset, Liability, Equity, Revenue or Expense before the entry posts.

### Platforms

| Platform | Status |
| --- | --- |
| Windows, macOS, Linux | Supported. The layout is designed for wide screens, so desktop is the best place to test. |
| Android, iOS | Supported. Backups and exports go through the share sheet. |
| Web | Will not run. `main()` calls `Platform.isWindows` from `dart:io`, which throws in a browser, and `sqflite` has no web support. |

## Requirements

- Flutter on the stable channel with Dart 3.5 or newer
- The toolchain for your target: Visual Studio with the "Desktop development with C++" workload for Windows, Xcode for macOS and iOS, Android Studio with an emulator or a phone for Android
- Optional: [DB Browser for SQLite](https://sqlitebrowser.org/) to look inside the database while testing

Check your setup first:

```bash
flutter doctor
```

## Run the app

```bash
git clone https://github.com/TarekAhmed353/Assetry-Vault-Accounting-App.git
cd Assetry-Vault-Accounting-App
flutter pub get
flutter devices          # list what you can run on
flutter run -d windows   # or macos, linux, or an Android device id
```

The first launch creates the database and shows the sign-in screen.

### Start from a clean database

Most manual tests are easier from an empty state. Close the app and delete `accounting_v10.db`:

- Windows: `C:\Users\<you>\Documents\accounting_v10.db`
- Linux: usually `~/Documents/accounting_v10.db`
- macOS: the sandboxed app's Documents folder, under `~/Library/Containers/`
- Android and iOS: uninstall the app, or clear its storage

Settings > Clear All Data is not a full reset. It removes your journal entries but keeps users, accounts and settings.

## Automated checks

### Static analysis

```bash
flutter analyze
```

The project uses the `flutter_lints` rule set. Expect some info-level warnings, mostly about the deprecated `withOpacity` and `Key? key` constructors. Treat anything at error level as a real problem.

### Unit tests

The existing `test/widget_test.dart` is the counter test Flutter generates for a new project. It builds a widget called `MyApp`, which no longer exists, so `flutter test` fails to compile before any test runs. Delete that file:

```bash
rm test/widget_test.dart
```

Then add `test/accounting_logic_test.dart` with the tests below. They cover the core accounting rules, which live in plain Dart classes and need no database or device:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:accounting_appv2/main.dart';

JournalEntry entry(List<JournalLine> lines) => JournalEntry(
      id: 'JE-test',
      date: DateTime(2026, 1, 1),
      description: 'Test entry',
      lines: lines,
    );

LedgerTransaction tx(double debit, double credit) => LedgerTransaction(
      date: DateTime(2026, 1, 1),
      description: 'Test',
      debit: debit,
      credit: credit,
      journalId: 'JE-test',
    );

void main() {
  group('JournalEntry', () {
    test('is balanced when debits equal credits', () {
      final e = entry([
        JournalLine(accountName: 'Cash', debit: 50000, credit: 0),
        JournalLine(accountName: 'Capital', debit: 0, credit: 50000),
      ]);
      expect(e.isBalanced, isTrue);
      expect(e.totalDebit, 50000);
      expect(e.totalCredit, 50000);
    });

    test('is not balanced when the sides differ', () {
      final e = entry([
        JournalLine(accountName: 'Cash', debit: 100, credit: 0),
        JournalLine(accountName: 'Capital', debit: 0, credit: 90),
      ]);
      expect(e.isBalanced, isFalse);
    });

    test('allows a rounding gap under 0.01', () {
      final e = entry([
        JournalLine(accountName: 'Cash', debit: 100.005, credit: 0),
        JournalLine(accountName: 'Capital', debit: 0, credit: 100),
      ]);
      expect(e.isBalanced, isTrue);
    });

    test('balances a compound entry with three lines', () {
      final e = entry([
        JournalLine(accountName: 'Equipment', debit: 20000, credit: 0),
        JournalLine(accountName: 'Cash', debit: 0, credit: 5000),
        JournalLine(accountName: 'Notes Payable', debit: 0, credit: 15000),
      ]);
      expect(e.isBalanced, isTrue);
    });
  });

  group('LedgerAccount.balance', () {
    test('assets and expenses grow with debits', () {
      final cash = LedgerAccount(
          name: 'Cash', type: 'Asset', transactions: [tx(500, 0), tx(0, 200)]);
      final rent = LedgerAccount(
          name: 'Rent Expense', type: 'Expense', transactions: [tx(300, 0)]);
      expect(cash.balance, 300);
      expect(rent.balance, 300);
    });

    test('liabilities, equity and revenue grow with credits', () {
      final loan = LedgerAccount(
          name: 'Notes Payable', type: 'Liability', transactions: [tx(0, 1000)]);
      final capital = LedgerAccount(
          name: 'Capital', type: 'Equity', transactions: [tx(0, 5000)]);
      final sales = LedgerAccount(
          name: 'Service Revenue', type: 'Revenue', transactions: [tx(0, 1200), tx(200, 0)]);
      expect(loan.balance, 1000);
      expect(capital.balance, 5000);
      expect(sales.balance, 1000);
    });

    test('drawings come out negative because they are filed under Equity', () {
      final drawings = LedgerAccount(
          name: 'Drawings', type: 'Equity', transactions: [tx(1000, 0)]);
      expect(drawings.balance, -1000);
    });
  });

  test('CurrencyService formats amounts with the current symbol', () {
    CurrencyService.currentCurrency = '\$';
    expect(CurrencyService.formatAmount(1234.5), '\$ 1234.50');
    expect(CurrencyService.formatAmountForPdf(1234.5), 'Tk 1234.50');
  });
}
```

Run them:

```bash
flutter test
```

All eight tests should pass. The last one also documents a known issue: PDF amounts always use "Tk", whatever currency you pick.

The database code and the screens are harder to test automatically. `DatabaseHelper` is a singleton that finds its folder through `path_provider`, which has no implementation in `flutter test`, and the report totals are calculated inside `build()` methods. Moving the totals into plain functions, and letting `DatabaseHelper` accept a database path, would make both testable with an in-memory SQLite database. Until then, use the manual plan below.

## Manual test plan

### Sample data

Sign up, sign in and post these six entries. Dates do not change the totals, so any dates will do. Use the account names exactly as written; all of them are default accounts.

| # | Description | Debit | Credit |
| --- | --- | --- | --- |
| 1 | Owner invests cash | Cash 50,000 | Capital 50,000 |
| 2 | Buy equipment, part on loan | Equipment 20,000 | Cash 5,000 and Notes Payable 15,000 |
| 3 | Service income | Cash 12,000 | Service Revenue 12,000 |
| 4 | Pay rent | Rent Expense 3,000 | Cash 3,000 |
| 5 | Pay salaries | Salary Expense 4,000 | Cash 4,000 |
| 6 | Owner withdrawal | Drawings 1,000 | Cash 1,000 |

Entry 2 has three lines, so tap "Add Line" before filling it in.

Expected results:

| Report | What you should see |
| --- | --- |
| Cash ledger | Balance 49,000 (50,000 − 5,000 + 12,000 − 3,000 − 4,000 − 1,000) |
| Trial balance | Debit total 77,000, credit total 77,000, marked balanced. Drawings appears in the debit column. |
| Income statement | Revenue 12,000, expenses 7,000, net profit 5,000 |
| Balance sheet | Assets 69,000 (Cash 49,000 and Equipment 20,000). Liabilities 15,000. Equity 54,000 (Capital 50,000, Drawings −1,000, net profit 5,000). Liabilities plus equity 69,000, marked balanced. |

If any number differs, the posting or report logic has a bug.

### Sign up, sign in and sessions

| Test | Steps | Expected |
| --- | --- | --- |
| Sign up | Choose sign up, enter a username and password | "Account created successfully", then the sign-in form |
| Duplicate user | Sign up again with the same username | "Username already exists" |
| Empty fields | Submit with a blank username or password | Inline "Please enter..." errors, nothing saved |
| Wrong password | Sign in with a bad password | "Invalid username or password" |
| Stay signed in | Sign in, close the app fully, open it again | Opens straight to the dashboard |
| Log out | Log out, then restart the app | Opens on the sign-in screen |
| Switch user | Create a second user, then use "Switch Accounts" in the workspace menu | Asks for that user's password first |

### Journal entries

| Test | Steps | Expected |
| --- | --- | --- |
| Unbalanced entry | Debit Cash 100, credit Capital 90 | Status shows "Not Balanced" and the post button stays disabled |
| Zero entry | Leave every amount blank | Post button stays disabled |
| Missing account | Enter amounts but leave an account name blank | "Required" under the account field |
| New account | Use an account name that does not exist, such as "Office Supplies" | A dialog asks for the account type. Cancel stops the posting; picking a type posts the entry and creates the account. |
| Blank description | Post with no description | Saved as "Journal No-N" |
| Edit | Edit entry 4 from the sample and change 3,000 to 3,500 on both lines | Rent Expense shows 3,500 and net profit drops to 4,500 |
| Delete | Delete an entry and confirm | It disappears from the journal and its amounts leave every ledger and report |
| Search | Search for "rent", then for "Cash" | Finds matches in descriptions and in account names |
| Persistence | Post entries, restart the app | All entries are still there |

### Ledger and reports

- Open the ledger for Cash and check that transactions run oldest to newest with the right running balance.
- Check the dashboard charts after posting the sample data: revenue and expense breakdowns should match the income statement.
- Recheck all three reports after every edit or delete above. The trial balance and the balance sheet should stay balanced.

### Export

| Test | Expected |
| --- | --- |
| Each report as PDF | A print preview opens; the figures match the screen |
| Each report as Excel | Desktop: a Save dialog, then a .xlsx file that opens in Excel or LibreOffice. Mobile: the share sheet. |
| Cancel the Save dialog | Nothing is written and the app keeps running |

### Settings

| Test | Expected |
| --- | --- |
| Currency | Switch between ৳, $, £ and €. Amounts on screen change symbol only; no conversion happens. The choice survives a restart. |
| Add account | The new account appears in the account suggestions in the journal form |
| Clear all data | Your journal entries go; other users' entries stay |
| Dark mode | The theme switches at once |

### Backup and restore

1. Post the sample data, then use Settings > Backup & Restore > Backup and save the .db file.
2. Delete two entries.
3. Restore from the backup file. The app returns to the sign-in screen.
4. Close the app completely and open it again, as the message asks, then sign in.
5. The two deleted entries should be back.

### Several users on one device

1. Sign in as user A and post the sample data.
2. Log out and sign in as user B.
3. User B should see no journal entries and empty reports.



## License

See [LICENSE](LICENSE).
