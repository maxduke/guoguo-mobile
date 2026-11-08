package app

import (
	"context"
	"errors"
)

// Only refusals from Hongguo registration/model endpoints stop later lookups.
// A CDN transfer failure or a single unavailable episode never gets this type.
type hongguoSourceRefusal struct{ cause error }

func (e *hongguoSourceRefusal) Error() string { return e.cause.Error() }
func (e *hongguoSourceRefusal) Unwrap() error { return e.cause }
func isHongguoSourceRefusal(err error) bool {
	var refusal *hongguoSourceRefusal
	return errors.As(err, &refusal)
}

func traceHongguoStage(ctx context.Context, stage string) {
	traceUpdate(ctx, func(v *mobileDiagnostic) {
		v.SourceStage = stage
		v.SourceFailure = ""
		v.ResponseBytes = 0
		v.HTTPStatus = 0
	})
}
func traceHongguoFailure(ctx context.Context, reason string) {
	traceUpdate(ctx, func(v *mobileDiagnostic) { v.SourceFailure = reason })
}
func hongguoRefused(ctx context.Context, reason string, cause error) error {
	traceHongguoFailure(ctx, reason)
	return &hongguoSourceRefusal{cause: cause}
}
func hongguoHTTPRefusal(ctx context.Context, status int, cause error) error {
	switch status {
	case 403:
		traceUpdate(ctx, func(v *mobileDiagnostic) { v.HTTPStatus = status })
		return hongguoRefused(ctx, "http_denied", cause)
	case 429:
		traceUpdate(ctx, func(v *mobileDiagnostic) { v.HTTPStatus = status })
		return hongguoRefused(ctx, "rate_limited", cause)
	}
	traceHongguoFailure(ctx, "http_error")
	return cause
}
