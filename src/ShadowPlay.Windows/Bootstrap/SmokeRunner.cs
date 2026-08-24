using System.Net.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using ShadowPlay.Windows.Services;

namespace ShadowPlay.Windows.Bootstrap;

/// <summary>
/// Headless diagnostics mode: `ShadowPlay.exe --smoke --folder C:\clips [--port N] [--smoke-seconds S]`.
/// Boots the full pipeline (settings, monitor, LAN API) without any UI, waits until the
/// health endpoint responds, then exits. Used for automated smoke tests and CI.
/// </summary>
public static class SmokeRunner
{
    public static async Task<int> RunAsync(CliOptions cli)
    {
        if (cli.Folder is null)
        {
            Console.WriteLine("SMOKE_FAIL missing --folder argument");
            return 2;
        }

        try
        {
            using var host = AppHostFactory.Build(cli);
            host.Start();

            var controller = host.Services.GetRequiredService<AppController>();

            // Smoke runs always share, regardless of persisted preference.
            await controller.ResumeSharingAsync();

            var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(20);
            while (controller.Status.State != SharingState.Running && DateTime.UtcNow < deadline)
            {
                await Task.Delay(250);
            }

            if (controller.Status.State != SharingState.Running)
            {
                Console.WriteLine($"SMOKE_FAIL sharing did not start: {controller.Status.Detail}");
                return 1;
            }

            var port = controller.Status.Port;
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
            var healthUrl = $"http://127.0.0.1:{port}/api/v1/health";

            HttpResponseMessage? response = null;
            deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
            while (DateTime.UtcNow < deadline)
            {
                try
                {
                    response = await http.GetAsync(healthUrl);
                    if (response.IsSuccessStatusCode)
                    {
                        break;
                    }
                }
                catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
                {
                }

                await Task.Delay(250);
            }

            if (response is null || !response.IsSuccessStatusCode)
            {
                Console.WriteLine("SMOKE_FAIL health endpoint never became ready");
                return 1;
            }

            var clipCount = controller.CatalogSnapshot().Count;
            Console.WriteLine($"SMOKE_OK {{\"port\":{port},\"clipsAtReady\":{clipCount}}}");

            // Give the monitor's stability window (6s) + polls time to detect clips.
            await Task.Delay(TimeSpan.FromSeconds(cli.SmokeSeconds));

            Console.WriteLine($"SMOKE_CLIPS {{\"clips\":{controller.CatalogSnapshot().Count}}}");

            await controller.DisposeAsync();
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"SMOKE_FAIL {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }
}
