// Adapted from SimpleSchedule desktop parser; same repository copyright and license.
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using HtmlAgilityPack;

namespace SimpleSchedule.Pwa.University;

/// <summary>Inert HTML DOM parser. No HtmlWeb, scripts, styles, external resources or network.</summary>
public static class IstuParser
{
    public static IReadOnlyList<SourceOption> Institutes(string html) => Options(html, "list-sublist", "podrazdelenie");
    public static IReadOnlyList<SourceOption> Groups(string html) => Options(html, "schd-grp-list", "grup");

    public static SchedulePage Schedule(string html, DateOnly reference, string groupId)
    {
        if (!IstuFetchPolicy.ValidId(groupId)) throw Layout("Некорректный идентификатор группы.");
        var doc = Document(html);
        var weeks = Nodes(doc.DocumentNode, "sch-list-week");
        if (weeks.Count == 0 && IsUnpublished(doc, html)) throw new NoPublishedScheduleException();
        if (weeks.Count != 1) throw Layout("Не найден единственный блок недели.");
        var week = weeks[0];
        var classes = Classes(week);
        bool even = classes.Contains("sch-list-week-even"), odd = classes.Contains("sch-list-week-odd");
        if (even == odd) throw Layout("Не указан единственный активный вариант недели.");
        var expected = Week(reference).ToHashSet();
        var range = Coverage(Info(doc.DocumentNode), reference);
        if (range?.Any(d => !expected.Contains(d)) == true) throw Layout("Диапазон находится вне запрошенной недели.");
        var days = Nodes(week, "sch-list-day");
        if (days.Count == 0 && range == null) throw Layout("Нет дат или подтверждённого пустого диапазона.");
        if (days.Count == 0 && Clean(week.InnerText) is { Length: > 0 } text &&
            !text.Contains("занятий нет", StringComparison.OrdinalIgnoreCase)) throw Layout("Вместо дат получен неизвестный текст.");
        var covered = days.Count == 0 ? new List<DateOnly>(range ?? []) : [];
        var seen = new HashSet<DateOnly>();
        var result = new Dictionary<string, ParsedLesson>(StringComparer.Ordinal);
        var subgroups = new HashSet<string>(StringComparer.Ordinal);
        foreach (var dayNode in days)
        {
            var day = ParseDay(dayNode, reference);
            if (!seen.Add(day) || !expected.Contains(day) || (range != null && !range.Contains(day)))
                throw Layout("Повторяющаяся дата или дата вне запрошенного диапазона.");
            covered.Add(day);
            var slots = Nodes(dayNode, "sch-list-item");
            var cards = Nodes(dayNode, "schcls-item");
            if (slots.Count == 0 && cards.Count == 0)
            {
                var content = Clean(dayNode.InnerText);
                var header = string.Join(" ", Nodes(dayNode, "sch-list-day-header").Select(n => Clean(n.InnerText)));
                var remaining = Clean(content.StartsWith(header, StringComparison.Ordinal) ? content[header.Length..] : content);
                if (!IsEmpty(remaining)) throw Layout("Не распознано содержимое пустого дня.");
            }
            var visited = 0;
            foreach (var slot in slots)
            {
                var start = StartMinute(slot);
                var containers = Nodes(slot, "sch-list-item-classes");
                if (containers.Count != 1) throw Layout("Не найден блок занятий времени.");
                var slotCards = Nodes(containers[0], "schcls-item");
                visited += slotCards.Count;
                if (slotCards.Count == 0 && Clean(containers[0].InnerText).Length != 0) throw Layout("Неизвестная разметка карточек занятий.");
                foreach (var card in slotCards)
                {
                    if (Classes(card).Contains("schcls-empty"))
                    {
                        if (IsActive(card, even) && !IsEmpty(Clean(card.InnerText))) throw Layout("Не распознан текст свободной пары.");
                        continue;
                    }
                    // Grey alternatives still reveal available subgroup numbers; import only active cards.
                    var targets = TargetSubgroups(card, groupId);
                    foreach (var value in targets.OfType<string>()) subgroups.Add(value);
                    if (!IsActive(card, even)) continue;
                    var subject = Text(card, "schcls-item-name");
                    if (subject.Length == 0) throw Layout("Отсутствует название предмета.");
                    var kind = Text(card, "schcls-item-distype");
                    var teacher = Text(card, "schcls-item-prepod");
                    var room = Text(card, "schcls-item-aud");
                    var rawId = card.GetAttributeValue("id", card.GetAttributeValue("title", ""));
                    if (rawId.Length is 0 or >= 128) throw Layout("У карточки нет идентификатора источника.");
                    foreach (var target in targets)
                    {
                        var sourceId = $"istu:{groupId}:{day.Year}-{day.Month}-{day.Day}:{rawId}:{target ?? "all"}";
                        var item = new ParsedLesson(sourceId, day, start, subject, kind, teacher, target, room);
                        if (result.TryGetValue(sourceId, out var old) && old != item) throw Layout("Один идентификатор содержит разные занятия.");
                        result[sourceId] = item;
                    }
                }
            }
            if (visited != cards.Count) throw Layout("Карточка занятия находится вне блока времени.");
        }
        if (covered.Count == 0) throw Layout("Не подтверждён ни один день расписания.");
        return new(result.Values.OrderBy(l => l.Day).ThenBy(l => l.StartMinute).ThenBy(l => l.SourceId, StringComparer.Ordinal).ToList(),
            covered.Order().ToList(), GroupName(doc.DocumentNode), subgroups.OrderBy(s => s.Length).ThenBy(s => s, StringComparer.Ordinal).ToList());
    }

    public static IEnumerable<DateOnly> Week(DateOnly day)
    {
        var monday = day.AddDays(-((int)day.DayOfWeek + 6) % 7);
        return Enumerable.Range(0, Math.Min(7, DateOnly.MaxValue.DayNumber - monday.DayNumber + 1)).Select(monday.AddDays);
    }

    private static HtmlDocument Document(string html)
    {
        if (html.Length == 0 || Encoding.UTF8.GetByteCount(html) > IstuFetchPolicy.MaximumBytes ||
            html.Contains("<!ENTITY", StringComparison.OrdinalIgnoreCase)) throw Layout("Некорректная HTML-страница расписания.");
        var document = new HtmlDocument { OptionReadEncoding = false, OptionCheckSyntax = true, OptionMaxNestedChildNodes = 128 };
        try { document.LoadHtml(html); }
        catch (Exception error) when (error is not OutOfMemoryException) { throw Layout("HTML-страница превышает допустимую глубину или повреждена."); }
        foreach (var node in document.DocumentNode.Descendants().Where(n =>
                     n.Name is "script" or "style" or "iframe" or "object" or "embed" or "link").ToList()) node.Remove();
        return document;
    }

    private static bool IsUnpublished(HtmlDocument document, string original)
    {
        if (!Regex.IsMatch(original, @"<main\b[^>]*>.*?</main\s*>", RegexOptions.IgnoreCase | RegexOptions.Singleline)) return false;
        var mains = document.DocumentNode.Descendants("main").Where(n => Classes(n).Contains("page-content")).ToList();
        if (mains.Count != 1) return false;
        var main = mains[0];
        var infos = Nodes(main, "schedule-info");
        var paragraphs = main.Descendants("p").ToList();
        if (infos.Count != 1 || paragraphs.Count != 1 || Clean(paragraphs[0].InnerText) != "Не обнаружено занятий с заданными характеристиками" ||
            GroupName(infos[0]) is not { Length: > 0 and <= 128 } || Nodes(main, "sch-list-day").Count != 0 || Nodes(main, "schcls-item").Count != 0) return false;
        var info = Info(infos[0]);
        if (!info.TryGetValue("учебное подразделение", out var institute) || institute.Length == 0 ||
            !info.TryGetValue("курс", out var course) || !int.TryParse(course, out var number) || number is < 1 or > 10) return false;
        return main.ChildNodes.All(n => ReferenceEquals(n, infos[0]) || ReferenceEquals(n, paragraphs[0]) ||
            n.NodeType == HtmlNodeType.Comment || (n.NodeType == HtmlNodeType.Text && Clean(n.InnerText).Length == 0));
    }

    private static IReadOnlyList<SourceOption> Options(string html, string container, string component)
    {
        var blocks = Nodes(Document(html).DocumentNode, container);
        if (blocks.Count != 1) throw Layout("Не найден список институтов или групп.");
        var values = new Dictionary<string, SourceOption>(StringComparer.Ordinal);
        foreach (var anchor in blocks[0].Descendants("a"))
        {
            var id = LinkedId(anchor.GetAttributeValue("href", ""), component);
            if (id == null) continue;
            var name = Clean(anchor.InnerText);
            if (name.Length == 0) throw Layout("Пустое название в списке.");
            if (values.TryGetValue(id, out var old) && old.Name != name) throw Layout("Одинаковый идентификатор содержит разные названия.");
            values[id] = new(id, name);
        }
        if (values.Count == 0) throw Layout("Список пуст или его ссылки не распознаны.");
        return values.Values.ToList();
    }

    private static string? LinkedId(string href, string component)
    {
        if (href.Length == 0 || href.Contains('?') || href.Contains('#') || href.Contains('\\')) return null;
        string path = href;
        if (href.StartsWith('/') && !href.StartsWith("//", StringComparison.Ordinal)) { }
        else if (Uri.TryCreate(href, UriKind.Absolute, out var url))
        {
            if (url.Scheme != "https" || url.Host != IstuFetchPolicy.Host || !url.IsDefaultPort || url.UserInfo.Length != 0) return null;
            path = url.AbsolutePath;
        }
        else return null;
        var match = Regex.Match(path, "\\A/raspisanie/" + component + "/([0-9]+)/?\\z");
        return match.Success ? match.Groups[1].Value : null;
    }

    private static Dictionary<string, string> Info(HtmlNode node)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var field in Nodes(node, "info-block-item"))
        {
            var labels = Nodes(field, "info-block-item-label"); var fields = Nodes(field, "info-block-item-value");
            if (labels.Count != 1 || fields.Count != 1) continue;
            var key = Clean(labels[0].InnerText).ToLowerInvariant().Trim(':');
            var value = Clean(fields[0].InnerText);
            if (values.TryGetValue(key, out var old) && old != value) throw Layout("Противоречивые сведения о неделе.");
            values[key] = value;
        }
        return values;
    }

    private static string? GroupName(HtmlNode node) => node.Descendants("h1").Concat(Nodes(node, "info-block-header"))
        .Select(n => Clean(n.InnerText)).Where(s => s.StartsWith("группа ", StringComparison.OrdinalIgnoreCase)).Select(s => Clean(s[7..])).FirstOrDefault();

    private static List<DateOnly>? Coverage(Dictionary<string, string> info, DateOnly reference)
    {
        info.TryGetValue("начало действия", out var start); info.TryGetValue("окончание действия", out var end);
        if (start == null && end == null) return null;
        if (start == null || end == null) throw Layout("Указана только одна граница расписания.");
        var first = ParseDate(start, reference); var last = ParseDate(end, reference);
        var count = last.DayNumber - first.DayNumber;
        if (count is < 0 or > 6) throw Layout("Неподдерживаемый диапазон недели.");
        return Enumerable.Range(0, count + 1).Select(first.AddDays).ToList();
    }

    private static DateOnly ParseDay(HtmlNode node, DateOnly reference)
    {
        var candidates = new List<string>();
        var value = Regex.Match(node.GetAttributeValue("data-params", ""), "['\"]date['\"]\\s*:\\s*['\"]([^'\"]+)['\"]");
        if (value.Success) candidates.Add(value.Groups[1].Value);
        var headers = Nodes(node, "sch-list-day-header");
        foreach (var header in headers)
        {
            var id = header.GetAttributeValue("id", "");
            if (id.StartsWith("date-", StringComparison.Ordinal)) candidates.Add(id[5..]);
        }
        if (candidates.Count == 0 && headers.Count != 0) candidates.Add(Clean(headers[0].InnerText));
        if (candidates.Count == 0) throw Layout("У дня нет распознаваемой даты.");
        var dates = candidates.Select(s => ParseDate(s, reference)).ToList();
        if (dates.Any(d => d != dates[0])) throw Layout("Дата дня и заголовок не совпадают.");
        return dates[0];
    }

    private static DateOnly ParseDate(string raw, DateOnly reference)
    {
        var value = Clean(raw);
        var match = Regex.Match(value, @"\A([0-9]{1,2})\.([0-9]{1,2})(?:\.([0-9]{4}))?\z");
        int day, month; string year;
        if (match.Success)
        {
            day = int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture);
            month = int.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture); year = match.Groups[3].Value;
        }
        else
        {
            match = Regex.Match(value.ToLowerInvariant(), @"(?:\A|,\s*)([0-9]{1,2})\s+([а-яё]+)(?:\s+([0-9]{4}))?\z");
            string[] months = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"];
            if (!match.Success || (month = Array.IndexOf(months, match.Groups[2].Value) + 1) == 0) throw Layout("Не распознана дата: " + value);
            day = int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture); year = match.Groups[3].Value;
        }
        if (year.Length != 0)
        {
            if (DateOnly.TryParseExact($"{day:00}.{month:00}.{year}", "dd.MM.yyyy", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)) return date;
            throw Layout("Несуществующая дата: " + value);
        }
        var possible = Week(reference).Where(d => d.Day == day && d.Month == month).ToList();
        if (possible.Count != 1) throw Layout("Год даты неоднозначен: " + value);
        return possible[0];
    }

    private static bool IsActive(HtmlNode card, bool even)
    {
        if (Classes(card).Contains("card-unactive")) return false;
        foreach (var ancestor in card.Ancestors())
        {
            var classes = Classes(ancestor);
            if (classes.Contains("sch-list-item-week"))
            {
                if (classes.Count(c => c is "week-all" or "week-even" or "week-odd") != 1) throw Layout("Противоречивые варианты недель одной карточки.");
                return classes.Contains("week-all") || classes.Contains(even ? "week-even" : "week-odd");
            }
            if (classes.Contains("sch-list-item")) break;
        }
        return true;
    }

    private static int StartMinute(HtmlNode slot)
    {
        var values = new List<string>();
        var value = Regex.Match(slot.GetAttributeValue("data-params", ""), "['\"]time['\"]\\s*:\\s*['\"]([^'\"]+)['\"]");
        if (value.Success) values.Add(value.Groups[1].Value);
        values.AddRange(Nodes(slot, "sch-list-item-time-inner").Select(n => Clean(n.InnerText)));
        if (values.Count == 0) throw Layout("Не указано время занятия.");
        var minutes = values.Select(s =>
        {
            var match = Regex.Match(s, @"\A([0-9]{1,2}):([0-9]{2})(?:\s*[–—-]\s*[0-9]{1,2}:[0-9]{2})?\z");
            if (!match.Success || !int.TryParse(match.Groups[1].Value, out var hour) || !int.TryParse(match.Groups[2].Value, out var minute) || hour > 23 || minute > 59)
                throw Layout("Некорректное время занятия: " + s);
            return hour * 60 + minute;
        }).ToList();
        if (minutes.Any(m => m != minutes[0])) throw Layout("Время заголовка и карточки не совпадает.");
        return minutes[0];
    }

    private static List<string?> TargetSubgroups(HtmlNode card, string groupId)
    {
        var fields = Nodes(card, "schcls-item-group");
        if (fields.Count != 1) throw Layout("У карточки нет блока группы.");
        var found = new List<string?>();
        foreach (var anchor in fields[0].Descendants("a"))
        {
            if (LinkedId(anchor.GetAttributeValue("href", ""), "grup") != groupId) continue;
            var suffix = new StringBuilder();
            for (var next = anchor.NextSibling; next != null && next.Name != "a"; next = next.NextSibling) suffix.Append(' ').Append(next.InnerText);
            var tail = Clean(suffix.ToString());
            var match = Regex.Match(tail, @"подгрупп[аы]\s*[:№]?\s*([0-9]+(?:\s*(?:[,/;&]|или|и)\s*[0-9]+)*)\s*[,;]?\s*\z", RegexOptions.IgnoreCase);
            if (match.Success)
            {
                foreach (Match number in Regex.Matches(match.Groups[1].Value, "[0-9]+"))
                {
                    var normalized = number.Value.TrimStart('0');
                    if (normalized.Length == 0) normalized = "0";
                    if (!found.Contains(normalized)) found.Add(normalized);
                }
            }
            else
            {
                if (tail.Contains("подгрупп", StringComparison.OrdinalIgnoreCase)) throw Layout("Не распознан номер подгруппы.");
                if (!found.Contains(null)) found.Add(null);
            }
        }
        if (found.Count == 0) throw Layout("Карточка относится к другой или неизвестной группе.");
        return found;
    }

    private static string Text(HtmlNode node, string className)
    {
        var fields = Nodes(node, className);
        if (fields.Count > 1) throw Layout("Повторяющееся поле карточки.");
        return fields.Count == 0 ? "" : Clean(fields[0].InnerText);
    }
    private static List<HtmlNode> Nodes(HtmlNode node, string className) => node.Descendants().Where(n => Classes(n).Contains(className)).ToList();
    private static HashSet<string> Classes(HtmlNode node) => node.GetAttributeValue("class", "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal);
    private static string Clean(string value) => Regex.Replace(HtmlEntity.DeEntitize(value), @"\s+", " ").Trim();
    private static bool IsEmpty(string text) => text.ToLowerInvariant() is "" or "свободно" or "занятий нет";
    private static InvalidDataException Layout(string message) => new("Не удалось распознать расписание. " + message);
}
