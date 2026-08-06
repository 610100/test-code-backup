# PMAnalyzer：SpectrumData.Data 集成 Zstd（.NET Framework 3.5）

本包采用**最小化改动**：不重写 `SpectrumData`、`SQliteDAL` 或所有调用点，而是在现有 `JPSPEC.SerializeHelper` 中只对 `SpecListEntity` 做类型分流。这样所有已经存在的谱图保存/打开代码会自动得到压缩和解压，菜单、配置等其他 BinaryFormatter 数据完全保持原样。

## 一键使用

把下面四项放在同一个目录：

```text
Integrate-PMAnalyzer-Zstd.ps1
Files\SpectrumDataCompression.cs
Files\SpectrumDataUpgradeForm.cs
PMAnalyzer_Source_修改谱图.zip
ZstdSharp-Net35-runtime-fix.zip
SpectrumData_Zstd_Dictionary_Pack_v2.zip
```

双击：

```text
Run-Integration.cmd
```

或在 PowerShell 中执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Integrate-PMAnalyzer-Zstd.ps1 `
  -ProjectZip .\PMAnalyzer_Source_修改谱图.zip `
  -ZstdZip .\ZstdSharp-Net35-runtime-fix.zip `
  -DictionaryZip .\SpectrumData_Zstd_Dictionary_Pack_v2.zip
```

默认输出：

```text
PMAnalyzer_Source_修改谱图_ZstdIntegrated.zip
```

原始 ZIP 不会被覆盖。需要脚本顺便调用 MSBuild 时增加：

```powershell
-Build -BuildConfiguration Debug -BuildPlatform x86
```

## 实际集成内容

### 1. 指定字典

脚本从字典包中选择：

```text
FastCover自动 4K
运行压缩级别：1
字典大小：4096 字节
基准行：26.735881 / 62.283 / 21.063
```

选择顺序：

1. 优先读取包含上述三个基准数值的 CSV/TXT/JSON/MD 行，并匹配其中的字典文件名；
2. 否则只在**恰好 4096 字节**的候选中，按 `FastCover + Auto + Level1 + 4K/4096` 精确评分；
3. 若最高分不唯一，脚本停止，不会猜测使用错误字典。

选中的字典会复制为：

```text
AppCore\EDX.DataLib\Resources\SpectrumData_FastCoverAuto_Level1_4K_v2.zdict
```

并以 `EmbeddedResource` 编入 `EDX.DataLib`。

### 2. 数据库存储字典

新增表：

```sql
CREATE TABLE SpectrumCompressionDictionary (
    Id INTEGER NOT NULL PRIMARY KEY,
    Name TEXT NOT NULL,
    Codec TEXT NOT NULL,
    CompressionLevel INTEGER NOT NULL,
    DictionarySize INTEGER NOT NULL,
    DictionaryHash TEXT NOT NULL,
    DictionaryData BLOB NOT NULL,
    FormatVersion INTEGER NOT NULL,
    CompletedUtc TEXT NOT NULL
);
```

固定记录 `Id=1`。程序校验名称、算法、级别、长度、版本以及字典自身 SHA-256。

加载顺序严格为：

```text
数据库有效字典 -> 缓存并复用
数据库无表/无记录/损坏/读取失败 -> 代码内嵌字典
```

`Compressor`、`Decompressor` 和字典都缓存复用，不会每条谱图重新建立 CDict/DDict 上下文。

### 3. SpectrumData.Data 兼容格式

原来的 BinaryFormatter 字节不会改变，外层增加 24 字节头：

```text
0x00  8 字节  ASCII "SPZSTD01"
0x08  1 字节  格式版本
0x09  1 字节  标志
0x0A  2 字节  头长度（24）
0x0C  4 字节  解压后原始长度
0x10  4 字节  字典 SHA-256 前 32 位标识
0x14  4 字节  Zstd 负载 CRC32
0x18  ...     Zstd frame
```

读取行为：

```text
无 SPZSTD01 -> 旧数据，直接交给原 BinaryFormatter
有 SPZSTD01 -> 校验头、CRC、字典标识后解压，再交给原 BinaryFormatter
有标记但头损坏 -> 明确报错，绝不误当旧数据
```

因此同一数据库即使因异常出现“部分旧数据 + 部分压缩数据”，读取也兼容；下次迁移会校验并继续。

### 4. 一次性数据库升级

程序在原有 `DataBaseHelper.CheckTable(...)` 返回后执行检测。原来的表结构升级和 `UpSpectrumData()` 已经先完成，再进入 Zstd 升级。

没有有效字典记录且 `SpectrumData` 有数据时，显示无边框升级窗口：

```text
数据库正在升级，请勿关闭程序…
正在压缩已有谱图：当前 / 总数
```

迁移优化：

- 单个 SQLite 事务；
- 每批读取 128 条，避免一次把全部 BLOB 放进内存；
- 复用一个 `Compressor`；
- 复用并 `Prepare()` 一个 UPDATE 命令；
- 每 16 条刷新一次 UI，避免进度刷新拖慢迁移；
- 已压缩记录只校验并跳过；
- **全部数据成功后才在同一事务最后写入字典完成记录**；
- 任意异常整体回滚；
- 不自动执行 `VACUUM`，避免首次启动额外耗时和数据库文件大规模重写。

空数据库不会弹窗，只写入字典记录。

## 修改/新增文件

```text
AppCore\EDX.DataLib\Helper\SerializeHelper.cs
AppCore\EDX.DataLib\Helper\SpectrumDataCompression.cs
AppCore\EDX.DataLib\Resources\SpectrumData_FastCoverAuto_Level1_4K_v2.zdict
AppCore\EDX.DataLib\Lib\ZstdSharp.dll
AppCore\EDX.DataLib\EDX.DataLib.csproj

AppCore\EDX.UserControl\Forms\SpectrumDataUpgradeForm.cs
AppCore\EDX.UserControl\EDX.UserControl.csproj
AppCore\EDX.UserControl\InitHelper.cs（或实际包含 CheckTable 调用的启动文件）
```

输出源码还会带：

```text
ThirdParty\PMAnalyzer-Zstd\ZstdSharp-Net35-runtime-fix.zip
ThirdParty\PMAnalyzer-Zstd\SpectrumData_Zstd_Dictionary_Pack_v2.zip
ZSTD_SPECTRUM_INTEGRATION.md
ZSTD_SPECTRUM_FILES.sha256
```

## 首次运行前后的验证

首次在客户数据库上运行前，仍建议停止 PMAnalyzer 并复制数据库、`-journal` 和运行配置作为只读备份。

升级后至少验证：

1. 打开原有曲线和旧谱图；
2. 开始一次测试并保存新谱图；
3. 关闭软件后重新启动，再次打开新旧谱图；
4. 历史记录、报告和打印仍能读取对应谱图；
5. 对数据库执行 `PRAGMA quick_check;`，必要时执行 `PRAGMA integrity_check;`；
6. 查看 `SpectrumCompressionDictionary` 是否只有一条有效记录；
7. 抽查 `SpectrumData.Data` 前 8 字节是否为 `SPZSTD01`。

## 设计边界

本轮不改变：

- `SpecListEntity` 的字段或 BinaryFormatter 对象图；
- `SpectrumData` 表原有列；
- 历史记录和报告结构；
- 原有公开接口；
- 其他序列化数据；
- SQLite 页大小、journal 模式、同步级别；
- 自动 `VACUUM`。

这样改动范围最小，出现问题时也容易定位和回退。
