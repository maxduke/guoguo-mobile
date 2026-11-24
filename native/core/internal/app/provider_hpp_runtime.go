package app

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/andybalholm/cascadia"
	"github.com/dop251/goja"
	"golang.org/x/net/html"
	"golang.org/x/net/publicsuffix"
)

type hppProgram struct {
	lock chan struct{}
	code *goja.Program
}

var hppPrograms sync.Map

const hppProgramLimit = 256 << 10

func (d *Downloader) hppProgram(ctx context.Context, source hppSource) (*goja.Program, error) {
	item, _ := hppPrograms.LoadOrStore(source.file, &hppProgram{lock: make(chan struct{}, 1)})
	entry := item.(*hppProgram)
	select {
	case entry.lock <- struct{}{}:
		defer func() { <-entry.lock }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	if entry.code != nil {
		return entry.code, nil
	}
	path := filepath.Join(d.cfg.dataDirectory(), "hpp-"+source.file+".js")
	var raw []byte
	if file, err := os.Open(path); err == nil {
		raw, _ = readHPPProgram(file, source)
		file.Close()
	}
	fromCache := raw != nil
	if !fromCache {
		var err error
		raw, err = d.downloadHPPProgram(ctx, source)
		if err != nil {
			return nil, err
		}
	}
	code, err := compileHPP(source.file, string(raw))
	if err != nil {
		return nil, errors.New("插件脚本与当前应用不兼容")
	}
	if !fromCache {
		cacheHPPProgram(path, raw)
	}
	entry.code = code
	return code, nil
}

func (d *Downloader) downloadHPPProgram(ctx context.Context, source hppSource) ([]byte, error) {
	ctx = context.WithValue(ctx, hppPublicRequestKey{}, true)
	file := "/plugins/" + source.file + ".js"
	client := *d.client
	client.Jar = nil
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	var lastErr error
	for _, address := range []string{
		"https://raw.githubusercontent.com/poisonhs/HGhub-Plugin/" + hppRevision + file,
		"https://cdn.jsdelivr.net/gh/poisonhs/HGhub-Plugin@" + hppRevision + file,
	} {
		raw, err := d.fetchHPPProgram(ctx, address, source, &client)
		if err == nil {
			return raw, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		lastErr = err
	}
	return nil, fmt.Errorf("插件脚本加载失败：%w", lastErr)
}

func (d *Downloader) fetchHPPProgram(ctx context.Context, address string, source hppSource, client *http.Client) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, errors.New("插件脚本地址无效")
	}
	resp, err := d.doPreparedCatalogRequestWithClient(request, 8*time.Second, nil, client)
	if err != nil {
		return nil, hppNetworkError(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("插件脚本服务器 HTTP %d", resp.StatusCode)
	}
	return readHPPProgram(resp.Body, source)
}

func readHPPProgram(reader io.Reader, source hppSource) ([]byte, error) {
	raw, err := io.ReadAll(io.LimitReader(reader, hppProgramLimit+1))
	if err != nil || len(raw) > hppProgramLimit {
		return nil, errors.New("插件脚本读取失败或过大")
	}
	if fmt.Sprintf("%x", sha256.Sum256(raw)) != source.hash {
		return nil, errors.New("插件脚本校验失败")
	}
	return raw, nil
}

func cacheHPPProgram(path string, raw []byte) {
	file, err := os.CreateTemp(filepath.Dir(path), ".hpp-*.tmp")
	if err != nil {
		return
	}
	defer os.Remove(file.Name())
	_, writeErr := file.Write(raw)
	closeErr := file.Close()
	if writeErr == nil && closeErr == nil {
		_ = os.Rename(file.Name(), path)
	}
}

// The pinned single-file plugins export one manifest and one factory.
func compileHPP(name, script string) (*goja.Program, error) {
	const manifest = "export const meta"
	const factory = "export default "
	if strings.Count(script, manifest) != 1 || strings.Count(script, factory) != 1 {
		return nil, errors.New("插件声明不完整")
	}
	script = strings.Replace(script, manifest, "const meta", 1)
	script = strings.Replace(script, factory, "const factory = ", 1)
	return goja.Compile(name, "'use strict';\n"+script+"\n;({ meta, factory })", true)
}

type hppInvocation struct {
	ctx          context.Context
	vm           *goja.Runtime
	api          *goja.Object
	client       http.Client
	d            *Downloader
	scriptID     string
	calls        int
	bytes        int
	denied       error
	requestError error
	mediaHeaders http.Header
}

func (d *Downloader) useHPP(ctx context.Context, source hppSource, action func(*hppInvocation) error) error {
	ctx, cancel := context.WithTimeout(ctx, 32*time.Second)
	defer cancel()
	program, err := d.hppProgram(ctx, source)
	if err != nil {
		traceUpdate(ctx, func(value *mobileDiagnostic) { value.SourceStage = "plugin_script" })
		return err
	}
	return d.useHPPProgram(ctx, source, program, action)
}

func (d *Downloader) useHPPProgram(ctx context.Context, source hppSource, program *goja.Program, action func(*hppInvocation) error) error {
	vm := goja.New()
	vm.SetMaxCallStackSize(256)
	stop := context.AfterFunc(ctx, func() { vm.Interrupt("插件请求已取消或超时") })
	defer stop()
	work := &hppInvocation{ctx: ctx, vm: vm, d: d, scriptID: source.file, client: *d.client}
	work.client.Jar, _ = cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
	work.client.CheckRedirect = func(request *http.Request, previous []*http.Request) error {
		if len(previous) >= 4 || !validImageURL(request.URL) ||
			providerMediaOrigin(request.URL) != providerMediaOrigin(previous[0].URL) {
			return http.ErrUseLastResponse
		}
		return nil
	}
	work.installGlobals()
	module, err := vm.RunProgram(program)
	if err != nil {
		return errors.New("插件初始化失败")
	}
	obj := module.ToObject(vm)
	meta := obj.Get("meta").ToObject(vm)
	factory, ok := goja.AssertFunction(obj.Get("factory"))
	if !ok || meta.Get("id").String() != source.file || meta.Get("protocol").ToInteger() != 1 {
		return errors.New("插件身份或协议不匹配")
	}
	work.mediaHeaders = make(http.Header)
	if header, ok := meta.Get("defaultHeaders").(*goja.Object); ok {
		for _, name := range header.Keys() {
			switch http.CanonicalHeaderKey(name) {
			case "Referer", "User-Agent":
				work.mediaHeaders.Set(name, header.Get(name).String())
			}
		}
	}
	api, err := factory(goja.Undefined(), work.host())
	if err != nil || goja.IsUndefined(api) || goja.IsNull(api) {
		return errors.New("插件初始化失败")
	}
	work.api = api.ToObject(vm)
	err = action(work)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return err
}

func (p *hppInvocation) call(group, name string, params map[string]any, out any) error {
	category := p.api.Get(group)
	if category == nil || goja.IsNull(category) || goja.IsUndefined(category) {
		return errors.New("插件暂未提供此功能")
	}
	object := category.ToObject(p.vm)
	method, ok := goja.AssertFunction(object.Get(name))
	if !ok {
		return errors.New("插件暂未提供此功能")
	}
	p.requestError = nil
	result, err := method(object, p.vm.ToValue(params), p.vm.NewObject())
	if p.denied != nil {
		return p.denied
	}
	if err != nil {
		if p.requestError != nil {
			return p.requestError
		}
		return errors.New("站源读取失败，请稍后重试")
	}
	if promise, ok := result.Export().(*goja.Promise); ok {
		if promise.State() != goja.PromiseStateFulfilled {
			if p.requestError != nil {
				return p.requestError
			}
			if promise.State() == goja.PromiseStateRejected {
				if value, ok := promise.Result().(*goja.Object); ok {
					if code := value.Get("code"); code != nil {
						switch code.String() {
						case "NOT_FOUND":
							return errors.New("站源未找到该作品或分集")
						case "CONTENT_LOCKED":
							return errors.New("站源未提供可用的公开播放地址")
						case "UPSTREAM_CHANGED":
							return errors.New("站源返回的数据结构已变化")
						case "INVALID_ARGUMENT":
							return errors.New("站源不接受该查询或分集标识")
						}
					}
				}
			}
			return errors.New("站源暂未返回可用结果")
		}
		result = promise.Result()
	}
	jsonObject := p.vm.Get("JSON").ToObject(p.vm)
	stringify, _ := goja.AssertFunction(jsonObject.Get("stringify"))
	encoded, err := stringify(jsonObject, result)
	if err != nil || goja.IsUndefined(encoded) {
		return errors.New("插件响应格式无效")
	}
	raw := encoded.String()
	if len(raw) > 4<<20 || json.Unmarshal([]byte(raw), out) != nil {
		return errors.New("插件响应格式无效")
	}
	return nil
}

func hppBase64(raw string) ([]byte, error) {
	raw = strings.Map(func(r rune) rune {
		switch r {
		case ' ', '\r', '\n', '\t':
			return -1
		case '-':
			return '+'
		case '_':
			return '/'
		}
		return r
	}, raw)
	return base64.RawStdEncoding.DecodeString(strings.TrimRight(raw, "="))
}

func (p *hppInvocation) installGlobals() {
	vm := p.vm
	vm.Set("atob", func(value string) string {
		raw, err := hppBase64(value)
		if err != nil {
			panic(vm.NewTypeError("Base64 无效"))
		}
		chars := make([]rune, len(raw))
		for i, ch := range raw {
			chars[i] = rune(ch)
		}
		return string(chars)
	})
	vm.Set("URL", func(call goja.ConstructorCall) *goja.Object {
		u, err := url.Parse(call.Argument(0).String())
		if err == nil && !u.IsAbs() && len(call.Arguments) > 1 {
			base, parseErr := url.Parse(call.Argument(1).String())
			if parseErr == nil {
				u = base.ResolveReference(u)
			}
		}
		if err != nil || !u.IsAbs() {
			panic(vm.NewTypeError("URL 无效"))
		}
		call.This.Set("href", u.String())
		call.This.Set("hostname", u.Hostname())
		call.This.Set("pathname", u.Path)
		call.This.Set("toString", func() string { return u.String() })
		call.This.Set("searchParams", map[string]any{"get": func(key string) any {
			if !u.Query().Has(key) {
				return nil
			}
			return u.Query().Get(key)
		}})
		return nil
	})
}

func (p *hppInvocation) host() *goja.Object {
	vm := p.vm
	host := vm.NewObject()
	errorConstructor, _ := goja.AssertFunction(vm.Get("Error"))
	host.Set("PluginError", func(call goja.ConstructorCall) *goja.Object {
		value, _ := errorConstructor(goja.Undefined(), call.Argument(1))
		obj := value.ToObject(vm)
		obj.Set("code", call.Argument(0))
		return obj
	})
	host.Set("http", map[string]any{"fetch": p.fetch})
	host.Set("html", map[string]any{"parse": func(raw string) goja.Value {
		node, err := html.Parse(strings.NewReader(raw))
		if err != nil {
			panic(vm.NewTypeError("HTML 无效"))
		}
		return p.node(node)
	}})
	store := map[string]goja.Value{}
	resolved := func(value goja.Value) goja.Value {
		promise, resolve, _ := vm.NewPromise()
		_ = resolve(value)
		return vm.ToValue(promise)
	}
	host.Set("storage", map[string]any{
		"get": func(key string) goja.Value {
			if value := store[key]; value != nil {
				return resolved(value)
			}
			return resolved(goja.Undefined())
		},
		"set": func(key string, value goja.Value) goja.Value {
			if len(store) < 32 {
				store[key] = value
			}
			return resolved(goja.Undefined())
		},
		"delete": func(key string) goja.Value {
			delete(store, key)
			return resolved(goja.Undefined())
		},
	})
	host.Set("log", map[string]any{"info": func(string) {}, "warn": func(string) {}})
	host.Set("codec", map[string]any{
		"base64Decode": func(raw string) goja.Value {
			bytes, err := hppBase64(raw)
			if err != nil {
				panic(vm.NewTypeError("Base64 无效"))
			}
			constructor, _ := goja.AssertConstructor(vm.Get("Uint8Array"))
			array, _ := constructor(nil, vm.ToValue(vm.NewArrayBuffer(bytes)))
			return array
		},
		"utf8Decode": func(bytes []byte) string { return string(bytes) },
	})
	return host
}

func (p *hppInvocation) node(node *html.Node) goja.Value {
	if node == nil {
		return goja.Null()
	}
	obj := p.vm.NewObject()
	obj.Set("attr", func(key string) any {
		for _, item := range node.Attr {
			if item.Key == key {
				return item.Val
			}
		}
		return nil
	})
	obj.Set("text", func() string {
		var out strings.Builder
		for _, text := range providerHTMLNodes(node, func(n *html.Node) bool { return n.Type == html.TextNode }) {
			out.WriteString(text.Data)
		}
		return out.String()
	})
	obj.Set("html", func() string {
		var out strings.Builder
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			_ = html.Render(&out, child)
		}
		return out.String()
	})
	obj.Set("parent", func() goja.Value { return p.node(node.Parent) })
	obj.Set("first", func(query string) goja.Value {
		selector, err := cascadia.ParseGroup(query)
		if err != nil {
			return goja.Null()
		}
		return p.node(cascadia.Query(node, selector))
	})
	obj.Set("select", func(query string) *goja.Object {
		selector, err := cascadia.ParseGroup(query)
		if err != nil {
			return p.vm.NewArray()
		}
		results := cascadia.QueryAll(node, selector)
		values := make([]any, 0, min(2048, len(results)))
		for _, result := range results[:min(2048, len(results))] {
			values = append(values, p.node(result))
		}
		return p.vm.NewArray(values...)
	})
	return obj
}
