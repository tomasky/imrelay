// HTTP transport shared by every adapter.
//
// Wraps `moonbitlang/async`'s HTTP client with JSON/text ergonomics: a plain
// `Map[String, String]` header API, typed errors, and one automatic retry on
// transient (connection-level) failures — mirroring Hermes' `_send_with_retry`
// in `gateway/platforms/base.py`.

///|
/// A failed raw HTTP exchange.
pub(all) struct ApiError {
  /// HTTP status code, or -1 when the connection itself failed.
  code : Int32
  /// Response/error body (truncated for logs).
  body : String
} derive(Debug)

///|
pub fn ApiError::network(body : String) -> ApiError {
  { code: -1, body, }
}

///|
/// An HTTP-level failure (`code` is the status code).
pub fn ApiError::http(code : Int32, body : String) -> ApiError {
  { code, body, }
}

///|
pub fn ApiError::is_transient(self : ApiError) -> Bool {
  self.code < 0 || classify_send_error(self.body) == Transient
}

///|
/// Convert a plain header map into the case-insensitive map the async HTTP
/// client expects.
pub fn headers_of(
  headers : Map[String, String],
) -> Map[@http.CaseInsensitiveString, String] {
  let out : Map[@http.CaseInsensitiveString, String] = Map([])
  for k, v in headers {
    out.set(@http.CaseInsensitiveString(k), v)
  }
  out
}

///|
/// Perform one HTTP exchange and return the raw response body text on 2xx.
pub async fn request_text(
  meth : @http.RequestMethod,
  url : String,
  body : String,
  headers : Map[String, String],
) -> Result[String, ApiError] {
  let (resp, data) = @http.request(url, meth, headers_of(headers), body) catch {
    _ => return Err(ApiError::network("connection failed: \{url}"))
  }
  let text = data.text() catch { _ => "" }
  if resp.code >= 200 && resp.code < 300 {
    Ok(text)
  } else {
    Err({ code: resp.code, body: truncate(text, 200), })
  }
}

///|
/// Perform one HTTP exchange and decode the response body as JSON. An empty
/// 2xx body decodes to `Json::null()`.
pub async fn request_json(
  meth : @http.RequestMethod,
  url : String,
  body : String,
  headers : Map[String, String],
) -> Result[Json, ApiError] {
  match request_text(meth, url, body, headers) {
    Err(e) => Err(e)
    Ok(text) =>
      if text.is_blank() {
        Ok(Json::null())
      } else {
        Ok(@json.parse(text)) catch {
          _ => Err({ code: 200, body: "invalid JSON response", })
        }
      }
  }
}

///|
/// POST ``payload`` as JSON; returns the decoded JSON body on 2xx.
pub async fn post_json(
  url : String,
  payload : Json,
  headers : Map[String, String],
) -> Result[Json, ApiError] {
  request_json(@http.Post, url, payload.stringify(), headers)
}

///|
/// PUT ``payload`` as JSON; returns the decoded JSON body on 2xx.
pub async fn put_json(
  url : String,
  payload : Json,
  headers : Map[String, String],
) -> Result[Json, ApiError] {
  request_json(@http.Put, url, payload.stringify(), headers)
}

///|
/// PATCH ``payload`` as JSON; returns the decoded JSON body on 2xx.
pub async fn patch_json(
  url : String,
  payload : Json,
  headers : Map[String, String],
) -> Result[Json, ApiError] {
  request_json(@http.Patch, url, payload.stringify(), headers)
}

///|
/// GET a JSON endpoint; returns the decoded JSON body on 2xx.
pub async fn get_json(
  url : String,
  headers : Map[String, String],
) -> Result[Json, ApiError] {
  request_json(@http.Get, url, "", headers)
}

///|
/// POST a JSON payload and return the raw text body (XML/plain platforms).
pub async fn post_text(
  url : String,
  payload : Json,
  headers : Map[String, String],
) -> Result[String, ApiError] {
  request_text(@http.Post, url, payload.stringify(), headers)
}

///|
/// Raw response: status code, response headers and the body as bytes.
pub(all) struct RawHttpResult {
  code : Int32
  headers : Map[@http.CaseInsensitiveString, String]
  body_bytes : Bytes
} derive(Debug)

///|
/// One HTTP exchange returning status + headers + raw body bytes (the
/// WeChat CDN paths need the `x-encrypted-param` response header, which the
/// text/json helpers drop).
pub async fn request_raw(
  meth : @http.RequestMethod,
  url : String,
  body : Bytes,
  headers : Map[String, String],
) -> Result[RawHttpResult, ApiError] {
  let (resp, data) = @http.request(url, meth, headers_of(headers), body) catch {
    _ => return Err(ApiError::network("connection failed: \{url}"))
  }
  let bytes = data.binary()
  Ok({ code: resp.code, headers: resp.headers, body_bytes: bytes, })
}

///|
/// GET a URL and return the raw body bytes on 2xx.
pub async fn get_bytes(
  url : String,
  headers : Map[String, String],
) -> Result[Bytes, ApiError] {
  match request_raw(@http.Get, url, Bytes::new(0), headers) {
    Err(e) => Err(e)
    Ok(r) =>
      if r.code >= 200 && r.code < 300 {
        Ok(r.body_bytes)
      } else {
        Err({ code: r.code, body: truncate(r.body_bytes.to_string(), 200), })
      }
  }
}

///|
/// POST an opaque byte body (`Content-Type: application/octet-stream`) and
/// return the raw result — Web/WeChat CDN uploads return the confirmation in
/// a response header rather than the body.
pub async fn post_octet(
  url : String,
  body : Bytes,
  headers : Map[String, String],
) -> Result[RawHttpResult, ApiError] {
  request_raw(@http.Post, url, body, headers)
}

///|
/// DELETE an endpoint (many platforms accept an optional JSON body).
pub async fn delete_json(
  url : String,
  payload : Json,
  headers : Map[String, String],
) -> Result[String, ApiError] {
  request_text(@http.Delete, url, payload.stringify(), headers)
}

///|
/// DELETE an endpoint with no body.
pub async fn delete_empty(
  url : String,
  headers : Map[String, String],
) -> Result[String, ApiError] {
  request_text(@http.Delete, url, "", headers)
}
