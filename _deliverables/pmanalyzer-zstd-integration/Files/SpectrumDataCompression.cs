using System;
using System.Collections.Generic;
using System.Data;
using System.Data.Common;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using Lephone.Data;
using ZstdSharp;

namespace JPSPEC
{
    public delegate void SpectrumDatabaseUpgradeProgress(int current, int total, string message);

    /// <summary>
    /// SpectrumData.Data 的 Zstandard 压缩、兼容解压、字典缓存和数据库升级。
    /// 原有 BinaryFormatter 字节格式保持不变，Zstd 只包装最终 byte[]。
    /// </summary>
    public static class SpectrumDataCompression
    {
        public const int DictionaryRecordId = 1;
        public const int DictionaryByteLength = 4096;
        public const int CompressionLevel = 1;
        public const int StorageFormatVersion = 1;
        public const string DictionaryDisplayName = "FastCover自动 4K";

        private const int HeaderSize = 24;
        private const int MaximumOriginalLength = 256 * 1024 * 1024;
        private const int UpgradeBatchSize = 128;
        private const byte RequiredHeaderFlags = 3;

        // ASCII: SPZSTD01
        private static readonly byte[] Magic = new byte[]
        {
            0x53, 0x50, 0x5A, 0x53, 0x54, 0x44, 0x30, 0x31
        };

        private static readonly object SyncRoot = new object();
        private static readonly uint[] Crc32Table = CreateCrc32Table();

        private static byte[] _embeddedDictionary;
        private static byte[] _activeDictionary;
        private static string _activeDictionaryHash;
        private static uint _activeDictionaryTag;
        private static Compressor _compressor;
        private static Decompressor _decompressor;

        /// <summary>
        /// 压缩原有 BinaryFormatter byte[]。已经带有效压缩头的数据会原样返回。
        /// </summary>
        public static byte[] Compress(byte[] source)
        {
            if (source == null || source.Length == 0)
                return source;

            if (HasMagic(source))
            {
                ValidateHeader(source);
                return source;
            }

            lock (SyncRoot)
            {
                EnsureCodecLocked();
                return WrapWithHeader(source, _compressor, _activeDictionaryTag);
            }
        }

        /// <summary>
        /// 解压 SpectrumData.Data。没有本格式标记时按旧数据原样返回。
        /// </summary>
        public static byte[] Decompress(byte[] source)
        {
            if (source == null || source.Length == 0 || !HasMagic(source))
                return source;

            ValidateHeader(source);

            int originalLength = ReadInt32(source, 12);
            uint dictionaryTag = ReadUInt32(source, 16);
            uint storedCrc = ReadUInt32(source, 20);
            int payloadLength = source.Length - HeaderSize;
            uint actualCrc = ComputeCrc32(source, HeaderSize, payloadLength);

            if (actualCrc != storedCrc)
                throw new InvalidDataException("SpectrumData 压缩负载校验失败，数据可能已损坏。");

            lock (SyncRoot)
            {
                EnsureCodecLocked();
                if (dictionaryTag != _activeDictionaryTag)
                {
                    throw new InvalidDataException(
                        "SpectrumData 压缩字典不匹配。数据库字典与该谱图使用的字典不是同一版本。");
                }

                byte[] payload = new byte[payloadLength];
                Buffer.BlockCopy(source, HeaderSize, payload, 0, payloadLength);
                byte[] result = _decompressor.Unwrap(payload);
                if (result == null || result.Length != originalLength)
                {
                    throw new InvalidDataException(
                        "SpectrumData 解压长度不正确。期望 " +
                        originalLength.ToString(CultureInfo.InvariantCulture) +
                        " 字节，实际 " +
                        (result == null
                            ? "null"
                            : result.Length.ToString(CultureInfo.InvariantCulture)) +
                        " 字节。");
                }
                return result;
            }
        }

        public static bool IsCompressed(byte[] source)
        {
            if (!HasMagic(source))
                return false;

            try
            {
                ValidateHeader(source);
                return true;
            }
            catch
            {
                return false;
            }
        }

        /// <summary>
        /// 没有有效数据库字典记录时认为需要升级。
        /// 空数据库只写入字典记录，不弹出升级窗口。
        /// </summary>
        public static bool NeedsDatabaseUpgrade(out int totalRows)
        {
            using (DbConnection connection = CreateConnection())
            {
                connection.Open();
                SetBusyTimeout(connection);
                EnsureDictionaryTable(connection, null);

                DictionaryRow row = ReadDictionaryRow(connection, null);
                totalRows = GetSpectrumRowCount(connection, null);
                if (IsValidDictionaryRow(row))
                    return false;

                if (totalRows != 0)
                    return true;

                byte[] dictionary = GetEmbeddedDictionaryCopy();
                string hash = ComputeSha256Hex(dictionary);
                DbTransaction transaction = connection.BeginTransaction();
                try
                {
                    SaveDictionaryRow(connection, transaction, dictionary, hash);
                    transaction.Commit();
                }
                catch
                {
                    TryRollback(transaction);
                    throw;
                }
                finally
                {
                    transaction.Dispose();
                }
            }

            ClearCache();
            return false;
        }

        /// <summary>
        /// 单事务升级全部 SpectrumData.Data。字典记录只在全部行成功后写入。
        /// 已压缩且字典一致的数据会校验后跳过，因此中断后可重新运行。
        /// </summary>
        public static void UpgradeDatabase(SpectrumDatabaseUpgradeProgress progress)
        {
            byte[] dictionary = GetEmbeddedDictionaryCopy();
            string dictionaryHash = ComputeSha256Hex(dictionary);
            uint dictionaryTag = GetDictionaryTag(dictionary);

            Report(progress, 0, 0, "正在准备数据库升级…");

            using (DbConnection connection = CreateConnection())
            {
                connection.Open();
                SetBusyTimeout(connection);
                EnsureDictionaryTable(connection, null);

                DictionaryRow existing = ReadDictionaryRow(connection, null);
                if (IsValidDictionaryRow(existing))
                {
                    Report(progress, 1, 1, "数据库已经是最新版本。");
                    return;
                }

                int totalRows = GetSpectrumRowCount(connection, null);
                DbTransaction transaction = connection.BeginTransaction();
                try
                {
                    using (Compressor compressor = new Compressor(CompressionLevel))
                    using (DbCommand updateCommand = CreateUpdateCommand(connection, transaction))
                    {
                        compressor.LoadDictionary(dictionary);

                        long lastId = Int64.MinValue;
                        int processed = 0;
                        while (true)
                        {
                            List<SpectrumRow> rows = ReadSpectrumBatch(
                                connection,
                                transaction,
                                lastId);
                            if (rows.Count == 0)
                                break;

                            int i;
                            for (i = 0; i < rows.Count; i++)
                            {
                                SpectrumRow row = rows[i];
                                lastId = row.Id;

                                if (row.Data != null && row.Data.Length != 0)
                                {
                                    if (HasMagic(row.Data))
                                    {
                                        ValidateStoredEnvelope(
                                            row.Id,
                                            row.Data,
                                            dictionaryTag);
                                    }
                                    else
                                    {
                                        byte[] compressed = WrapWithHeader(
                                            row.Data,
                                            compressor,
                                            dictionaryTag);
                                        SetParameterValue(updateCommand, "@Data", compressed);
                                        SetParameterValue(updateCommand, "@Id", row.Id);
                                        updateCommand.ExecuteNonQuery();
                                    }
                                }

                                processed++;
                                if ((processed & 15) == 0 || processed == totalRows)
                                {
                                    Report(
                                        progress,
                                        processed,
                                        totalRows,
                                        "正在压缩已有谱图：" +
                                        processed.ToString(CultureInfo.InvariantCulture) +
                                        " / " +
                                        totalRows.ToString(CultureInfo.InvariantCulture));
                                }
                            }

                            if (rows.Count < UpgradeBatchSize)
                                break;
                        }
                    }

                    // 完成标记必须最后写入，并与 BLOB 更新处于同一事务。
                    SaveDictionaryRow(
                        connection,
                        transaction,
                        dictionary,
                        dictionaryHash);
                    transaction.Commit();
                }
                catch
                {
                    TryRollback(transaction);
                    throw;
                }
                finally
                {
                    transaction.Dispose();
                }

                Report(progress, totalRows, totalRows, "数据库升级完成。");
            }

            ClearCache();
        }

        /// <summary>
        /// 数据库切换或升级完成后清除字典与 Zstd 上下文缓存。
        /// </summary>
        public static void ClearCache()
        {
            lock (SyncRoot)
            {
                if (_compressor != null)
                {
                    _compressor.Dispose();
                    _compressor = null;
                }
                if (_decompressor != null)
                {
                    _decompressor.Dispose();
                    _decompressor = null;
                }

                _activeDictionary = null;
                _activeDictionaryHash = null;
                _activeDictionaryTag = 0;
            }
        }

        public static string GetActiveDictionaryHash()
        {
            lock (SyncRoot)
            {
                EnsureCodecLocked();
                return _activeDictionaryHash;
            }
        }

        private static void EnsureCodecLocked()
        {
            if (_activeDictionary == null)
            {
                byte[] databaseDictionary;
                if (TryLoadDictionaryFromDatabase(out databaseDictionary))
                    _activeDictionary = databaseDictionary;
                else
                    _activeDictionary = GetEmbeddedDictionaryCopyLocked();

                _activeDictionaryHash = ComputeSha256Hex(_activeDictionary);
                _activeDictionaryTag = GetDictionaryTag(_activeDictionary);
            }

            if (_compressor == null)
            {
                _compressor = new Compressor(CompressionLevel);
                _compressor.LoadDictionary(_activeDictionary);
            }
            if (_decompressor == null)
            {
                _decompressor = new Decompressor();
                _decompressor.LoadDictionary(_activeDictionary);
            }
        }

        private static byte[] GetEmbeddedDictionaryCopy()
        {
            lock (SyncRoot)
            {
                return GetEmbeddedDictionaryCopyLocked();
            }
        }

        private static byte[] GetEmbeddedDictionaryCopyLocked()
        {
            byte[] source = GetEmbeddedDictionaryLocked();
            byte[] copy = new byte[source.Length];
            Buffer.BlockCopy(source, 0, copy, 0, source.Length);
            return copy;
        }

        private static byte[] GetEmbeddedDictionaryLocked()
        {
            if (_embeddedDictionary != null)
                return _embeddedDictionary;

            Assembly assembly = typeof(SpectrumDataCompression).Assembly;
            string[] resourceNames = assembly.GetManifestResourceNames();
            byte[] best = null;
            int bestScore = Int32.MinValue;
            int i;

            for (i = 0; i < resourceNames.Length; i++)
            {
                string resourceName = resourceNames[i];
                string lower = resourceName.ToLowerInvariant();
                if (!lower.EndsWith(".zdict") && !lower.EndsWith(".dict"))
                    continue;

                byte[] bytes;
                using (Stream stream = assembly.GetManifestResourceStream(resourceName))
                {
                    if (stream == null)
                        continue;
                    bytes = ReadAllBytes(stream);
                }

                if (bytes.Length != DictionaryByteLength)
                    continue;

                int score = 0;
                if (lower.IndexOf("fastcoverauto", StringComparison.Ordinal) >= 0)
                    score += 1000;
                else
                {
                    if (lower.IndexOf("fastcover", StringComparison.Ordinal) >= 0)
                        score += 400;
                    if (lower.IndexOf("auto", StringComparison.Ordinal) >= 0)
                        score += 400;
                }
                if (lower.IndexOf("spectrumdata", StringComparison.Ordinal) >= 0)
                    score += 200;
                if (lower.IndexOf("level1", StringComparison.Ordinal) >= 0 ||
                    lower.IndexOf("_l1", StringComparison.Ordinal) >= 0)
                    score += 100;
                if (lower.IndexOf("4k", StringComparison.Ordinal) >= 0 ||
                    lower.IndexOf("4096", StringComparison.Ordinal) >= 0)
                    score += 50;

                if (best == null || score > bestScore)
                {
                    best = bytes;
                    bestScore = score;
                }
            }

            if (best == null)
            {
                throw new InvalidOperationException(
                    "未找到代码内置的 4096 字节 SpectrumData Zstd 字典资源。" +
                    "请确认 .zdict 的生成操作为 EmbeddedResource。");
            }

            _embeddedDictionary = best;
            return _embeddedDictionary;
        }

        private static bool TryLoadDictionaryFromDatabase(out byte[] dictionary)
        {
            dictionary = null;
            try
            {
                using (DbConnection connection = CreateConnection())
                {
                    connection.Open();
                    DictionaryRow row = ReadDictionaryRow(connection, null);
                    if (!IsValidDictionaryRow(row))
                        return false;

                    dictionary = new byte[row.Data.Length];
                    Buffer.BlockCopy(row.Data, 0, dictionary, 0, row.Data.Length);
                    return true;
                }
            }
            catch
            {
                // 数据库尚未初始化、表不存在或读取失败时使用代码资源。
                dictionary = null;
                return false;
            }
        }

        private static bool IsValidDictionaryRow(DictionaryRow row)
        {
            if (row == null || row.Data == null)
                return false;
            if (!String.Equals(row.Name, DictionaryDisplayName, StringComparison.Ordinal))
                return false;
            if (!String.Equals(row.Codec, "zstd", StringComparison.OrdinalIgnoreCase))
                return false;
            if (row.Level != CompressionLevel || row.Size != DictionaryByteLength)
                return false;
            if (row.FormatVersion != StorageFormatVersion ||
                row.Data.Length != DictionaryByteLength)
                return false;

            string actualHash = ComputeSha256Hex(row.Data);
            return String.Equals(row.Hash, actualHash, StringComparison.OrdinalIgnoreCase);
        }

        private static DbConnection CreateConnection()
        {
            Type connectionType = Type.GetType(
                "System.Data.SQLite.SQLiteConnection, System.Data.SQLite",
                false);

            if (connectionType == null)
            {
                Assembly[] assemblies = AppDomain.CurrentDomain.GetAssemblies();
                int i;
                for (i = 0; i < assemblies.Length; i++)
                {
                    if (!String.Equals(
                        assemblies[i].GetName().Name,
                        "System.Data.SQLite",
                        StringComparison.OrdinalIgnoreCase))
                        continue;

                    connectionType = assemblies[i].GetType(
                        "System.Data.SQLite.SQLiteConnection",
                        false);
                    if (connectionType != null)
                        break;
                }
            }

            if (connectionType == null)
            {
                try
                {
                    Assembly sqliteAssembly = Assembly.Load("System.Data.SQLite");
                    connectionType = sqliteAssembly.GetType(
                        "System.Data.SQLite.SQLiteConnection",
                        true);
                }
                catch (Exception ex)
                {
                    throw new InvalidOperationException(
                        "无法加载 System.Data.SQLite.SQLiteConnection。",
                        ex);
                }
            }

            DbConnection connection = Activator.CreateInstance(connectionType) as DbConnection;
            if (connection == null)
                throw new InvalidOperationException("SQLiteConnection 不是 DbConnection。");

            string connectionString = DbEntry.Context.Driver.ConnectionString;
            if (String.IsNullOrEmpty(connectionString))
            {
                connection.Dispose();
                throw new InvalidOperationException("数据库连接字符串尚未初始化。");
            }

            connection.ConnectionString = connectionString;
            return connection;
        }

        private static void SetBusyTimeout(DbConnection connection)
        {
            using (DbCommand command = connection.CreateCommand())
            {
                command.CommandText = "PRAGMA busy_timeout=30000";
                command.ExecuteNonQuery();
            }
        }

        private static void EnsureDictionaryTable(
            DbConnection connection,
            DbTransaction transaction)
        {
            using (DbCommand command = connection.CreateCommand())
            {
                if (transaction != null)
                    command.Transaction = transaction;

                command.CommandText =
                    "CREATE TABLE IF NOT EXISTS SpectrumCompressionDictionary (" +
                    "Id INTEGER NOT NULL PRIMARY KEY," +
                    "Name TEXT NOT NULL," +
                    "Codec TEXT NOT NULL," +
                    "CompressionLevel INTEGER NOT NULL," +
                    "DictionarySize INTEGER NOT NULL," +
                    "DictionaryHash TEXT NOT NULL," +
                    "DictionaryData BLOB NOT NULL," +
                    "FormatVersion INTEGER NOT NULL," +
                    "CompletedUtc TEXT NOT NULL" +
                    ")";
                command.ExecuteNonQuery();
            }
        }

        private static int GetSpectrumRowCount(
            DbConnection connection,
            DbTransaction transaction)
        {
            using (DbCommand command = connection.CreateCommand())
            {
                if (transaction != null)
                    command.Transaction = transaction;
                command.CommandText = "SELECT COUNT(1) FROM SpectrumData";
                object value = command.ExecuteScalar();
                return Convert.ToInt32(value, CultureInfo.InvariantCulture);
            }
        }

        private static DictionaryRow ReadDictionaryRow(
            DbConnection connection,
            DbTransaction transaction)
        {
            using (DbCommand command = connection.CreateCommand())
            {
                if (transaction != null)
                    command.Transaction = transaction;
                command.CommandText =
                    "SELECT Name, Codec, CompressionLevel, DictionarySize, " +
                    "DictionaryHash, DictionaryData, FormatVersion " +
                    "FROM SpectrumCompressionDictionary WHERE Id=@Id";
                AddParameter(command, "@Id", DbType.Int32, DictionaryRecordId);

                using (DbDataReader reader = command.ExecuteReader())
                {
                    if (!reader.Read())
                        return null;

                    DictionaryRow row = new DictionaryRow();
                    row.Name = Convert.ToString(
                        reader.GetValue(0),
                        CultureInfo.InvariantCulture);
                    row.Codec = Convert.ToString(
                        reader.GetValue(1),
                        CultureInfo.InvariantCulture);
                    row.Level = Convert.ToInt32(
                        reader.GetValue(2),
                        CultureInfo.InvariantCulture);
                    row.Size = Convert.ToInt32(
                        reader.GetValue(3),
                        CultureInfo.InvariantCulture);
                    row.Hash = Convert.ToString(
                        reader.GetValue(4),
                        CultureInfo.InvariantCulture);
                    row.Data = reader.IsDBNull(5)
                        ? null
                        : (byte[])reader.GetValue(5);
                    row.FormatVersion = Convert.ToInt32(
                        reader.GetValue(6),
                        CultureInfo.InvariantCulture);
                    return row;
                }
            }
        }

        private static void SaveDictionaryRow(
            DbConnection connection,
            DbTransaction transaction,
            byte[] dictionary,
            string dictionaryHash)
        {
            using (DbCommand command = connection.CreateCommand())
            {
                command.Transaction = transaction;
                command.CommandText =
                    "INSERT OR REPLACE INTO SpectrumCompressionDictionary " +
                    "(Id, Name, Codec, CompressionLevel, DictionarySize, " +
                    "DictionaryHash, DictionaryData, FormatVersion, CompletedUtc) " +
                    "VALUES (@Id, @Name, @Codec, @Level, @Size, @Hash, @Data, @Version, @Utc)";

                AddParameter(command, "@Id", DbType.Int32, DictionaryRecordId);
                AddParameter(command, "@Name", DbType.String, DictionaryDisplayName);
                AddParameter(command, "@Codec", DbType.String, "zstd");
                AddParameter(command, "@Level", DbType.Int32, CompressionLevel);
                AddParameter(command, "@Size", DbType.Int32, dictionary.Length);
                AddParameter(command, "@Hash", DbType.String, dictionaryHash);
                AddParameter(command, "@Data", DbType.Binary, dictionary);
                AddParameter(command, "@Version", DbType.Int32, StorageFormatVersion);
                AddParameter(
                    command,
                    "@Utc",
                    DbType.String,
                    DateTime.UtcNow.ToString(
                        "yyyy-MM-ddTHH:mm:ss.fffZ",
                        CultureInfo.InvariantCulture));
                command.ExecuteNonQuery();
            }
        }

        private static List<SpectrumRow> ReadSpectrumBatch(
            DbConnection connection,
            DbTransaction transaction,
            long lastId)
        {
            List<SpectrumRow> rows = new List<SpectrumRow>(UpgradeBatchSize);
            using (DbCommand command = connection.CreateCommand())
            {
                command.Transaction = transaction;
                command.CommandText =
                    "SELECT Id, Data FROM SpectrumData WHERE Id>@Id " +
                    "ORDER BY Id LIMIT " +
                    UpgradeBatchSize.ToString(CultureInfo.InvariantCulture);
                AddParameter(command, "@Id", DbType.Int64, lastId);

                using (DbDataReader reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        SpectrumRow row = new SpectrumRow();
                        row.Id = Convert.ToInt64(
                            reader.GetValue(0),
                            CultureInfo.InvariantCulture);
                        row.Data = reader.IsDBNull(1)
                            ? null
                            : (byte[])reader.GetValue(1);
                        rows.Add(row);
                    }
                }
            }
            return rows;
        }

        private static DbCommand CreateUpdateCommand(
            DbConnection connection,
            DbTransaction transaction)
        {
            DbCommand command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = "UPDATE SpectrumData SET Data=@Data WHERE Id=@Id";
            AddParameter(command, "@Data", DbType.Binary, DBNull.Value);
            AddParameter(command, "@Id", DbType.Int64, 0L);
            try
            {
                command.Prepare();
            }
            catch
            {
                // 旧版 Provider 不支持显式 Prepare 时仍可正常执行。
            }
            return command;
        }

        private static void AddParameter(
            DbCommand command,
            string name,
            DbType type,
            object value)
        {
            DbParameter parameter = command.CreateParameter();
            parameter.ParameterName = name;
            parameter.DbType = type;
            parameter.Value = value == null ? DBNull.Value : value;
            command.Parameters.Add(parameter);
        }

        private static void SetParameterValue(
            DbCommand command,
            string name,
            object value)
        {
            command.Parameters[name].Value = value == null ? DBNull.Value : value;
        }

        private static byte[] WrapWithHeader(
            byte[] source,
            Compressor compressor,
            uint dictionaryTag)
        {
            byte[] payload = compressor.Wrap(source);
            if (payload == null || payload.Length == 0)
                throw new InvalidDataException("Zstd 未返回有效压缩数据。");

            byte[] result = new byte[HeaderSize + payload.Length];
            Buffer.BlockCopy(Magic, 0, result, 0, Magic.Length);
            result[8] = StorageFormatVersion;
            result[9] = RequiredHeaderFlags;
            WriteUInt16(result, 10, HeaderSize);
            WriteInt32(result, 12, source.Length);
            WriteUInt32(result, 16, dictionaryTag);
            WriteUInt32(
                result,
                20,
                ComputeCrc32(payload, 0, payload.Length));
            Buffer.BlockCopy(payload, 0, result, HeaderSize, payload.Length);
            return result;
        }

        private static bool HasMagic(byte[] source)
        {
            if (source == null || source.Length < Magic.Length)
                return false;

            int i;
            for (i = 0; i < Magic.Length; i++)
            {
                if (source[i] != Magic[i])
                    return false;
            }
            return true;
        }

        private static void ValidateHeader(byte[] source)
        {
            if (!HasMagic(source))
                throw new InvalidDataException("SpectrumData 压缩标记无效。");
            if (source.Length <= HeaderSize)
                throw new InvalidDataException("SpectrumData 压缩数据过短。");
            if (source[8] != StorageFormatVersion)
                throw new InvalidDataException("不支持的 SpectrumData 压缩格式版本。");
            if ((source[9] & RequiredHeaderFlags) != RequiredHeaderFlags)
                throw new InvalidDataException("SpectrumData 压缩标志无效。");
            if (ReadUInt16(source, 10) != HeaderSize)
                throw new InvalidDataException("SpectrumData 压缩头长度无效。");

            int originalLength = ReadInt32(source, 12);
            if (originalLength <= 0 || originalLength > MaximumOriginalLength)
                throw new InvalidDataException("SpectrumData 原始长度无效。");
        }

        private static void ValidateStoredEnvelope(
            long rowId,
            byte[] source,
            uint expectedDictionaryTag)
        {
            ValidateHeader(source);

            uint dictionaryTag = ReadUInt32(source, 16);
            if (dictionaryTag != expectedDictionaryTag)
            {
                throw new InvalidDataException(
                    "SpectrumData Id=" +
                    rowId.ToString(CultureInfo.InvariantCulture) +
                    " 使用了其他 Zstd 字典，不能自动覆盖。");
            }

            uint storedCrc = ReadUInt32(source, 20);
            uint actualCrc = ComputeCrc32(
                source,
                HeaderSize,
                source.Length - HeaderSize);
            if (storedCrc != actualCrc)
            {
                throw new InvalidDataException(
                    "SpectrumData Id=" +
                    rowId.ToString(CultureInfo.InvariantCulture) +
                    " 的压缩负载 CRC 校验失败。");
            }
        }

        private static void TryRollback(DbTransaction transaction)
        {
            try
            {
                transaction.Rollback();
            }
            catch
            {
            }
        }

        private static byte[] ReadAllBytes(Stream stream)
        {
            using (MemoryStream memory = new MemoryStream())
            {
                byte[] buffer = new byte[4096];
                int read;
                while ((read = stream.Read(buffer, 0, buffer.Length)) != 0)
                    memory.Write(buffer, 0, read);
                return memory.ToArray();
            }
        }

        private static string ComputeSha256Hex(byte[] data)
        {
            byte[] hash;
            using (SHA256 sha = SHA256.Create())
                hash = sha.ComputeHash(data);

            StringBuilder builder = new StringBuilder(hash.Length * 2);
            int i;
            for (i = 0; i < hash.Length; i++)
                builder.Append(hash[i].ToString("x2", CultureInfo.InvariantCulture));
            return builder.ToString();
        }

        private static uint GetDictionaryTag(byte[] dictionary)
        {
            byte[] hash;
            using (SHA256 sha = SHA256.Create())
                hash = sha.ComputeHash(dictionary);

            return unchecked((uint)(
                hash[0] |
                (hash[1] << 8) |
                (hash[2] << 16) |
                (hash[3] << 24)));
        }

        private static void Report(
            SpectrumDatabaseUpgradeProgress progress,
            int current,
            int total,
            string message)
        {
            if (progress != null)
                progress(current, total, message);
        }

        private static ushort ReadUInt16(byte[] data, int offset)
        {
            return (ushort)(data[offset] | (data[offset + 1] << 8));
        }

        private static int ReadInt32(byte[] data, int offset)
        {
            return data[offset] |
                   (data[offset + 1] << 8) |
                   (data[offset + 2] << 16) |
                   (data[offset + 3] << 24);
        }

        private static uint ReadUInt32(byte[] data, int offset)
        {
            return unchecked((uint)(
                data[offset] |
                (data[offset + 1] << 8) |
                (data[offset + 2] << 16) |
                (data[offset + 3] << 24)));
        }

        private static void WriteUInt16(byte[] data, int offset, int value)
        {
            data[offset] = (byte)value;
            data[offset + 1] = (byte)(value >> 8);
        }

        private static void WriteInt32(byte[] data, int offset, int value)
        {
            data[offset] = (byte)value;
            data[offset + 1] = (byte)(value >> 8);
            data[offset + 2] = (byte)(value >> 16);
            data[offset + 3] = (byte)(value >> 24);
        }

        private static void WriteUInt32(byte[] data, int offset, uint value)
        {
            data[offset] = (byte)value;
            data[offset + 1] = (byte)(value >> 8);
            data[offset + 2] = (byte)(value >> 16);
            data[offset + 3] = (byte)(value >> 24);
        }

        private static uint[] CreateCrc32Table()
        {
            uint[] table = new uint[256];
            int i;
            for (i = 0; i < table.Length; i++)
            {
                uint value = (uint)i;
                int bit;
                for (bit = 0; bit < 8; bit++)
                {
                    if ((value & 1U) != 0)
                        value = 0xEDB88320U ^ (value >> 1);
                    else
                        value >>= 1;
                }
                table[i] = value;
            }
            return table;
        }

        private static uint ComputeCrc32(byte[] data, int offset, int count)
        {
            uint crc = 0xFFFFFFFFU;
            int end = offset + count;
            int i;
            for (i = offset; i < end; i++)
            {
                int tableIndex = (int)((crc ^ data[i]) & 0xFFU);
                crc = Crc32Table[tableIndex] ^ (crc >> 8);
            }
            return crc ^ 0xFFFFFFFFU;
        }

        private sealed class DictionaryRow
        {
            public string Name;
            public string Codec;
            public int Level;
            public int Size;
            public string Hash;
            public byte[] Data;
            public int FormatVersion;
        }

        private sealed class SpectrumRow
        {
            public long Id;
            public byte[] Data;
        }
    }
}
