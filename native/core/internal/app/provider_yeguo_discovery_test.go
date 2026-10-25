package app

import (
	"context"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

const yeguoDiscoveryPage = `<script type="module" src="/_nuxt/entry.js"></script>
<script type="application/json" id="__NUXT_DATA__">[{"apiBaseURL":1},"https://www.yeguodj.com/api.php"]</script>`
const yeguoDiscoveryEntry = `import {config} from "./config.js";`
const yeguoDiscoveryConfig = `const config = {version:"v0",mode:"CBC",padding:"Pkcs7",key:"0123456789abcdef",iv:"abcdef0123456789",sign_key:"fixture-sign"};`

func TestYeguoDiscoveryFindsRuntimeBaseWithoutNuxtField(t *testing.T) {
	var requests []string
	d := rankingTestDownloader(t, func(r *http.Request) (*http.Response, error) {
		requests = append(requests, r.URL.Path)
		body := ""
		switch r.URL.Path {
		case "/":
			body = `<script type="module" src="/_nuxt/entry.js"></script><script id="__NUXT_DATA__">[{"state":1},{}]</script>`
		case "/_nuxt/entry.js":
			body = "const __vite__mapDeps=[];import {config} from './config.js';import {a,b} from './client.js';import {x} from 'https://other.callawtj.cc/_nuxt/cross.js';"
		case "/_nuxt/config.js":
			body = yeguoDiscoveryConfig
		case "/_nuxt/client.js":
			body = "const runtime=()=>`https://www.yeguodj.com/api.php`;function request(e){return fetch(e,{baseURL:runtime(),method:'POST'})}"
		default:
			t.Errorf("discovery escaped its line: %s", r.URL.Path)
		}
		return rankingHTTPResponse(r, 200, body), nil
	})
	access, err := d.yeguoClient().discoverConfigurationAt(context.Background(), yeguoBaseURL)
	if err != nil || access.base != "https://www.yeguodj.com/api.php" || len(access.key) != 16 {
		t.Fatal("current runtime configuration was not discovered", err)
	}
	if !reflect.DeepEqual(requests, []string{"/", "/_nuxt/entry.js", "/_nuxt/config.js", "/_nuxt/client.js"}) {
		t.Fatal("unexpected module discovery requests", requests)
	}
}

func TestYeguoRuntimeBaseRequiresKnownAPIHostAndClientReference(t *testing.T) {
	for _, script := range []string{
		`const x=()=>"https://outside.example.org/api.php";fetch(a,{baseURL:x()})`,
		`const x=()=>"https://www.yeguodj.com.evil.test/api.php";fetch(a,{baseURL:x()})`,
		`const x=()=>"https://user@www.yeguodj.com/api.php";fetch(a,{baseURL:x()})`,
		`const x=()=>"https://www.yeguodj.com/api.php";fetch(a,{baseURL:other()})`,
		"const x=()=>`https://${host}/api.php`;fetch(a,{baseURL:x()})",
	} {
		if yeguoRuntimeAPIBase(script) != "" {
			t.Error("invalid runtime base accepted")
		}
	}
}

func TestYeguoCurrentContentRoutesStayAllowlisted(t *testing.T) {
	for _, site := range []string{
		"https://analyze.callawtj.cc", "https://backup.fzchosdi.cc", "https://old.buxefaex.cc",
	} {
		if validYeguoSite(site) != site || !isYeguoActiveSite(site) || providerSourceForURL(site) != sourceYeguo {
			t.Errorf("content route was not recognized: %s", site)
		}
	}
	for _, site := range []string{
		"https://adviser.ocdjlxow.cc", "https://callawtj.cc.example.org", "https://notcallawtj.cc",
		"https://analyze.callawtj.cc@outside.example.org", "https://analyze.callawtj.cc/?next=1",
	} {
		if validYeguoSite(site) != "" {
			t.Errorf("unexpected route accepted: %s", site)
		}
	}
	sites := yeguoTransitSites(`<a href="https://adviser.ocdjlxow.cc/">广告</a>
<a href="https://fresh.callawtj.cc/">线路</a>
<script>words = 'analyze'.split(','); line = words.random() + '.callawtj.cc'; backup = words.random() + '.fzchosdi.cc';</script>`)
	want := []string{"https://fresh.callawtj.cc", "https://analyze.callawtj.cc", "https://analyze.fzchosdi.cc"}
	if !reflect.DeepEqual(sites, want) {
		t.Fatalf("unexpected content routes: %v, want %v", sites, want)
	}
}

func TestYeguoDiscoveryDoesNotRehostTransitOrConfiguration(t *testing.T) {
	const site = "https://backup.fzchosdi.cc"
	var requests []string
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		requests = append(requests, request.URL.String())
		body := "<html>发布页</html>"
		switch request.URL.String() {
		case yeguoTransitURL + "/":
			body = `<a href="` + site + `/">线路</a>`
		case site + "/":
			body = yeguoDiscoveryPage
		case site + "/_nuxt/entry.js":
			body = yeguoDiscoveryEntry
		case site + "/_nuxt/config.js":
			body = yeguoDiscoveryConfig
		}
		return rankingHTTPResponse(request, http.StatusOK, body), nil
	})
	d.cfg.YeguoURL = "https://configured.buxefaex.cc"
	d.cfg.YeguoAPIURL = "https://custom-api.example.org/api.php"
	d.providerHosts[sourceYeguo] = "https://preferred.buxefaex.cc"
	client := d.yeguoClient()
	if routes := client.discoverTransitSites(context.Background()); !reflect.DeepEqual(routes, []string{site}) {
		t.Fatalf("transit was replaced by the cached content host: %v", routes)
	}
	d.providerHosts[sourceYeguo] = yeguoTransitURL
	access, err := client.discoverConfigurationAt(context.Background(), site)
	if err != nil {
		t.Fatal(err)
	}
	if access.site != site || access.base != d.cfg.YeguoAPIURL || len(access.key) != 16 || len(access.iv) != 16 {
		t.Fatalf("configuration or custom API endpoint changed: %+v", access)
	}
	want := []string{yeguoTransitURL + "/", site + "/", site + "/_nuxt/entry.js", site + "/_nuxt/config.js"}
	if !reflect.DeepEqual(requests, want) {
		t.Fatalf("discovery rehosted an explicit URL: %v, want %v", requests, want)
	}
}

func TestYeguoConfigurationFallsBackToCurrentTransitRoute(t *testing.T) {
	const site = "https://fresh.callawtj.cc"
	var requests []string
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		requests = append(requests, request.URL.String())
		body := "<html>旧线路已失效</html>"
		switch request.URL.String() {
		case yeguoTransitURL + "/":
			body = `<a href="` + site + `/">线路</a>`
		case site + "/":
			body = yeguoDiscoveryPage
		case site + "/_nuxt/entry.js":
			body = yeguoDiscoveryEntry
		case site + "/_nuxt/config.js":
			body = yeguoDiscoveryConfig
		}
		return rankingHTTPResponse(request, http.StatusOK, body), nil
	})
	access, err := d.yeguoClient().configuration(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if access.site != site || access.base != "https://www.yeguodj.com/api.php" {
		t.Fatalf("wrong discovered configuration: %+v", access)
	}
	if len(requests) != 5 || requests[0] != yeguoBaseURL+"/" || requests[1] != yeguoTransitURL+"/" {
		t.Fatalf("unexpected discovery requests: %s", strings.Join(requests, ", "))
	}
}
