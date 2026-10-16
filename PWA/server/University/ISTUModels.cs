// Adapted from SimpleSchedule desktop parser; same repository copyright and license.
namespace SimpleSchedule.Pwa.University;

public sealed record SourceOption(string Id, string Name);
public sealed record ParsedLesson(string SourceId, DateOnly Day, int StartMinute, string Subject,
    string Kind, string Teacher, string? Subgroup, string Room);
public sealed record SchedulePage(IReadOnlyList<ParsedLesson> Lessons, IReadOnlyList<DateOnly> CoveredDays,
    string? GroupName, IReadOnlyList<string> Subgroups);

public sealed class NoPublishedScheduleException : Exception
{
    public NoPublishedScheduleException() : base("Расписание на этот период ещё не опубликовано.") { }
}
