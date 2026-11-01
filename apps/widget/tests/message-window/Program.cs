using System;
using System.Linq;
using WidgetSampleCS;
static class Program {
    sealed record Row(string Id,string Text,string Status="sent");
    static DateTime At(int seconds)=>new DateTime(2026,1,1,0,0,0,DateTimeKind.Utc).AddSeconds(seconds);
    static MessageWindow<Row> Window(int count=6)=>new(count,row=>row.Id,row=>row.Text+"/"+row.Status);
    static void Check(bool pass,string description){if(!pass)throw new Exception(description);}
    static void Main(){
        var view=Window();var a=new Row("a","original");var b=new Row("b","second");
        view.Project(new[]{a,b},At(0),30,60);
        var edited=a with {Text="edited"};var rows=view.Project(new[]{edited,b},At(1),30,60);
        Check(rows.Single(row=>row.Id=="a").Text=="edited","Visible edit must replace same-ID canonical text immediately");
        var delivered=edited with {Status="delivered"};rows=view.Project(new[]{delivered,b},At(2),30,60);
        Check(rows.Single(row=>row.Id=="a").Status=="delivered","Visible delivery status must update without waiting for fade");
        rows=view.Project(new[]{b},At(3),30,60);Check(rows.Count==1&&rows[0].Id=="b","Deletion must override minimum visibility immediately");
        rows=view.Project(new[]{b with {Text=""}},At(4),30,60);Check(rows[0].Text=="","Privacy redaction must replace retained text immediately");
        rows=view.Project(Array.Empty<Row>(),At(5),30,60);Check(rows.Count==0,"Empty canonical timeline must erase all retained content");
        view=Window(1);view.Project(new[]{a},At(0),10,0);view.Project(new[]{a,b},At(1),10,0);
        view.Project(new[]{a,b with {Text="edited while queued"}},At(2),10,0);
        rows=view.Project(new[]{a,b with {Text="edited while queued"}},At(11),10,0);Check(rows[0].Text=="edited while queued","Queued IDs must resolve the latest canonical row at display time");
        view=Window(1);view.Project(new[]{a},At(0),10,0);view.Project(new[]{a,b},At(1),10,0);view.Project(new[]{a},At(2),10,0);
        rows=view.Project(new[]{a},At(11),10,0);Check(rows.Count==1&&rows[0].Id=="a","Deleted queued message must never appear after minimum delay");
        view=Window(1);view.Project(new[]{a},At(0),0,5);view.Project(new[]{a},At(4),0,5);
        rows=view.Project(new[]{a},At(6),0,5);Check(rows.Count==0,"Unchanged authoritative content must preserve its original fade timestamp");
        view=Window(1);view.Project(new[]{a},At(0),10,0);view.Project(new[]{edited,b},At(5),10,0);
        rows=view.Project(new[]{edited,b},At(11),10,0);Check(rows[0].Id=="a","Changed visible content starts its own presentation interval");
        rows=view.Project(new[]{edited,b},At(16),10,0);Check(rows[0].Id=="b","New interval must eventually release the next canonical message");
        view.Reset();rows=view.Project(new[]{new Row("new-peer","private")},At(17),10,0);Check(rows.Count==1&&rows[0].Id=="new-peer","Conversation reset must discard previous message IDs and timing");
        Console.WriteLine("11 actual MessageWindow edit/delete/privacy/queue/timing checks passed");
    }
}
