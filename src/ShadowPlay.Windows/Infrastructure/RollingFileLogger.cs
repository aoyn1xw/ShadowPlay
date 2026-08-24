using System.Globalization;
using System.IO;
using System.Text;
using Microsoft.Extensions.Logging;

namespace ShadowPlay.Windows.Infrastructure;

/// <summary>
/// Minimal size-capped rotating file logger. No external packages.
/// Logs live under %LocalAppData%\ShadowPlay\logs and never receive secrets -
/// callers are responsible for keeping tokens/pairing codes out of messages.
/// </summary>
public sealed class RollingFileLoggerProvider : ILoggerProvider
{
    private const long MaxBytes = 512 * 1024;
    private const int MaxBackups = 3;

    private readonly string _logFilePath;
    private readonly object _sync = new();

    public RollingFileLoggerProvider(string logDirectory)
    {
        Directory.CreateDirectory(logDirectory);
        _logFilePath = Path.Combine(logDirectory, "shadowplay.log");
    }

    public ILogger CreateLogger(string categoryName) =>
        new RollingFileLogger(this, Shorten(categoryName));

    private void Write(LogLevel level, string category, string message, Exception? exception)
    {
        lock (_sync)
        {
            try
            {
                RotateIfNeeded();

                var builder = new StringBuilder(256);
                builder.Append(DateTimeOffset.UtcNow.ToString("yyyy-MM-dd HH:mm:ss.fff 'Z'", CultureInfo.InvariantCulture));
                builder.Append(" [").Append(level switch
                {
                    LogLevel.Trace => "TRC",
                    LogLevel.Debug => "DBG",
                    LogLevel.Information => "INF",
                    LogLevel.Warning => "WRN",
                    LogLevel.Error => "ERR",
                    LogLevel.Critical => "FTL",
                    _ => "LOG",
                }).Append("] ").Append(category).Append(": ").AppendLine(message);

                if (exception is not null)
                {
                    builder.AppendLine(exception.ToString());
                }

                File.AppendAllText(_logFilePath, builder.ToString());
            }
            catch (IOException)
            {
                // Never crash the app because logging failed.
            }
        }
    }

    private void RotateIfNeeded()
    {
        try
        {
            if (!File.Exists(_logFilePath))
            {
                return;
            }

            var info = new FileInfo(_logFilePath);
            if (info.Length < MaxBytes)
            {
                return;
            }

            var oldest = $"{_logFilePath}.{MaxBackups}";
            if (File.Exists(oldest))
            {
                File.Delete(oldest);
            }

            for (var i = MaxBackups - 1; i >= 1; i--)
            {
                var source = $"{_logFilePath}.{i}";
                if (File.Exists(source))
                {
                    File.Move(source, $"{_logFilePath}.{i + 1}", overwrite: true);
                }
            }

            File.Move(_logFilePath, $"{_logFilePath}.1", overwrite: true);
        }
        catch (IOException)
        {
        }
    }

    private static string Shorten(string category)
    {
        // "ShadowPlay.Windows.Services.AppController" -> "S.W.S.AppController"
        var parts = category.Split('.');
        if (parts.Length <= 2)
        {
            return category;
        }

        return string.Join('.', parts[..^1].Select(p => p.Length > 0 ? p[..1] : p).Concat([parts[^1]]));
    }

    public void Dispose()
    {
    }

    private sealed class RollingFileLogger(RollingFileLoggerProvider owner, string category) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Debug;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            if (!IsEnabled(logLevel))
            {
                return;
            }

            owner.Write(logLevel, category, formatter(state, exception), exception);
        }
    }
}

public static class LoggingBuilderExtensions
{
    public static ILoggingBuilder AddShadowPlayFileLog(this ILoggingBuilder builder, string logDirectory)
    {
        builder.AddProvider(new RollingFileLoggerProvider(logDirectory));
        builder.SetMinimumLevel(LogLevel.Information);
        return builder;
    }
}
