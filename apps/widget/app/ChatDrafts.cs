using System;
using System.Collections.Generic;

namespace WidgetSampleCS
{
    // A draft key restores local text only; commands still require a fresh token.
    sealed class ChatDrafts
    {
        internal sealed class Draft
        {
            public string Text = "", SubmittedText = "", OperationId, Error;
            public bool Pending, Unknown, Settled;
        }
        readonly Dictionary<string,Draft> drafts = new Dictionary<string,Draft>();
        readonly Dictionary<string,string> bindings = new Dictionary<string,string>();
        public void Bind(string owner, string draftKey) {
            if (!string.IsNullOrEmpty(owner) && !string.IsNullOrEmpty(draftKey))
                bindings[owner] = draftKey;
        }
        public Draft For(string owner) {
            if (string.IsNullOrEmpty(owner)) return new Draft();
            string key = bindings.TryGetValue(owner,out var draftKey) ? "draft:"+draftKey : "token:"+owner;
            if (!drafts.TryGetValue(key,out var draft)) drafts[key] = draft = new Draft();
            return draft;
        }
        public bool SharesDraft(string left, string right) => !string.IsNullOrEmpty(left) && !string.IsNullOrEmpty(right) && ReferenceEquals(For(left), For(right));
        internal static string Outcome(bool dispatched, bool? acknowledged, string status, string error) {
            if (!dispatched) return "failedBeforeCommit";
            if (status == "pending" || status == "committed" || status == "failedBeforeCommit" || status == "unknown") return status;
            if (acknowledged == false && (error == "busy" || error == "stale" || error == "locked" || error == "consent" || error == "consent_required" || error == "disconnected")) return "failedBeforeCommit";
            return "unknown";
        }
        public void Begin(string owner,string text,string operationId) {
            var draft=For(owner); draft.Text=text;draft.SubmittedText=text;draft.OperationId=operationId;draft.Pending=true;draft.Unknown=false;draft.Settled=false;draft.Error=null;
        }
        public bool Complete(string owner,string text,string operationId,string status) {
            var draft=For(owner);
            if (draft.OperationId!=operationId || draft.Settled) return false;
            if(status=="pending"){draft.Pending=true;draft.Unknown=false;draft.Error=null;return true;}
            draft.Pending=false;draft.Unknown=status=="unknown";
            if(status=="committed"&&draft.Text==text) draft.Text="";
            if(status=="committed")draft.SubmittedText="";
            draft.Settled=status=="committed"||status=="failedBeforeCommit";
            draft.Error=status=="unknown"?"Delivery is unconfirmed. Check Doorlight before sending again.":status=="failedBeforeCommit"?"Couldn’t send. Your message is ready to retry.":null;
            return true;
        }
        public bool Reconcile(string owner,string text,string operationId,string status,string visibleText) {
            var draft=For(owner);
            if(draft.OperationId!=operationId){
                // A coalesced terminal receipt may be the first observed frame.
                // Never let an older receipt replace a different active operation.
                if(draft.Pending||draft.Unknown)return false;
                draft.OperationId=operationId;
                draft.Settled=false;
                draft.SubmittedText=text;
                draft.Text=string.IsNullOrEmpty(visibleText)&&status!="committed"?text:visibleText;
            }else if(!draft.Pending&&!draft.Unknown){draft.Text=visibleText;if(draft.Settled)return false;}
            return Complete(owner,text,operationId,status);
        }
        public bool ReconcileReceipt(string owner,string operationId,string status,string visibleText) {
            var draft=For(owner);
            if(string.IsNullOrEmpty(operationId)||draft.OperationId!=operationId)return false;
            return Reconcile(owner,draft.SubmittedText,operationId,status,visibleText);
        }
        public void Interrupt() { foreach(var draft in drafts.Values)if(draft.Pending){draft.Pending=false;draft.Unknown=true;draft.Error="Delivery is unconfirmed. Check Doorlight before sending again.";} }
    }
}
