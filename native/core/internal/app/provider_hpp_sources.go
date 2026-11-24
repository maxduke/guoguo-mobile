package app

const hppRevision = "017ff9289fdbdde31b2116e2655b203c027db45c"

type hppSource struct {
	file   string
	home   string
	hash   string
	search bool
}

var hppSources = map[string]hppSource{
	"bfzy":      {"bfzy.source", "https://bfzyapi.com/", "04835ec4bac1cf05d11bddcfa365c919aae24628ab68d81ed403eca28ab25cf2", true},
	"tangxin":   {"tangxin.vlog", "https://tangxinvlog.app/", "fc00b01f7d356964af56ca3a977c403b14a13786d3679c0bd383d662202d8ade", true},
	"av321":     {"av321.source", "https://321av.art/", "e4d3312bd539c365b4ae474943af699a5fce33dcec49c448a7f11375328b9d69", true},
	"hanime16":  {"hanime16.source", "https://www.hanime16.com/", "abd7e07370bbf3e544a0d7b479c2bb696045018cc46c12183887633f43719a90", true},
	"hlws":      {"hlws.source", "https://51hlws.com/", "4e5390c2294f923a56601b5ce2910dcce99b5f33c18a2cb4be5cc85c120c1a40", true},
	"jisu":      {"jisu.source", "https://jisuzhuiju.com/", "5b0fb081d86de26a9f2675ba4c87cbda06f9ba144051a3817c1802891e22e45e", true},
	"kxyy":      {"kxyy.source", "https://www.kxyy1.cc/", "44c40deb7c76561e3af3791d33c8b8e4d1cbc123eafd71e2bcbdb94d00a5fb87", true},
	"auete":     {"auete.source", "https://www.aeete.com/", "1edad3058830b5b3180cd0ee89a6260a2faaed9b26af92b47a72b8a422aaa351", false},
	"netflixgc": {"netflixgc.source", "https://www.netflixgc.com/", "cff875ad972fb635c4a3b856b50ab16416c556b667e1c39404f61470fffc18be", true},
	"cg91":      {"cg91.source", "https://www.91cg1.com/", "408e5c012e7d7e383daa2c86456994cf682009a11d24ac171c5dc9f358df6a39", true},
	"av591":     {"av591.source", "https://591av.ws/", "4f965f926787ed52c8671e1944b9bc31a0da26264703823c0d6474d8cfc243a8", true},
	"yingxi":    {"yingxi.source", "https://yingxivod.com/", "8d4f435bd040fb2c6313aa6978ff4780e1228169704817191d8bb411fe906f5e", true},
	"heiliao":   {"heiliao.source", "https://heiliao.com/", "11eceb4b27f6fd26ecc0446ef4019ae9ba9f256c89be70b689d8743d25eae10e", true},
	"hl365":     {"hl365.source", "https://hl365.com/", "8af731122e458c17b75b3438c3a402f6d7793d767902d62ed6df58ed40f36065", true},
	"pianku":    {"pianku.source", "https://4k01.pianku.online/", "1824019817ebe98d772b2bba86bf953eaa17ab0d6197c4a60d13296dab7e7576", true},
	"dpw":       {"dpw.source", "https://www.77dpw.vip/", "d37f992ed2201582292e7e13182dd00d583d08f73c931d4652b77ecd9b2c73dd", false},
	"lovebox":   {"lovebox.source", "https://lovebox.xm0108.lol/", "48f3389b61c5bcacb1998fcc81b6781046bae55959241771f1aa1cce1d2d9ca7", true},
}
