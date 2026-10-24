package app

type mobileSourceCapability struct {
	Source            string `json:"source"`
	Categories        bool   `json:"categories"`
	Search            bool   `json:"search"`
	SearchScope       string `json:"searchScope"`
	BackgroundCatalog bool   `json:"backgroundCatalog"`
}

func (c *MobileClient) sourceCapabilities() []mobileSourceCapability {
	sources := []string{sourceHongguo, "huangguo", sourceHuangdou, sourceHuangju, sourceYeguo, sourceDSD, sourceYaguo, sourceMaoguo, sourceFanguo, sourceGuanguo, sourceHeguo, sourceXingguo, sourceHuaguo, sourceNiuguo, sourcePiguo, sourceWuguo, sourceChaoguo, sourceMiguo, sourceShuangguo}
	items := make([]mobileSourceCapability, 0, len(sources))
	for _, source := range sources {
		_, categories := c.downloader.mobileSource(source)
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
		items = append(items, mobileSourceCapability{Source: source, Categories: categories, Search: search, SearchScope: scope, BackgroundCatalog: categories})
	}
	return items
}
