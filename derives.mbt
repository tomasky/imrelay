// Explicit `extend` declarations for every derived trait method.
//
// MoonBit is deprecating the implicit promotion of derived `impl` methods
// (`to_repr`, `equal`, `hash`, …) into regular methods on the type; these
// declarations keep the derived impls and silence the migration warning.

///|
pub extend Platform with Eq::{not_equal, equal}

///|
pub extend Platform with Hash::{hash, hash_combine}

///|
pub extend Platform with @debug.Debug::{to_repr}

///|
pub extend MessageType with Eq::{not_equal, equal}

///|
pub extend MessageType with @debug.Debug::{to_repr}

///|
pub extend SendErrorKind with Eq::{not_equal, equal}

///|
pub extend SendErrorKind with @debug.Debug::{to_repr}

///|
pub extend SendResult with @debug.Debug::{to_repr}

///|
pub extend HomeChannel with @debug.Debug::{to_repr}

///|
pub extend ChatInfo with @debug.Debug::{to_repr}

///|
pub extend MediaAttachment with @debug.Debug::{to_repr}

///|
pub extend MessageEvent with @debug.Debug::{to_repr}

///|
pub extend ApiError with @debug.Debug::{to_repr}

///|
pub extend PlatformConfig with @debug.Debug::{to_repr}

///|
pub extend GatewayConfig with @debug.Debug::{to_repr}

///|
pub extend SmtpConfig with @debug.Debug::{to_repr}

///|
pub extend Session with @debug.Debug::{to_repr}

///|
pub extend SessionStore with @debug.Debug::{to_repr}

///|
pub extend Gateway with @debug.Debug::{to_repr}

///|
pub extend HubParams with @debug.Debug::{to_repr}

///|
pub extend RawHttpResult with @debug.Debug::{to_repr}

///|
pub extend DingtalkToken with @debug.Debug::{to_repr}

///|
pub extend DingtalkChatSession with @debug.Debug::{to_repr}

///|
pub extend DingtalkStreamFrame with @debug.Debug::{to_repr}
