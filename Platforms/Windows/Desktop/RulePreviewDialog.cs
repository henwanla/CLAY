namespace Clay.Windows;

internal static class RulePreviewDialog
{
    internal static void Show(Form owner, string cli, string path)
    {
        using var cancel = new CancellationTokenSource();
        using var dialog = new Form
        {
            Text = L("Rule preview", "规则预览", "ルールの確認"),
            StartPosition = FormStartPosition.CenterParent, FormBorderStyle = FormBorderStyle.FixedDialog,
            MinimizeBox = false, MaximizeBox = false, ShowInTaskbar = false,
            Font = owner.Font, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink
        };
        var layout = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, ColumnCount = 1,
            Padding = new Padding(16), MinimumSize = new Size(510, 0) };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        var caption = L("Domain, IP address or URL (optional)", "域名、IP 地址或 URL（可留空）", "ドメイン、IP アドレス、URL（省略可）");
        var target = new TextBox { MaxLength = 4096, Dock = DockStyle.Fill, AccessibleName = caption };
        var hint = L("Leave blank to validate the file. No lookup or connection is made.",
            "留空只检查规则文件。不会查询或连接目标。", "空欄ならファイルのみを検証します。名前解決や接続は行いません。");
        var result = Label(hint);
        var check = new Button { Text = L("Check", "检查", "確認"), AutoSize = true };
        var close = new Button { Text = L("Close", "关闭", "閉じる"), AutoSize = true, DialogResult = DialogResult.Cancel };
        var actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill };
        actions.Controls.AddRange([check, close]);
        layout.Controls.Add(Label(L(
            "Check this file in Rule mode. Global and Direct ignore it. The system PAC may bypass the proxy for local requests. Rule numbers skip comments and blank lines.",
            "检查规则模式下这份文件的判断。全局和直连模式不使用它。系统 PAC 可能先让本地请求直连。规则编号跳过注释和空行。",
            "ルールモードでの判定を確認します。グローバルと直接接続ではこのファイルを使いません。システム PAC はローカル通信を直接接続することがあります。ルール番号はコメントと空行を数えません。")));
        layout.Controls.Add(Label(caption));
        layout.Controls.Add(target);
        layout.Controls.Add(actions);
        layout.Controls.Add(result);
        dialog.Controls.Add(layout);
        dialog.AcceptButton = check;
        dialog.CancelButton = close;
        dialog.Shown += (_, _) => target.Focus();
        target.TextChanged += (_, _) => result.Text = hint;
        check.Click += async (_, _) =>
        {
            check.Enabled = target.Enabled = false;
            result.Text = L("Checking…", "正在检查…", "確認中…");
            string message;
            try { message = Describe(await PortableSession.PreviewRulesAsync(cli, path, target.Text, cancel.Token)); }
            catch { message = L("Could not check the rules file.", "无法检查规则文件。", "ルールファイルを確認できませんでした。"); }
            if (cancel.IsCancellationRequested || dialog.IsDisposed) return;
            result.Text = message;
            check.Enabled = target.Enabled = true;
            target.Focus();
        };
        try { dialog.ShowDialog(owner); }
        finally { cancel.Cancel(); target.Clear(); }
    }

    private static string Describe(RulePreview preview)
    {
        var number = preview.Number;
        var decision = preview.Direct ? L("Direct", "直连", "直接接続") : L("Proxy", "代理", "プロキシ");
        return preview.Kind switch
        {
            "count" => L($"Valid file · Rule count: {number}", $"文件有效 · 规则数：{number}", $"有効なファイル · ルール数：{number}"),
            "rule-line" => L($"Invalid rule on line {number}.", $"第 {number} 行规则无效。", $"{number} 行目のルールが無効です。"),
            "rules" => L("Choose a readable UTF-8 rules file of up to 2 MiB.", "请选择不超过 2 MiB 的可读 UTF-8 规则文件。",
                "読み取り可能な 2 MiB 以下の UTF-8 ルールファイルを選んでください。"),
            "target" => L("Enter a valid domain, IP address, or URL.", "请输入有效的域名、IP 地址或 URL。",
                "有効なドメイン、IP アドレス、または URL を入力してください。"),
            "too-long" => L("Enter a shorter domain, IP address, or URL.", "请输入更短的域名、IP 地址或 URL。",
                "短いドメイン、IP アドレス、または URL を入力してください。"),
            "rule" => L($"{decision} · Rule {number}", $"{decision} · 第 {number} 条规则", $"{decision} · ルール {number}"),
            "loopback" => L($"{decision} · Loopback", $"{decision} · 回环地址", $"{decision} · ループバック"),
            "local" => L($"{decision} · Local address", $"{decision} · 本地地址", $"{decision} · ローカルアドレス"),
            _ => L($"{decision} · No matching rule", $"{decision} · 未命中规则", $"{decision} · 一致するルールなし")
        };
    }

    private static Label Label(string caption) => new() { AutoSize = true, Text = caption, MaximumSize = new Size(475, 0) };
    private static string L(string en, string zh, string ja) => MainWindow.L(en, zh, ja);
}
