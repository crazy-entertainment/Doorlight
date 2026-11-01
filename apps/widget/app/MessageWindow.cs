using System;
using System.Collections.Generic;
using System.Linq;

namespace WidgetSampleCS
{
    // Presentation timing never preserves content that the canonical timeline
    // removed or changed. Queues retain IDs, and resolve fresh rows each frame.
    sealed class MessageWindow<T>
    {
        sealed class Entry { public string Id, Content; public DateTime Shown; }
        readonly Func<T,string> identify, fingerprint;
        readonly int limit;
        readonly HashSet<string> seen = new HashSet<string>();
        readonly Queue<string> waiting = new Queue<string>();
        readonly List<Entry> shown = new List<Entry>();
        bool initialized;
        public MessageWindow(int limit,Func<T,string> identify,Func<T,string> fingerprint) {
            if(limit<1)throw new ArgumentOutOfRangeException(nameof(limit));
            this.limit=limit;this.identify=identify;this.fingerprint=fingerprint;
        }
        public void Reset(){seen.Clear();waiting.Clear();shown.Clear();initialized=false;}
        public IReadOnlyList<T> Project(IEnumerable<T> source,DateTime now,double minimumSeconds,double fadeSeconds) {
            var rows=source.ToArray();
            var current=new Dictionary<string,T>();
            foreach(var row in rows)current[identify(row)]=row;
            seen.IntersectWith(current.Keys);
            shown.RemoveAll(entry=>!current.ContainsKey(entry.Id));
            var retained=waiting.Where(current.ContainsKey).ToArray();waiting.Clear();foreach(var id in retained)waiting.Enqueue(id);
            foreach(var entry in shown){
                string content=fingerprint(current[entry.Id]);
                if(content!=entry.Content){entry.Content=content;entry.Shown=now;}
            }
            if(!initialized){
                initialized=true;seen.UnionWith(current.Keys);
                foreach(var row in rows.Reverse().Take(limit).Reverse())waiting.Enqueue(identify(row));
            }else foreach(var row in rows){string id=identify(row);if(seen.Add(id))waiting.Enqueue(id);}
            double minimum=Math.Max(0,minimumSeconds);
            if(fadeSeconds>0)shown.RemoveAll(entry=>(now-entry.Shown).TotalSeconds>=Math.Max(minimum,fadeSeconds));
            while(waiting.Count>0&&(shown.Count<limit||(now-shown[0].Shown).TotalSeconds>=minimum)){
                if(shown.Count==limit)shown.RemoveAt(0);
                string id=waiting.Dequeue();shown.Add(new Entry{Id=id,Content=fingerprint(current[id]),Shown=now});
            }
            return shown.Select(entry=>current[entry.Id]).ToArray();
        }
    }
}
