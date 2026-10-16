// Adapted from SimpleSchedule desktop parser; same repository copyright and license.
using System.Globalization;
using System.Text.RegularExpressions;

namespace SimpleSchedule.Pwa.University;

/// <summary>Only official timetable paths. Never accepts arbitrary URLs, parameters or redirects.</summary>
public static class IstuFetchPolicy
{
    public const int MaximumBytes = 2_000_000;
    public const string Host = "www.istu.edu";

    public static Uri UrlFor(string path)
    {
        if (path.Length > 128) throw Invalid();
        var ordinary = Regex.IsMatch(path, @"\A/raspisanie(?:/(?:podrazdelenie|grup)/[0-9]+)?\z");
        var dated = Regex.Match(path, @"\A/raspisanie/grup/[0-9]+/([0-9]{2}\.[0-9]{2}\.[0-9]{4})/\z");
        if (!ordinary && !(dated.Success && DateOnly.TryParseExact(dated.Groups[1].Value, "dd.MM.yyyy",
                CultureInfo.InvariantCulture, DateTimeStyles.None, out _))) throw Invalid();
        var url = new Uri("https://" + Host + path, UriKind.Absolute);
        if (url.Scheme != Uri.UriSchemeHttps || url.Host != Host || !url.IsDefaultPort ||
            url.UserInfo.Length != 0 || url.Query.Length != 0 || url.Fragment.Length != 0 ||
            url.AbsolutePath != path) throw Invalid();
        return url;
    }

    public static bool ValidId(string? value) => value is { Length: > 0 and <= 12 } && value.All(c => c is >= '0' and <= '9');
    private static ArgumentException Invalid() => new("Разрешены только страницы расписания ИРНИТУ без параметров и перенаправлений.");
}
