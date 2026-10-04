<#
.SYNOPSIS
    Builds RaceMenu Overlay Depth Fix from your own RaceMenu.bsa.
.DESCRIPTION
    Reads RaceMenu's body, hands and feet overlay templates from RaceMenu.bsa and clears two shader
    flags on them: SLSF1 Cast_Shadows and SLSF2 ZBuffer_Write. Writes them as loose files under
    -Output (meshes\actors\character\character assets\*_overlay.nif): zip that folder and install it
    with your mod manager, or copy it into Data.
.PARAMETER Bsa
    RaceMenu.bsa. Default: the one in the game's Data folder (found through the registry).
.PARAMETER Output
    Folder to write the meshes into. Default: out\ next to this script.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File patch.ps1 -Bsa "D:\MO2\mods\RaceMenu\RaceMenu.bsa"
#>
param(
    [string]$Bsa,
    [string]$Output = (Join-Path $PSScriptRoot 'out')
)
$ErrorActionPreference = 'Stop'

if (-not $Bsa) {
    $key = 'HKLM:\SOFTWARE\WOW6432Node\Bethesda Softworks\Skyrim Special Edition'
    $game = (Get-ItemProperty $key -ErrorAction SilentlyContinue).'installed path'
    if ($game) { $Bsa = Join-Path $game 'Data\RaceMenu.bsa' }
    if (-not $Bsa -or -not (Test-Path $Bsa)) { throw 'RaceMenu.bsa not found in the game''s Data folder: pass -Bsa <path to RaceMenu.bsa>.' }
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class OverlayDepthFix
{
    // Shader flags 1 and 2 of RaceMenu's overlay templates (BSLightingShaderProperty, stored next to
    // each other) and the same flags without SLSF1 Cast_Shadows (0x200) and SLSF2 ZBuffer_Write (0x1).
    static readonly byte[] Original = Pack(0x82601303, 0x02008081);
    static readonly byte[] Fixed = Pack(0x82601103, 0x02008080);

    static byte[] Pack(uint a, uint b)
    {
        byte[] r = new byte[8];
        BitConverter.GetBytes(a).CopyTo(r, 0);
        BitConverter.GetBytes(b).CopyTo(r, 4);
        return r;
    }

    // Clears the two flags. Throws unless the original flags occur exactly once.
    public static byte[] Patch(byte[] nif)
    {
        int at = -1, count = 0;
        for (int i = 0; i + 8 <= nif.Length; i++) {
            int k = 0;
            while (k < 8 && nif[i + k] == Original[k]) k++;
            if (k == 8) { at = i; count++; }
        }
        if (count != 1) throw new InvalidDataException("expected the overlay shader flags once, found them " + count + " times");
        byte[] r = (byte[])nif.Clone();
        Fixed.CopyTo(r, at);
        return r;
    }

    // Reads the named files ("folder\file", lower case) from a Skyrim SE (version 105) BSA.
    public static Dictionary<string, byte[]> ReadBsa(string path, string[] wanted)
    {
        byte[] d = File.ReadAllBytes(path);
        if (Encoding.ASCII.GetString(d, 0, 3) != "BSA" || BitConverter.ToUInt32(d, 4) != 105)
            throw new InvalidDataException(path + " is not a Skyrim SE BSA");
        uint offset = BitConverter.ToUInt32(d, 8), flags = BitConverter.ToUInt32(d, 12);
        int folders = (int)BitConverter.ToUInt32(d, 16);
        bool compressedDefault = (flags & 0x4) != 0, embedNames = (flags & 0x100) != 0;
        if ((flags & 0x3) != 0x3) throw new InvalidDataException("BSA without folder/file names");

        int[] counts = new int[folders];
        int p = (int)offset;
        for (int i = 0; i < folders; i++, p += 24) counts[i] = (int)BitConverter.ToUInt32(d, p + 8);

        var records = new List<KeyValuePair<string, long>>();   // folder, (size << 32 | offset)
        for (int i = 0; i < folders; i++) {
            int n = d[p];
            string folder = Encoding.GetEncoding(1252).GetString(d, p + 1, n - 1);
            p += 1 + n;
            for (int j = 0; j < counts[i]; j++, p += 16) {
                long size = BitConverter.ToUInt32(d, p + 8), off = BitConverter.ToUInt32(d, p + 12);
                records.Add(new KeyValuePair<string, long>(folder, (size << 32) | off));
            }
        }

        var want = new HashSet<string>(wanted, StringComparer.OrdinalIgnoreCase);
        var result = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
        foreach (var rec in records) {
            int end = Array.IndexOf(d, (byte)0, p);
            string name = rec.Key + "\\" + Encoding.GetEncoding(1252).GetString(d, p, end - p);
            p = end + 1;
            if (!want.Contains(name)) continue;

            uint size = (uint)(rec.Value >> 32);
            int off = (int)(rec.Value & 0xFFFFFFFF);
            bool compressed = compressedDefault != ((size & 0x40000000) != 0);
            int len = (int)(size & 0x3FFFFFFF);
            if (embedNames) { int skip = 1 + d[off]; off += skip; len -= skip; }
            byte[] blob;
            if (compressed) {
                blob = Lz4Frame(d, off + 4, off + len);   // 4 bytes: uncompressed size
            } else {
                blob = new byte[len];
                Array.Copy(d, off, blob, 0, len);
            }
            result[name] = blob;
        }
        return result;
    }

    // Minimal LZ4 frame decoder (no checksum validation): enough for BSA file data.
    static byte[] Lz4Frame(byte[] s, int p, int limit)
    {
        if (BitConverter.ToUInt32(s, p) != 0x184D2204) throw new InvalidDataException("not an LZ4 frame");
        byte flg = s[p + 4];
        p += 6 + ((flg & 0x08) != 0 ? 8 : 0) + 1;
        var o = new List<byte>();
        while (p < limit) {
            uint bsize = BitConverter.ToUInt32(s, p);
            p += 4;
            if (bsize == 0) break;
            bool raw = (bsize & 0x80000000) != 0;
            int n = (int)(bsize & 0x7FFFFFFF), end = p + n;
            if (raw) {
                for (int i = p; i < end; i++) o.Add(s[i]);
            } else {
                int i = p;
                while (i < end) {
                    int token = s[i++], lit = token >> 4;
                    if (lit == 15) { int b; do { b = s[i++]; lit += b; } while (b == 255); }
                    for (int k = 0; k < lit; k++) o.Add(s[i++]);
                    if (i >= end) break;
                    int back = s[i] | (s[i + 1] << 8);
                    i += 2;
                    int mlen = token & 15;
                    if (mlen == 15) { int b; do { b = s[i++]; mlen += b; } while (b == 255); }
                    mlen += 4;
                    int start = o.Count - back;
                    for (int k = 0; k < mlen; k++) o.Add(o[start + k]);
                }
            }
            p = end + ((flg & 0x10) != 0 ? 4 : 0);
        }
        return o.ToArray();
    }
}
'@

$folder = 'meshes\actors\character\character assets'
$names = 'body_overlay.nif', 'hands_overlay.nif', 'feet_overlay.nif'
$files = [OverlayDepthFix]::ReadBsa((Resolve-Path $Bsa).Path, [string[]]($names | ForEach-Object { "$folder\$_" }))
$dest = Join-Path $Output $folder
New-Item -ItemType Directory -Force $dest | Out-Null
foreach ($n in $names) {
    $nif = $files["$folder\$n"]
    if (-not $nif) { throw "$folder\$n is not in $Bsa" }
    [IO.File]::WriteAllBytes((Join-Path $dest $n), [OverlayDepthFix]::Patch($nif))
    Write-Host "Patched $folder\$n"
}
Write-Host "Done: $Output"
