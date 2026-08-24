using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Color = System.Windows.Media.Color;
using Point = System.Windows.Point;
using Brushes = System.Windows.Media.Brushes;

namespace ShadowPlay.Windows.Services;

/// <summary>
/// Generates the tray/window icon at runtime so the repository stays text-only.
/// Simple rounded square with a play glyph.
/// </summary>
public static class RuntimeIcon
{
    public static ImageSource CreateIconSource(int size = 32)
    {
        const double dpi = 96;

        var visual = new DrawingVisual();
        using (var context = visual.RenderOpen())
        {
            var background = new RectangleGeometry(new Rect(0, 0, size, size), size * 0.25, size * 0.25);
            context.DrawGeometry(
                new LinearGradientBrush
                {
                    StartPoint = new Point(0, 0),
                    EndPoint = new Point(0, 1),
                    GradientStops =
                    [
                        new GradientStop(Color.FromRgb(0x7C, 0x4D, 0xFF), 0),
                        new GradientStop(Color.FromRgb(0x45, 0x27, 0xA0), 1),
                    ],
                },
                null,
                background);

            var triangle = new StreamGeometry();
            using (var geo = triangle.Open())
            {
                var left = size * 0.34;
                var top = size * 0.26;
                var right = size * 0.74;
                var bottom = size * 0.74;
                geo.BeginFigure(new Point(left, top), true, true);
                geo.LineTo(new Point(right, size / 2d), true, false);
                geo.LineTo(new Point(left, bottom), true, false);
            }

            triangle.Freeze();
            context.DrawGeometry(Brushes.White, null, triangle);
        }

        var bitmap = new RenderTargetBitmap(size, size, dpi, dpi, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        bitmap.Freeze();
        return bitmap;
    }
}
