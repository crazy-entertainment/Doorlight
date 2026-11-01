using System;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace WidgetSampleCS
{
    static class WeatherResponse
    {
        internal const int MaxBytes = 262144, MaxDepth = 12, MaxString = 4096, MaxResults = 100, MaxPostcodes = 32;
        internal static readonly TimeSpan Deadline = TimeSpan.FromSeconds(12);

        internal static async Task<string> FetchAsync(HttpClient client, Uri uri, CancellationToken cancellation)
        {
            if (uri.Scheme != "https" || uri.UserInfo.Length != 0 || uri.Fragment.Length != 0 ||
                (uri.Host != "api.open-meteo.com" && uri.Host != "geocoding-api.open-meteo.com"))
                throw new InvalidDataException("Invalid weather destination");
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation)) {
                deadline.CancelAfter(Deadline);
                using (var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, deadline.Token)) {
                    response.EnsureSuccessStatusCode();
                    var length = response.Content.Headers.ContentLength;
                    if (length.HasValue && length.Value > MaxBytes) throw new InvalidDataException("Weather response too large");
                    using (deadline.Token.Register(() => response.Dispose()))
                    using (var input = await response.Content.ReadAsStreamAsync())
                    using (var output = new MemoryStream()) {
                        var buffer = new byte[4096];
                        int count;
                        while ((count = await input.ReadAsync(buffer, 0, Math.Min(buffer.Length, MaxBytes + 1 - (int)output.Length), deadline.Token)) != 0) {
                            if (output.Length + count > MaxBytes) throw new InvalidDataException("Weather response too large");
                            output.Write(buffer, 0, count);
                        }
                        deadline.Token.ThrowIfCancellationRequested();
                        return Validate(new UTF8Encoding(false, true).GetString(output.ToArray()));
                    }
                }
            }
        }

        // Bound nesting and every string before the platform JSON parser allocates its object graph.
        internal static string Validate(string json)
        {
            if (json == null || Encoding.UTF8.GetByteCount(json) > MaxBytes) throw new InvalidDataException("Weather response too large");
            int depth = 0, text = 0;
            bool quoted = false, escaped = false;
            foreach (char c in json) {
                if (quoted) {
                    if (!escaped && c == '"') { quoted = false; continue; }
                    if (++text > MaxString) throw new InvalidDataException("Weather string too long");
                    if (escaped) escaped = false;
                    else if (c == '\\') escaped = true;
                } else if (c == '"') { quoted = true; text = 0; }
                else if (c == '{' || c == '[') { if (++depth > MaxDepth) throw new InvalidDataException("Weather JSON too deep"); }
                else if (c == '}' || c == ']') { if (--depth < 0) throw new InvalidDataException("Invalid weather JSON"); }
            }
            if (quoted || depth != 0) throw new InvalidDataException("Incomplete weather JSON");
            return json;
        }
    }
}
