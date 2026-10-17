using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Lib.Net.Http.WebPush;
using Lib.Net.Http.WebPush.Authentication;

namespace SimpleSchedule.Pwa;

public sealed record PushRegistration(string DeviceId, string Endpoint, Dictionary<string, string> Keys);
public sealed record PushDevice(string DeviceId);
public sealed record PushNotice(string Key, string Type, string LessonId, string Signature, string Date,
    DateTimeOffset ExpiresAt, string Title, string Body);
public sealed record PushPlan(JsonObject Sources, List<PushNotice> Notices);

public static class PushRules
{
    private static readonly string[] SourceFields = ["date", "startMinute", "endMinute", "subject", "kind", "teacher", "room", "subgroup", "sourceGroupId", "sourceCancelled"];
    public static readonly TimeZoneInfo Zone = TimeZoneInfo.FindSystemTimeZoneById("Asia/Irkutsk");
    public static string Text(JsonObject data, string key) => data[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";
    public static int Number(JsonObject data, string key, int fallback = 0) => data[key] is JsonValue v && v.TryGetValue<int>(out var n) ? n : fallback;
    public static bool Flag(JsonObject data, string key, bool fallback = false) => data[key] is JsonValue v && v.TryGetValue<bool>(out var n) ? n : fallback;
    public static string SubjectKey(string subject) => Regex.Replace(subject.Trim().Normalize(NormalizationForm.FormKC).ToLowerInvariant(), @"\s+", " ");
    public static string Signature(JsonObject data) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
        new JsonObject(SourceFields.Select(k => KeyValuePair.Create(k, data[k]?.DeepClone()))).ToJsonString()))).ToLowerInvariant();
    public static JsonObject Preferences(IEnumerable<Entity> records) => records.SingleOrDefault(r => r.Id == "preferences" && !r.Deleted)?.Data ?? [];
    public static bool Allowed(JsonObject lesson, JsonObject prefs) => Flag(prefs, "notificationsEnabled") &&
        (Text(lesson, "sourceGroupId").Length == 0 || Text(lesson, "sourceGroupId") == Text(prefs, "groupId")) &&
        (Text(lesson, "subgroup").Length == 0 || Text(prefs, "subgroup").Length == 0 || Text(lesson, "subgroup") == Text(prefs, "subgroup")) &&
        !(prefs["mutedDates"] as JsonArray ?? []).Any(v => v?.ToString() == Text(lesson, "date")) &&
        !(prefs["mutedSubjects"] as JsonArray ?? []).Any(v => v?.ToString() == SubjectKey(Text(lesson, "subject")));
    public static DateTimeOffset? Start(JsonObject data)
    {
        if (!DateOnly.TryParseExact(Text(data, "date"), "yyyy-MM-dd", out var date)) return null;
        var minute = Number(data, "startMinute", -1);
        if (minute is < 0 or >= 1440) return null;
        var local = date.ToDateTime(TimeOnly.MinValue).AddMinutes(minute);
        return new DateTimeOffset(local, Zone.GetUtcOffset(local)).ToUniversalTime();
    }
    public static JsonObject Sources(IEnumerable<Entity> records) => new(records.Where(r => r.Kind == "lesson" && !r.Deleted && r.Data["sourceBaseline"] is JsonObject)
        .Select(r => KeyValuePair.Create<string, JsonNode?>(r.Id, Source(r.Data))));
    private static JsonObject Source(JsonObject data)
    {
        var source = (JsonObject)data["sourceBaseline"]!.DeepClone();
        source["sourceCancelled"] = Flag(data, "sourceCancelled");
        return source;
    }
    public static PushPlan Plan(List<Entity> records, JsonObject? previous, DateTimeOffset now)
    {
        var prefs = Preferences(records); var sources = Sources(records); var notices = new List<PushNotice>();
        int lead = Math.Clamp(Number(prefs, "leadMinutes", 5), 1, 1440);
        foreach (var lesson in records.Where(r => r.Kind == "lesson" && !r.Deleted && !Flag(r.Data, "sourceCancelled")))
        {
            var start = Start(lesson.Data);
            if (!Allowed(lesson.Data, prefs) || !Flag(prefs, "beforeLessonEnabled", true) || start == null || start <= now ||
                now < start.Value.AddMinutes(-lead) || now >= start.Value.AddMinutes(-lead).AddMinutes(2)) continue;
            var signature = Signature(lesson.Data);
            // Lead-time changes never send another reminder for the same occurrence.
            string key = $"before:{lesson.Id}:{Text(lesson.Data, "date")}:{Number(lesson.Data, "startMinute")}";
            int minutes = Math.Max(1, (int)Math.Ceiling((start.Value - now).TotalMinutes));
            notices.Add(new(key, "before", lesson.Id, signature, Text(lesson.Data, "date"), start.Value,
                $"Через {minutes} мин — {Short(Text(lesson.Data, "subject"), 130)}", Details(lesson.Data)));
        }
        // Establish a baseline silently on first import; compare website data only.
        // Homework and personal overrides must not masquerade as changes on the website.
        if (previous is { Count: > 0 } && Flag(prefs, "scheduleChangesEnabled", true))
        {
            foreach (var (id, node) in sources)
            {
                var source = node!.AsObject(); var old = previous[id] as JsonObject;
                if ((old != null && Signature(old) == Signature(source)) || !Allowed(source, prefs) || Start(source) is not { } start || start <= now) continue;
                // A personal deletion or detachment has no new source entry and is silent.
                string signature = Signature(source);
                string change = Flag(source, "sourceCancelled") ? "Занятие отменено" : old == null ? "Добавлено занятие" : "Расписание изменилось";
                var version = records.First(r => r.Id == id).Version;
                notices.Add(new($"change:{id}:{signature}:{version}", "change", id, signature, Text(source, "date"),
                    new[] { now.AddHours(6), start }.Min(), $"{change}: {Short(Text(source, "subject"), 100)}",
                    $"{Text(source, "date")} · {Time(Number(source, "startMinute"))}. {Details(source)}"));
            }
            // ImportMerge detaches a cancelled source lesson when it has personal edits,
            // preserving that manual lesson. The website cancellation still merits a notice.
            foreach (var (id, node) in previous.Where(p => !sources.ContainsKey(p.Key)))
            {
                var preserved = records.FirstOrDefault(r => r.Id == id && r.Kind == "lesson" && !r.Deleted && r.Data["sourceBaseline"] == null);
                if (preserved == null || node is not JsonObject old || !Allowed(old, prefs) || Start(old) is not { } start || start <= now) continue;
                string signature = Signature(preserved.Data);
                notices.Add(new($"removed:{id}:{preserved.Version}", "removed", id, signature, Text(old, "date"), new[] { now.AddHours(6), start }.Min(),
                    $"Занятие отменено на сайте: {Short(Text(old, "subject"), 100)}", "Ваши личные правки сохранены. " + Details(old)));
            }
        }
        return new(sources, notices);
    }
    public static bool StillValid(PushNotice notice, List<Entity> records, DateTimeOffset now)
    {
        if (notice.ExpiresAt <= now) return false;
        var prefs = Preferences(records); var entity = records.FirstOrDefault(r => r.Id == notice.LessonId && r.Kind == "lesson" && !r.Deleted);
        if (entity == null) return false;
        JsonObject data = notice.Type == "change" && entity.Data["sourceBaseline"] is JsonObject ? Source(entity.Data) : entity.Data;
        if (!Allowed(data, prefs) || Signature(data) != notice.Signature) return false;
        if (notice.Type is "change" or "removed") return Flag(prefs, "scheduleChangesEnabled", true) &&
            !(prefs["mutedDates"] as JsonArray ?? []).Any(v => v?.ToString() == notice.Date);
        return !Flag(data, "sourceCancelled") && Flag(prefs, "beforeLessonEnabled", true) && Start(data) is { } start &&
            start > now && now >= start.AddMinutes(-Math.Clamp(Number(prefs, "leadMinutes", 5), 1, 1440));
    }
    public static string Details(JsonObject data) => $"Аудитория: {Short(Text(data, "room"), 100, "не указана")}. Преподаватель: {Short(Text(data, "teacher"), 160, "не указан")}. Вид занятия: {Short(Text(data, "kind"), 80, "не указан")}.";
    private static string Short(string value, int max, string fallback = "") => value.Length == 0 ? fallback : value.Length <= max ? value : value[..max] + "…";
    private static string Time(int minute) => $"{minute / 60:00}:{minute % 60:00}";
}

public sealed class PushSender
{
    private readonly PushServiceClient client;
    private readonly IConfiguration config;
    public string PublicKey => config["Push:PublicKey"] ?? "";
    public bool Configured { get; }
    public PushSender(HttpClient http, IConfiguration config)
    {
        this.config = config;
        client = new(http) { AutoRetryAfter = false, DefaultTimeToLive = 60 };
        try
        {
            using var key = new VapidAuthentication(PublicKey, config["Push:PrivateKey"]) { Subject = config["PublicOrigin"] };
            Configured = PublicKey.Length > 0 && config["PublicOrigin"]?.StartsWith("https://", StringComparison.Ordinal) == true;
        }
        catch (Exception e) when (e is ArgumentException or FormatException or CryptographicException) { Configured = false; }
    }
    public static void Validate(PushRegistration registration)
    {
        if (!Guid.TryParseExact(registration.DeviceId, "D", out _) || registration.Endpoint is null || registration.Endpoint.Length > 2048 ||
            !Uri.TryCreate(registration.Endpoint, UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.Port != 443 ||
            uri.UserInfo.Length != 0 || uri.Fragment.Length != 0 || uri.Query.Length != 0 ||
            !(uri.Host == "web.push.apple.com" || Regex.IsMatch(uri.Host, @"\A[a-z0-9-]+\.push\.apple\.com\z") ||
              uri.Host == "fcm.googleapis.com" || uri.Host == "updates.push.services.mozilla.com" || uri.Host == "updates-autopush.stage.mozaws.net"))
            throw new ApiException(400, "Браузер вернул неподдерживаемый адрес push-службы.");
        try
        {
            if (registration.Keys == null || registration.Keys.Count != 2) throw new FormatException();
            byte[] point = Decode(registration.Keys["p256dh"]), auth = Decode(registration.Keys["auth"]);
            if (point.Length != 65 || point[0] != 4 || auth.Length != 16) throw new FormatException();
            using var ec = ECDiffieHellman.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, Q = new() { X = point[1..33], Y = point[33..65] } });
        }
        catch (Exception e) when (e is FormatException or KeyNotFoundException or CryptographicException or ArgumentException)
        { throw new ApiException(400, "Браузер вернул некорректные ключи уведомлений. Подключите устройство снова."); }
    }
    public async Task<string> Send(PushRegistration registration, object payload, int ttl, CancellationToken ct)
    {
        Validate(registration);
        using var auth = new VapidAuthentication(PublicKey, config["Push:PrivateKey"]) { Subject = config["PublicOrigin"] };
        try
        {
            await client.RequestPushMessageDeliveryAsync(new() { Endpoint = registration.Endpoint, Keys = registration.Keys },
                new PushMessage(JsonSerializer.Serialize(payload, new JsonSerializerOptions(SupabaseGateway.Json) { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping })) { TimeToLive = Math.Clamp(ttl, 0, 21600), Urgency = PushMessageUrgency.High }, auth, ct);
            return "sent";
        }
        catch (PushServiceClientException error)
        {
            if (error.StatusCode is HttpStatusCode.Gone or HttpStatusCode.NotFound) return "expired";
            return (int)error.StatusCode == 429 || (int)error.StatusCode >= 500 ? "retry" : "failed";
        }
        catch (HttpRequestException) { return "retry"; }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { return "retry"; }
    }
    private static byte[] Decode(string value)
    {
        if (value.Length > 100 || !Regex.IsMatch(value, @"\A[A-Za-z0-9_-]+\z")) throw new FormatException();
        return Convert.FromBase64String(value.Replace('-', '+').Replace('_', '/') + new string('=', (4 - value.Length % 4) % 4));
    }
}

public sealed class PushWorker(SupabaseGateway gateway, PushSender sender, ILogger<PushWorker> logger) : BackgroundService
{
    private readonly SemaphoreSlim gate = new(1);
    public bool Configured => gateway.Configured && sender.Configured;
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try { if (Configured) await RunOnce(stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception) { logger.LogWarning("Push worker could not complete its batch; durable jobs will retry."); }
            try { await Task.Delay(TimeSpan.FromSeconds(30), stoppingToken); } catch (OperationCanceledException) { break; }
        }
    }
    public async Task<int> RunOnce(CancellationToken ct)
    {
        if (!Configured) return 0;
        if (!await gate.WaitAsync(0, ct)) return 0;
        int sent = 0;
        try
        {
            // Bounded batches and database leases also protect overlapping scheduler calls.
            for (int i = 0; i < 20; i++)
            {
                var account = await gateway.ServiceRpc("pwa_push_plan_claim", new { }, ct);
                if (account == null) break;
                var records = account["records"]!.Deserialize<List<Entity>>(SupabaseGateway.Json)!;
                var plan = PushRules.Plan(records, account["sources"] as JsonObject, DateTimeOffset.UtcNow);
                await gateway.ServiceRpc("pwa_push_plan_complete", new { p_user = account["userId"]!.GetValue<string>(), p_lease = account["lease"]!.GetValue<string>(),
                    p_revision = account["revision"]!.GetValue<long>(), p_sources = plan.Sources, p_notices = plan.Notices }, ct);
            }
            for (int i = 0; i < 40; i++)
            {
                var job = await gateway.ServiceRpc("pwa_push_delivery_claim", new { }, ct);
                if (job == null) break;
                var notice = job["notice"]!.Deserialize<PushNotice>(SupabaseGateway.Json)!;
                var records = job["records"]!.Deserialize<List<Entity>>(SupabaseGateway.Json)!;
                var now = DateTimeOffset.UtcNow;
                string status = "cancelled";
                if (PushRules.StillValid(notice, records, now))
                {
                    var registration = job["subscription"]!.Deserialize<PushRegistration>(SupabaseGateway.Json)!;
                    try
                    {
                        status = await sender.Send(registration, Payload(notice), (int)(notice.ExpiresAt - now).TotalSeconds, ct);
                    }
                    catch (ApiException) { status = "failed"; }
                }
                await gateway.ServiceRpc("pwa_push_delivery_complete", new { p_id = job["id"]!.GetValue<string>(), p_lease = job["lease"]!.GetValue<string>(), p_status = status }, ct);
                if (status == "sent") sent++;
            }
            return sent;
        }
        finally { gate.Release(); }
    }
    public static object Payload(PushNotice notice) => new { title = notice.Title, body = notice.Body, tag = notice.Key,
        url = "/?mode=schedule&date=" + notice.Date, expiresAt = notice.ExpiresAt.ToUnixTimeMilliseconds() };
}
