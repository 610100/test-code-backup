using System;
using System.ComponentModel;
using System.Drawing;
using System.Windows.Forms;

namespace JPSPEC
{
    /// <summary>
    /// 首次启用 SpectrumData Zstd 压缩时显示的阻塞式升级窗口。
    /// 数据库升级在 BackgroundWorker 中执行，UI 线程只负责显示进度。
    /// </summary>
    public sealed class SpectrumDataUpgradeForm : Form
    {
        private readonly BackgroundWorker _worker;
        private readonly Label _titleLabel;
        private readonly Label _detailLabel;
        private readonly ProgressBar _progressBar;
        private readonly int _initialTotal;
        private bool _running;
        private Exception _upgradeError;

        public Exception UpgradeError
        {
            get { return _upgradeError; }
        }

        public static void EnsureUpgraded()
        {
            int totalRows;
            bool needsUpgrade;

            try
            {
                needsUpgrade = SpectrumDataCompression.NeedsDatabaseUpgrade(out totalRows);
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException("检测 SpectrumData 数据库压缩状态失败。", ex);
            }

            if (!needsUpgrade)
                return;

            using (SpectrumDataUpgradeForm form = new SpectrumDataUpgradeForm(totalRows))
            {
                DialogResult result = form.ShowDialog();
                if (result != DialogResult.OK)
                {
                    if (form.UpgradeError != null)
                    {
                        throw new InvalidOperationException(
                            "SpectrumData 数据库升级失败，原数据库未被部分提交。",
                            form.UpgradeError);
                    }

                    throw new InvalidOperationException("SpectrumData 数据库升级没有完成。");
                }
            }
        }

        private SpectrumDataUpgradeForm(int totalRows)
        {
            _initialTotal = totalRows < 0 ? 0 : totalRows;
            _running = true;

            AutoScaleMode = AutoScaleMode.Font;
            BackColor = Color.White;
            ClientSize = new Size(520, 184);
            ControlBox = false;
            DoubleBuffered = true;
            Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Regular, GraphicsUnit.Point, 134);
            FormBorderStyle = FormBorderStyle.None;
            MaximizeBox = false;
            MinimizeBox = false;
            Name = "SpectrumDataUpgradeForm";
            ShowIcon = false;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterScreen;
            Text = "数据库升级";
            TopMost = true;
            UseWaitCursor = true;

            _titleLabel = new Label();
            _titleLabel.AutoSize = false;
            _titleLabel.Font = new Font(Font.FontFamily, 13F, FontStyle.Bold);
            _titleLabel.Location = new Point(28, 28);
            _titleLabel.Name = "titleLabel";
            _titleLabel.Size = new Size(464, 30);
            _titleLabel.Text = "数据库正在升级，请勿关闭程序…";
            _titleLabel.TextAlign = ContentAlignment.MiddleLeft;

            _detailLabel = new Label();
            _detailLabel.AutoEllipsis = true;
            _detailLabel.Location = new Point(30, 72);
            _detailLabel.Name = "detailLabel";
            _detailLabel.Size = new Size(460, 24);
            _detailLabel.Text = _initialTotal == 0
                ? "正在准备谱图压缩…"
                : "准备压缩已有谱图：0 / " + _initialTotal.ToString();
            _detailLabel.TextAlign = ContentAlignment.MiddleLeft;

            _progressBar = new ProgressBar();
            _progressBar.Location = new Point(30, 112);
            _progressBar.Name = "progressBar";
            _progressBar.Size = new Size(460, 20);
            _progressBar.Minimum = 0;
            _progressBar.Maximum = _initialTotal > 0 ? _initialTotal : 100;
            _progressBar.Style = ProgressBarStyle.Continuous;

            Label hintLabel = new Label();
            hintLabel.AutoSize = false;
            hintLabel.ForeColor = Color.DimGray;
            hintLabel.Location = new Point(30, 140);
            hintLabel.Name = "hintLabel";
            hintLabel.Size = new Size(460, 20);
            hintLabel.Text = "升级采用事务处理；失败或断电不会提交半升级数据。";
            hintLabel.TextAlign = ContentAlignment.MiddleLeft;

            Controls.Add(_titleLabel);
            Controls.Add(_detailLabel);
            Controls.Add(_progressBar);
            Controls.Add(hintLabel);

            _worker = new BackgroundWorker();
            _worker.WorkerReportsProgress = true;
            _worker.DoWork += WorkerDoWork;
            _worker.ProgressChanged += WorkerProgressChanged;
            _worker.RunWorkerCompleted += WorkerRunWorkerCompleted;

            Shown += FormShown;
        }

        private void FormShown(object sender, EventArgs e)
        {
            _worker.RunWorkerAsync();
        }

        private void WorkerDoWork(object sender, DoWorkEventArgs e)
        {
            SpectrumDataCompression.UpgradeDatabase(ReportUpgradeProgress);
        }

        private void ReportUpgradeProgress(int current, int total, string message)
        {
            int percent;
            if (total <= 0)
                percent = 0;
            else
                percent = Math.Max(0, Math.Min(100, (int)((long)current * 100L / total)));

            _worker.ReportProgress(percent, new UpgradeStatus(current, total, message));
        }

        private void WorkerProgressChanged(object sender, ProgressChangedEventArgs e)
        {
            UpgradeStatus status = e.UserState as UpgradeStatus;
            if (status == null)
                return;

            int maximum = status.Total > 0 ? status.Total : 100;
            if (_progressBar.Maximum != maximum)
                _progressBar.Maximum = maximum;

            int value = status.Total > 0 ? status.Current : e.ProgressPercentage;
            value = Math.Max(_progressBar.Minimum, Math.Min(_progressBar.Maximum, value));
            _progressBar.Value = value;
            _detailLabel.Text = String.IsNullOrEmpty(status.Message)
                ? "数据库正在升级…"
                : status.Message;
            _detailLabel.Refresh();
            _progressBar.Refresh();
        }

        private void WorkerRunWorkerCompleted(object sender, RunWorkerCompletedEventArgs e)
        {
            _running = false;
            UseWaitCursor = false;

            if (e.Error != null)
            {
                _upgradeError = e.Error;
                _titleLabel.Text = "数据库升级失败";
                _detailLabel.Text = e.Error.GetBaseException().Message;
                Refresh();

                MessageBox.Show(
                    this,
                    "数据库升级失败，全部修改已经回滚。\r\n\r\n" +
                    e.Error.GetBaseException().Message,
                    "数据库升级",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);

                DialogResult = DialogResult.Cancel;
                Close();
                return;
            }

            _titleLabel.Text = "数据库升级完成";
            _detailLabel.Text = "谱图压缩和字典写入已经完成。";
            if (_progressBar.Maximum > 0)
                _progressBar.Value = _progressBar.Maximum;
            Refresh();

            DialogResult = DialogResult.OK;
            Close();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (_running)
            {
                e.Cancel = true;
                System.Media.SystemSounds.Beep.Play();
                return;
            }

            base.OnFormClosing(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            using (Pen borderPen = new Pen(Color.FromArgb(205, 210, 218)))
            {
                e.Graphics.DrawRectangle(
                    borderPen,
                    0,
                    0,
                    ClientSize.Width - 1,
                    ClientSize.Height - 1);
            }
        }

        private sealed class UpgradeStatus
        {
            public readonly int Current;
            public readonly int Total;
            public readonly string Message;

            public UpgradeStatus(int current, int total, string message)
            {
                Current = current;
                Total = total;
                Message = message;
            }
        }
    }
}
