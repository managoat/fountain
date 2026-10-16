package layers

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"time"
)

// Upload sends a bounded, already sealed object to exactly the configured
// HTTPS origin. It never follows redirects or inherits broker credentials.
func Upload(ctx context.Context, signedURL, origin, source, expected string, limits Limits) (Result, error) {
	transport := &http.Transport{Proxy: nil, DialContext: (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
		TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}, TLSHandshakeTimeout: 10 * time.Second,
		ResponseHeaderTimeout: 15 * time.Second, DisableCompression: true}
	defer transport.CloseIdleConnections()
	return upload(ctx, signedURL, origin, source, expected, limits, transport)
}
func upload(ctx context.Context, signedURL, origin, source, expected string, limits Limits, transport http.RoundTripper) (Result, error) {
	if !limits.valid() {
		return Result{}, ErrInvalid
	}
	u, e := url.Parse(signedURL)
	if e != nil {
		return Result{}, ErrTransfer
	}
	base, e := url.Parse(origin)
	if e != nil {
		return Result{}, ErrTransfer
	}
	if u.Scheme != "https" || base.Scheme != "https" || u.Host == "" || u.Host != base.Host || u.User != nil || base.User != nil || u.Fragment != "" || base.Fragment != "" || base.RawQuery != "" || (base.Path != "" && base.Path != "/") {
		return Result{}, ErrTransfer
	}
	ctx, cancel := context.WithTimeout(ctx, time.Duration(limits.TimeoutSeconds)*time.Second)
	defer cancel()
	file, e := os.Open(source)
	if e != nil {
		return Result{}, ErrTransfer
	}
	defer file.Close()
	info, e := file.Stat()
	if e != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > limits.CipherBytes {
		return Result{}, ErrTransfer
	}
	hash := sha256.New()
	n, e := io.Copy(hash, &contextReader{ctx, io.LimitReader(file, limits.CipherBytes+1)})
	if e != nil || n != info.Size() || hex.EncodeToString(hash.Sum(nil)) != expected {
		return Result{}, ErrAuthentication
	}
	if _, e = file.Seek(0, 0); e != nil {
		return Result{}, ErrTransfer
	}
	request, e := http.NewRequestWithContext(ctx, http.MethodPut, u.String(), io.LimitReader(file, n))
	if e != nil {
		return Result{}, ErrTransfer
	}
	request.ContentLength = n
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, e := client.Do(request)
	if e != nil {
		return Result{}, ErrTransfer
	}
	defer response.Body.Close()
	if response.StatusCode != 200 && response.StatusCode != 204 {
		return Result{}, ErrTransfer
	}
	return Result{SHA256: expected, Bytes: n}, nil
}
