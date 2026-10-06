package app

func (cfg Config) dataDirectory() string {
	return firstNonEmpty(cfg.dataDir, "data")
}
