using System.Text.Json;
using System.Text.Json.Nodes;

namespace SimpleSchedule.Pwa;

public static class ImportMerge
{
    private static readonly string[] SourceFields = ["date", "startMinute", "endMinute", "subject", "kind", "teacher", "room", "subgroup", "sourceId", "sourceGroupId"];

    public static List<SyncOperation> Operations(IEnumerable<Entity> existing, RefreshReply reply, string groupId)
    {
        var records = existing.Where(r => r.Kind == "lesson").ToDictionary(r => r.Id, StringComparer.Ordinal);
        var result = new List<SyncOperation>(); var incoming = new HashSet<string>(StringComparer.Ordinal);
        foreach (var lesson in reply.Lessons)
        {
            incoming.Add(lesson.Id);
            var baseline = JsonSerializer.SerializeToNode(lesson, SupabaseGateway.Json)!.AsObject();
            baseline.Remove("id"); baseline["sourceGroupId"] = groupId;
            if (records.TryGetValue(lesson.Id, out var old) && old.Deleted) continue;
            JsonObject data;
            if (old == null) { data = (JsonObject)baseline.DeepClone(); data["homework"] = ""; }
            else
            {
                data = (JsonObject)old.Data.DeepClone();
                var previous = old.Data["sourceBaseline"] as JsonObject;
                foreach (var field in SourceFields)
                    if (previous != null && JsonNode.DeepEquals(old.Data[field], previous[field])) data[field] = baseline[field]?.DeepClone();
            }
            data["sourceBaseline"] = baseline.DeepClone();
            data["sourceCancelled"] = false;
            if (old == null || !JsonNode.DeepEquals(old.Data, data))
                result.Add(new(Guid.NewGuid().ToString(), lesson.Id, "lesson", old?.Version ?? 0, old?.Data, data));
        }
        foreach (var old in records.Values.Where(r => !r.Deleted && r.Data["sourceGroupId"]?.GetValue<string>() == groupId &&
                     reply.CoveredDays.Contains((r.Data["sourceBaseline"] as JsonObject)?["date"]?.GetValue<string>() ?? r.Data["date"]?.GetValue<string>() ?? "") && !incoming.Contains(r.Id)))
        {
            // Preserve any personal edits/homework on a removed source lesson as a manual lesson.
            var baseline = old.Data["sourceBaseline"] as JsonObject;
            bool edited = (old.Data["homework"]?.GetValue<string>() ?? "").Length != 0 || baseline == null ||
                SourceFields.Any(f => !JsonNode.DeepEquals(old.Data[f], baseline[f]));
            if (edited)
            {
                var manual = (JsonObject)old.Data.DeepClone();
                manual.Remove("sourceId"); manual.Remove("sourceGroupId"); manual.Remove("sourceBaseline"); manual.Remove("sourceCancelled");
                result.Add(new(Guid.NewGuid().ToString(), old.Id, "lesson", old.Version, old.Data, manual));
            }
            else if (old.Data["sourceCancelled"]?.GetValue<bool>() != true)
            {
                // A source cancellation can be reversed by a later import. Only an explicit
                // user deletion writes a tombstone, which the import must never resurrect.
                var cancelled = (JsonObject)old.Data.DeepClone(); cancelled["sourceCancelled"] = true;
                result.Add(new(Guid.NewGuid().ToString(), old.Id, "lesson", old.Version, old.Data, cancelled));
            }
        }
        return result;
    }
}
