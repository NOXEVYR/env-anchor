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
        public bool Completed { get { return invocation != null && invocation.IsCompleted; } }
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
            space=RunspaceFactory.CreateRunspace(); space.Open();
            shell=PowerShell.Create(); shell.Runspace=space;
            shell.AddScript(core,false).Invoke();
            if(shell.Streams.Error.Count>0) throw new Exception(shell.Streams.Error[0].ToString());
            shell.Commands.Clear();
            shell.AddCommand("Invoke-PlanOperation").AddParameter("Operation",operation)
                .AddParameter("Store",store).AddParameter("RequestsJson",requests);
            invocation=shell.BeginInvoke();
        }
        public string Finish()
        {
            try {shell.EndInvoke(invocation);}
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
