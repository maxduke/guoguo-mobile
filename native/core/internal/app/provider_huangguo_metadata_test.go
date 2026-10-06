package app

import (
	"fmt"
	"testing"
)

func TestHuangguoCatalogMergesRepairTitlesWithoutRegressingGoodData(t *testing.T) {
	broken := Drama{ID: "huangguoai:501", Source: sourceHuangguoAI, SourceID: "501", Title: "ata-search-input> 搜索记录 清除 暂无搜索记录", Name: "搜索", Remark: "新上架"}
	correct := Drama{ID: broken.ID, Source: sourceHuangguoAI, SourceID: broken.SourceID, Title: "正确剧名", Name: "正确剧名", TotalEpisode: 12, EpisodeCount: 12}
	for _, pair := range [][2]Drama{{broken, correct}, {correct, broken}} {
		result := mergeLoadedDramas([]Drama{pair[0]}, []Drama{pair[1]}, nil)
		if len(result) != 1 || result[0].Title != correct.Title || result[0].Name != correct.Name || fmt.Sprint(result[0].TotalEpisode) != "12" {
			t.Fatal("a catalog update kept or restored a corrupted title")
		}
	}
}

func TestHuangguoJSONCountsUseAvailableEpisodeFields(t *testing.T) {
	for _, row := range []map[string]any{
		{"id": "501", "title": "测试剧", "episode_count": 12, "total_episodes": 0, "remark": "新上架"},
		{"id": "501", "title": "测试剧", "episode_count": 0, "total_episodes": 12, "is_finished": true},
	} {
		drama, ok := dramaFromAIMap(row, huangguoAIBaseURL, "测试")
		if !ok || fmt.Sprint(drama.TotalEpisode) != "12" || fmt.Sprint(drama.EpisodeCount) != "12" {
			t.Fatal("available episode counts were dropped")
		}
	}
	for _, row := range []map[string]any{
		{"id": "501", "title": "测试剧", "episode_count": 0, "total_episodes": 0, "total_collect": 12},
		{"id": "501", "title": "测试剧", "episode_count": "1小时前"},
	} {
		drama, ok := dramaFromAIMap(row, huangguoAIBaseURL, "测试")
		if !ok || !valueEmpty(drama.TotalEpisode) || !valueEmpty(drama.EpisodeCount) {
			t.Fatal("invented episode counts from zero, time, or collections")
		}
	}
}

func TestHuangguoJSONCardsDoNotTreatAuthorsAsDramas(t *testing.T) {
	body := `{"data":{"items":[{"id":501,"title":"真实剧名","episode_count":12,"author":{"id":156291,"name":"作者名称"}},{"id":501,"title":"真实剧名","episode_count":12,"author":{"id":156292,"name":"另一作者"}}]}}`
	items := parseHuangguoAIJSONCards([]byte(body), huangguoAIBaseURL, "测试")
	if len(items) != 1 || items[0].ID != "huangguoai:501" || items[0].Title != "真实剧名" {
		t.Fatal("nested author metadata was imported as additional dramas")
	}
}
