using System;
using System.IO;
using System.Reflection;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows.Forms;
using System.Runtime.InteropServices;

[assembly: AssemblyTitle("环境锚点")]
[assembly: AssemblyVersion("0.5.0.0")]
[assembly: AssemblyFileVersion("0.5.0.0")]
internal static class Client
{
    [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
    private static string Resource(string name)
    {
        using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        using (var reader = new StreamReader(stream)) return reader.ReadToEnd();
    }
    [STAThread]
    private static int Main(string[] args)
    {
        bool resume = false, smoke = false, selfTest = false;
        string store = @"E:\个人环境";
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--resume") resume = true;
            else if (args[i] == "--smoke-test") smoke = true;
            else if (args[i] == "--self-test") { selfTest = true; smoke = true; }
            else if (args[i] == "--store" && i + 1 < args.Length) store = args[++i];
            else return 2;
        }
        Application.EnableVisualStyles();
        try
        {
            if (GetConsoleWindow() != IntPtr.Zero) throw new Exception("客户端意外附加了控制台。");
            using (var runspace = RunspaceFactory.CreateRunspace())
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                runspace.SessionStateProxy.SetVariable("EnvAnchorExecutable", Application.ExecutablePath);
                using(var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("app.png"))
                using(var image=System.Drawing.Image.FromStream(stream))
                    runspace.SessionStateProxy.SetVariable("EnvAnchorMark",new System.Drawing.Bitmap(image));
                using (var ps = PowerShell.Create())
                {
                    ps.Runspace = runspace;
                    ps.AddScript(Resource("Core.ps1"), false).Invoke();
                    if (ps.Streams.Error.Count > 0) throw new Exception(ps.Streams.Error[0].ToString());
                    ps.Commands.Clear();
                    if (selfTest)
                    {
                        var output = ps.AddScript(Resource("Core.Tests.ps1"), false).Invoke();
                        if (ps.Streams.Error.Count > 0) throw new Exception(ps.Streams.Error[0].ToString());
                        using (var writer = new StreamWriter(Path.Combine(Path.GetTempPath(), "env-anchor-client-tests.txt")))
                            foreach (var line in output) writer.WriteLine(line);
                        return 0;
                    }
                    ps.AddScript(Resource("EnvAnchor.ps1"), false)
                        .AddParameter("Mode", resume ? "Resume" : "UI")
                        .AddParameter("Store", store)
                        .AddParameter("SmokeTest", smoke).Invoke();
                    if (ps.Streams.Error.Count > 0) throw new Exception(ps.Streams.Error[0].ToString());
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            if (!resume && !smoke) MessageBox.Show(error.Message, "环境锚点 · 无法启动", MessageBoxButtons.OK, MessageBoxIcon.Error);
            // Smoke test failures must be observable without a console window.
            if (smoke) File.WriteAllText(Path.Combine(Path.GetTempPath(), "env-anchor-client-error.txt"), error.ToString());
            return 1;
        }
    }
}
