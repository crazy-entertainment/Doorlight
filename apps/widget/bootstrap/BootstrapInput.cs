using System;
using System.IO;
using System.Text;

static class BootstrapInput
{
    internal const int MaxLine = 256;

    internal static void ReadCommands(Stream input, Action<string> dispatch)
    {
        try {
            string command;
            while ((command = ReadCommand(input)) != null) dispatch(command);
        }
        catch (IOException) { }
        catch (InvalidDataException) { }
    }

    // Commands are ASCII literals; bound bytes before decoding or dispatching.
    internal static string ReadCommand(Stream input)
    {
        var bytes = new byte[MaxLine];
        int count = 0;
        while (true) {
            int next = input.ReadByte();
            if (next < 0) {
                if (count == 0) return null;
                throw new InvalidDataException("Incomplete bootstrap command");
            }
            if (next == '\n') {
                int length = count > 0 && bytes[count - 1] == '\r' ? count - 1 : count;
                string command = Encoding.ASCII.GetString(bytes, 0, length);
                if (command != "DESKTOP_STATUS" && command != "DESKTOP_OPEN" && command != "DESKTOP_INSTALL")
                    throw new InvalidDataException("Invalid bootstrap command");
                return command;
            }
            if (count == MaxLine || (next != '\r' && (next < 32 || next > 126)))
                throw new InvalidDataException("Invalid bootstrap frame");
            bytes[count++] = (byte)next;
        }
    }
}
