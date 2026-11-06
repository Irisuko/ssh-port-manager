using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class Launcher
{
    private const string ResourcePrefix = "SshPortManager.Runtime.";
    private static readonly string[] PayloadNames = new string[]
    {
        "App.ps1", "App.xaml", "Apply-Changes.ps1", "Check-Coder.ps1",
        "Coder.psm1", "CoderJob.psm1", "CredentialStore.psm1", "HostManagement.psm1",
        "HostManager.ps1", "HostManager.xaml", "Mappings.psm1", "Operations.psm1",
        "SshConfig.psm1", "Start-Coder.ps1", "CoderTerminal.psm1",
        "PreparationJob.psm1", "Start-Prepare.ps1", "HostKeys.psm1", "VsCode.psm1"
    };

    [STAThread]
    private static void Main()
    {
        try
        {
            // Process-only policy: no persistent Windows setting is changed.
            Environment.SetEnvironmentVariable("PSExecutionPolicyPreference", "Bypass");
            string runtime = PrepareRuntime(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
            string script = Path.Combine(runtime, "App.ps1");
            using (Runspace runspace = RunspaceFactory.CreateRunspace())
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using (PowerShell shell = PowerShell.Create())
                {
                    shell.Runspace = runspace;
                    shell.AddCommand(script);
                    shell.Invoke();
                    if (shell.HadErrors)
                        throw new InvalidOperationException(shell.Streams.Error[0].ToString());
                }
            }
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "SSH Port Manager", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    // Main and packaging checks use the same extraction path; this never executes scripts.
    internal static string PrepareRuntime(string localApplicationData)
    {
        if (String.IsNullOrWhiteSpace(localApplicationData) || !Path.IsPathRooted(localApplicationData))
            throw new ArgumentException("A local application data directory is required.", "localApplicationData");

        byte[][] payload = ReadPayload();
        string contentHash = GetPayloadHash(payload);
        string appRoot = Path.Combine(Path.GetFullPath(localApplicationData), "SshPortManager");
        string runtimeRoot = Path.Combine(appRoot, "Runtime");
        string runtime = Path.Combine(runtimeRoot, contentHash);
        string mutexKey = HashBytes(Encoding.UTF8.GetBytes(runtime.ToUpperInvariant()));

        using (Mutex mutex = new Mutex(false, @"Local\SshPortManager.Runtime." + mutexKey))
        {
            bool acquired = false;
            try
            {
                try { acquired = mutex.WaitOne(TimeSpan.FromSeconds(30)); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired)
                    throw new IOException("Another SSH Port Manager instance is preparing its files. Try again shortly.");

                EnsureDirectory(appRoot);
                EnsureDirectory(runtimeRoot);
                EnsureDirectory(runtime);
                for (int i = 0; i < PayloadNames.Length; i++)
                    EnsurePayloadFile(Path.Combine(runtime, PayloadNames[i]), payload[i]);

                // Verify every file against immutable assembly bytes before returning to Main.
                for (int i = 0; i < PayloadNames.Length; i++)
                    if (!FileMatches(Path.Combine(runtime, PayloadNames[i]), payload[i]))
                        throw new IOException("Application file integrity check failed: " + PayloadNames[i]);
                return runtime;
            }
            finally
            {
                if (acquired) mutex.ReleaseMutex();
            }
        }
    }

    private static byte[][] ReadPayload()
    {
        Assembly assembly = Assembly.GetExecutingAssembly();
        if (assembly.GetManifestResourceNames().Length != PayloadNames.Length)
            throw new InvalidDataException("Unexpected application resource manifest.");
        byte[][] payload = new byte[PayloadNames.Length][];
        for (int i = 0; i < PayloadNames.Length; i++)
        {
            using (Stream resource = assembly.GetManifestResourceStream(ResourcePrefix + PayloadNames[i]))
            {
                if (resource == null)
                    throw new InvalidDataException("Missing application resource: " + PayloadNames[i]);
                using (MemoryStream bytes = new MemoryStream())
                {
                    resource.CopyTo(bytes);
                    payload[i] = bytes.ToArray();
                }
            }
        }
        return payload;
    }

    private static string GetPayloadHash(byte[][] payload)
    {
        using (MemoryStream manifest = new MemoryStream())
        {
            using (BinaryWriter writer = new BinaryWriter(manifest, Encoding.UTF8))
            {
                // Names and lengths make boundaries unambiguous; order is fixed by the allowlist.
                for (int i = 0; i < PayloadNames.Length; i++)
                {
                    writer.Write(ResourcePrefix + PayloadNames[i]);
                    writer.Write(payload[i].Length);
                    writer.Write(payload[i]);
                }
                writer.Flush();
                return HashBytes(manifest.ToArray());
            }
        }
    }

    private static string HashBytes(byte[] bytes)
    {
        using (SHA256 sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
    }

    private static void EnsureDirectory(string path)
    {
        if (Directory.Exists(path)) RejectReparsePoint(path);
        Directory.CreateDirectory(path);
        RejectReparsePoint(path);
    }

    private static void RejectReparsePoint(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Application runtime paths cannot be symbolic links or junctions: " + path);
    }

    private static bool FileMatches(string path, byte[] expected)
    {
        if (!File.Exists(path)) return false;
        RejectReparsePoint(path);
        using (FileStream file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            if (file.Length != expected.Length) return false;
            byte[] buffer = new byte[8192];
            int offset = 0;
            int count;
            while ((count = file.Read(buffer, 0, buffer.Length)) != 0)
            {
                for (int i = 0; i < count; i++)
                    if (buffer[i] != expected[offset + i]) return false;
                offset += count;
            }
            return offset == expected.Length;
        }
    }

    private static void EnsurePayloadFile(string path, byte[] expected)
    {
        if (FileMatches(path, expected)) return;
        string temporary = Path.Combine(Path.GetDirectoryName(path), Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (FileStream file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write,
                FileShare.None, 8192, FileOptions.WriteThrough))
            {
                file.Write(expected, 0, expected.Length);
                file.Flush(true);
            }
            if (File.Exists(path))
            {
                RejectReparsePoint(path);
                File.Replace(temporary, path, null);
            }
            else
            {
                // A complete file becomes visible in one rename; partial writes are never executed.
                try { File.Move(temporary, path); }
                catch (IOException)
                {
                    // Another Windows session may share this cache despite a session-local mutex.
                    if (!FileMatches(path, expected)) throw;
                }
            }
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
