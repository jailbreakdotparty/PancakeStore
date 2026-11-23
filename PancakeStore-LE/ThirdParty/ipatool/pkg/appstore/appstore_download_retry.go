package appstore

import (
	"context"
	"errors"
	"io"
	"net"
	gohttp "net/http"
	"strings"
	"syscall"
	"time"

	"github.com/majd/ipatool/v2/pkg/http"
)

const (
	maxCommerceRequestAttempts = 3
	maxCommerceRetryDelay      = 15 * time.Second
)

func cloneCommerceHeaders(source map[string]string) map[string]string {
	cloned := make(map[string]string, len(source)+4)
	for key, value := range source {
		cloned[key] = value
	}
	return cloned
}

func isRetryableCommerceStatus(status int) bool {
	switch status {
	case gohttp.StatusRequestTimeout, gohttp.StatusTooManyRequests,
		gohttp.StatusInternalServerError, gohttp.StatusBadGateway,
		gohttp.StatusServiceUnavailable, gohttp.StatusGatewayTimeout:
		return true
	default:
		return false
	}
}

func commerceHTTPStatusError(result http.Result[downloadResult]) error {
	status := result.StatusCode
	if !isRetryableCommerceStatus(status) {
		return nil
	}

	return &http.UnexpectedResponseError{
		StatusCode:    status,
		Reason:        strings.ToLower(gohttp.StatusText(status)),
		RetryAfter:    resultHeader(result.Headers, "Retry-After"),
		ContentType:   resultHeader(result.Headers, "Content-Type"),
		CorrelationID: resultHeader(result.Headers, "X-Apple-Jingle-Correlation-Key"),
	}
}

func resultHeader(headers map[string]string, wanted string) string {
	for key, value := range headers {
		if strings.EqualFold(key, wanted) {
			return value
		}
	}
	return ""
}

func commerceRetryDelay(err error, attempt int) (time.Duration, bool) {
	retryAfter := ""
	var responseErr *http.UnexpectedResponseError
	if errors.As(err, &responseErr) {
		if !isRetryableCommerceStatus(responseErr.StatusCode) {
			return 0, false
		}
		retryAfter = responseErr.RetryAfter
	} else {
		var transportErr *http.TransportError
		if !errors.As(err, &transportErr) || errors.Is(err, context.Canceled) {
			return 0, false
		}

		// The HTTP client applies a per-attempt timeout. Retry that timeout while
		// the caller's outer context is still alive; the caller checks ctx.Err()
		// before sleeping or starting another attempt.
		retryable := errors.Is(transportErr, context.DeadlineExceeded) ||
			errors.Is(transportErr, io.EOF) || errors.Is(transportErr, io.ErrUnexpectedEOF) ||
			errors.Is(transportErr, syscall.ECONNRESET) || errors.Is(transportErr, syscall.EPIPE)
		if !retryable {
			for cause := transportErr.Err; cause != nil; cause = errors.Unwrap(cause) {
				if networkErr, ok := cause.(net.Error); ok && networkErr.Timeout() {
					retryable = true
					break
				}
			}
		}
		if !retryable {
			return 0, false
		}
		retryAfter = transportErr.RetryAfter
	}

	fallback := time.Duration(1<<(attempt-1)) * time.Second
	if fallback > 4*time.Second {
		fallback = 4 * time.Second
	}

	if requested, ok := authenticationRetryAfter(retryAfter, time.Now()); ok {
		if requested > maxCommerceRetryDelay {
			return 0, false
		}
		if requested > fallback {
			fallback = requested
		}
	}

	if fallback < time.Second {
		fallback = time.Second
	}
	return fallback, true
}

func (t *appstore) waitForCommerceRetry(ctx context.Context, delay time.Duration) error {
	if t.commerceRetrySleep != nil {
		return t.commerceRetrySleep(ctx, delay)
	}

	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
