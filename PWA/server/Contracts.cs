using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace SimpleSchedule.Pwa;

public sealed record Entity(string Id, string Kind, JsonObject Data, long Version, bool Deleted);
public sealed record SyncOperation(string OperationId, string EntityId, string Kind, long BaseVersion, JsonObject? Base, JsonObject? Data);
public sealed record OperationResult(string OperationId, string Status, Entity Record, string[] ConflictingFields);
public sealed record SyncReply(List<Entity> Records, List<OperationResult> Results, long Revision);
public sealed record SyncRequest(List<SyncOperation> Operations);
public sealed record EmailRequest(string Email);
public sealed record VerifyRequest(string Email, string Code);
public sealed record RefreshRequest(string GroupId, DateOnly From, DateOnly To, int DurationMinutes = 90);
public sealed record SourceLesson(string Id, string SourceId, string Date, int StartMinute, int EndMinute, string Subject,
    string Kind, string Teacher, string? Subgroup, string Room);
public sealed record RefreshReply(List<SourceLesson> Lessons, List<string> CoveredDays, List<string> Subgroups, string? GroupName, string? Message);
public sealed record ApiUser(string Id, string Email);
public sealed record TokenSet(string AccessToken, string RefreshToken, long ExpiresAt, ApiUser User);

public sealed class ApiException(int status, string message, int? retryAfterSeconds = null) : Exception(message)
{
    public int Status { get; } = status;
    public int? RetryAfterSeconds { get; } = retryAfterSeconds;
}

public static class Validation
{
    private static readonly HashSet<string> Kinds = ["task", "group", "lesson", "preferences"];
    private static readonly Dictionary<string, HashSet<string>> Fields = new()
    {
        ["task"] = ["title", "date", "groupId", "note", "completed"],
        ["group"] = ["name", "color"],
        ["lesson"] = ["date", "startMinute", "endMinute", "subject", "kind", "teacher", "room", "subgroup", "homework", "sourceId", "sourceGroupId", "sourceBaseline", "sourceCancelled"],
        ["preferences"] = ["instituteId", "groupId", "subgroup", "durationMinutes", "refreshMode", "refreshIntervalHours", "notificationsEnabled", "beforeLessonEnabled", "scheduleChangesEnabled", "leadMinutes", "mutedSubjects", "mutedDates"]
    };

    public static string Email(string? value)
    {
        value = value?.Trim() ?? "";
        if (value.Length is < 3 or > 254 || !Regex.IsMatch(value, @"\A[^\s@]+@[^\s@]+\.[^\s@]+\z"))
            throw new ApiException(400, "Введите корректный адрес электронной почты.");
        return value;
    }

    public static void Operations(List<SyncOperation>? operations)
    {
        if (operations is null || operations.Count > 100) throw new ApiException(400, "Допустимо не более 100 изменений за один запрос.");
        foreach (var op in operations)
        {
            if (op is null || op.OperationId is null || !Guid.TryParse(op.OperationId, out _) || op.EntityId is null ||
                op.EntityId.Length is < 1 or > 200 || !Kinds.Contains(op.Kind) || op.BaseVersion < 0 ||
                (op.Kind == "preferences" && op.EntityId != "preferences"))
                throw new ApiException(400, "Некорректная команда синхронизации.");
            if (op.Data != null) Data(op.Kind, op.Data);
        }
    }

    public static void Data(string kind, JsonObject data)
    {
        if (data.Count > 32 || data.Any(p => !Fields[kind].Contains(p.Key)) || data.ToJsonString().Length > 48_000)
            throw new ApiException(400, "Некорректные поля записи.");
        string? Str(string key) => data[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
        int Int(string key) => data[key] is JsonValue v && v.TryGetValue<int>(out var n) ? n : -1;
        bool Text(string key, int max, bool required = false) => Str(key) is { } s ? s.Length <= max && (!required || s.Trim().Length > 0) : !required && data[key] == null;
        bool Date(string key) => DateOnly.TryParseExact(Str(key), "yyyy-MM-dd", out _);
        bool valid = kind switch
        {
            "task" => Text("title", 500, true) && Date("date") && Text("note", 20_000) && Text("groupId", 200) && data["completed"] is JsonValue c && c.TryGetValue<bool>(out _),
            "group" => Text("name", 120, true) && Str("color") is { } color && Regex.IsMatch(color, @"\A#[0-9a-fA-F]{6}\z"),
            "lesson" => Text("subject", 500, true) && Date("date") && Int("startMinute") >= 0 && Int("endMinute") > Int("startMinute") && Int("endMinute") <= 1440 && Text("kind", 100) && Text("teacher", 500) && Text("room", 200) && Text("subgroup", 50) && Text("homework", 20_000) && Text("sourceId", 200) && Text("sourceGroupId", 12) &&
                (!data.ContainsKey("sourceCancelled") || data["sourceCancelled"] is JsonValue flag && flag.TryGetValue<bool>(out _)),
            "preferences" => (!data.ContainsKey("durationMinutes") || Int("durationMinutes") is >= 1 and <= 360) &&
                (!data.ContainsKey("refreshMode") || Str("refreshMode") is "manual" or "auto") &&
                (!data.ContainsKey("refreshIntervalHours") || Int("refreshIntervalHours") is 1 or 3 or 6) &&
                Text("groupId", 12) && Text("instituteId", 12) && Text("subgroup", 50) &&
                new[] { "notificationsEnabled", "beforeLessonEnabled", "scheduleChangesEnabled" }.All(k => !data.ContainsKey(k) || data[k] is JsonValue v && v.TryGetValue<bool>(out _)) &&
                (!data.ContainsKey("leadMinutes") || Int("leadMinutes") is >= 1 and <= 1440) &&
                new[] { "mutedSubjects", "mutedDates" }.All(k => !data.ContainsKey(k) || data[k] is JsonArray a && a.Count <= 1000 && a.All(v => v is JsonValue j && j.TryGetValue<string>(out var t) && t.Length <= 500 && (k != "mutedDates" || DateOnly.TryParseExact(t, "yyyy-MM-dd", out _)))),
            _ => false
        };
        if (!valid) throw new ApiException(400, "Проверьте название, дату, время и остальные поля записи.");
    }
}
