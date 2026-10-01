using System;
using System.IO;
using System.Reflection;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows.Forms;
using System.Runtime.InteropServices;

[assembly: AssemblyTitle("环境锚点")]
[assembly: AssemblyVersion("0.8.0.0")]
[assembly: AssemblyFileVersion("0.8.0.0")]
[assembly: AssemblyInformationalVersion("0.8.0-preview.1")]
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
                string engine = Resource("Core.ps1") + "\r\n" + Resource("Preflight.ps1") + "\r\n" + Resource("Environment.ps1");
                runspace.SessionStateProxy.SetVariable("EnvAnchorCore", engine);
                runspace.SessionStateProxy.SetVariable("EnvAnchorUITests", Resource("Ui.Tests.ps1"));
                using(var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("app.png"))
                using(var image=System.Drawing.Image.FromStream(stream))
                    runspace.SessionStateProxy.SetVariable("EnvAnchorMark",new System.Drawing.Bitmap(image));
                using (var ps = PowerShell.Create())
                {
                    ps.Runspace = runspace;
                    ps.AddScript(engine, false).Invoke();
                    if (ps.Streams.Error.Count > 0) throw new Exception(ps.Streams.Error[0].ToString());
                    ps.Commands.Clear();
                    if (selfTest)
                    {
                        using (var writer = new StreamWriter(Path.Combine(Path.GetTempPath(), "env-anchor-client-tests.txt")))
                            foreach (string test in new string[] { "Core.Tests.ps1", "Preflight.Tests.ps1", "Environment.Tests.ps1" })
                            {
                                ps.Commands.Clear();
                                var output = ps.AddScript(Resource(test), false).Invoke();
                                if (ps.Streams.Error.Count > 0) throw new Exception(test + ": " + ps.Streams.Error[0].ToString());
                                foreach (var line in output) writer.WriteLine(line);
                            }
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
