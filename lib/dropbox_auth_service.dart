// dropbox_auth_service.dart
// Scratchpad の Dropbox 認証 (PKCE + Cloudflare Workers プロキシ) をベースに Web 対応を追加。
//  - Android : ローカルHTTPサーバー方式 (127.0.0.1:8080) で code を受け取る
//  - Web     : 同じタブで Dropbox へ移動し、戻ってきた URL の ?code= を処理する
//
// SharedPreferences のキーは、同じ github.io ドメイン上の他アプリ(Scratchpad の Web 版など)と
// 衝突しないよう、すべて "sn_" を付けている。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class DropboxAuthService {
  static const String _workerBaseUrl =
      'https://simplenote-oauth.youm00.workers.dev';
  static const String _authEndpoint =
      'https://www.dropbox.com/oauth2/authorize';
  static const String _appKey = 'r6vfvwn9qrenikk';
  static const String _androidRedirectUri = 'http://127.0.0.1:8080/';

  static const String _keyAccessToken = 'sn_dropbox_access_token';
  static const String _keyRefreshToken = 'sn_dropbox_refresh_token';
  static const String _keyTokenExpiry = 'sn_dropbox_token_expiry';
  static const String _keyPkceVerifier = 'sn_dropbox_pkce_verifier';
  static const int _refreshMarginMinutes = 5;

  // 同時に複数のリクエストがトークン更新を走らせないようにする
  static Future<String?>? _refreshing;

  /// 直近の失敗理由(画面に表示してデバッグしやすくする)
  String? lastError;

  // 直近のトークン交換が「通信エラー」で失敗したか(再試行してよいかの判定用)
  bool _networkError = false;

  /// Android は固定、Web は「今開いているページのURL(クエリ除く)」
  String get _redirectUri {
    if (!kIsWeb) return _androidRedirectUri;
    final b = Uri.base;
    return '${b.origin}${b.path}';
  }

  // ============================================================
  // 公開メソッド
  // ============================================================

  /// 保存済みのログイン情報(リフレッシュトークン)があるか。ネットワーク不要。
  Future<bool> hasLogin() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyRefreshToken) != null;
  }

  Future<String?> getValidAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    final accessToken = prefs.getString(_keyAccessToken);
    final refreshToken = prefs.getString(_keyRefreshToken);
    final expiryMs = prefs.getInt(_keyTokenExpiry);

    if (accessToken == null || refreshToken == null || expiryMs == null) {
      return null;
    }

    final expiry = DateTime.fromMillisecondsSinceEpoch(expiryMs);
    final threshold =
        DateTime.now().add(const Duration(minutes: _refreshMarginMinutes));
    if (expiry.isAfter(threshold)) return accessToken;

    return _refreshing ??= _refreshAccessToken(refreshToken)
        .whenComplete(() => _refreshing = null);
  }

  /// Web版: Dropbox から戻ってきた直後の URL に code があれば、トークン交換する。
  /// main() の最初に呼ぶ。
  Future<void> handleWebRedirect() async {
    if (!kIsWeb) return;
    final code = Uri.base.queryParameters['code'];
    if (code == null) return;
    final prefs = await SharedPreferences.getInstance();
    final verifier = prefs.getString(_keyPkceVerifier);
    if (verifier == null) return;
    await prefs.remove(_keyPkceVerifier);
    await _exchangeCodeForTokens(code, verifier);
  }

  /// OAuth2 認証フロー (PKCE)。
  /// Android: 認証完了で true を返す。
  /// Web    : ページ遷移するため、ここには戻ってこない(false を返す)。
  Future<bool> authenticate() async {
    lastError = null;
    final verifier = _generateCodeVerifier();
    final challenge = _generateCodeChallenge(verifier);

    final authUri = Uri.parse(
      '$_authEndpoint'
      '?client_id=$_appKey'
      '&response_type=code'
      '&redirect_uri=${Uri.encodeComponent(_redirectUri)}'
      '&token_access_type=offline'
      '&code_challenge=${Uri.encodeComponent(challenge)}'
      '&code_challenge_method=S256',
    );

    // ---------- Web ----------
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyPkceVerifier, verifier);
      await launchUrl(authUri, webOnlyWindowName: '_self');
      return false;
    }

    // ---------- Android (ローカルHTTPサーバー方式) ----------
    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8080);
    } catch (e) {
      debugPrint('[DropboxAuth] サーバー起動失敗: $e');
      lastError = 'ローカルサーバー(127.0.0.1:8080)を起動できません: $e';
      return false;
    }

    final launched =
        await launchUrl(authUri, mode: LaunchMode.externalApplication);
    if (!launched) {
      await server.close(force: true);
      debugPrint('[DropboxAuth] ブラウザを開けませんでした');
      lastError = 'ブラウザを開けませんでした';
      return false;
    }

    String? code;
    try {
      await for (final request in server.timeout(const Duration(minutes: 3))) {
        final c = request.uri.queryParameters['code'];
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(c != null
              ? '<!DOCTYPE html><html><head><meta charset="utf-8"><title>認証完了</title></head>'
                  '<body style="font-family:sans-serif;text-align:center;padding-top:60px;">'
                  '<h2>✅ 認証完了</h2><p>アプリに戻ってください。</p></body></html>'
              : '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body></body></html>');
        await request.response.close();
        if (c != null) {
          code = c;
          break;
        }
      }
    } on TimeoutException {
      debugPrint('[DropboxAuth] タイムアウト(3分)');
      lastError = 'タイムアウト(3分)。ブラウザで許可する前に時間切れになりました';
    } catch (e) {
      debugPrint('[DropboxAuth] コールバック受信エラー: $e');
      lastError = 'コールバック受信エラー: $e';
    } finally {
      await server.close(force: true);
    }

    if (code == null) {
      lastError ??= '認証コードを受け取れませんでした';
      return false;
    }
    // (1) アプリが前面に戻るまで待つ。
    //     ブラウザが前面にいる間(アプリが裏にいる間)は、端末によって通信が止められるため。
    for (var i = 0; i < 120; i++) {
      final st = WidgetsBinding.instance.lifecycleState;
      if (st == null || st == AppLifecycleState.resumed) break;
      await Future.delayed(const Duration(milliseconds: 500));
    }
    await Future.delayed(const Duration(milliseconds: 800)); // 通信の復帰待ち

    // (2) トークン交換。"Failed host lookup" のように「送信前に失敗した」場合だけ再試行する。
    //     (認証コードは1回しか使えないため、送信済みかもしれない失敗は再試行しない)
    final log = <String>[];
    for (var attempt = 0; attempt < 10; attempt++) {
      if (await _exchangeCodeForTokens(code, verifier)) return true;
      log.add('#${attempt + 1}: $lastError');
      if (!_networkError) break;
      await Future.delayed(const Duration(seconds: 2));
    }
    lastError = log.join('\n');
    return false;
  }

  Future<void> signOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyAccessToken);
    await prefs.remove(_keyRefreshToken);
    await prefs.remove(_keyTokenExpiry);
    await prefs.remove(_keyPkceVerifier);
  }

  // ============================================================
  // 非公開メソッド
  // ============================================================

  Future<bool> _exchangeCodeForTokens(String code, String verifier) async {
    _networkError = false;
    try {
      final response = await http.post(
        Uri.parse('$_workerBaseUrl/token/exchange'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'code': code,
          'redirect_uri': _redirectUri,
          'code_verifier': verifier,
        }),
      );
      if (response.statusCode != 200) {
        debugPrint(
            '[DropboxAuth] exchange failed ${response.statusCode}: ${response.body}');
        lastError = 'トークン交換に失敗(${response.statusCode}): ${response.body}';
        return false;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      await _saveTokens(data);
      return true;
    } catch (e) {
      debugPrint('[DropboxAuth] exchange error: $e');
      lastError = 'トークン交換エラー: $e';
      _networkError = e.toString().contains('Failed host lookup');
      return false;
    }
  }

  Future<String?> _refreshAccessToken(String refreshToken) async {
    try {
      final response = await http.post(
        Uri.parse('$_workerBaseUrl/token/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': refreshToken}),
      );
      if (response.statusCode != 200) {
        // 認証自体が無効になった場合のみサインアウト(400番台)。
        if (response.statusCode >= 400 && response.statusCode < 500) {
          await signOut();
        }
        return null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      await _saveTokens(data, keepRefreshToken: true);
      return data['access_token'] as String?;
    } catch (e) {
      // ネットワークエラー等: ログイン情報は消さない
      debugPrint('[DropboxAuth] refresh error: $e');
      return null;
    }
  }

  Future<void> _saveTokens(
    Map<String, dynamic> data, {
    bool keepRefreshToken = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final accessToken = data['access_token'] as String?;
    final refreshToken = data['refresh_token'] as String?;
    final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 14400;

    if (accessToken != null) {
      await prefs.setString(_keyAccessToken, accessToken);
    }
    if (!keepRefreshToken && refreshToken != null) {
      await prefs.setString(_keyRefreshToken, refreshToken);
    }
    final expiryMs = DateTime.now()
        .add(Duration(seconds: expiresIn))
        .millisecondsSinceEpoch;
    await prefs.setInt(_keyTokenExpiry, expiryMs);
  }

  // ── PKCE helpers ─────────────────────────────────────────────
  String _generateCodeVerifier() {
    final rand = Random.secure();
    final bytes = List<int>.generate(32, (_) => rand.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  String _generateCodeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }
}