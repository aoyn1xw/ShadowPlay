using System.Buffers.Binary;
using ShadowPlay.Core.Clips;
using Xunit;

namespace ShadowPlay.Tests;

public sealed class Mp4DurationReaderTests : IDisposable
{
    private readonly TempFolder _folder = new();

    [Fact]
    public void Reads_version_zero_movie_header_duration()
    {
        var path = _folder.CreateMp4("duration.mp4", sizeBytes: 8);
        var mvhd = Box("mvhd", [
            0, 0, 0, 0, // version + flags
            0, 0, 0, 0, // creation
            0, 0, 0, 0, // modification
            0, 0, 3, 232, // timescale 1000
            0, 0, 9, 196, // duration 2500 ms
        ]);
        var bytes = Box("ftyp", new byte[4])
            .Concat(Box("moov", mvhd))
            .ToArray();
        File.WriteAllBytes(path, bytes);

        var duration = Mp4DurationReader.TryRead(path);

        Assert.Equal(TimeSpan.FromSeconds(2.5), duration);
    }

    public void Dispose() => _folder.Dispose();

    private static byte[] Box(string type, byte[] payload)
    {
        var bytes = new byte[8 + payload.Length];
        BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(0, 4), (uint)bytes.Length);
        System.Text.Encoding.ASCII.GetBytes(type, bytes.AsSpan(4, 4));
        payload.CopyTo(bytes, 8);
        return bytes;
    }
}
