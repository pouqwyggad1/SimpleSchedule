using System.Text.Json.Nodes;
using SimpleSchedule.Pwa;

int assertions = 0;
void Expect(bool value, string name)
{
    assertions++;
    if (!value) throw new Exception("FAIL: " + name);
}
void Reject(string name, Action action)
{
    try { action(); }
    catch (ApiException) { Expect(true, name); return; }
    Expect(false, name);
}
IstuRegression.Run(Expect);
await SessionRegression.Run(Expect);
await ScheduleWorkerRegression.Run(Expect);
await AuthRegression.Run(Expect);
Reject("empty email rejected", () => Validation.Email(null));
Reject("invalid email rejected", () => Validation.Email("wrong"));
Expect(Validation.Email(" a@example.com ") == "a@example.com", "email trim");
Reject("oversized period rejected", () => UniversityService.Validate(new("42", new(2026, 1, 1), new(2026, 3, 20), 90)));
Reject("arbitrary group URL rejected", () => UniversityService.Validate(new("https://attacker.invalid", new(2026, 1, 1), new(2026, 1, 2), 90)));
var prefs = JsonNode.Parse("""{"instituteId":"683","groupId":"42","subgroup":"1","durationMinutes":90,"refreshMode":"auto","refreshIntervalHours":1,"notificationsEnabled":false,"beforeLessonEnabled":true,"scheduleChangesEnabled":true,"leadMinutes":5,"mutedSubjects":[],"mutedDates":["2026-10-13"]}""")!.AsObject();
Validation.Data("preferences", prefs); Expect(true, "exact client preference contract accepted");
prefs["leadMinutes"] = 0; Reject("zero reminder rejected", () => Validation.Data("preferences", prefs));
prefs["leadMinutes"] = 5; prefs["mutedDates"] = new JsonArray("2026-02-30"); Reject("impossible muted date rejected", () => Validation.Data("preferences", prefs));
var source = new SourceLesson("source:42:stable", "stable", "2026-10-13", 705, 795, "Математика", "лекция", "Иванов", null, "Б-100");
var import = new RefreshReply([source], ["2026-10-13"], ["1", "2"], "ТЕСТ-1", null);
var added = ImportMerge.Operations([], import, "42");
Expect(added.Count == 1 && added[0].EntityId == source.Id, "stable source entity ID");
var baseline = added[0].Data!;
var entity = new Entity(source.Id, "lesson", baseline, 1, false);
Expect(ImportMerge.Operations([entity], import, "42").Count == 0, "unchanged import is no-op");
var personalized = (JsonObject)baseline.DeepClone(); personalized["room"] = "Моя аудитория"; personalized["homework"] = "Решить задачу";
var edited = entity with { Data = personalized };
var updated = import with { Lessons = [source with { Room = "Б-200", Teacher = "Петров" }] };
var merged = ImportMerge.Operations([edited], updated, "42").Single().Data!;
Expect(merged["room"]!.GetValue<string>() == "Моя аудитория" && merged["teacher"]!.GetValue<string>() == "Петров" && merged["homework"]!.GetValue<string>() == "Решить задачу", "source updates preserve overrides and homework");
Expect(ImportMerge.Operations([entity with { Deleted = true }], import, "42").Count == 0, "user tombstone never resurrects");
Expect(ImportMerge.Operations([entity], import with { Lessons = [], CoveredDays = [] }, "42").Count == 0, "unknown days never delete");
var cancelOperation = ImportMerge.Operations([entity], import with { Lessons = [] }, "42").Single();
Expect(cancelOperation.EntityId == entity.Id && cancelOperation.Data?["sourceCancelled"]?.GetValue<bool>() == true, "source cancellation is reversible instead of user tombstone");
var cancelledEntity = entity with { Data = cancelOperation.Data!, Version = 2 };
Expect(ImportMerge.Operations([cancelledEntity], import with { Lessons = [] }, "42").Count == 0, "repeated cancellation is no-op");
var restored = ImportMerge.Operations([cancelledEntity], import, "42").Single();
Expect(restored.EntityId == entity.Id && restored.Data?["sourceCancelled"]?.GetValue<bool>() == false, "same source ID restores after site cancellation");
Expect(ImportMerge.Operations([cancelledEntity], import with { Lessons = [], CoveredDays = [] }, "42").Count == 0, "unknown coverage preserves cancelled status");
Expect(ImportMerge.Operations([cancelledEntity with { Deleted = true }], import, "42").Count == 0, "explicit deletion after cancellation still never resurrects");
Validation.Data("lesson", cancelOperation.Data!); Expect(true, "boolean sourceCancelled accepted by API");
var badFlag = (JsonObject)cancelOperation.Data!.DeepClone(); badFlag["sourceCancelled"] = "true";
Reject("string sourceCancelled rejected by API", () => Validation.Data("lesson", badFlag));
Expect(ImportMerge.Operations([edited], import with { Lessons = [] }, "42").Any(o => o.Data?["homework"]?.GetValue<string>() == "Решить задачу"), "removed lesson preserves personal homework");
personalized["date"] = "2026-10-15";
var cancelledMoved = ImportMerge.Operations([edited], import with { Lessons = [] }, "42");
Expect(cancelledMoved.Count == 1 && cancelledMoved[0].EntityId == source.Id &&
    cancelledMoved[0].Data?["date"]?.GetValue<string>() == "2026-10-15" && cancelledMoved[0].Data?["sourceId"] == null &&
    cancelledMoved[0].Data?["sourceCancelled"] == null, "cancel original source date converts edited record to manual without user tombstone");
Console.WriteLine($"PASS: {assertions} assertions (ISTU fixtures, import merge, request validation, encrypted sessions, account isolation).");
