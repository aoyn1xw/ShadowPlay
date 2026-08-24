using System.IO;
using System.Windows;
using System.Windows.Media.Imaging;
using QRCoder;
using MessageBox = System.Windows.MessageBox;
using MessageBoxButton = System.Windows.MessageBoxButton;
using MessageBoxImage = System.Windows.MessageBoxImage;

namespace ShadowPlay.Windows.Services;

/// <summary>Renders pairing payloads into QR images for the desktop UI.</summary>
public static class QrCodeService
{
    public static BitmapSource? CreatePng(string payload, int pixelsPerModule = 8)
    {
        if (string.IsNullOrWhiteSpace(payload))
        {
            return null;
        }

        try
        {
            using var generator = new QRCodeGenerator();
            using var data = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.Q);
            var qr = new PngByteQRCode(data);
            var pngBytes = qr.GetGraphic(pixelsPerModule);

            var image = new BitmapImage();
            using var stream = new MemoryStream(pngBytes);
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = stream;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException)
        {
            MessageBox.Show($"Could not render the pairing QR code: {ex.Message}", "ShadowPlay",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return null;
        }
    }
}
