using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace SimpleSchedule.Pwa;

// The browser holds an opaque random ID. Access/refresh tokens remain encrypted in the
// server-only database table; changing EncryptionKey signs every device out.
public sealed class SessionService
{
    private const string Cookie = "ss_session";
    private readonly SupabaseGateway gateway;
    private readonly byte[]? key;
    public bool Configured => gateway.Configured && key != null;

    public SessionService(SupabaseGateway gateway, IConfiguration config)
    {
        this.gateway = gateway;
        try { key = Convert.FromBase64String(config["Session:EncryptionKey"] ?? ""); }
        catch (FormatException) { }
        if (key?.Length != 32) key = null;
    }

    public async Task Create(HttpContext context, TokenSet tokens, CancellationToken ct)
    {
        RequireConfigured();
        var id = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
        var expires = DateTimeOffset.UtcNow.AddDays(30);
        await gateway.ServiceRpc("pwa_session_create", new { p_id = Hash(id), p_payload = Encrypt(tokens), p_expires = expires }, ct);
        context.Response.Cookies.Append(Cookie, id, Options(context, expires));
    }

    public async Task<TokenSet?> Get(HttpContext context, CancellationToken ct)
    {
        if (!Configured || !context.Request.Cookies.TryGetValue(Cookie, out var id) ||
            !Regex.IsMatch(id, "\\A[0-9a-f]{64}\\z")) return null;
        var hash = Hash(id);
        var lease = Guid.NewGuid();
        string? cipher = null;
        for (int i = 0; i < 8; i++)
        {
            var result = await gateway.ServiceRpc("pwa_session_claim", new { p_id = hash, p_lease = lease }, ct);
            if (result?["missing"]?.GetValue<bool>() == true) { context.Response.Cookies.Delete(Cookie, Options(context)); return null; }
            cipher = result?["payload"]?.GetValue<string>();
            if (cipher != null) break;
            await Task.Delay(100 + i * 80, ct);
        }
        if (cipher == null) throw new ApiException(503, "Вход обновляется. Повторите запрос через несколько секунд.");
        TokenSet? tokens = null;
        try
        {
            tokens = Decrypt(cipher);
            if (tokens.ExpiresAt < DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 90)
                tokens = await gateway.Refresh(tokens.RefreshToken, ct);
            await gateway.ServiceRpc("pwa_session_release", new { p_id = hash, p_lease = lease, p_payload = Encrypt(tokens) }, ct);
            return tokens;
        }
        catch (Exception error) when (error is CryptographicException or JsonException or FormatException || error is ApiException { Status: 401 or 400 })
        {
            await gateway.ServiceRpc("pwa_session_remove", new { p_id = hash }, ct);
            context.Response.Cookies.Delete(Cookie, Options(context));
            return null;
        }
        catch
        {
            // Do not overwrite a rotated token with the pre-refresh version on network ambiguity.
            await gateway.ServiceRpc("pwa_session_release", new { p_id = hash, p_lease = lease, p_payload = (string?)null }, CancellationToken.None);
            throw;
        }
    }

    public async Task SignOut(HttpContext context, CancellationToken ct)
    {
        try
        {
            var tokens = await Get(context, ct);
            if (tokens != null)
            {
                try { await gateway.Logout(tokens.AccessToken, ct); }
                finally
                {
                    if (context.Request.Cookies.TryGetValue(Cookie, out var id))
                        await gateway.ServiceRpc("pwa_session_remove", new { p_id = Hash(id) }, ct);
                }
            }
        }
        finally { context.Response.Cookies.Delete(Cookie, Options(context)); }
    }

    public void RequireConfigured()
    {
        if (!Configured) throw new ApiException(503, "Вход ещё не настроен на сервере. Можно пользоваться приложением локально.");
    }

    public static void GuardAccount(HttpContext context, TokenSet tokens)
    {
        // Another tab may have replaced the shared cookie with a different account.
        // This header only detects mismatch; the verified session determines identity.
        if (context.Request.Headers["X-SimpleSchedule-Account"].ToString() != tokens.User.Id)
            throw new ApiException(409, "Аккаунт изменён в другой вкладке. Откройте приложение заново; локальные правки сохранены.");
    }

    public static string? SessionId(HttpContext context) => context.Request.Cookies.TryGetValue(Cookie, out var id) ? Hash(id) : null;

    private static CookieOptions Options(HttpContext context, DateTimeOffset? expires = null) => new()
    {
        HttpOnly = true, Secure = context.Request.IsHttps || !context.RequestServices.GetRequiredService<IWebHostEnvironment>().IsDevelopment(),
        SameSite = SameSiteMode.Strict, Path = "/api", Expires = expires, IsEssential = true
    };
    private static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
    private string Encrypt(TokenSet tokens)
    {
        var clear = JsonSerializer.SerializeToUtf8Bytes(tokens, SupabaseGateway.Json);
        var nonce = RandomNumberGenerator.GetBytes(12);
        var cipher = new byte[clear.Length]; var tag = new byte[16];
        using var aes = new AesGcm(key!, 16);
        aes.Encrypt(nonce, clear, cipher, tag, "SimpleSchedule.PWA.sessions.v1"u8);
        CryptographicOperations.ZeroMemory(clear);
        return Convert.ToBase64String(nonce.Concat(tag).Concat(cipher).ToArray());
    }
    private TokenSet Decrypt(string value)
    {
        var encrypted = Convert.FromBase64String(value);
        if (encrypted.Length < 29) throw new CryptographicException();
        var clear = new byte[encrypted.Length - 28];
        using var aes = new AesGcm(key!, 16);
        aes.Decrypt(encrypted.AsSpan(0, 12), encrypted.AsSpan(28), encrypted.AsSpan(12, 16), clear, "SimpleSchedule.PWA.sessions.v1"u8);
        try { return JsonSerializer.Deserialize<TokenSet>(clear, SupabaseGateway.Json) ?? throw new CryptographicException(); }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }
}
