using System.Net;
using System.Text;
using Microsoft.Extensions.Caching.Memory;
using SimpleSchedule.Pwa.University;

namespace SimpleSchedule.Pwa;

public sealed class UniversityService(HttpClient http, IMemoryCache cache)
{
    private readonly SemaphoreSlim fetchGate = new(1);
    private DateTimeOffset lastRequest;

    public async Task<IReadOnlyList<SourceOption>> Institutes(CancellationToken ct)
    {
        if (cache.TryGetValue<IReadOnlyList<SourceOption>>("institutes", out var value)) return value!;
        value = IstuParser.Institutes(await Fetch("/raspisanie", ct));
        cache.Set("institutes", value, TimeSpan.FromHours(1)); return value;
    }

    public async Task<IReadOnlyList<SourceOption>> Groups(string institute, CancellationToken ct)
    {
        if (!IstuFetchPolicy.ValidId(institute)) throw new ApiException(400, "Выберите институт из списка.");
        if (cache.TryGetValue<IReadOnlyList<SourceOption>>("groups:" + institute, out var value)) return value!;
        value = IstuParser.Groups(await Fetch("/raspisanie/podrazdelenie/" + institute, ct));
        cache.Set("groups:" + institute, value, TimeSpan.FromHours(1)); return value;
    }

    public async Task<RefreshReply> Refresh(RefreshRequest request, CancellationToken ct)
    {
        Validate(request);
        var lessons = new Dictionary<string, SourceLesson>(StringComparer.Ordinal);
        var coverage = new HashSet<string>(StringComparer.Ordinal);
        var subgroups = new HashSet<string>(StringComparer.Ordinal);
        string? name = null; bool partial = false;
        var mondays = Enumerable.Range(0, request.To.DayNumber - request.From.DayNumber + 1)
            .Select(i => IstuParser.Week(request.From.AddDays(i)).First()).Distinct();
        foreach (var monday in mondays)
        {
            try
            {
                var path = $"/raspisanie/grup/{request.GroupId}/{monday:dd.MM.yyyy}/";
                var page = IstuParser.Schedule(await Fetch(path, ct), monday, request.GroupId);
                name ??= page.GroupName;
                foreach (var subgroup in page.Subgroups) subgroups.Add(subgroup);
                foreach (var date in page.CoveredDays.Where(d => d >= request.From && d <= request.To)) coverage.Add(date.ToString("yyyy-MM-dd"));
                foreach (var item in page.Lessons.Where(l => l.Day >= request.From && l.Day <= request.To))
                {
                    // A source lesson cannot cross a civil day in this contract.
                    var end = Math.Min(1440, item.StartMinute + request.DurationMinutes);
                    lessons[item.SourceId] = new("source:" + request.GroupId + ":" + item.SourceId, item.SourceId,
                        item.Day.ToString("yyyy-MM-dd"), item.StartMinute, end, item.Subject, item.Kind, item.Teacher, item.Subgroup, item.Room);
                }
            }
            catch (NoPublishedScheduleException) { partial = true; }
            catch (Exception error) when (error is HttpRequestException or InvalidDataException or ApiException || error is OperationCanceledException && !ct.IsCancellationRequested)
            {
                // A failed week is unknown, never a confirmed empty week. Import the rest.
                partial = true;
            }
        }
        return new(lessons.Values.OrderBy(l => l.Date, StringComparer.Ordinal).ThenBy(l => l.StartMinute).ThenBy(l => l.Id, StringComparer.Ordinal).ToList(),
            coverage.Order(StringComparer.Ordinal).ToList(), subgroups.OrderBy(s => s.Length).ThenBy(s => s, StringComparer.Ordinal).ToList(), name,
            partial ? "Загружены доступные дни. Неопубликованные или недоступные даты сохранены без изменений." : null);
    }

    public static void Validate(RefreshRequest request)
    {
        if (!IstuFetchPolicy.ValidId(request.GroupId) || request.From.Year < 2000 || request.To.Year > 2100 ||
            request.To < request.From || request.To.DayNumber - request.From.DayNumber > 61 || request.DurationMinutes is < 1 or > 360)
            throw new ApiException(400, "Выберите группу, период до 62 дней и длительность от 1 до 360 минут.");
    }

    private async Task<string> Fetch(string path, CancellationToken ct)
    {
        var url = IstuFetchPolicy.UrlFor(path);
        await fetchGate.WaitAsync(ct);
        try
        {
            var delay = TimeSpan.FromMilliseconds(850) - (DateTimeOffset.UtcNow - lastRequest);
            if (delay > TimeSpan.Zero) await Task.Delay(delay, ct);
            lastRequest = DateTimeOffset.UtcNow;
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
            limit.CancelAfter(TimeSpan.FromSeconds(22));
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.Accept.ParseAdd("text/html"); request.Headers.UserAgent.ParseAdd("SimpleSchedule-PWA/1.0");
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, limit.Token);
            if (response.StatusCode != HttpStatusCode.OK || response.Headers.Location != null || response.RequestMessage?.RequestUri != url ||
                response.Content.Headers.ContentType?.MediaType is not ("text/html" or "application/xhtml+xml"))
                throw new InvalidDataException("Сайт вернул неподходящую страницу расписания.");
            if (response.Content.Headers.ContentLength > IstuFetchPolicy.MaximumBytes) throw new InvalidDataException("Страница расписания превышает 2 МБ.");
            await using var source = await response.Content.ReadAsStreamAsync(limit.Token);
            using var buffer = new MemoryStream(); var block = new byte[16_384];
            while (true)
            {
                int read = await source.ReadAsync(block, limit.Token);
                if (read == 0) break;
                if (buffer.Length + read > IstuFetchPolicy.MaximumBytes) throw new InvalidDataException("Страница расписания превышает 2 МБ.");
                buffer.Write(block, 0, read);
            }
            try { return new UTF8Encoding(false, true).GetString(buffer.GetBuffer(), 0, (int)buffer.Length); }
            catch (DecoderFallbackException) { throw new InvalidDataException("Кодировка страницы не распознана."); }
        }
        finally { fetchGate.Release(); }
    }
}
