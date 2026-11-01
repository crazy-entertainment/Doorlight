using System;
using WidgetSampleCS;
static class Program {
    static void Check(bool pass,string description){if(!pass)throw new Exception(description);}
    static void Main(){
        var drafts=new ChatDrafts();
        drafts.Begin("peer-a","private a","op-a");drafts.For("peer-b").Text="private b";
        drafts.Complete("peer-a","private a","op-a","committed");
        Check(drafts.For("peer-a").Text==""&&drafts.For("peer-b").Text=="private b","A completion must not clear B draft");
        drafts.Begin("peer-a","uncertain a","op-a2");drafts.Complete("peer-a","uncertain a","wrong-id","committed");
        Check(drafts.For("peer-a").Pending,"Wrong receipt must not finish operation");
        drafts.Complete("peer-a","uncertain a","op-a2","unknown");
        Check(drafts.For("peer-a").Unknown&&drafts.For("peer-a").Text=="uncertain a","Unknown must retain scoped text and block retry");
        drafts.Begin("peer-b","private b","op-b");drafts.Interrupt();
        Check(drafts.For("peer-b").Unknown&&!drafts.For("peer-b").Pending&&drafts.For("peer-b").Text=="private b","Disconnect must preserve pending draft as unknown");
        drafts.Complete("peer-b","private b","op-b","failedBeforeCommit");
        Check(!drafts.For("peer-b").Unknown&&drafts.For("peer-b").Text=="private b","Definite refusal retains editable original draft");
        Check(drafts.For("new-owner").Text=="","New conversation must never inherit another draft");
        drafts.For("coalesced").Text="quick draft";
        Check(drafts.Reconcile("coalesced","quick draft","quick-1","committed","quick draft")&&drafts.For("coalesced").Text=="","Committed receipt without pending must clear its exact quick draft");
        Check(drafts.Reconcile("coalesced","old quick text","quick-2","committed","newer typed text")&&drafts.For("coalesced").Text=="newer typed text","Terminal receipt must retain newer typed text");
        Check(drafts.For("peer-b").Text=="private b","Coalesced receipt must remain scoped to its original owner");
        drafts.Begin("coalesced","new active operation","active-new");
        Check(!drafts.Reconcile("coalesced","old quick text","quick-old","committed","new active operation")&&drafts.For("coalesced").Pending,"Old terminal receipt must not replace a newer pending operation");
        Check(ChatDrafts.Outcome(false,null,"","")=="failedBeforeCommit","A local admission refusal is known not to have dispatched");
        Check(ChatDrafts.Outcome(true,null,"","")=="unknown","A dispatched transport timeout must remain unknown");
        Check(ChatDrafts.Outcome(true,false,"","unavailable")=="unknown"&&ChatDrafts.Outcome(true,false,"","unknown")=="unknown","Ambiguous server errors must never permit retry");
        Check(ChatDrafts.Outcome(true,false,"","busy")=="failedBeforeCommit","A pre-admission busy result must remain safely retryable");
        Check(ChatDrafts.Outcome(true,true,"pending","")=="pending"&&ChatDrafts.Outcome(true,true,"","")=="unknown","Pending and malformed positive receipts must not become a terminal success");
        drafts.Bind("connection-old","same-account-conversation");
        drafts.Begin("connection-old","retained unknown","surviving-operation");
        drafts.Complete("connection-old","retained unknown","surviving-operation","pending");
        Check(drafts.For("connection-old").Pending,"A prompt pending receipt must keep its draft pending");
        drafts.Interrupt();drafts.Bind("connection-new","same-account-conversation");
        Check(drafts.SharesDraft("connection-old","connection-new")&&drafts.For("connection-new").Text=="retained unknown"&&drafts.For("connection-new").Unknown,"A fresh token may recover only the same scoped draft key");
        drafts.Bind("other-account","different-account-conversation");
        Check(!drafts.SharesDraft("connection-old","other-account")&&drafts.For("other-account").Text=="","An account replacement must not recover another account's text");
        Check(!drafts.ReconcileReceipt("connection-new","wrong-operation","committed","retained unknown")&&drafts.For("connection-new").Unknown,"A receipt for another operation cannot clear retained unknown text");
        Check(drafts.ReconcileReceipt("connection-new","surviving-operation","committed","retained unknown")&&drafts.For("connection-new").Text==""&&!drafts.For("connection-new").Unknown,"A matching authoritative terminal receipt settles a recovered draft");
        drafts.Begin("connection-new","original text","later-operation");
        drafts.Complete("connection-new","original text","later-operation","failedBeforeCommit");
        Check(!drafts.ReconcileReceipt("connection-new","later-operation","committed","new typed text")&&drafts.For("connection-new").Text=="new typed text","A settled operation cannot rewrite newer typed text");
        Check(!drafts.ReconcileReceipt("other-account","surviving-operation","unknown","")&&drafts.For("other-account").Text=="","A snapshot receipt never adopts an operation without its own draft");
        drafts.Begin("connection-new","yes","repeat-safe");drafts.Complete("connection-new","yes","repeat-safe","committed");
        Check(!drafts.Reconcile("connection-new","yes","repeat-safe","committed","yes")&&drafts.For("connection-new").Text=="yes","Repeated committed receipts cannot erase identical newly typed text");
        Check(!drafts.Complete("connection-old","yes","repeat-safe","pending")&&!drafts.For("connection-new").Pending,"A delayed pending response cannot reopen an already settled operation");
        Check(!drafts.ReconcileReceipt("fast-receipt","fast-operation","committed","fast text"),"A terminal snapshot before local Begin cannot invent its draft");
        drafts.Begin("fast-receipt","fast text","fast-operation");
        Check(drafts.ReconcileReceipt("fast-receipt","fast-operation","committed","fast text")&&drafts.For("fast-receipt").Text==""&&!drafts.For("fast-receipt").Pending,"The same terminal snapshot must settle after the local draft is bound");
        Console.WriteLine("26 scoped draft/receipt/admission/reconnect checks passed");
    }
}
