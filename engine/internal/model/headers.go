package model

import (
	"errors"
	"net/http"
	"strings"

	"golang.org/x/net/http/httpguts"
)

// ValidateHeaders accepts extension headers without allowing them to replace
// credentials or the protocol headers owned by the selected adapter.
func ValidateHeaders(headers map[string]string) error {
	for name, value := range headers {
		if !httpguts.ValidHeaderFieldName(name) || !httpguts.ValidHeaderFieldValue(value) {
			return errors.New("自定义请求头包含无效名称或值")
		}
		switch strings.ToLower(name) {
		case "authorization", "proxy-authorization", "x-api-key", "x-goog-api-key",
			"host", "content-type", "accept", "content-length", "connection",
			"transfer-encoding", "trailer", "te", "upgrade", "keep-alive", "proxy-connection", "cookie", "set-cookie":
			return errors.New("自定义请求头不能覆盖鉴权、内容类型或连接控制字段，请使用 API Key 设置鉴权")
		}
	}
	return nil
}

// withHeaders clones the request so callers may safely reuse their client and
// map across concurrent completions. Credentials remain the adapter's headers.
func withHeaders(req *http.Request, headers map[string]string) *http.Request {
	if len(headers) == 0 {
		return req
	}
	clone := req.Clone(req.Context())
	for name, value := range headers {
		clone.Header.Set(name, value)
	}
	return clone
}
