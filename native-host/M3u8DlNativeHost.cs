using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

public static class M3u8DlNativeHost
{
    static readonly string BaseDir = AppDomain.CurrentDomain.BaseDirectory;
    static readonly string Root = Path.GetFullPath(Path.Combine(BaseDir, ".."));
    static readonly string ConfigPath = Path.Combine(Root, "auto-m3u8dl.config.json");
    static readonly string StateDir = Path.Combine(Root, ".auto-m3u8dl");
    static readonly string LogPath = Path.Combine(StateDir, "native-host.log");

    public static int Main()
    {
        try
        {
            var message = ReadMessage();
            if (message == null) return 0;

            string type = GetString(message, "type");
            if (type != "download") throw new Exception("Unsupported message type: " + type);

            WriteMessage(RunDownload(message));
            return 0;
        }
        catch (Exception ex)
        {
            Log("ERROR " + ex);
            WriteMessage(new Dictionary<string, object> {
                { "ok", false },
                { "error", ex.Message }
            });
            return 1;
        }
    }

    static Dictionary<string, object> ReadMessage()
    {
        var stdin = Console.OpenStandardInput();
        byte[] header = ReadExact(stdin, 4);
        if (header == null) return null;
        int length = BitConverter.ToInt32(header, 0);
        byte[] body = ReadExact(stdin, length);
        string json = Encoding.UTF8.GetString(body);
        return new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(json);
    }

    static byte[] ReadExact(Stream stream, int length)
    {
        byte[] buffer = new byte[length];
        int offset = 0;
        while (offset < length)
        {
            int read = stream.Read(buffer, offset, length - offset);
            if (read == 0)
            {
                if (offset == 0) return null;
                throw new EndOfStreamException();
            }
            offset += read;
        }
        return buffer;
    }

    static void WriteMessage(Dictionary<string, object> message)
    {
        string json = new JavaScriptSerializer().Serialize(message);
        byte[] body = Encoding.UTF8.GetBytes(json);
        byte[] header = BitConverter.GetBytes(body.Length);
        var stdout = Console.OpenStandardOutput();
        stdout.Write(header, 0, header.Length);
        stdout.Write(body, 0, body.Length);
        stdout.Flush();
    }

    static Dictionary<string, object> RunDownload(Dictionary<string, object> message)
    {
        string url = GetString(message, "url");
        if (!Regex.IsMatch(url ?? "", "^https?://", RegexOptions.IgnoreCase))
            throw new Exception("Message does not contain an HTTP video URL");

        var config = ReadConfig();
        string workDir = GetString(message, "workDir");
        if (String.IsNullOrWhiteSpace(workDir)) workDir = GetString(config, "workDirTemplate");
        if (String.IsNullOrWhiteSpace(workDir)) workDir = Path.Combine(Root, "Downloads");
        Directory.CreateDirectory(workDir);

        string title = SafeFileName(GetString(message, "title"));
        string mediaType = GetString(message, "mediaType");
        if (String.IsNullOrWhiteSpace(mediaType)) mediaType = DetectMediaType(url);
        if (mediaType == "media") mediaType = DetectMediaType(url);

        string playlistBody = GetString(message, "playlistBody");
        if (!String.IsNullOrWhiteSpace(playlistBody) && playlistBody.Contains("#EXTM3U"))
        {
            string playlistPath = Path.Combine(workDir, title + ".m3u8");
            File.WriteAllText(playlistPath, playlistBody, Encoding.UTF8);
            url = playlistPath;
            mediaType = "hls-file";
        }

        if (mediaType == "file")
        {
            return RunDirectFileDownload(url, title, workDir);
        }

        string downloaderDir = GetString(config, "downloaderDir");
        if (String.IsNullOrWhiteSpace(downloaderDir))
            downloaderDir = Path.Combine(Root, "N_m3u8DL-CLI_v3.0.2_with_ffmpeg_and_SimpleG");

        string cliExe = GetString(config, "cliExe");
        if (String.IsNullOrWhiteSpace(cliExe)) cliExe = "N_m3u8DL-CLI_v3.0.2.exe";

        string cliPath = Path.Combine(downloaderDir, cliExe);
        if (!File.Exists(cliPath)) throw new Exception("Downloader not found: " + cliPath);

        var args = new List<string> {
            Quote(url),
            "--workDir", Quote(workDir),
            "--saveName", Quote(title)
        };

        string headerArg = BuildHeaderArg(message);
        if (!String.IsNullOrWhiteSpace(headerArg))
        {
            args.Add("--headers");
            args.Add(Quote(headerArg));
        }

        if (GetBool(config, "enableDelAfterDone", true)) args.Add("--enableDelAfterDone");

        var psi = new ProcessStartInfo {
            FileName = cliPath,
            Arguments = String.Join(" ", args.ToArray()),
            WorkingDirectory = downloaderDir,
            UseShellExecute = false
        };
        var process = Process.Start(psi);
        Log("START type=\"" + mediaType + "\" title=\"" + title + "\" workDir=\"" + workDir + "\" url=\"" + url + "\"");

        return new Dictionary<string, object> {
            { "ok", true },
            { "pid", process.Id },
            { "title", title },
            { "workDir", workDir },
            { "mediaType", mediaType }
        };
    }

    static Dictionary<string, object> RunDirectFileDownload(string url, string title, string workDir)
    {
        string outPath = Path.Combine(workDir, title + ExtensionFromUrl(url));
        string command = "$ProgressPreference='SilentlyContinue'; Invoke-WebRequest -Uri " + PsQuote(url) + " -OutFile " + PsQuote(outPath);
        var psi = new ProcessStartInfo {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -Command " + Quote(command),
            UseShellExecute = false
        };
        var process = Process.Start(psi);
        Log("START type=\"file\" title=\"" + title + "\" out=\"" + outPath + "\" url=\"" + url + "\"");
        return new Dictionary<string, object> {
            { "ok", true },
            { "pid", process.Id },
            { "title", title },
            { "workDir", workDir },
            { "outPath", outPath },
            { "mediaType", "file" }
        };
    }

    static Dictionary<string, object> ReadConfig()
    {
        if (!File.Exists(ConfigPath)) return new Dictionary<string, object>();
        string json = File.ReadAllText(ConfigPath, Encoding.UTF8);
        return new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(json);
    }

    static string DetectMediaType(string url)
    {
        if (Regex.IsMatch(url, "\\.m3u8(?:[?#]|$)", RegexOptions.IgnoreCase)) return "hls";
        if (Regex.IsMatch(url, "\\.mpd(?:[?#]|$)", RegexOptions.IgnoreCase)) return "dash";
        if (Regex.IsMatch(url, "\\.(mp4|m4v|webm|mov|flv|f4v)(?:[?#]|$)", RegexOptions.IgnoreCase)) return "file";
        if (Regex.IsMatch(url, "\\.(ts|m4s)(?:[?#]|$)", RegexOptions.IgnoreCase)) return "segment";
        return "media";
    }

    static string ExtensionFromUrl(string url)
    {
        var match = Regex.Match(url, "\\.(mp4|m4v|webm|mov|flv|f4v)(?:[?#]|$)", RegexOptions.IgnoreCase);
        return match.Success ? "." + match.Groups[1].Value.ToLowerInvariant() : ".mp4";
    }

    static string BuildHeaderArg(Dictionary<string, object> message)
    {
        if (!message.ContainsKey("headers") || message["headers"] == null) return "";
        var dict = message["headers"] as Dictionary<string, object>;
        if (dict == null) return "";

        var parts = new List<string>();
        foreach (var key in new [] { "Referer", "User-Agent", "Cookie", "Origin", "Accept", "Accept-Language" })
        {
            if (dict.ContainsKey(key) && dict[key] != null)
            {
                string value = Convert.ToString(dict[key]);
                if (!String.IsNullOrWhiteSpace(value)) parts.Add(key + ":" + value.Replace("|", "%7C"));
            }
        }
        return String.Join("|", parts.ToArray());
    }

    static string SafeFileName(string name)
    {
        if (String.IsNullOrWhiteSpace(name)) name = "video_" + DateTime.Now.ToString("yyyyMMdd_HHmmss");
        foreach (char c in Path.GetInvalidFileNameChars()) name = name.Replace(c, '_');
        name = Regex.Replace(name, "\\s+", " ").Trim().Trim('.', ' ');
        if (name.Length > 120) name = name.Substring(0, 120).Trim().Trim('.', ' ');
        return String.IsNullOrWhiteSpace(name) ? "video_" + DateTime.Now.ToString("yyyyMMdd_HHmmss") : name;
    }

    static string GetString(IDictionary<string, object> dict, string key)
    {
        return dict != null && dict.ContainsKey(key) && dict[key] != null ? Convert.ToString(dict[key]) : "";
    }

    static bool GetBool(IDictionary<string, object> dict, string key, bool fallback)
    {
        if (dict == null || !dict.ContainsKey(key) || dict[key] == null) return fallback;
        return Convert.ToBoolean(dict[key]);
    }

    static string Quote(string value)
    {
        return "\"" + (value ?? "").Replace("\"", "\\\"") + "\"";
    }

    static string PsQuote(string value)
    {
        return "'" + (value ?? "").Replace("'", "''") + "'";
    }

    static void Log(string line)
    {
        Directory.CreateDirectory(StateDir);
        File.AppendAllText(LogPath, "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + line + Environment.NewLine, Encoding.UTF8);
    }
}
