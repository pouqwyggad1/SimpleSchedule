using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Lib.Net.Http.WebPush.Authentication;
using Microsoft.Extensions.Configuration;
using SimpleSchedule.Pwa;

public static class PushRegression
{
    public static async Task Run(Action<bool,string> expect)
    {
        var now = DateTimeOffset.Parse("2026-10-17T03:40:00Z"); // 11:40 Irkutsk.
        var prefs = JsonNode.Parse("""{"notificationsEnabled":true,"beforeLessonEnabled":true,"scheduleChangesEnabled":true,"groupId":"42","subgroup":"1","leadMinutes":5,"mutedSubjects":[],"mutedDates":[]}""")!.AsObject();
        var lesson = JsonNode.Parse("""{"date":"2026-10-17","startMinute":705,"endMinute":795,"subject":"Математика","kind":"лекция","teacher":"Иванов","room":"Б-100","subgroup":"1","homework":"PRIVATE HOMEWORK","sourceGroupId":"42"}""")!.AsObject();
        lesson["sourceBaseline"] = lesson.DeepClone();
        List<Entity> Records() => [new("preferences","preferences",prefs,1,false),new("test","lesson",lesson,2,false)];
        var plan = PushRules.Plan(Records(), null, now);
        expect(plan.Notices.Count == 1 && plan.Notices[0].Title == "Через 5 мин — Математика", "reminder uses Irkutsk wall time");
        var notice = plan.Notices[0];
        expect(notice.Body.Contains("Б-100") && notice.Body.Contains("Иванов") && !notice.Body.Contains("PRIVATE"), "push includes only requested lesson details");
        expect(PushRules.StillValid(notice, Records(), now), "fresh reminder valid");
        expect(!PushRules.StillValid(notice, Records(), now.AddMinutes(5)), "started reminder expires");
        expect(PushRules.Plan(Records(), null, now.AddMinutes(-1)).Notices.Count == 0, "no early reminder");
        expect(PushRules.Plan(Records(), null, now.AddMinutes(3)).Notices.Count == 0, "missed reminders not sent late");
        prefs["subgroup"]="2"; expect(PushRules.Plan(Records(),null,now).Notices.Count==0 && !PushRules.StillValid(notice,Records(),now),"other subgroup suppressed, including queued job"); prefs["subgroup"]="1";
        prefs["mutedDates"]=new JsonArray("2026-10-17"); expect(!PushRules.StillValid(notice,Records(),now),"quiet day cancels queued job"); prefs["mutedDates"]=new JsonArray();
        prefs["mutedSubjects"]=new JsonArray(PushRules.SubjectKey(" МАТЕМАТИКА ")); expect(!PushRules.StillValid(notice,Records(),now),"subject mute normalized"); prefs["mutedSubjects"]=new JsonArray();
        prefs["notificationsEnabled"]=false; expect(!PushRules.StillValid(notice,Records(),now),"master off cancels queued job"); prefs["notificationsEnabled"]=true;
        prefs["beforeLessonEnabled"]=false; expect(!PushRules.StillValid(notice,Records(),now),"before switch cancels queued job"); prefs["beforeLessonEnabled"]=true;
        prefs["leadMinutes"]=1; expect(!PushRules.StillValid(notice,Records(),now),"changed lead prevents early queued reminder"); prefs["leadMinutes"]=5;
        lesson["sourceCancelled"]=true; expect(!PushRules.StillValid(notice,Records(),now),"source cancellation suppresses reminder"); lesson.Remove("sourceCancelled");
        var previous=PushRules.Sources(Records());
        lesson["homework"]="My personal change"; lesson["room"]="Personal room";
        expect(PushRules.Plan(Records(),previous,now).Notices.All(n=>n.Type!="change"),"personal edit never counts as website update");
        ((JsonObject)lesson["sourceBaseline"]!)["room"]="Б-200";
        var changes=PushRules.Plan(Records(),previous,now).Notices.Where(n=>n.Type=="change").ToList();
        expect(changes.Count==1 && changes[0].Body.Contains("Б-200"),"website baseline difference generates change event");
        expect(PushRules.StillValid(changes[0],Records(),now),"website event valid even with personal override");
        prefs["scheduleChangesEnabled"]=false; expect(!PushRules.StillValid(changes[0],Records(),now),"changes switch suppresses queued event"); prefs["scheduleChangesEnabled"]=true;
        expect(PushRules.Plan(Records(),null,now).Notices.All(n=>n.Type!="change"),"first import silent");
        lesson["sourceCancelled"]=true;
        expect(PushRules.Plan(Records(),previous,now).Notices.Single().Title.StartsWith("Занятие отменено"),"source cancellation notification");
        lesson.Remove("sourceBaseline"); lesson.Remove("sourceGroupId"); lesson.Remove("sourceCancelled");
        var detached = PushRules.Plan(Records(),previous,now).Notices.Single(n=>n.Type=="removed");
        expect(detached.Title.StartsWith("Занятие отменено на сайте") && PushRules.StillValid(detached,Records(),now),"personal lesson preserved while source cancellation is reported");
        expect(PushRules.Start(new JsonObject{["date"]="2026-10-18",["startMinute"]=0})==DateTimeOffset.Parse("2026-10-17T16:00:00Z"),"midnight civil date does not shift a day");
        // Real encryption/signing against an in-memory HTTP transport; no notification leaves this process.
        using var ec=ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        var parameters=ec.ExportParameters(true);
        string B64(byte[] bytes)=>Convert.ToBase64String(bytes).TrimEnd('=').Replace('+','-').Replace('/','_');
        var publicKey=B64([4,..parameters.Q.X!,..parameters.Q.Y!]); var privateKey=B64(parameters.D!);
        var registration=new PushRegistration(Guid.NewGuid().ToString(),"https://web.push.apple.com/test",new(){["p256dh"]=publicKey,["auth"]=B64(RandomNumberGenerator.GetBytes(16))});
        PushSender.Validate(registration); expect(true,"valid browser ECDH capability accepted");
        foreach(var endpoint in new[]{"https://127.0.0.1/", "https://evil.push.apple.com.attacker.test/a","http://web.push.apple.com/a","https://web.push.apple.com:444/a","https://user@web.push.apple.com/a","https://web.push.apple.com/a?redirect=x"})
        {
            try { PushSender.Validate(registration with {Endpoint=endpoint}); expect(false,"unsafe endpoint rejected"); } catch(ApiException) {expect(true,"unsafe endpoint rejected");}
        }
        using var transport=new Transport(expect);
        var config=new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string,string?>{["Push:PublicKey"]=publicKey,["Push:PrivateKey"]=privateKey,["PublicOrigin"]="https://example.test"}).Build();
        var sender=new PushSender(new HttpClient(transport),config);
        expect(sender.Configured,"VAPID config validated");
        foreach(var pair in new[]{(HttpStatusCode.Created,"sent"),(HttpStatusCode.Gone,"expired"),(HttpStatusCode.NotFound,"expired"),(HttpStatusCode.TooManyRequests,"retry"),(HttpStatusCode.ServiceUnavailable,"retry"),(HttpStatusCode.Forbidden,"failed")})
        { transport.Status=pair.Item1; expect(await sender.Send(registration,new{title="Тест",body="Предмет"},120,CancellationToken.None)==pair.Item2,"delivery status classified without exposing endpoint"); }
    }
    private sealed class Transport(Action<bool,string> expect):HttpMessageHandler
    {
        public HttpStatusCode Status=HttpStatusCode.Created;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct)
        {
            expect(request.Content!.Headers.ContentEncoding.Contains("aes128gcm"),"Apple-compatible encrypted payload encoding");
            expect(request.Headers.Authorization?.Scheme=="vapid","VAPID authentication scheme");
            expect(request.Headers.GetValues("TTL").Single()=="120","bounded message lifetime");
            var body=await request.Content.ReadAsByteArrayAsync(ct);
            expect(body.Length>80 && !Encoding.UTF8.GetString(body).Contains("Предмет"),"plaintext content not present in wire payload");
            return new(Status){Content=new StringContent("")};
        }
    }
}
