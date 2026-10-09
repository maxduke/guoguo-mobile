package app

import (
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/net/html"
)

var maccmsPagePath = regexp.MustCompile(`(?i)/page/([0-9]+)|-([0-9]+)---\.html`)

func maccmsHasMore(document *html.Node, page, count int) bool {
	if count == 0 {
		return false
	}
	containers := providerHTMLNodes(document, func(node *html.Node) bool {
		for _, name := range []string{"pagination", "page", "module-page", "stui-page", "myui-page", "page-nav", "pagebox"} {
			if providerHTMLClass(node, name) {
				return true
			}
		}
		return false
	})
	if len(containers) == 0 {
		return true
	}
	for _, container := range containers {
		for _, anchor := range providerHTMLNodes(container, func(node *html.Node) bool { return node.Data == "a" }) {
			link := providerHTMLAttr(anchor, "href")
			if link == "" || link == "#" || providerHTMLClass(anchor, "disabled") || providerHTMLClass(anchor.Parent, "disabled") {
				continue
			}
			parsed, err := url.Parse(link)
			if err != nil {
				continue
			}
			if next, _ := strconv.Atoi(parsed.Query().Get("page")); next > page {
				return true
			}
			for _, match := range maccmsPagePath.FindAllStringSubmatch(parsed.Path, -1) {
				if next, _ := strconv.Atoi(firstNonEmpty(match[1], match[2])); next > page {
					return true
				}
			}
			text := providerHTMLText(anchor)
			if strings.Contains(text, "下一") || strings.EqualFold(providerHTMLAttr(anchor, "rel"), "next") {
				if !strings.HasPrefix(link, "javascript:") {
					return true
				}
			}
		}
	}
	return false
}
