using System.Buffers.Binary;

namespace ShadowPlay.Core.Clips;

/// <summary>Reads the duration from an MP4 movie header without decoding the recording.</summary>
public static class Mp4DurationReader
{
    public static TimeSpan? TryRead(string fullPath)
    {
        try
        {
            using var stream = new FileStream(fullPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            return TryRead(stream);
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
        catch (OverflowException)
        {
            return null;
        }
    }

    private static TimeSpan? TryRead(Stream stream)
    {
        if (!TryFindMovieHeader(stream, stream.Length, out var headerStart, out var headerSize))
        {
            return null;
        }

        if (headerSize < 20 || headerStart > stream.Length - headerSize)
        {
            return null;
        }

        stream.Position = headerStart;
        var version = stream.ReadByte();
        if (version < 0)
        {
            return null;
        }

        stream.Position += 3; // flags
        if (version == 0)
        {
            if (!TryReadUInt32(stream, out _) || !TryReadUInt32(stream, out _)
                || !TryReadUInt32(stream, out var timescale)
                || !TryReadUInt32(stream, out var duration)
                || timescale == 0)
            {
                return null;
            }

            return TimeSpan.FromSeconds((double)duration / timescale);
        }

        if (version != 1
            || !TryReadUInt64(stream, out _)
            || !TryReadUInt64(stream, out _)
            || !TryReadUInt32(stream, out var versionOneTimescale)
            || !TryReadUInt64(stream, out var versionOneDuration)
            || versionOneTimescale == 0)
        {
            return null;
        }

        return TimeSpan.FromSeconds((double)versionOneDuration / versionOneTimescale);
    }

    private static bool TryFindMovieHeader(Stream stream, long end, out long headerStart, out long headerSize)
    {
        stream.Position = 0;
        while (TryReadBox(stream, end, out var type, out var dataStart, out var dataSize))
        {
            if (type == "moov" && TryFindChild(stream, dataStart, dataSize, "mvhd", out headerStart, out headerSize))
            {
                return true;
            }

            stream.Position = dataStart + dataSize;
        }

        headerStart = 0;
        headerSize = 0;
        return false;
    }

    private static bool TryFindChild(Stream stream, long start, long size, string wantedType, out long childStart, out long childSize)
    {
        var end = start + size;
        stream.Position = start;
        while (TryReadBox(stream, end, out var type, out var dataStart, out var dataSize))
        {
            if (type == wantedType)
            {
                childStart = dataStart;
                childSize = dataSize;
                return true;
            }

            stream.Position = dataStart + dataSize;
        }

        childStart = 0;
        childSize = 0;
        return false;
    }

    private static bool TryReadBox(Stream stream, long end, out string type, out long dataStart, out long dataSize)
    {
        type = string.Empty;
        dataStart = 0;
        dataSize = 0;

        if (stream.Position < 0 || stream.Position > end - 8)
        {
            return false;
        }

        var boxStart = stream.Position;
        Span<byte> header = stackalloc byte[8];
        if (stream.Read(header) != header.Length)
        {
            return false;
        }

        var boxSize = BinaryPrimitives.ReadUInt32BigEndian(header[..4]);
        type = System.Text.Encoding.ASCII.GetString(header[4..]);
        dataStart = stream.Position;

        long totalSize;
        var headerSize = 8;
        if (boxSize == 1)
        {
            Span<byte> extendedSize = stackalloc byte[8];
            if (stream.Position > end - 8 || stream.Read(extendedSize) != extendedSize.Length)
            {
                return false;
            }

            totalSize = checked((long)BinaryPrimitives.ReadUInt64BigEndian(extendedSize));
            dataStart = stream.Position;
            headerSize = 16;
        }
        else if (boxSize == 0)
        {
            totalSize = end - (dataStart - 8);
        }
        else
        {
            totalSize = boxSize;
        }

        if (totalSize < headerSize)
        {
            return false;
        }

        var boxEnd = boxStart + totalSize;
        if (boxEnd > end || boxEnd < dataStart)
        {
            return false;
        }

        dataSize = boxEnd - dataStart;
        return true;
    }

    private static bool TryReadUInt32(Stream stream, out uint value)
    {
        Span<byte> buffer = stackalloc byte[4];
        if (stream.Read(buffer) != buffer.Length)
        {
            value = 0;
            return false;
        }

        value = BinaryPrimitives.ReadUInt32BigEndian(buffer);
        return true;
    }

    private static bool TryReadUInt64(Stream stream, out ulong value)
    {
        Span<byte> buffer = stackalloc byte[8];
        if (stream.Read(buffer) != buffer.Length)
        {
            value = 0;
            return false;
        }

        value = BinaryPrimitives.ReadUInt64BigEndian(buffer);
        return true;
    }
}
