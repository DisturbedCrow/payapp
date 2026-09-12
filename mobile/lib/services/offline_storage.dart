import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/payment_token.dart';
import '../models/transaction.dart';
import '../config/constants.dart';


class OfflineStorage {
  static final OfflineStorage _instance = OfflineStorage._internal();
  factory OfflineStorage() => _instance;
  OfflineStorage._internal();

  Database? _database;

  Future<Database> get database async {
    _database ??= await _initDB();
    return _database!;
  }

  Future<Database> _initDB() async {
    if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
      return await openDatabase(
        AppConstants.dbName,
        version: AppConstants.dbVersion,
        onCreate: _createTables,
        onUpgrade: _onUpgrade,
        onOpen: _ensureLateColumns,
      );
    }
    
    if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux)) {
       sqfliteFfiInit();
       databaseFactory = databaseFactoryFfi;
    }

    final dbPath = await getDatabasesPath();
    final path = join(dbPath, AppConstants.dbName);

    return await openDatabase(
      path,
      version: AppConstants.dbVersion,
      onCreate: _createTables,
      onUpgrade: _onUpgrade,
      onOpen: _ensureLateColumns,
    );
  }

  /// Columns added after a version was first shipped.
  ///
  /// `onUpgrade` only fires when the recorded version CHANGES. An interim
  /// build can create the database at the current version with an older
  /// schema — then the upgrade never runs and every insert fails with
  /// "no column named ...". Applying the ALTERs on every open, guarded, is
  /// cheap and immune to whatever state a demo phone is already in.
  ///
  /// PROD-TODO: replace with a real migration framework (e.g. drift) that
  /// records applied migrations rather than inferring them.
  static const List<List<String>> _lateColumns = [
    ['payment_blobs', 'handoff_method', 'TEXT'],
    ['payment_blobs', 'direction', "TEXT DEFAULT 'sent'"],
    ['payment_blobs', 'sender_public_key', 'TEXT'],
    ['payment_blobs', 'device_signature_ed25519', 'TEXT'],
    ['payment_blobs', 'sender_ed25519_pk', 'TEXT'],
  ];

  Future<void> _ensureLateColumns(Database db) async {
    for (final col in _lateColumns) {
      try {
        await db.execute('ALTER TABLE ${col[0]} ADD COLUMN ${col[1]} ${col[2]}');
      } catch (_) {
        // Already present — the expected case on every open after the first.
      }
    }
  }

  Future<void> _createTables(Database db, int version) async {
    // Offline tokens table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS offline_tokens (
        token_id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        amount REAL NOT NULL,
        issued_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        nonce TEXT NOT NULL UNIQUE,
        signature TEXT NOT NULL,
        is_consumed INTEGER DEFAULT 0
      )
    ''');

    // Offline transactions table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS offline_transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        token_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        receiver_id TEXT,
        receiver_name TEXT,
        amount REAL NOT NULL,
        nonce TEXT NOT NULL UNIQUE,
        signature TEXT NOT NULL,
        status TEXT DEFAULT 'pending_offline',
        created_at TEXT NOT NULL,
        synced_at TEXT,
        settled_at TEXT
      )
    ''');

    // Payment blobs table (v2) — offline payment captures pending sync
    // v5 added handoff_method / direction / sender_public_key.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS payment_blobs (
        id TEXT PRIMARY KEY,
        sender_id TEXT NOT NULL,
        receiver_id TEXT NOT NULL,
        amount REAL NOT NULL,
        timestamp TEXT NOT NULL,
        nonce TEXT NOT NULL UNIQUE,
        device_signature TEXT NOT NULL,
        status TEXT DEFAULT 'pending_sync',
        is_offline INTEGER DEFAULT 1,
        offline_limit_at_time REAL NOT NULL DEFAULT 0,
        handoff_method TEXT,
        direction TEXT DEFAULT 'sent',
        sender_public_key TEXT,
        device_signature_ed25519 TEXT,
        sender_ed25519_pk TEXT
      )
    ''');

    // Cached server transactions (v3) — persisted so they're visible offline
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cached_server_transactions (
        id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        counterparty_name TEXT,
        amount REAL NOT NULL,
        nonce TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        settled_at TEXT,
        PRIMARY KEY (user_id, nonce)
      )
    ''');

    // Nonce tracker (v4) — replay protection for offline transactions
    await db.execute('''
      CREATE TABLE IF NOT EXISTS nonce_tracker (
        nonce TEXT PRIMARY KEY,
        created_at TEXT NOT NULL
      )
    ''');

    // Device registration log (v4) — tracks public key registration with backend
    await db.execute('''
      CREATE TABLE IF NOT EXISTS device_registry (
        device_id TEXT PRIMARY KEY,
        public_key TEXT NOT NULL,
        registered_at TEXT NOT NULL,
        last_verified TEXT
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 → v2: add payment_blobs table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS payment_blobs (
          id TEXT PRIMARY KEY,
          sender_id TEXT NOT NULL,
          receiver_id TEXT NOT NULL,
          amount REAL NOT NULL,
          timestamp TEXT NOT NULL,
          nonce TEXT NOT NULL UNIQUE,
          device_signature TEXT NOT NULL,
          status TEXT DEFAULT 'pending_sync',
          is_offline INTEGER DEFAULT 1,
          offline_limit_at_time REAL NOT NULL DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 3) {
      // v2 → v3: add cached_server_transactions table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS cached_server_transactions (
          id TEXT NOT NULL,
          user_id TEXT NOT NULL,
          counterparty_name TEXT,
          amount REAL NOT NULL,
          nonce TEXT NOT NULL,
          status TEXT NOT NULL,
          created_at TEXT NOT NULL,
          settled_at TEXT,
          PRIMARY KEY (user_id, nonce)
        )
      ''');
    }
    if (oldVersion < 4) {
      // v3 → v4: add nonce tracker and device registry for security layer
      await db.execute('''
        CREATE TABLE IF NOT EXISTS nonce_tracker (
          nonce TEXT PRIMARY KEY,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS device_registry (
          device_id TEXT PRIMARY KEY,
          public_key TEXT NOT NULL,
          registered_at TEXT NOT NULL,
          last_verified TEXT
        )
      ''');
    }
    if (oldVersion < 5) {
      // v4 → v5: QR handoff (Case 3b) — route, side of the payment, and the
      // sending device's public key so a received blob can be re-verified
      // and forwarded to the backend at sync time.
      //
      // Each ALTER is guarded: SQLite has no ADD COLUMN IF NOT EXISTS, and a
      // partially-upgraded install (or a fresh _createTables that already
      // includes the column) must not brick the database on startup.
      await _addColumnIfMissing(
          db, 'payment_blobs', 'handoff_method', 'TEXT');
      await _addColumnIfMissing(
          db, 'payment_blobs', 'direction', "TEXT DEFAULT 'sent'");
      await _addColumnIfMissing(
          db, 'payment_blobs', 'sender_public_key', 'TEXT');
    }
  }

  /// `ALTER TABLE ... ADD COLUMN`, tolerating "duplicate column name".
  Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    try {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
    } catch (e) {
      // Already present (or the table does not exist yet, in which case
      // _createTables owns it). Never fail the migration over this.
      debugPrint('Migration: skipped $table.$column — $e');
    }
  }

  // ─── Token Operations ──────────────────────────────────────

  Future<void> insertToken(PaymentToken token) async {
    final db = await database;
    await db.insert(
      'offline_tokens',
      token.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<PaymentToken>> getActiveTokens() async {
    final db = await database;
    final results = await db.query(
      'offline_tokens',
      where: 'is_consumed = ?',
      whereArgs: [0],
    );
    return results
        .map((r) => PaymentToken.fromDbMap(r))
        .where((t) => !t.isExpired)
        .toList();
  }

  Future<void> markTokenConsumed(String tokenId) async {
    final db = await database;
    await db.update(
      'offline_tokens',
      {'is_consumed': 1},
      where: 'token_id = ?',
      whereArgs: [tokenId],
    );
  }

  Future<void> clearAllTokens() async {
    final db = await database;
    await db.delete('offline_tokens');
  }

  // ─── Transaction Operations ────────────────────────────────

  Future<int> insertTransaction(OfflineTransaction tx) async {
    final db = await database;
    return await db.insert(
      'offline_transactions',
      tx.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<OfflineTransaction>> getPendingTransactions() async {
    final db = await database;
    final results = await db.query(
      'offline_transactions',
      where: 'status = ?',
      whereArgs: ['pending_offline'],
      orderBy: 'created_at ASC',
    );
    return results.map((r) => OfflineTransaction.fromDbMap(r)).toList();
  }

  Future<List<OfflineTransaction>> getAllTransactions() async {
    final db = await database;
    final results = await db.query(
      'offline_transactions',
      orderBy: 'created_at DESC',
    );
    return results.map((r) => OfflineTransaction.fromDbMap(r)).toList();
  }

  Future<List<OfflineTransaction>> getTransactionsForUser(String userId) async {
    final db = await database;
    final results = await db.query(
      'offline_transactions',
      where: 'sender_id = ? OR receiver_id = ?',
      whereArgs: [userId, userId],
      orderBy: 'created_at DESC',
    );
    return results.map((r) => OfflineTransaction.fromDbMap(r)).toList();
  }

  Future<void> updateTransactionStatus(
    String nonce,
    String status, {
    String? syncedAt,
    String? settledAt,
  }) async {
    final db = await database;
    final updates = <String, dynamic>{'status': status};
    if (syncedAt != null) updates['synced_at'] = syncedAt;
    if (settledAt != null) updates['settled_at'] = settledAt;

    await db.update(
      'offline_transactions',
      updates,
      where: 'nonce = ?',
      whereArgs: [nonce],
    );
  }

  Future<int> getPendingCount() async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT COUNT(*) as cnt FROM offline_transactions WHERE status = 'pending_offline'",
    );
    return result.first['cnt'] as int? ?? 0;
  }

  Future<double> getTotalPending() async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT COALESCE(SUM(amount), 0) as total FROM offline_transactions WHERE status = 'pending_offline'",
    );
    return (result.first['total'] as num?)?.toDouble() ?? 0.0;
  }

  // ─── Cached Server Transactions ────────────────────────────

  /// Upsert server-fetched transactions so they survive offline.
  Future<void> cacheServerTransactions(
    List<OfflineTransaction> txs,
    String userId,
  ) async {
    final db = await database;
    final batch = db.batch();
    for (final tx in txs) {
      batch.insert(
        'cached_server_transactions',
        {
          'id': tx.id,
          'user_id': userId,
          'counterparty_name': tx.receiverName ?? '',
          'amount': tx.amount,
          'nonce': tx.nonce,
          'status': tx.status,
          'created_at': tx.createdAt,
          'settled_at': tx.settledAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Load all cached server transactions for a user, newest first.
  Future<List<OfflineTransaction>> getCachedServerTransactions(
    String userId,
  ) async {
    final db = await database;
    final rows = await db.query(
      'cached_server_transactions',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'created_at DESC',
    );
    return rows.map((r) {
      return OfflineTransaction(
        id: r['id'] as String,
        tokenId: '',
        senderId: '',
        receiverName: r['counterparty_name'] as String?,
        amount: (r['amount'] as num).toDouble(),
        nonce: r['nonce'] as String,
        signature: '',
        status: r['status'] as String,
        createdAt: r['created_at'] as String,
        settledAt: r['settled_at'] as String?,
      );
    }).toList();
  }
}
