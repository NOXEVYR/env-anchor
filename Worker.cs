using System;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

namespace EnvAnchorUi
{
    public sealed class OperationWorker : IDisposable
    {
        private PowerShell shell;
        private Runspace space;
        private IAsyncResult invocation;
        public string ResultJson { get; private set; }
        public bool Completed { get { return invocation != null && invocation.IsCompleted; } }
        public int Percent { get { return shell == null || shell.Streams.Progress.Count == 0 ? -1 : shell.Streams.Progress[shell.Streams.Progress.Count-1].PercentComplete; } }
        public string Progress
        {
            get
            {
                if(shell==null || shell.Streams.Progress.Count==0) return "正在检查方案…";
                var p=shell.Streams.Progress[shell.Streams.Progress.Count-1];
                return p.Activity+" · "+p.StatusDescription+(p.PercentComplete>=0?" ("+p.PercentComplete+"%)":"");
            }
        }
        public void Start(string core, string operation, string store, string requests)
        {
            Initialize(core);
            shell.AddCommand("Invoke-PlanOperation").AddParameter("Operation",operation)
                .AddParameter("Store",store).AddParameter("RequestsJson",requests);
            invocation=shell.BeginInvoke();
        }
        private void Initialize(string core)
        {
            ResultJson = "";
            space=RunspaceFactory.CreateRunspace(); space.Open();
            shell=PowerShell.Create(); shell.Runspace=space;
            shell.AddScript(core,false).Invoke();
            if(shell.Streams.Error.Count>0) throw new Exception(shell.Streams.Error[0].ToString());
            shell.Commands.Clear();
        }
        public void StartCommand(string engine, string command, string arguments)
        {
            string[] allowed = { "Get-OperationPreview", "Invoke-PlanOperation", "Get-ReferenceReport", "Invoke-ReferenceRepair", "Export-RecoveryManifest", "Import-RecoveryManifest" };
            if (Array.IndexOf(allowed, command) < 0) throw new ArgumentException("不支持的后台任务。");
            Initialize(engine);
            shell.AddScript("param($name,$json) $p=@{}; $o=ConvertFrom-Json $json; foreach($v in $o.PSObject.Properties){$p[$v.Name]=$v.Value}; & $name @p | ConvertTo-Json -Depth 24 -Compress", false)
                .AddArgument(command).AddArgument(arguments);
            invocation=shell.BeginInvoke();
        }
        public string Finish()
        {
            try {var output=shell.EndInvoke(invocation); if(output.Count>0) ResultJson=output[output.Count-1].ToString();}
            catch(Exception error) {return error.Message;}
            return shell.Streams.Error.Count==0 ? "" : shell.Streams.Error[0].ToString();
        }
        public void Dispose()
        {
            if(shell!=null) shell.Dispose();
            if(space!=null) space.Dispose();
        }
    }
}
