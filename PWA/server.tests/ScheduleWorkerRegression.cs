using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using SimpleSchedule.Pwa;
using SimpleSchedule.Pwa.University;

public static class ScheduleWorkerRegression
{
    public static async Task Run(Action<bool, string> expect)
    {
        var zone = TimeZoneInfo.FindSystemTimeZoneById("Asia/Irkutsk");
        var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(DateTimeOffset.UtcNow, zone).DateTime);
        var first = new DateOnly(today.Year, today.Month, 1);
        var last = first.AddMonths(2).AddDays(-1);
        var html = PublishedDay(first);
        var parsed = IstuParser.Schedule(html, first, "42");
        var common = parsed.Lessons.Single(l => l.Subgroup == null);
        var original = SourceEntity(new("source:42:" + common.SourceId, common.SourceId, first.ToString("yyyy-MM-dd"),
            common.StartMinute, common.StartMinute + 90, common.Subject, common.Kind, "Прежний преподаватель", null, "Б-100"));
        original.Data["room"] = "Личная аудитория";
        original.Data["homework"] = "Сохранить домашнее задание";
        var removed = SourceEntity(new("source:42:removed", "removed", first.ToString("yyyy-MM-dd"), 600, 690,
            "Отменённая пара", "лекция", "Иванов", null, "Б-101"));
        var unknown = SourceEntity(new("source:42:unknown", "unknown", last.ToString("yyyy-MM-dd"), 600, 690,
            "Ещё не опубликовано", "лекция", "Иванов", null, "Б-101"));
        var manual = new Entity("manual", "lesson", new JsonObject { ["date"] = first.ToString("yyyy-MM-dd"),
            ["startMinute"] = 600, ["endMinute"] = 690, ["subject"] = "Личное занятие", ["homework"] = "Моё" }, 2, false);

        // HttpMessageHandler transports are in-memory; neither fake service can open a socket.
        using (var harness = new Harness([Preferences(), original, removed, unknown, manual], first, html))
        {
            expect(await harness.Worker.RunOnce(CancellationToken.None), "worker handles a claimed automatic job");
            expect(harness.Database.Completions.Count == 1, "worker publishes partial import in one completion");
            var completed = harness.Database.Completions.Single();
            expect(completed["p_user"]!.GetValue<string>() == Harness.User && completed["p_lease"]!.GetValue<string>() == Harness.Lease &&
                   completed["p_group"]!.GetValue<string>() == "42", "worker completion preserves claimed account, lease and group");
            expect(completed["p_error"] == null, "published days succeed even when other weeks fail");
            var operations = completed["p_operations"]!.Deserialize<List<SyncOperation>>(SupabaseGateway.Json)!;
            var updated = operations.Single(o => o.EntityId == original.Id).Data!;
            expect(updated["teacher"]!.GetValue<string>() == "Иванов И. И." && updated["room"]!.GetValue<string>() == "Личная аудитория" &&
                   updated["homework"]!.GetValue<string>() == "Сохранить домашнее задание", "automatic publication updates source and preserves personal room and homework");
            expect(updated["endMinute"]!.GetValue<int>() - updated["startMinute"]!.GetValue<int>() == 100,
                "automatic import uses configured lesson duration");
            expect(operations.Any(o => o.Data?["subgroup"]?.GetValue<string>() == "2"), "worker imports other subgroups despite selected subgroup one");
            expect(operations.Single(o => o.EntityId == removed.Id).Data?["sourceCancelled"]?.GetValue<bool>() == true,
                "missing lesson on confirmed day is reversibly cancelled");
            expect(operations.All(o => o.EntityId != unknown.Id && o.EntityId != manual.Id),
                "unknown dates and manual lessons survive automatic partial import");
            expect(harness.University.RequestedMondays.SequenceEqual(ExpectedMondays(first, last)),
                "automatic import requests current and next month in Irkutsk calendar");
            expect(!await harness.Worker.RunOnce(CancellationToken.None) && harness.Database.Completions.Count == 1,
                "empty queue does not publish a duplicate automatic import");
        }

        using (var harness = new Harness([Preferences(), unknown], first, null))
        {
            expect(await harness.Worker.RunOnce(CancellationToken.None), "worker releases job when all source weeks are unavailable");
            var completed = harness.Database.Completions.Single();
            expect(completed["p_operations"]!.AsArray().Count == 0 && completed["p_error"]?.GetValue<string>().Length > 0,
                "unknown source coverage reports retry without publishing deletions");
        }

        using (var harness = new Harness([Preferences("manual")], first, html))
        {
            expect(await harness.Worker.RunOnce(CancellationToken.None), "stale job with manual preferences is released");
            expect(harness.University.RequestedMondays.Count == 0 && harness.Database.Completions.Single()["p_operations"]!.AsArray().Count == 0,
                "manual mode performs no university fetch or publication");
        }

        using (var harness = new Harness([Preferences()], first, html, enabled: false))
        {
            expect(!harness.Worker.Configured, "disabled automatic worker is not configured");
            try { await harness.Worker.RunOnce(CancellationToken.None); expect(false, "disabled worker rejects run"); }
            catch (ApiException error) { expect(error.Status == 503, "disabled worker rejects run"); }
            expect(harness.Database.ClaimCount == 0 && harness.University.RequestedMondays.Count == 0,
                "disabled worker makes no database or university request");
        }
    }

    private static Entity Preferences(string mode = "auto") => new("preferences", "preferences", new JsonObject
    {
        ["groupId"] = "42", ["subgroup"] = "1", ["durationMinutes"] = 100, ["refreshMode"] = mode, ["refreshIntervalHours"] = 1
    }, 1, false);

    private static Entity SourceEntity(SourceLesson source)
    {
        var data = ImportMerge.Operations([], new([source], [source.Date], [], "ТЕСТ-1", null), "42").Single().Data!;
        return new(source.Id, "lesson", data, 2, false);
    }

    private static string PublishedDay(DateOnly date)
    {
        string Card(string id, string? subgroup) => $"<div class='schcls-item schcls-card' id='{id}'><div class='schcls-item-name'>Математика</div><div class='schcls-item-distype'>практика</div><div class='schcls-item-prepod'>Иванов И. И.</div><div class='schcls-item-group'><a href='/raspisanie/grup/42/'>ТЕСТ-1</a>{(subgroup == null ? "" : " подгруппа " + subgroup)}</div><div class='schcls-item-aud'>Б-200</div></div>";
        return $"<html><body><h1>Группа ТЕСТ-1</h1><div class='sch-list-week sch-list-week-even'><div class='sch-list-day' data-params=\"{{'date':'{date:dd.MM.yyyy}'}}\"><h2 class='sch-list-day-header' id='date-{date:dd.MM.yyyy}'>День</h2><div class='sch-list-item' data-params=\"{{'time':'8:15'}}\"><div class='sch-list-item-time-inner'>8:15</div><div class='sch-list-item-classes'><div class='sch-list-item-week week-all'>{Card("common", null)}{Card("second", "2")}</div></div></div></div></div></body></html>";
    }

    private static List<DateOnly> ExpectedMondays(DateOnly first, DateOnly last) =>
        Enumerable.Range(0, last.DayNumber - first.DayNumber + 1).Select(i => IstuParser.Week(first.AddDays(i)).First()).Distinct().ToList();

    private sealed class Harness : IDisposable
    {
        public const string User = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
        public const string Lease = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
        private readonly HttpClient databaseClient;
        private readonly HttpClient universityClient;
        private readonly MemoryCache cache = new(new MemoryCacheOptions());
        public DatabaseTransport Database { get; }
        public UniversityTransport University { get; }
        public ScheduleWorker Worker { get; }

        public Harness(List<Entity> records, DateOnly first, string? html, bool enabled = true)
        {
            var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Supabase:Url"] = "https://worker-test.supabase.co", ["Supabase:PublishableKey"] = "sb_publishable_test",
                ["Supabase:ServiceRoleKey"] = "sb_secret_test", ["ScheduleWorker:Enabled"] = enabled.ToString()
            }).Build();
            Database = new DatabaseTransport(records);
            University = new UniversityTransport(IstuParser.Week(first).First(), html);
            databaseClient = new HttpClient(Database);
            universityClient = new HttpClient(University);
            Worker = new(new SupabaseGateway(databaseClient, config), new UniversityService(universityClient, cache), config, NullLogger<ScheduleWorker>.Instance);
        }

        public void Dispose() { Worker.Dispose(); databaseClient.Dispose(); universityClient.Dispose(); cache.Dispose(); }
    }

    private sealed class DatabaseTransport(List<Entity> records) : HttpMessageHandler
    {
        public int ClaimCount { get; private set; }
        public List<JsonObject> Completions { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (request.RequestUri!.Host != "worker-test.supabase.co") throw new Exception("Unexpected worker database host");
            JsonNode? response;
            switch (request.RequestUri.AbsolutePath)
            {
                case "/rest/v1/rpc/pwa_job_claim":
                    ClaimCount++;
                    response = ClaimCount == 1 ? new JsonObject { ["userId"] = Harness.User, ["lease"] = Harness.Lease,
                        ["records"] = JsonSerializer.SerializeToNode(records, SupabaseGateway.Json) } : null;
                    break;
                case "/rest/v1/rpc/pwa_job_complete":
                    Completions.Add(JsonNode.Parse(await request.Content!.ReadAsStringAsync(cancellationToken))!.AsObject());
                    response = null;
                    break;
                default: throw new Exception("Unexpected worker database endpoint");
            }
            return new(HttpStatusCode.OK) { Content = new StringContent(response?.ToJsonString() ?? "null", Encoding.UTF8, "application/json") };
        }
    }

    private sealed class UniversityTransport(DateOnly publishedMonday, string? html) : HttpMessageHandler
    {
        public List<DateOnly> RequestedMondays { get; } = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (request.RequestUri!.Host != "www.istu.edu" || !request.RequestUri.AbsolutePath.StartsWith("/raspisanie/grup/42/", StringComparison.Ordinal))
                throw new Exception("Unexpected worker university address");
            var dateText = request.RequestUri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries).Last();
            var monday = DateOnly.ParseExact(dateText, "dd.MM.yyyy");
            RequestedMondays.Add(monday);
            if (monday != publishedMonday || html == null) throw new HttpRequestException("Simulated unpublished or unavailable week");
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                RequestMessage = request, Content = new StringContent(html, Encoding.UTF8, "text/html")
            });
        }
    }
}
