using System.Reflection.PortableExecutable;

namespace Doorlight.Setup;

public static class WindowsExecutable
{
    // Hashes bind bytes to the release; reject malformed or wrong-platform entry
    // points separately, before asking the running app to shut down.
    public static void Validate(string path)
    {
        PackageStage.RejectLinkedAncestors(path);
        using var input = File.OpenRead(path);
        try
        {
            using var image = new PEReader(input);
            var headers = image.PEHeaders;
            if (headers.PEHeader?.Magic != PEMagic.PE32Plus ||
                headers.CoffHeader.Machine != Machine.Amd64 ||
                (headers.CoffHeader.Characteristics & Characteristics.ExecutableImage) == 0 ||
                (headers.CoffHeader.Characteristics & Characteristics.Dll) != 0)
                throw new InvalidDataException("The package does not contain a Windows x64 application.");
        }
        catch (BadImageFormatException exception)
        {
            throw new InvalidDataException("The Windows application is malformed.", exception);
        }
    }
}
