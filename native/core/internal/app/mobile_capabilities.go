package app

import "sort"

type mobileSourceCapability struct {
	Source            string `json:"source"`
	Categories        bool   `json:"categories"`
	Search            bool   `json:"search"`
	SearchScope       string `json:"searchScope"`
	BackgroundCatalog bool   `json:"backgroundCatalog"`
	Plugin            bool   `json:"plugin,omitempty"`
}

func (c *MobileClient) sourceCapabilities() []mobileSourceCapability {
	sources := []string{sourceHongguo, "huangguo", sourceHuangdou, sourceHuangju, sourceYeguo, sourceDSD, sourceYaguo, sourceMaoguo, sourceFanguo, sourceGuanguo, sourceHeguo, sourceXingguo, sourceHuaguo, sourceNiuguo, sourcePiguo, sourceWuguo, sourceChaoguo, sourceMiguo, sourceShuangguo, sourceDbku}
	items := make([]mobileSourceCapability, 0, len(sources))
	for _, source := range sources {
		_, categories := c.downloader.mobileSource(source)
		background := categories
		categories = categories || source == "huangguo"
		search := source != sourceHuangdou
		if spec, found := duanjuSourcesByName[source]; found {
			search = spec.Searcher
		}
		scope := "online"
		if source == "huangguo" {
			scope = "huangguoai"
		} else if !search {
			scope = "local"
		}
		items = append(items, mobileSourceCapability{Source: source, Categories: categories, Search: search, SearchScope: scope, BackgroundCatalog: background})
	}
	names := make([]string, 0, len(hppSources))
	for name := range hppSources {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		search := hppSources[name].search
		scope := "local"
		if search {
			scope = "online"
		}
		items = append(items, mobileSourceCapability{Source: name, Categories: true, Search: search, SearchScope: scope, Plugin: true})
	}
	return items
}
