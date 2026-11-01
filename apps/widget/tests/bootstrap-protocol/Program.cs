using System;
using System.IO;
using System.Text;
using WidgetSampleCS;
static class Program {
    static void Check(bool pass,string message){if(!pass)throw new Exception(message);}
    static void Main(){
        Check(BootstrapProtocol.TryParse("HELLO|1.15.90",out var version)&&version=="1.15.90","A bounded version greeting is allowed");
        foreach(var malformed in new[]{"HELLO","HELLO|","HELLO|1.2","HELLO|1.2.3|INPUT","HELLO| 1.2.3","HELLO|65536.2.3"})Check(!BootstrapProtocol.TryParse(malformed,out _),"Malformed greetings are refused: "+malformed);
        foreach(var line in new[]{"DESKTOP|installed|running|1","DESKTOP|installed|closed|0","DESKTOP|missing|closed|1","DESKTOP|unknown|unknown|0","DESKTOP_ACTION|opened","DESKTOP_ACTION|installed","DESKTOP_ACTION|download_opened","DESKTOP_ACTION|unavailable","DESKTOP_ACTION|failed"})Check(BootstrapProtocol.TryParse(line,out version)&&version==null,"Known installation status is allowed: "+line);
        foreach(var line in new[]{"INPUT|{\"type\":\"sendResult\",\"status\":\"committed\"}","MOUSE|1|2|1","AIM|right|1","AIMRESET","COMPOSE|private","DESKTOP|installed|running|2","DESKTOP|missing|running|1","DESKTOP_ACTION|opened|INPUT","HELLO|1.2.3\nINPUT","DESKTOP_ACTION|opened\0",new string('x',257)})Check(!BootstrapProtocol.TryParse(line,out _),"Bootstrap must not admit overlay input or malformed frames");
        Check(BootstrapProtocol.IsCommand("DESKTOP_STATUS")&&BootstrapProtocol.IsCommand("DESKTOP_OPEN")&&BootstrapProtocol.IsCommand("DESKTOP_INSTALL"),"Only fixed install/open/status commands are supported");
        Check(!BootstrapProtocol.IsCommand("DESKTOP_DELETE")&&!BootstrapProtocol.IsCommand("DESKTOP_OPEN\nCAPTURE|chat.quick")&&!BootstrapProtocol.IsCommand("CAPTURE|chat.quick"),"No arbitrary command reaches the bootstrap writer");
        foreach(var command in new[]{"DESKTOP_STATUS","DESKTOP_OPEN","DESKTOP_INSTALL"})foreach(var newline in new[]{"\n","\r\n"}){
            using var input=new MemoryStream(Encoding.UTF8.GetBytes(command+newline));
            Check(BootstrapInput.ReadCommand(input)==command,"Legitimate ASCII command and line ending remain supported");
            Check(BootstrapInput.ReadCommand(input)==null,"Clean EOF is allowed");
        }
        foreach(var frame in new[]{new string('X',257),"DESKTOP_OPEN|extra\n","DESKTOP_OPEN\0\n","DESKTOP\r_OPEN\n","DESKTOP_OPEN", "DESKTOP_ÖPEN\n","\n"}){
            using var input=new MemoryStream(Encoding.UTF8.GetBytes(frame));bool rejected=false;
            try{BootstrapInput.ReadCommand(input);}catch(InvalidDataException){rejected=true;}
            Check(rejected,"Reject malformed/oversized bootstrap input before dispatch");
            Check(input.Position<=BootstrapInput.MaxLine+1,"Reject without consuming an unbounded line");
        }
        using(var input=new MemoryStream(new byte[]{0xff,10})){
            bool rejected=false;try{BootstrapInput.ReadCommand(input);}catch(InvalidDataException){rejected=true;}Check(rejected,"Reject invalid UTF-8 rather than replacing bytes");
        }
        using(var input=new MemoryStream(Encoding.ASCII.GetBytes("DESKTOP_STATUS\nDESKTOP_OPEN\n"))){
            Check(BootstrapInput.ReadCommand(input)=="DESKTOP_STATUS"&&BootstrapInput.ReadCommand(input)=="DESKTOP_OPEN","Separate bounded commands retain framing");
        }
        int dispatched=0;
        foreach(var frame in new[]{new string('X',257),"DESKTOP_OPEN|extra\n","DESKTOP_OPEN","\0\n"}){
            using(var rejected=new MemoryStream(Encoding.ASCII.GetBytes(frame)))
                BootstrapInput.ReadCommands(rejected,_=>throw new Exception("Malformed frame dispatched"));
            using(var nextConnection=new MemoryStream(Encoding.ASCII.GetBytes("DESKTOP_STATUS\n")))
                BootstrapInput.ReadCommands(nextConnection,command=>{Check(command=="DESKTOP_STATUS","Next connection stays usable");dispatched++;});
        }
        Check(dispatched==4,"Malformed connections return to the accept loop without terminating the broker");
        Console.WriteLine("Bootstrap protocol and bounded production-reader checks passed");
    }
}
