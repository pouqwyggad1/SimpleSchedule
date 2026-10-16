using System.Text.Json;
using System.Text.Json.Nodes;

namespace SimpleSchedule.Pwa;

public sealed class ScheduleWorker(SupabaseGateway gateway, UniversityService university, IConfiguration config, ILogger<ScheduleWorker> logger) : BackgroundService
{
    private readonly SemaphoreSlim gate = new(1);
    public bool Configured => gateway.WorkerConfigured && config.GetValue("ScheduleWorker:Enabled", true);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try { if (Configured) await RunOnce(stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception) { logger.LogWarning("Schedule worker could not contact the configured database. It will retry."); }
            try { await Task.Delay(TimeSpan.FromMinutes(1), stoppingToken); }
            catch (OperationCanceledException) { break; }
        }
    }

    public async Task<bool> RunOnce(CancellationToken ct)
    {
        if (!Configured) throw new ApiException(503, "Сервер автоматического обновления ещё не настроен.");
        if (!await gate.WaitAsync(0, ct)) return false;
        try
        {
            var job = await gateway.ServiceRpc("pwa_job_claim", new { }, ct);
            if (job == null) return false;
            string user = job["userId"]!.GetValue<string>(), lease = job["lease"]!.GetValue<string>();
            var records = job["records"]!.Deserialize<List<Entity>>(SupabaseGateway.Json)!;
            var preferences = records.SingleOrDefault(r => r.Id == "preferences" && !r.Deleted);
            var group = preferences?.Data["groupId"]?.GetValue<string>() ?? "";
            try
            {
                if (preferences?.Data["refreshMode"]?.GetValue<string>() != "auto")
                    throw new InvalidDataException();
                var zone = TimeZoneInfo.FindSystemTimeZoneById("Asia/Irkutsk");
                var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(DateTimeOffset.UtcNow, zone).DateTime);
                var from = new DateOnly(today.Year, today.Month, 1); var to = from.AddMonths(2).AddDays(-1);
                var duration = preferences.Data["durationMinutes"]?.GetValue<int>() ?? 90;
                var reply = await university.Refresh(new(group, from, to, duration), ct);
                if (reply.CoveredDays.Count == 0) throw new InvalidDataException();
                var operations = ImportMerge.Operations(records, reply, group);
                // Chunking is deliberately not done outside the transaction: a publication is atomic.
                // Worker completion accepts a larger bounded batch than a public client request.
                await gateway.ServiceRpc("pwa_job_complete", new { p_user = user, p_lease = lease, p_group = group,
                    p_operations = operations, p_error = (string?)null }, ct);
            }
            catch (Exception) when (!ct.IsCancellationRequested)
            {
                await gateway.ServiceRpc("pwa_job_complete", new { p_user = user, p_lease = lease, p_group = group,
                    p_operations = Array.Empty<SyncOperation>(), p_error = "Источник недоступен или нет опубликованных дат. Данные сохранены; будет повтор." }, ct);
            }
            return true;
        }
        finally { gate.Release(); }
    }
}
