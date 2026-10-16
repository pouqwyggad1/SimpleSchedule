using System;
using System.IO;
using System.Linq;
using SimpleSchedule.Pwa.University;

public static class IstuRegression
{
    public static void Run(Action<bool, string> expect)
    {
        string Fixture(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "ISTU", name));
        void Reject(string name, Action action)
        {
            try { action(); } catch { expect(true, name); return; }
            expect(false, name);
        }
        void InvalidLayout(string name, Action action)
        {
            try { action(); } catch (InvalidDataException) { expect(true, name); return; }
            expect(false, name);
        }
        string Card(string id, string subject = "Математика", string? subgroup = null) =>
            $"<div class='schcls-item schcls-card' id='{id}'><div class='schcls-item-name'>{subject}</div><div class='schcls-item-distype'>практика</div><div class='schcls-item-prepod'>Иванов&nbsp;И.&nbsp;И.</div><div class='schcls-item-group'><a href='/raspisanie/grup/42/'>ТЕСТ-1</a>{(subgroup == null ? "" : " подгруппа " + subgroup)}</div><div class='schcls-item-aud'>Б-101 &amp; Б-102</div></div>";
        string Slot(string cards, string time = "8:15", string parity = "week-all") =>
            $"<div class='sch-list-item' data-params=\"{{'time':'{time}'}}\"><div class='sch-list-item-time-inner'>{time}</div><div class='sch-list-item-classes'><div class='sch-list-item-week {parity}'>{cards}</div></div></div>";
        string Day(string date, string content) => $"<div class='sch-list-day' data-params=\"{{'date':'{date}'}}\"><h2 class='sch-list-day-header' id='date-{date}'>День</h2>{content}</div>";
        string Page(string content, string? start = null, string? end = null, string rendered = "even")
        {
            string Field(string label, string value) => $"<div class='info-block-item'><div class='info-block-item-label'>{label}:</div><div class='info-block-item-value'>{value}</div></div>";
            return "<html><body><h1>Группа ТЕСТ-1</h1>" + (start == null ? "" : Field("Начало действия", start)) +
                   (end == null ? "" : Field("Окончание действия", end)) + $"<div class='sch-list-week sch-list-week-{rendered}'>{content}</div></body></html>";
        }
        var october = new DateOnly(2026, 10, 12);
        SchedulePage Parse(string text, DateOnly? day = null, string group = "42") => IstuParser.Schedule(text, day ?? october, group);
        var institutes = IstuParser.Institutes(Fixture("institutes.html"));
        expect(institutes.Count == 12, "Все институты из реальной страницы");
        expect(institutes.Any(v => v.Id == "683" && v.Name == "Институт информационных технологий и анализа данных"), "Название института");
        var groups = IstuParser.Groups(Fixture("groups-683.html"));
        expect(groups.Count == 39 && groups.Any(v => v.Id == "478240" && v.Name == "ИСТб-26-1"), "Все группы из реальной страницы");
        var real = Parse(Fixture("group-478240-2026-10-12.html"), group: "478240");
        expect(real.GroupName == "ИСТб-26-1" && real.Lessons.Count == 20, "Реальные карточки всех подгрупп");
        expect(real.CoveredDays.Count == 5 && real.CoveredDays.Last() == new DateOnly(2026, 10, 16), "Только опубликованные даты покрыты");
        expect(real.Subgroups.SequenceEqual(["1", "2"]), "Номера подгрупп с сайта");
        expect(real.Lessons.Any(l => l.SourceId.Contains("sh13419575")) && !real.Lessons.Any(l => l.SourceId.Contains("sh13414651")), "Активная CSS-четность важнее подписи недели");
        expect(real.Lessons.Any(l => l.Subgroup == null) && real.Lessons.Any(l => l.Subgroup == "1") && real.Lessons.Any(l => l.Subgroup == "2"), "Общие занятия и обе подгруппы сохранены");
        var november = Parse(Fixture("group-478240-2026-11-02.html"), new DateOnly(2026, 11, 2), "478240");
        expect(november.CoveredDays.Count == 5 && november.CoveredDays[0] == new DateOnly(2026, 11, 2), "Ноябрьский маршрут");
        expect(!real.Lessons.Select(l => l.SourceId).Intersect(november.Lessons.Select(l => l.SourceId)).Any(), "Повторные ID разделены датами");
        var regression = Parse(Fixture("group-478229-2026-10-12.html"), group: "478229");
        var tuesday = regression.Lessons.Where(l => l.Day == new DateOnly(2026, 10, 13)).ToList();
        expect(regression.GroupName == "ИСИб-23-1" && regression.Lessons.Count == 19, "Регрессионная группа");
        expect(tuesday.Count == 2 && tuesday.Select(l => l.StartMinute).SequenceEqual([705, 825]), "13 октября ровно две пары");
        expect(tuesday[0].Subject == "История России" && tuesday[0].Room == "Б-100" && tuesday[0].Teacher == "Наумов И.В." && tuesday[0].Kind == "практика", "Активная аудитория и преподаватель вторника");
        expect(tuesday[1].Subject == "Технологии разработки программ-роботов" && tuesday[1].Room == "3-210", "Вторая пара вторника сохранена");
        expect(regression.Lessons.All(l => l.Day != new DateOnly(2026, 10, 14)), "14 октября нет пар");
        expect(regression.CoveredDays.Count == 6 && regression.Subgroups.SequenceEqual(["1"]), "Воскресенье не очищается, подгруппа 2 не выдумывается");
        var following = Parse(Fixture("group-478229-2026-10-19.html"), new DateOnly(2026, 10, 19), "478229");
        expect(following.Lessons.Count(l => l.Day.Day == 20) == 1 && following.Lessons.Count(l => l.Day.Day == 21) == 3, "Следующая неделя меняет активный вариант");
        var unpublished = Fixture("group-478229-2026-12-21-unpublished.html");
        bool knownUnpublished = false;
        try { Parse(unpublished, new DateOnly(2026, 12, 21), "478229"); }
        catch (NoPublishedScheduleException) { knownUnpublished = true; }
        expect(knownUnpublished, "Официальное отсутствие публикации не создаёт пустое покрытие");
        foreach (var altered in new[]
        {
            unpublished.Replace("Не обнаружено занятий с заданными характеристиками", "Ошибка сервера"),
            unpublished.Replace("Группа ИСИб-23-1", "Ошибка"),
            unpublished.Replace("Учебное подразделение:", "Неизвестное поле:"),
            unpublished.Replace("</main>", "<div>Ошибка сервера</div></main>"),
            unpublished.Replace("</main>", "")
        }) InvalidLayout("Поврежденная страница не маскируется под отсутствие публикации", () => Parse(altered, new DateOnly(2026, 12, 21), "478229"));
        var sample = Page(Day("12.10.2026", Slot(Card("a", "Алгебра &amp; геометрия") + Card("b", subgroup: "1") + Card("c", subgroup: "2"))));
        var parsed = Parse(sample);
        expect(parsed.Lessons.Count == 3 && parsed.Lessons.All(l => l.StartMinute == 495), "Карточки одного временного блока");
        expect(parsed.Lessons.Any(l => l.Subject == "Алгебра & геометрия" && l.Room == "Б-101 & Б-102" && l.Teacher == "Иванов И. И."), "HTML-сущности и неразрывные пробелы");
        var inactive = Parse(Page(Day("12.10.2026", Slot(Card("even", subgroup: "1"), parity: "week-even") + Slot(Card("odd", subgroup: "2"), parity: "week-odd"))));
        expect(inactive.Lessons.Count == 1 && inactive.Lessons[0].Subgroup == "1" && inactive.Subgroups.SequenceEqual(["1", "2"]), "Неактивная карточка даёт номер подгруппы, но не пару");
        expect(Parse(sample.Replace("schcls-item schcls-card' id='b", "schcls-item schcls-card card-unactive' id='b")).Lessons.Count == 2, "card-unactive исключён");
        foreach (var subgroup in new[] { "2 / 1", "1 и 2", "1И2" })
        {
            var shared = Parse(Page(Day("12.10.2026", Slot(Card("shared", subgroup: subgroup)))));
            expect(shared.Lessons.Count == 2 && shared.Subgroups.SequenceEqual(["1", "2"]), "Карточка нескольких подгрупп");
        }
        var foreign = Card("foreign", subgroup: "3").Replace("<a href='/raspisanie/grup/42/'>", "<a href='/raspisanie/grup/99/'>ДРУГАЯ</a> подгруппа 8, <a href='/raspisanie/grup/42/'>");
        expect(Parse(Page(Day("12.10.2026", Slot(foreign)))).Subgroups.SequenceEqual(["3"]), "Чужой номер подгруппы не присвоен выбранной группе");
        expect(Parse(sample.Replace("8:15", "9:00")).Lessons.Select(l => l.SourceId).SequenceEqual(parsed.Lessons.Select(l => l.SourceId)), "Время меняется без смены устойчивого ID");
        var cross = Parse(Page(Day("31.12", Slot(Card("dec"))) + Day("01.01", Slot(Card("jan")))), new DateOnly(2026, 12, 28));
        expect(cross.CoveredDays.SequenceEqual([new DateOnly(2026, 12, 31), new DateOnly(2027, 1, 1)]), "Граница года");
        var partial = Parse(Page(Day("12.10.2026", Slot(Card("mon"))) + Day("13.10.2026", Slot(Card("tue"))) + Day("14.10.2026", ""), "12.10.2026", "18.10.2026"));
        expect(partial.Lessons.Count == 2 && partial.CoveredDays.Count == 3, "Частичная неделя принимается, остаток не очищается");
        expect(Parse(Page("занятий нет", "12.10.2026", "14.10.2026")).CoveredDays.Count == 3, "Явно пустой короткий диапазон");
        expect(Parse(Page(Day("12.10.2026", ""))).Lessons.Count == 0, "Явно пустая дата");
        foreach (var bad in new[]
        {
            "<html><body>Ошибка сервера</body></html>", Page(""), Page("Ошибка сервера", "12.10.2026", "18.10.2026"),
            Page(Day("12.10.2026", "Ошибка сервера")), Page(Day("19.10.2026", Slot(Card("wrong")))),
            Page("", "19.10.2026", "25.10.2026"), Page(Day("29.02.2027", "")), Page(Day("12.10.2026", "") + Day("12.10.2026", "")),
            Page(Day("12.10.2026", Slot(Card("bad"), "25:99"))), Page(Day("12.10.2026", Slot(Card("empty", " ")))),
            Page(Day("12.10.2026", Slot(Card("same")) + Slot(Card("same"), "10:00"))),
            sample.Replace("sch-list-week-even", ""), sample.Replace("sch-list-week-even", "sch-list-week-even sch-list-week-odd"),
            sample.Replace("sch-list-item-week week-all", "sch-list-item-week week-even week-odd"),
            Page(Day("12.10.2026", Slot(Card("unknown-subgroup", subgroup: "неизвестно")))),
            Page(Day("12.10.2026", Slot(Card("unknown-suffix", subgroup: "1 неизвестно")))),
            sample.Replace("schcls-item schcls-card", "unknown-layout"), "<!DOCTYPE html [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>" + sample
        }) Reject("Поврежденная/чужая разметка не очищает расписание", () => Parse(bad));
        Reject("Чужая группа не импортируется", () => Parse(sample, group: "99"));
        var inert = Parse(sample.Replace("<body>", "<body><script>throw 'not executed'</script><iframe src='https://example.invalid/'></iframe>"));
        expect(inert.Lessons.SequenceEqual(parsed.Lessons), "Скрипты и ресурсы не исполняются");
        foreach (var path in new[] { "/raspisanie", "/raspisanie/podrazdelenie/683", "/raspisanie/grup/42", "/raspisanie/grup/42/29.02.2028/" })
            expect(IstuFetchPolicy.UrlFor(path).Host == "www.istu.edu", "Разрешенные пути сайта");
        foreach (var path in new[] { "https://evil.invalid/", "//evil.invalid", "/raspisanie?x=1", "/raspisanie#x", "/raspisanie/../", "/raspisanie/grup/42/29.02.2027/", "/raspisanie/grup/42/01.01.0000/", "/raspisanie/grup/42/%31.10.2026/", "/raspisanie/grup/42/13.10.2026/?x=1" })
            Reject("Произвольный сетевой адрес запрещен", () => IstuFetchPolicy.UrlFor(path));
    }
}
