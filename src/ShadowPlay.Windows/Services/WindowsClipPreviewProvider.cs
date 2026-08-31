using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using ShadowPlay.Core.Clips;
using ShadowPlay.Core.Models;

namespace ShadowPlay.Windows.Services;

/// <summary>
/// Reads MP4 duration without decoding and asks the Windows shell thumbnail
/// provider for a preview. PNGs are cached by clip identity and file version.
/// </summary>
public sealed class WindowsClipPreviewProvider : IClipPreviewProvider
{
    private const int ThumbnailOnly = 0x00000008;
    private const int BiggerSizeOk = 0x00000001;
    private static readonly Guid ShellItemImageFactoryId = new("BCC18B79-BA16-442F-80C4-8A59C30C463B");

    private readonly string _cacheDirectory;
    private readonly object _cacheSync = new();

    public WindowsClipPreviewProvider(string cacheDirectory)
    {
        _cacheDirectory = cacheDirectory ?? throw new ArgumentNullException(nameof(cacheDirectory));
    }

    public bool SupportsThumbnails => true;

    public TimeSpan? GetDuration(string fullPath) => Mp4DurationReader.TryRead(fullPath);

    public byte[]? GetThumbnail(ClipEntry entry)
    {
        lock (_cacheSync)
        {
            var cachePath = GetCachePath(entry);
            try
            {
                if (File.Exists(cachePath))
                {
                    var cached = File.ReadAllBytes(cachePath);
                    if (cached.Length > 0)
                    {
                        return cached;
                    }
                }

                var thumbnail = CreateThumbnail(entry.FullPath);
                if (thumbnail is null)
                {
                    return null;
                }

                Directory.CreateDirectory(_cacheDirectory);
                File.WriteAllBytes(cachePath, thumbnail);
                return thumbnail;
            }
            catch (IOException)
            {
                return null;
            }
            catch (UnauthorizedAccessException)
            {
                return null;
            }
        }
    }

    private string GetCachePath(ClipEntry entry) => Path.Combine(
        _cacheDirectory,
        $"{entry.Id}_{entry.SizeBytes}_{entry.LastWriteTimeUtc.UtcTicks}.png");

    private static byte[]? CreateThumbnail(string fullPath)
    {
        if (!File.Exists(fullPath))
        {
            return null;
        }

        IShellItemImageFactory? factory = null;
        IntPtr bitmap = IntPtr.Zero;
        try
        {
            var iid = ShellItemImageFactoryId;
            SHCreateItemFromParsingName(fullPath, IntPtr.Zero, ref iid, out factory);
            var result = factory.GetImage(new ShellSize(640, 360), ThumbnailOnly | BiggerSizeOk, out bitmap);
            if (result != 0 || bitmap == IntPtr.Zero)
            {
                return null;
            }

            var source = Imaging.CreateBitmapSourceFromHBitmap(
                bitmap,
                IntPtr.Zero,
                Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions());
            source.Freeze();

            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(source));
            using var output = new MemoryStream();
            encoder.Save(output);
            return output.ToArray();
        }
        catch (COMException)
        {
            return null;
        }
        catch (FileNotFoundException)
        {
            return null;
        }
        finally
        {
            if (bitmap != IntPtr.Zero)
            {
                DeleteObject(bitmap);
            }

            if (factory is not null)
            {
                Marshal.ReleaseComObject(factory);
            }
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(
        string path,
        IntPtr bindContext,
        ref Guid riid,
        out IShellItemImageFactory imageFactory);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObject(IntPtr objectHandle);

    [ComImport]
    [Guid("BCC18B79-BA16-442F-80C4-8A59C30C463B")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItemImageFactory
    {
        [PreserveSig]
        int GetImage(ShellSize size, int flags, out IntPtr bitmap);
    }

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct ShellSize(int width, int height)
    {
        public readonly int Width = width;
        public readonly int Height = height;
    }
}
