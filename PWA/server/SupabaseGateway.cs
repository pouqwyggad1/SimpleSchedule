using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace SimpleSchedule.Pwa;

public sealed class SupabaseGateway
{
    public const int EmailResendIntervalSeconds = 60;
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private readonly HttpClient http;
    private readonly string? url;
    private readonly string? publishable;
    private readonly string? service;
    public bool Configured { get; }
    public bool WorkerConfigured => Configured;

    public SupabaseGateway(HttpClient http, IConfiguration config)
    {
        this.http = http;
        url = config["Supabase:Url"]?.TrimEnd('/');
        publishable = config["Supabase:PublishableKey"];
        service = config["Supabase:ServiceRoleKey"];
        Configured = Uri.TryCreate(url, UriKind.Absolute, out var parsed) && parsed.Scheme == "https" &&
            parsed.UserInfo.Length == 0 && parsed.Query.Length == 0 && parsed.AbsolutePath == "/" &&
            !string.IsNullOrWhiteSpace(publishable) && !string.IsNullOrWhiteSpace(service);
    }

    public async Task<JsonNode?> Send(string path, object? body, string? token, bool privileged, CancellationToken ct, HttpMethod? method = null)
    {
        if (!Configured) throw new ApiException(503, "Синхронизация ещё не настроена на сервере. Локальные данные доступны.");
        using var request = new HttpRequestMessage(method ?? HttpMethod.Post, url + path);
        request.Headers.Add("apikey", privileged ? service : publishable);
        if (token != null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        else if (privileged && service!.StartsWith("eyJ", StringComparison.Ordinal))
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", service);
        if (body != null) request.Content = JsonContent.Create(body, options: Json);
        using var response = await http.SendAsync(request, ct);
        if (!response.IsSuccessStatusCode)
        {
            var status = response.StatusCode switch
            {
                HttpStatusCode.Unauthorized => 401,
                HttpStatusCode.TooManyRequests => 429,
                HttpStatusCode.BadRequest or HttpStatusCode.UnprocessableEntity => 400,
                _ => 502
            };
            string? code = null;
            if (status == 429)
            {
                // Translate only the provider's public error code. Never relay its raw
                // response, which can include account details or internal diagnostics.
                try
                {
                    var error = await response.Content.ReadFromJsonAsync<JsonObject>(Json, ct);
                    if (error?["code"] is JsonValue value && value.TryGetValue<string>(out var providerCode)) code = providerCode;
                }
                catch (JsonException) { }
            }
            string message = status switch
            {
                401 => "Сессия истекла. Войдите по почте снова.",
                429 when code == "over_email_send_rate_limit" => "Почтовый сервис временно ограничил отправку кодов. Повторите попытку позже.",
                429 => "Слишком много запросов. Подождите немного и повторите.",
                400 when path.Contains("/auth/", StringComparison.Ordinal) => "Код неверен или истёк. Запросите новый код и проверьте настройки почты.",
                400 => "Изменения не приняты сервером. Обновите приложение и повторите синхронизацию.",
                _ => "Облачный сервис временно недоступен. Локальные изменения сохранены."
            };
            var retryAfter = response.Headers.RetryAfter;
            double? delay = retryAfter?.Delta?.TotalSeconds ?? (retryAfter?.Date - DateTimeOffset.UtcNow)?.TotalSeconds;
            int? retryAfterSeconds = status == 429
                ? delay is { } seconds ? (int)Math.Clamp(Math.Ceiling(seconds), 1, 86_400) : EmailResendIntervalSeconds
                : null;
            throw new ApiException(status, message, retryAfterSeconds);
        }
        if (response.StatusCode == HttpStatusCode.NoContent) return null;
        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        if (response.Content.Headers.ContentLength == 0) return null;
        try { return await JsonNode.ParseAsync(stream, cancellationToken: ct); }
        catch (JsonException) { throw new ApiException(502, "Облачный сервис вернул неподходящий ответ."); }
    }

    public async Task RequestCode(string email, CancellationToken ct) =>
        _ = await Send("/auth/v1/otp", new { email, create_user = true }, null, false, ct);

    public async Task<TokenSet> Verify(string email, string code, CancellationToken ct) =>
        Tokens(await Send("/auth/v1/verify", new { email, token = code, type = "email" }, null, false, ct));

    public async Task<TokenSet> Refresh(string refresh, CancellationToken ct) =>
        Tokens(await Send("/auth/v1/token?grant_type=refresh_token", new { refresh_token = refresh }, null, false, ct));

    public async Task Logout(string token, CancellationToken ct) =>
        _ = await Send("/auth/v1/logout?scope=local", null, token, false, ct);

    public async Task<SyncReply> Sync(string token, List<SyncOperation> ops, CancellationToken ct)
    {
        var result = await Send("/rest/v1/rpc/pwa_sync", new { p_operations = ops }, token, false, ct);
        return result?.Deserialize<SyncReply>(Json) ?? throw new ApiException(502, "Не удалось прочитать снимок данных.");
    }

    public Task<JsonNode?> ServiceRpc(string name, object args, CancellationToken ct) =>
        Send("/rest/v1/rpc/" + name, args, null, true, ct);

    private static TokenSet Tokens(JsonNode? result)
    {
        if (result?["access_token"]?.GetValue<string>() is not { } access ||
            result["refresh_token"]?.GetValue<string>() is not { } refresh ||
            result["user"]?["id"]?.GetValue<string>() is not { } id)
            throw new ApiException(502, "Сервис входа вернул неподходящий ответ.");
        var expires = result["expires_at"]?.GetValue<long>() ??
            DateTimeOffset.UtcNow.ToUnixTimeSeconds() + (result["expires_in"]?.GetValue<long>() ?? 3600);
        return new(access, refresh, expires, new(id, result["user"]?["email"]?.GetValue<string>() ?? ""));
    }
}
