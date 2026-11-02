using System.Text.Json.Serialization;

namespace Doorlight.Setup;

[JsonSerializable(typeof(PackageManifest))]
[JsonSerializable(typeof(BundleInstall.Journal))]
[JsonSerializable(typeof(string[]))]
internal partial class CoreJsonContext : JsonSerializerContext;
