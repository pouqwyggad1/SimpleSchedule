using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.RateLimiting;
using SimpleSchedule.Pwa;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(o => o.Limits.MaxRequestBodySize = 2_000_000);
builder.Services.ConfigureHttpJsonOptions(o => { o.SerializerOptions.MaxDepth = 32; });
builder.Services.AddMemoryCache();
builder.Services.AddHttpClient("supabase", c => c.Timeout = TimeSpan.FromSeconds(25));
builder.Services.AddHttpClient("university", c => c.Timeout = TimeSpan.FromSeconds(25))
    .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
    {
        AllowAutoRedirect = false, UseCookies = false, Credentials = null, PreAuthenticate = false,
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli,
        ConnectTimeout = TimeSpan.FromSeconds(12), MaxResponseHeadersLength = 32, MaxConnectionsPerServer = 2
    });
builder.Services.AddSingleton(sp => new SupabaseGateway(sp.GetRequiredService<IHttpClientFactory>().CreateClient("supabase"), sp.GetRequiredService<IConfiguration>()));
builder.Services.AddSingleton<SessionService>();
builder.Services.AddSingleton(sp => new UniversityService(sp.GetRequiredService<IHttpClientFactory>().CreateClient("university"), sp.GetRequiredService<Microsoft.Extensions.Caching.Memory.IMemoryCache>()));
builder.Services.AddSingleton<ScheduleWorker>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<ScheduleWorker>());
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = 429;
    o.OnRejected = async (context, ct) => await context.HttpContext.Response.WriteAsJsonAsync(new { error = "Слишком много запросов. Подождите немного." }, ct);
    foreach (var (name, permits, minutes) in new[] { ("auth-send", 4, 10), ("auth-verify", 12, 10), ("refresh", 3, 1), ("lists", 30, 1), ("sync", 120, 1) })
        o.AddPolicy(name, ctx => RateLimitPartition.GetFixedWindowLimiter(ctx.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            _ => new FixedWindowRateLimiterOptions { PermitLimit = permits, Window = TimeSpan.FromMinutes(minutes), QueueLimit = 0, AutoReplenishment = true }));
});

var app = builder.Build();
// Configure a canonical HTTPS PublicOrigin behind Render. Never trust arbitrary forwarded hosts.
// Only X-Forwarded-Proto affects secure cookie detection; the canonical Origin comparison below
// does not derive an allowlist from proxy headers.
app.UseForwardedHeaders(new ForwardedHeadersOptions { ForwardedHeaders = ForwardedHeaders.XForwardedProto });
app.Use(async (context, next) =>
{
    context.Response.Headers.XContentTypeOptions = "nosniff";
    context.Response.Headers["Referrer-Policy"] = "no-referrer";
    context.Response.Headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()";
    context.Response.Headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; worker-src 'self'; manifest-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'";
    if (context.Request.Path.StartsWithSegments("/api")) context.Response.Headers.CacheControl = "no-store";
    try
    {
        if (context.Request.Method is "POST" or "PUT" or "PATCH" or "DELETE" && context.Request.Path != "/api/jobs/run")
        {
            string expected = app.Configuration["PublicOrigin"]?.TrimEnd('/') ?? "";
            if (expected.Length == 0 && app.Environment.IsDevelopment())
                expected = context.Request.Scheme + "://" + context.Request.Host;
            if (!Uri.TryCreate(expected, UriKind.Absolute, out var origin) ||
                (!app.Environment.IsDevelopment() && origin.Scheme != "https") ||
                context.Request.Headers.Origin.Count != 1 || context.Request.Headers.Origin.ToString() != expected)
                throw new ApiException(403, "Запрос отклонён: откройте приложение по его основному адресу.");
            if (!context.Request.HasJsonContentType()) throw new ApiException(415, "Ожидается запрос JSON.");
            if (context.Request.Headers["Sec-Fetch-Site"] == "cross-site") throw new ApiException(403, "Запрос с другого сайта запрещён.");
        }
        await next();
    }
    catch (ApiException error) { context.Response.StatusCode = error.Status; await context.Response.WriteAsJsonAsync(new { error = error.Message }); }
    catch (Exception error) when (error is ArgumentException or InvalidDataException or System.Text.Json.JsonException or BadHttpRequestException)
    { context.Response.StatusCode = 400; await context.Response.WriteAsJsonAsync(new { error = "Некорректный запрос или изменилась разметка расписания. Сохранённые данные доступны." }); }
    catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested) { }
    catch (Exception)
    { context.Response.StatusCode = 503; await context.Response.WriteAsJsonAsync(new { error = "Сервис временно недоступен. Локальные изменения сохранены, повторите позже." }); }
});
app.UseRateLimiter();
app.UseDefaultFiles();
app.UseStaticFiles(new StaticFileOptions { OnPrepareResponse = ctx =>
{
    if (ctx.File.Name is "sw.js" or "index.html" or "manifest.webmanifest") ctx.Context.Response.Headers.CacheControl = "no-cache";
} });

app.MapGet("/api/health", (SessionService sessions, ScheduleWorker worker) => Results.Ok(new { status = "ok", authConfigured = sessions.Configured, automaticRefreshConfigured = worker.Configured, notificationsConfigured = false }));
app.MapGet("/health", () => Results.Ok(new { status = "ok" }));
app.MapGet("/api/auth/session", async (HttpContext ctx, SessionService sessions, CancellationToken ct) =>
{
    var tokens = await sessions.Get(ctx, ct);
    return Results.Ok(new { configured = sessions.Configured, user = tokens?.User });
});
app.MapPost("/api/auth/request-code", async (EmailRequest body, SessionService sessions, SupabaseGateway gateway, CancellationToken ct) =>
{
    sessions.RequireConfigured(); await gateway.RequestCode(Validation.Email(body.Email), ct); return Results.Ok(new { sent = true });
}).RequireRateLimiting("auth-send");
app.MapPost("/api/auth/verify-code", async (VerifyRequest body, HttpContext ctx, SessionService sessions, SupabaseGateway gateway, CancellationToken ct) =>
{
    sessions.RequireConfigured();
    if (body.Code is null || !System.Text.RegularExpressions.Regex.IsMatch(body.Code, "\\A[0-9]{6}\\z")) throw new ApiException(400, "Введите шестизначный код из письма.");
    var tokens = await gateway.Verify(Validation.Email(body.Email), body.Code, ct);
    await sessions.Create(ctx, tokens, ct); return Results.Ok(new { user = tokens.User });
}).RequireRateLimiting("auth-verify");
app.MapPost("/api/auth/sign-out", async (HttpContext ctx, SessionService sessions, CancellationToken ct) => { await sessions.SignOut(ctx, ct); return Results.Ok(new { signedOut = true }); });
app.MapGet("/api/sync", async (HttpContext ctx, SessionService sessions, SupabaseGateway gateway, CancellationToken ct) =>
{
    var tokens = await sessions.Get(ctx, ct) ?? throw new ApiException(401, "Войдите по почте, чтобы включить синхронизацию.");
    SessionService.GuardAccount(ctx, tokens);
    return Results.Ok(await gateway.Sync(tokens.AccessToken, [], ct));
}).RequireRateLimiting("sync");
app.MapPost("/api/sync", async (SyncRequest body, HttpContext ctx, SessionService sessions, SupabaseGateway gateway, CancellationToken ct) =>
{
    Validation.Operations(body.Operations);
    var tokens = await sessions.Get(ctx, ct) ?? throw new ApiException(401, "Войдите по почте, чтобы включить синхронизацию.");
    SessionService.GuardAccount(ctx, tokens);
    return Results.Ok(await gateway.Sync(tokens.AccessToken, body.Operations, ct));
}).RequireRateLimiting("sync");
app.MapGet("/api/university/institutes", async (UniversityService university, CancellationToken ct) => Results.Ok(new { options = await university.Institutes(ct) })).RequireRateLimiting("lists");
app.MapGet("/api/university/groups", async (string instituteId, UniversityService university, CancellationToken ct) => Results.Ok(new { options = await university.Groups(instituteId, ct) })).RequireRateLimiting("lists");
app.MapPost("/api/schedule/refresh", async (RefreshRequest body, UniversityService university, CancellationToken ct) => Results.Ok(await university.Refresh(body, ct))).RequireRateLimiting("refresh");
app.MapPost("/api/jobs/run", async (HttpContext ctx, ScheduleWorker worker, CancellationToken ct) =>
{
    var secret = app.Configuration["Jobs:Secret"];
    string supplied = ctx.Request.Headers.Authorization.ToString();
    if (string.IsNullOrEmpty(secret) || secret.Length < 32 ||
        !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes("Bearer " + secret), Encoding.UTF8.GetBytes(supplied)))
        return Results.Unauthorized();
    return Results.Ok(new { processed = await worker.RunOnce(ct) });
});
app.MapFallback(async ctx =>
{
    if (ctx.Request.Path.StartsWithSegments("/api")) { ctx.Response.StatusCode = 404; await ctx.Response.WriteAsJsonAsync(new { error = "Неизвестный адрес API." }); return; }
    var file = Path.Combine(app.Environment.WebRootPath ?? Path.Combine(app.Environment.ContentRootPath, "wwwroot"), "index.html");
    if (!File.Exists(file)) { ctx.Response.StatusCode = 404; await ctx.Response.WriteAsync("PWA client is not built. Build PWA/client and copy dist to server/wwwroot."); return; }
    ctx.Response.ContentType = "text/html; charset=utf-8"; ctx.Response.Headers.CacheControl = "no-cache"; await ctx.Response.SendFileAsync(file);
});
app.Run();

public partial class Program { }
